import 'package:flutter/foundation.dart' show kDebugMode;

import 'export-floor.dart';

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
    this.useConsoleLogs = kDebugMode,
    this.presentFlutterErrors = kDebugMode,
    this.enableLogs = true,
    this.enableMetrics = false,
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

  final String? _loggerName;
  final bool? _secure;

  /// The OTel instrumentation-scope name log records are emitted under.
  String get loggerName => _loggerName ?? serviceName;

  /// Whether the exporter uses TLS.
  bool get secure => _secure ?? endpoint.startsWith('https://');
}
