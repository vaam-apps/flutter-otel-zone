import 'dart:async' show FutureOr;
import 'dart:io' show Directory;

import 'package:flutter/foundation.dart' show kDebugMode;

import 'export-floor.dart';

/// One function that scrubs a single string of anything that must not leave
/// the device.
///
/// It is handed one field at a time, never a rendered record, so a whole-value
/// pattern such as `^\+?\d{9,12}$` matches a field as it would a string of its
/// own. For a log record the fields are the message, the title, the
/// error/exception text and the stack trace's text. A breadcrumb line is
/// `time [title] message`, and a `[riverpod-fail]` record's error and stack
/// trace (which live only in that record's own fields) are scrubbed one by one
/// and then laid out as it lays them out. A record kind that renders more than
/// `TalkerData` does sends only the title, time, message and stack trace when
/// a redactor is set. For a span the
/// fields are each attribute value (and each element of a string list), each
/// event and link attribute (a recorded exception's message and stack trace),
/// the status description and the name.
///
/// It runs synchronously, on the isolate that exports (the UI isolate in a
/// Flutter app), so keep it cheap.
///
/// ```dart
/// String scrubPhoneNumbers(String input) =>
///     input.replaceAll(RegExp(r'\d{9}'), '<phone>');
/// ```
typedef Redactor = String Function(String input);

/// Everything about a build's telemetry that is known before the build
/// runs.
///
/// The split against `OtelZone.start` is deliberate and is the only one in
/// this package: what is *compiled in* lives here, and what has to be
/// *read off the running device* — the installed artifact's version, the
/// phone's model, the OS — is an argument to `start`, because none of it
/// can be known until the Flutter binding exists.
///
/// Every field has the default the Vaam Store mobile app shipped with; a
/// caller that names only [serviceName] and [endpoint] gets that behaviour.
///
/// ```dart
/// final config = OtelZoneConfig(
///   serviceName: 'vaam-mobile',
///   endpoint: 'https://otel.example.com',
///   deploymentEnvironmentName: 'production',
///   exportFloor: ExportFloor.parse('warning'),
/// );
/// ```
final class OtelZoneConfig {
  /// Creates a configuration.
  ///
  /// [loggerName] defaults to [serviceName], which is what an instrumentation
  /// scope named after the service already means.
  ///
  /// [secure] defaults to whether [endpoint] is `https://`, which is the
  /// answer in every case anyone has needed so far: plain HTTP to a
  /// collector on `localhost`, TLS to a deployed one. Set it explicitly for
  /// a TLS endpoint behind a scheme this cannot see.
  const OtelZoneConfig({
    required this.serviceName,
    required this.endpoint,
    String? loggerName,
    this.deploymentEnvironmentName,
    this.exportFloor = const ExportFloor.of(ExportFloor.defaultLevel),
    this.breadcrumbCount = 12,
    this.breadcrumbLineLimit = 160,
    this.redact,
    this.useConsoleLogs = kDebugMode,
    this.presentFlutterErrors = kDebugMode,
    this.enableLogs = true,
    this.enableMetrics = false,
    this.spoolDirectory,
    this.spoolMaxBatches = 32,
    this.spoolMaxAge = const Duration(days: 7),
    this.spoolMaxBytes = 5 * 1024 * 1024,
    this.spoolMaxAttempts = 5,
    bool? secure,
  }) : _loggerName = loggerName,
       _secure = secure;

  /// OpenTelemetry's `service.name`.
  ///
  /// One name per *service*, not per build flavour. Two flavours of one app
  /// are one service built twice; splitting them here makes them look
  /// unrelated to every backend that groups by this key, and every "the
  /// mobile app" query then has to remember to union them back together.
  /// Use [deploymentEnvironmentName] to tell them apart instead.
  final String serviceName;

  /// The OTLP endpoint records are exported to.
  final String endpoint;

  /// OpenTelemetry's `deployment.environment.name` — which tier of the
  /// service this build is, `production` or `development`.
  ///
  /// Left off the resource entirely when `null`.
  ///
  /// This is the stable semantic convention for the question. Plain
  /// `deployment.environment` is deprecated — the registry entry reads
  /// "Replaced by deployment.environment.name" — and is not used here:
  /// https://opentelemetry.io/docs/specs/semconv/registry/attributes/deployment/
  ///
  /// It describes the *build's* tier, not the backend's, so it usually
  /// cannot be derived from an API base URL and is a build input of its own.
  final String? deploymentEnvironmentName;

  /// The severity a record has to clear before it is exported.
  ///
  /// Records below it are still recorded locally — they are the material a
  /// fault's breadcrumb trail is built from. See `OtelBridge`.
  final ExportFloor exportFloor;

  /// How many preceding records ride along with a fault, as one extra
  /// record.
  ///
  /// Twelve, because that is roughly one screen of navigation plus the
  /// provider transitions around it — the "what was the user doing"
  /// question an error record cannot answer on its own.
  final int breadcrumbCount;

  /// Breadcrumb lines are truncated to this, so one enormous value cannot
  /// turn a fault into a payload.
  final int breadcrumbLineLimit;

  /// Scrubs every exported string before it leaves the device: log records,
  /// crash reports and spans.
  ///
  /// This is the one point every record crosses, which is why scrubbing lives
  /// here and not at each call site: a rule bolted on per call site is a rule
  /// that one call site eventually misses. It runs *before* truncation and
  /// before any export, so nothing unredacted can be persisted or sent.
  ///
  /// For a span that is every attribute value (and each element of a
  /// string-list value), the attributes of each event and link, the status
  /// description and the name. Keys, event names and non-text values are left
  /// alone. With a [redact] set, [OtelZone.start] builds the trace pipeline
  /// itself, from the same `OTEL_TRACES_EXPORTER` and `OTEL_EXPORTER_OTLP_*`
  /// variables dartastic reads; without one, dartastic's own is used. The
  /// first span a throwing [redact] drops is one warning on the talker.
  ///
  /// It does not reach the raw crash files the Android and iOS code write
  /// before Dart runs (in no-backup storage, deleted once acknowledged); the
  /// README's "What the platforms store before Dart runs" lists them.
  ///
  /// `null` means no scrubbing — the behaviour of every build that does not
  /// supply one. A [redact] that throws drops the record, or the span, rather
  /// than letting it through unredacted (fail closed).
  ///
  /// ```dart
  /// redact: (input) => input.replaceAll(RegExp(r'\d{9}'), '<phone>'),
  /// ```
  final Redactor? redact;

  /// Whether Talker prints to the console.
  ///
  /// This gates the *console* and nothing else — it is not a second export
  /// switch, and reading it as one is how a build ships with
  /// `useConsoleLogs: kDebugMode` and a wide-open exporter. The wire is
  /// gated by [exportFloor].
  final bool useConsoleLogs;

  /// Whether `FlutterError.presentError` still runs for a framework error —
  /// the red screen and the console dump.
  ///
  /// The log record is for the backend; the presented error is for the
  /// person looking at the simulator.
  final bool presentFlutterErrors;

  /// Whether the OTel logs pipeline is started. Off means Talker records
  /// stay on the device.
  final bool enableLogs;

  /// Whether the OTel metrics pipeline is started. **Off, and that is a
  /// decision rather than an oversight.**
  ///
  /// Metrics are the only signal here that costs a phone something when
  /// nothing happens. `PeriodicExportingMetricReader` is a bare
  /// `Timer.periodic` on the spec's 60s default; it skips an export only
  /// while *no instrument exists at all*, and a cumulative counter or a
  /// gauge is required to keep reporting its last value, so the first
  /// instrument anyone registers turns this into a 60s heartbeat for the
  /// life of the process. Traces and logs reach the radio only when the
  /// user did something. On a metered prepaid connection that is the
  /// difference between telemetry costing what a session costs and the app
  /// billing someone for standing still, and every wake-up holds the
  /// cellular radio in its high-power tail long after the bytes are gone.
  /// The timer also keeps firing when the collector is unreachable, so the
  /// battery is spent whether or not anything arrives.
  ///
  /// Little is given up for that: call rate, error rate and latency are
  /// already on the wire as spans, and deriving them belongs in the
  /// collector's `spanmetrics` connector, which costs the device nothing.
  ///
  /// Turn it on only for something a span cannot express — a device gauge
  /// such as battery level or offline-queue depth — and then with an
  /// explicit long interval and a named list of instruments, never the
  /// default reader.
  final bool enableMetrics;

  /// Where batches are spooled, or `null` for no spooling.
  ///
  /// `null` is the default and the behaviour every existing build has: a
  /// batch the collector refuses is retried in memory and then dropped.
  /// Supply a provider — `getApplicationSupportDirectory` from
  /// `path_provider`, read after the binding exists — and every batch is
  /// written there *before* it is sent and deleted once the collector has
  /// taken it, so a refusal, or a process killed mid-request, leaves it on
  /// disk. [OtelZone.start] replays what is left on the next launch.
  ///
  /// Prefer a directory the OS does not back up:
  /// `getApplicationSupportDirectory` is included in Android Auto Backup and
  /// in iOS backups, and `getApplicationCacheDirectory` is not. Delete the
  /// directory on sign-out. See the README's "Where the spool lives".
  ///
  /// A function rather than a [Directory] because the directory does not
  /// exist to be named until the platform channels do, which is after this
  /// config is built. It may return the [Directory] or a `Future` of one, so
  /// `path_provider`'s function is passed as it is and a plain
  /// `() => directory` works too; [OtelZone.start] awaits it once, before the
  /// SDK is brought up. A provider that throws, or whose future fails, leaves
  /// telemetry off for the process, like any other failure of `start`.
  final FutureOr<Directory> Function()? spoolDirectory;

  /// The most spool files kept before the oldest is evicted.
  ///
  /// A cap, not a preference: a phone that never reconnects must not fill its
  /// disk with telemetry nobody collected.
  final int spoolMaxBatches;

  /// The age past which a spool file is discarded, or `null` for no age cap.
  final Duration? spoolMaxAge;

  /// The most bytes, on disk, the spool files may hold together, or `null` for
  /// no byte cap. Defaults to 5 MiB (`5 * 1024 * 1024`).
  ///
  /// [spoolMaxBatches] bounds how many files there are, not how big they are:
  /// one file is one refused export batch of up to 512 log records, and a
  /// record's size is not capped, so the count alone allows an unbounded
  /// number of bytes. This is the bound on the bytes. The unit is bytes as the
  /// files occupy on disk (their length), not records or batches; the journal
  /// of handled crash reports and half-written temp files are not counted.
  ///
  /// Past it the oldest ordinary batch is evicted first, and a crash report
  /// only once no ordinary batch is left, oldest first — the same order as
  /// [spoolMaxBatches]. It is enforced after every write and when
  /// [OtelZone.start] replays, so a directory an older release left over the
  /// cap is trimmed on the next launch. A single batch larger than the cap is
  /// not spooled at all, with one warning on the talker: writing it would
  /// evict everything else, crash reports included, and still not fit. It is
  /// still sent to the collector. A cap below the size of one batch therefore
  /// turns spooling off in effect.
  ///
  /// A batch is written before it is sent and the cap is checked against that
  /// file, so the room for undelivered backlog is about the cap minus the
  /// largest batch in flight. A crash report dropped by any spool cap is
  /// warned about, and taken off the crash journal so the platform offers it
  /// again; recovered crash reports never displace one already on disk.
  final int? spoolMaxBytes;

  /// How many counted failures a spooled batch survives before it is
  /// dropped, with one warning, so it stops standing in front of the batches
  /// behind it.
  ///
  /// A failure is counted only in a replay pass where the collector
  /// demonstrably works — another batch was delivered in the same pass, or
  /// this process delivered one moments ago. The exporter cannot tell a
  /// collector that is unreachable from one that will never take this batch
  /// (a 400, a 413), so being offline is never counted: a phone can spend any
  /// number of launches without a connection and lose nothing to this. The
  /// price is that a lone poisoned batch with no traffic behind it is never
  /// dropped by count; [spoolMaxAge] bounds it. Values below 1 are treated as
  /// 1.
  final int spoolMaxAttempts;

  final String? _loggerName;
  final bool? _secure;

  /// The OTel instrumentation-scope name log records are emitted under.
  String get loggerName => _loggerName ?? serviceName;

  /// Whether the exporter uses TLS.
  bool get secure => _secure ?? endpoint.startsWith('https://');
}
