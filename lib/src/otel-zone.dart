import 'dart:async';
import 'dart:io' show Directory;
import 'dart:isolate';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, NavigatorObserver;
import 'package:otel_go_router/otel_go_router.dart';
import 'package:otel_riverpod/otel_riverpod.dart';
import 'package:riverpod/riverpod.dart' show ProviderObserver;
import 'package:talker/talker.dart';

import 'bridge.dart';
import 'config.dart';
import 'native-crash.dart';
import 'otlp-exporter.dart';
import 'riverpod-arguments.dart';
import 'span-redaction.dart';
import 'spool.dart';

/// One `Talker`, one OpenTelemetry SDK, and one guarded zone that funnels
/// every uncaught error in the process into both.
///
/// Build it once, before `runApp`, and hold it somewhere the whole app can
/// reach:
///
/// ```dart
/// final OtelZone observability = OtelZone(
///   const OtelZoneConfig(
///     serviceName: 'my-app',
///     endpoint: 'http://localhost:4318',
///   ),
/// );
///
/// Future<void> main() => observability.runGuarded(() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await observability.start(serviceVersion: '1.2.3');
///   runApp(const MyApp());
/// });
/// ```
///
/// [talker] exists from the moment the object does, so anything that logs
/// before [start] — including [start]'s own failure — is recorded. Nothing
/// reaches the collector until [start] has succeeded.
class OtelZone {
  /// Creates the zone's `Talker` and its OTel bridge.
  ///
  /// Constructing this starts nothing and reaches no network. [start] does
  /// that, and has to, because most of what goes on the OTel resource can
  /// only be read once the Flutter binding exists.
  ///
  /// [talker] and [sink] are injection points for tests. A caller that
  /// supplies its own [talker] is responsible for having given it this
  /// object's [bridge] as an observer.
  ///
  /// [nativeCrashSource] is the previous run's crash reports. It defaults to
  /// the plugin's Pigeon channel, and is an injection point so the drain can
  /// be tested without a device.
  OtelZone(
    this.config, {
    Talker? talker,
    TalkerObserver? sink,
    NativeCrashSource? nativeCrashSource,
  }) : _nativeCrashSource = nativeCrashSource ?? PigeonNativeCrashSource() {
    bridge = OtelBridge(
      floor: config.exportFloor,
      // Read lazily: the trail is this object's own Talker, which does not
      // exist yet on the line below.
      history: () => this.talker.history,
      loggerName: config.loggerName,
      breadcrumbCount: config.breadcrumbCount,
      breadcrumbLineLimit: config.breadcrumbLineLimit,
      redact: config.redact,
      sink: sink,
    );
    this.talker =
        talker ??
        Talker(
          observer: bridge,
          settings: TalkerSettings(useConsoleLogs: config.useConsoleLogs),
        );
  }

  /// What this build was configured with.
  final OtelZoneConfig config;

  /// The one log and error sink. Everything in the app writes here.
  ///
  /// Records made inside a `Tracer.startActiveSpan` block inherit its trace
  /// and span ids, so a log lands correlated with the operation that
  /// produced it.
  late final Talker talker;

  /// The Talker-to-OpenTelemetry bridge, and the thing that decides what
  /// leaves the device.
  late final OtelBridge bridge;

  /// The lifecycle hook that flushes the batch queue before the OS may kill
  /// the process. `null` until the first [start], and stays `null` if there
  /// is no binding to attach it to.
  AppLifecycleListener? _lifecycle;

  final NativeCrashSource _nativeCrashSource;

  /// Whether the SDK came up. `false` before [start], and after a [start]
  /// that failed.
  bool get isReady => bridge.ready;

  /// Brings up the OpenTelemetry SDK and points it at
  /// [OtelZoneConfig.endpoint].
  ///
  /// Nothing in here waits on the collector: this is awaited before `runApp`,
  /// so a native crash recovered from the last run is written to the spool
  /// and acknowledged, and its delivery, like the replay, carries on in the
  /// background.
  ///
  /// **Never throws.** A phone with no route to the collector — the normal
  /// case on a bad connection, and the case on every developer machine
  /// without a collector running — must not be a phone that cannot open the
  /// app. A failure here is one warning on [talker] and an app that runs
  /// with local logging only.
  ///
  /// [serviceVersion] is `service.version`, and is an argument rather than
  /// a [config] field because it must be read back out of the *installed
  /// artifact* — `package_info_plus`'s `version` on a phone — and not
  /// hardcoded. Without it the SDK writes its own `'1.0.0'` default, which
  /// every build ever shipped then reports identically, and "is the running
  /// app the one with the fix in it" becomes unanswerable from the
  /// telemetry. It must not be empty: `OTel.initialize` throws
  /// `ArgumentError` on an empty version, and this method's own `catch`
  /// would swallow that into "telemetry is off" for the whole process.
  ///
  /// [buildId] is the semconv `app.build_id` — the other half of the same
  /// question, and the `app` entity's own identifying attribute. Two builds
  /// of one marketing version are told apart by this and nothing else.
  ///
  /// [resourceAttributes] is everything else that is fixed for the life of
  /// the process: the device model, the OS version, whatever else the
  /// caller knows. Resource attributes cannot be changed afterwards, so
  /// read them before calling this.
  Future<void> start({
    required String serviceVersion,
    String? buildId,
    Map<String, String> resourceAttributes = const <String, String>{},
  }) async {
    // The lifecycle hook is registered before the SDK is brought up, so that
    // a failed [start] still leaves the (no-op) flush in place rather than
    // silently changing the app's lifecycle wiring on a retry.
    _watchLifecycle();
    // Held outside the `try` so a failed start can shut it down: a batch
    // processor starts a timer when it is built.
    SpanProcessor? redactingSpans;
    try {
      // Resolved once, so the spool, its replay and the crash drain all send
      // what dartastic's own exporter would have sent. Built by hand, an
      // exporter sends no headers at all, and the crash path is the one that
      // must not lose its credentials.
      final Map<String, String> headers = resolveOtlpHeaders();
      LogRecordExporter newExporter() =>
          buildOtlpLogExporter(endpoint: config.endpoint, headers: headers);

      // Built before `initialize` so the pipeline is handed an exporter that
      // already knows where to spool. `null` leaves dartastic's own exporter
      // in place, which is what every build that does not opt in gets.
      final FutureOr<Directory> Function()? spoolDirectory =
          config.spoolDirectory;
      SpoolingLogRecordExporter? spool;
      if (spoolDirectory != null) {
        spool = SpoolingLogRecordExporter(
          delegate: newExporter(),
          directory: await spoolDirectory(),
          maxBatches: config.spoolMaxBatches,
          maxAge: config.spoolMaxAge,
          maxAttempts: config.spoolMaxAttempts,
          onWarning: talker.warning,
        );
      }
      // With a `redact`, spans need a pipeline of their own: dartastic offers
      // no way to put a scrubber in front of the exporter it builds. `null`
      // (no `redact`, or `OTEL_TRACES_EXPORTER=none`) leaves that one in
      // place, configured from the environment as before.
      final Redactor? redact = config.redact;
      if (redact != null) {
        redactingSpans = buildRedactingSpanProcessor(
          endpoint: config.endpoint,
          secure: config.secure,
          redact: redact,
          // Once. A redactor that always throws would otherwise warn per span.
          onDropped: (Object error) => talker.warning(
            'A span was dropped because redact threw '
            '(${error.runtimeType}); later drops are not reported.',
          ),
        );
      }
      await OTel.initialize(
        serviceName: config.serviceName,
        serviceVersion: serviceVersion,
        endpoint: config.endpoint,
        secure: config.secure,
        enableLogs: config.enableLogs,
        enableMetrics: config.enableMetrics,
        spanProcessor: redactingSpans,
        logRecordExporter: spool,
        resourceAttributes: OTel.attributesFromMap(<String, String>{
          ...resourceAttributes,
          App.appBuildId.key: ?buildId,
          'deployment.environment.name': ?config.deploymentEnvironmentName,
        }),
      );
      // `OTEL_SDK_DISABLED` makes `initialize` skip the trace pipeline, which
      // leaves the processor built above running its timer for nothing.
      final SpanProcessor? unused = redactingSpans;
      if (unused != null &&
          !OTel.tracerProvider().spanProcessors.contains(unused)) {
        unawaited(unused.shutdown().catchError((Object _) {}));
      }
      // Only now may the bridge forward: `OTel.loggerProvider()` throws
      // until initialize() has returned successfully.
      bridge.ready = true;

      // Recovered before the summary, so the line can report it. Only local
      // work is awaited: reports are written to the spool and acknowledged,
      // and delivery carries on after `start` has returned. Awaiting the
      // network here would put a crash report on a bad connection in front
      // of the app's first frame.
      int nativeCrashes = 0;
      if (config.enableLogs) {
        nativeCrashes = await NativeCrashDrain(
          source: _nativeCrashSource,
          exporter: spool ?? newExporter(),
          loggerName: config.loggerName,
          redact: config.redact,
          onWarning: talker.warning,
        ).drain();
      }

      final SpoolingLogRecordExporter? exporter = spool;
      if (exporter == null) {
        talker.warning(
          startupSummary(serviceVersion, buildId, nativeCrashes: nativeCrashes),
        );
      } else {
        // Replay reaches for the network, and `start` is awaited before
        // `runApp`, so it cannot be on that path. The summary does wait for
        // it: with spooling on, how much was replayed is the line's point.
        // Files the crash drain just wrote are being delivered already, and
        // the spool keeps replay from sending them a second time.
        unawaited(
          exporter
              .replay()
              .then(
                (int replayed) => talker.warning(
                  startupSummary(
                    serviceVersion,
                    buildId,
                    replayed: replayed,
                    nativeCrashes: nativeCrashes,
                  ),
                ),
              )
              .catchError((Object _) {
                talker.warning(
                  startupSummary(
                    serviceVersion,
                    buildId,
                    nativeCrashes: nativeCrashes,
                  ),
                );
              }),
        );
      }
    } on Object catch (error, stackTrace) {
      bridge.ready = false;
      final SpanProcessor? orphaned = redactingSpans;
      if (orphaned != null) {
        unawaited(orphaned.shutdown().catchError((Object _) {}));
      }
      // Deliberately a warning, not an error: nothing the user does is
      // affected, and an unreachable collector is an expected state, not a
      // fault. `talker.handle` here would also try to emit through the very
      // pipeline that just failed to start.
      talker.warning(
        'OpenTelemetry did not start (${config.endpoint}); '
        'logging locally only.',
        error,
        stackTrace,
      );
    }
  }

  /// The one line [start] logs on success.
  ///
  /// A build reporting under the wrong environment, or exporting far more
  /// or far less than intended, is then visible on the very first records
  /// rather than only once someone notices. The identity and the floor are
  /// in the same line because the two together are what decide whether a
  /// stream means what a dashboard thinks it means.
  ///
  /// Note the severity [start] uses: `warning`, not `info`. It is the one
  /// record that has to survive its own subject — at a shipped `warning`
  /// floor an `info` line would be withheld, and a build would then be
  /// unable to tell you why it is quiet.
  ///
  /// ```dart
  /// const config = OtelZoneConfig(
  ///   serviceName: 'my-app',
  ///   endpoint: 'https://otel.example.com',
  ///   deploymentEnvironmentName: 'production',
  /// );
  /// final zone = OtelZone(config, sink: RecordingTalkerObserver());
  /// zone.startupSummary('1.2.3', '48');
  /// // 'OpenTelemetry: exporting to https://otel.example.com as my-app '
  /// // '1.2.3 build 48 (production), records at warning and above'
  /// ```
  ///
  /// [replayed] is the count of spooled batches handed back to the collector
  /// on this launch, and is `null` when nothing is spooled. It is part of the
  /// line rather than a line of its own because "did the backlog drain" is
  /// answered by the same reader who asks "is this build exporting".
  ///
  /// [nativeCrashes] is the count of native deaths recovered from the previous
  /// run, and is likewise omitted when there were none.
  String startupSummary(
    String serviceVersion,
    String? buildId, {
    int? replayed,
    int? nativeCrashes,
  }) {
    final String environment = config.deploymentEnvironmentName == null
        ? ''
        : ' (${config.deploymentEnvironmentName})';
    final String build = buildId == null ? '' : ' build $buildId';
    final String recovered = nativeCrashes == null || nativeCrashes == 0
        ? ''
        : ', recovered $nativeCrashes native '
              '${nativeCrashes == 1 ? 'crash' : 'crashes'}';
    final String spooled = replayed == null
        ? ''
        : ', replayed $replayed spooled ${replayed == 1 ? 'batch' : 'batches'}';
    final String? unrecognised = config.exportFloor.unrecognised;
    return 'OpenTelemetry: exporting to ${config.endpoint} '
        'as ${config.serviceName} $serviceVersion$build$environment, '
        'records at ${config.exportFloor.level.name} and above'
        '$recovered$spooled'
        '${unrecognised == null ? '' : ' — the configured export level said '
                  '"$unrecognised", which is not a level; '
                  'fell back to ${config.exportFloor.level.name}'}';
  }

  /// Flushes the OpenTelemetry logs pipeline.
  ///
  /// The batch processor holds records in memory for its scheduled delay, so
  /// this is the one call that pushes a just-recorded fault towards the
  /// collector. The lifecycle hook below calls it; it is also safe to call
  /// on demand.
  ///
  /// Overridable so a test can count the flush without a live SDK — a real
  /// `LoggerProvider` has no call counter, and "flushed" and "did not flush"
  /// are otherwise indistinguishable from outside.
  @protected
  @visibleForTesting
  Future<void> flushLogs() => OTel.loggerProvider().forceFlush();

  /// Registers the one lifecycle hook this package needs: the moment the OS
  /// may kill a backgrounded process with records still queued.
  ///
  /// Best-effort by design. Without a Flutter binding there is nothing to
  /// attach to, and that must never be a reason [start] fails.
  void _watchLifecycle() {
    if (_lifecycle != null) return;
    try {
      _lifecycle = AppLifecycleListener(
        onPause: _flushBeforeBackground,
        onDetach: _flushBeforeBackground,
      );
    } on Object {
      // No binding or no lifecycle channel: local logging still works, and
      // telemetry must never be the reason an app cannot start.
    }
  }

  /// Fire-and-forget: a lifecycle callback must not block, and telemetry is
  /// never in the functional path. `safely` covers the SDK being down; the
  /// `catchError` covers the flush rejecting asynchronously.
  void _flushBeforeBackground() {
    safely(() {
      unawaited(flushLogs().catchError((Object _) {}));
    });
  }

  /// The single reporting entry point for an error the app caught itself.
  /// Safe to call from anywhere, including from inside an error handler.
  void reportError(Object error, StackTrace stackTrace, {String? context}) {
    talker.handle(error, stackTrace, context);
  }

  /// Runs [body] — which must include `WidgetsFlutterBinding.ensureInitialized()`
  /// *and* `runApp` — inside a guarded zone with every uncaught-error
  /// channel wired to [reportError].
  ///
  /// Flutter scatters those across four channels — `FlutterError.onError`
  /// for framework errors, `PlatformDispatcher.instance.onError` for errors
  /// that escape the engine's callbacks, the zone's own handler for
  /// uncaught async errors, and `Isolate.addErrorListener` for the root
  /// isolate. Each has a different default (some print, some are silently
  /// swallowed), so anything less than all four means a class of crash
  /// never reaches the logs.
  ///
  /// The binding has to be created inside this zone rather than before it:
  /// Flutter records the zone that created the binding and warns (and can
  /// mis-route errors) if `runApp` is later called from a different one.
  Future<void> runGuarded(Future<void> Function() body) async {
    // `runZonedGuarded` returns the body's own future, or `null` if the
    // zone died before it completed; awaiting it either way is what makes a
    // start-up failure surface here rather than as a silent blank screen.
    await runZonedGuarded<Future<void>>(
      () async {
        // Framework errors: build/layout/paint failures, failed assertions.
        final FlutterExceptionHandler? previousOnError = FlutterError.onError;
        FlutterError.onError = (FlutterErrorDetails details) {
          reportError(
            details.exception,
            details.stack ?? StackTrace.current,
            context: details.context?.toDescription(),
          );
          // `presentFlutterErrors` alone decides whether the red screen and
          // the console dump happen. Flutter's default `FlutterError.onError`
          // *is* `presentError`, so chaining to it unconditionally makes the
          // flag meaningless: it would present twice when on, and still once
          // when off.
          if (config.presentFlutterErrors) {
            FlutterError.presentError(details);
          }
          // A handler an app or plugin installed before `runGuarded` still
          // runs. Only the default is skipped, because `presentError` above
          // already does exactly what it would have done.
          if (!identical(previousOnError, FlutterError.presentError)) {
            previousOnError?.call(details);
          }
        };

        // Errors that escape an engine callback (gesture handlers, platform
        // channel replies) without passing through FlutterError. Chained, not
        // replaced: a handler installed before this point — by a plugin, or
        // by the app itself — otherwise silently stops running.
        final bool Function(Object, StackTrace)? previousPlatformOnError =
            PlatformDispatcher.instance.onError;
        PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
          reportError(error, stack, context: 'PlatformDispatcher');
          if (previousPlatformOnError != null) {
            // A previous handler that throws must not cost the report above,
            // nor propagate out of the engine callback.
            try {
              previousPlatformOnError(error, stack);
            } on Object {
              // Deliberately swallowed: the report has already been made.
            }
          }
          // `true` = handled; without it the engine also prints it, which
          // would double every record.
          return true;
        };

        _listenForRootIsolateErrors();

        await body();
      },
      (Object error, StackTrace stack) =>
          reportError(error, stack, context: 'Uncaught zone error'),
    );
  }

  /// Errors thrown on the root isolate outside any zone — e.g. from a
  /// platform-channel handler registered by a plugin.
  ///
  /// The port delivers `[String error, String stackTrace]`, already
  /// stringified, because an arbitrary error object may not be sendable
  /// across an isolate boundary.
  void _listenForRootIsolateErrors() {
    final ReceivePort port = ReceivePort()
      ..listen((dynamic pair) {
        if (pair is! List || pair.length < 2) return;
        reportError(
          pair.first?.toString() ?? 'Unknown isolate error',
          StackTrace.fromString(pair.last?.toString() ?? ''),
          context: 'Root isolate',
        );
      });
    Isolate.current.addErrorListener(port.sendPort);
  }

  /// Runs [emit] only if OpenTelemetry is up, and never lets it throw.
  ///
  /// Every dartastic instrumentation entry point resolves its tracer or
  /// context eagerly — `OTel.tracerProvider()`, `Context.current.span` —
  /// and throws `StateError: OTel.initialize() must be called first` when
  /// the SDK is absent. Unguarded, that propagates out of whatever callback
  /// it was in: it has taken down a connectivity subscription (leaving an
  /// app permanently unable to notice the network returning) and silently
  /// stopped a secure-storage write.
  ///
  /// The rule this encodes: **instrumentation is never in the functional
  /// path.** A telemetry call that fails costs a span, never a feature.
  void safely(void Function() emit) {
    if (!bridge.ready) return;
    try {
      emit();
    } on Object {
      // Not reported through the talker: the talker's own observer feeds
      // the same pipeline, so reporting a telemetry failure through
      // telemetry is how you get a loop.
    }
  }

  /// The OTel Riverpod `ProviderObserver`, or `null` when OTel is not
  /// running.
  ///
  /// Both observers below are built lazily, and only when [isReady],
  /// because each captures a `Tracer` *at construction* via
  /// `OTel.tracerProvider()`. Constructing one eagerly would turn "no
  /// collector on this network" into "the app does not start".
  ///
  /// **What the spans carry.** Each provider event is a span with the
  /// provider's name, runtime type, family and the value's runtime type. A
  /// failed provider adds the error's message and stack trace as an exception
  /// event and as the status description. Those go through
  /// [OtelZoneConfig.redact] when one is configured, like every other span.
  ///
  /// [recordValues] stays off by default: provider state is where an app's
  /// own data lives — orders, phone numbers, identity drafts — and this
  /// leaves the device. Off, the value's `toString()` and the previous
  /// value's are not recorded; on, they are (scrubbed by `redact`, and cut at
  /// 256 characters).
  ///
  /// [recordArguments] stays off by default for the same reason. A family
  /// provider's argument is often what a user typed — a search query, a
  /// phone number, a coordinate — and `otel_riverpod` 0.2.0 records its
  /// `toString()` as `riverpod.provider.argument` on every span, whatever
  /// [recordValues] says. A keyed mutation's `toString()` carries its key the
  /// same way, as `riverpod.mutation`
  /// (`Mutation<int>#d9771(<key>, label: addToCart)`). Off, this observer
  /// drops both attributes before the span ends. On, they are recorded and
  /// `redact` is the only thing between them and the collector; `redact` is
  /// best-effort pattern matching, so prefer leaving it off. Only the spans of
  /// the observer this returns are affected.
  ProviderObserver? riverpodObserver({
    bool recordValues = false,
    bool recordArguments = false,
  }) {
    if (!bridge.ready) return null;
    try {
      final ProviderObserver observer = OTelRiverpodObserver(
        recordValues: recordValues,
      );
      return recordArguments ? observer : withoutProviderArguments(observer);
    } on Object catch (error) {
      talker.warning('OTel Riverpod instrumentation unavailable', error);
      return null;
    }
  }

  /// The OTel `NavigatorObserver`, or `null` when OTel is not running.
  ///
  /// [recordArguments] stays off for the same reason [riverpodObserver]'s
  /// `recordValues` does.
  NavigatorObserver? routeObserver({bool recordArguments = false}) {
    if (!bridge.ready) return null;
    try {
      return OTelGoRouterObserver(recordArguments: recordArguments);
    } on Object catch (error) {
      talker.warning('OTel navigation instrumentation unavailable', error);
      return null;
    }
  }
}
