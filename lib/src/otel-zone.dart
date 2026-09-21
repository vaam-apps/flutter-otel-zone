import 'dart:async';
import 'dart:isolate';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show NavigatorObserver;
import 'package:otel_go_router/otel_go_router.dart';
import 'package:otel_riverpod/otel_riverpod.dart';
import 'package:riverpod/riverpod.dart' show ProviderObserver;
import 'package:talker/talker.dart';

import 'bridge.dart';
import 'config.dart';

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
  OtelZone(this.config, {Talker? talker, TalkerObserver? sink}) {
    bridge = OtelBridge(
      floor: config.exportFloor,
      // Read lazily: the trail is this object's own Talker, which does not
      // exist yet on the line below.
      history: () => this.talker.history,
      loggerName: config.loggerName,
      breadcrumbCount: config.breadcrumbCount,
      breadcrumbLineLimit: config.breadcrumbLineLimit,
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

  /// Whether the SDK came up. `false` before [start], and after a [start]
  /// that failed.
  bool get isReady => bridge.ready;

  /// Brings up the OpenTelemetry SDK and points it at
  /// [OtelZoneConfig.endpoint].
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
    try {
      await OTel.initialize(
        serviceName: config.serviceName,
        serviceVersion: serviceVersion,
        endpoint: config.endpoint,
        secure: config.secure,
        enableLogs: config.enableLogs,
        enableMetrics: config.enableMetrics,
        resourceAttributes: OTel.attributesFromMap(<String, String>{
          ...resourceAttributes,
          App.appBuildId.key: ?buildId,
          'deployment.environment.name': ?config.deploymentEnvironmentName,
        }),
      );
      // Only now may the bridge forward: `OTel.loggerProvider()` throws
      // until initialize() has returned successfully.
      bridge.ready = true;
      talker.warning(startupSummary(serviceVersion, buildId));
    } on Object catch (error, stackTrace) {
      bridge.ready = false;
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
  String startupSummary(String serviceVersion, String? buildId) {
    final String environment = config.deploymentEnvironmentName == null
        ? ''
        : ' (${config.deploymentEnvironmentName})';
    final String build = buildId == null ? '' : ' build $buildId';
    final String? unrecognised = config.exportFloor.unrecognised;
    return 'OpenTelemetry: exporting to ${config.endpoint} '
        'as ${config.serviceName} $serviceVersion$build$environment, '
        'records at ${config.exportFloor.level.name} and above'
        '${unrecognised == null ? '' : ' — the configured export level said '
                  '"$unrecognised", which is not a level; '
                  'fell back to ${config.exportFloor.level.name}'}';
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
          if (config.presentFlutterErrors) {
            FlutterError.presentError(details);
          }
          previousOnError?.call(details);
        };

        // Errors that escape an engine callback (gesture handlers, platform
        // channel replies) without passing through FlutterError.
        PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
          reportError(error, stack, context: 'PlatformDispatcher');
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
  /// [recordValues] stays off by default: provider state is where an app's
  /// own data lives — orders, phone numbers, identity drafts — and this
  /// leaves the device. The runtime *type* of each value is recorded either
  /// way, which is what makes the spans useful without making them a PII
  /// channel.
  ProviderObserver? riverpodObserver({bool recordValues = false}) {
    if (!bridge.ready) return null;
    try {
      return OTelRiverpodObserver(recordValues: recordValues);
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
