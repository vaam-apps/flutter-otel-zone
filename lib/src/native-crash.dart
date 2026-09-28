import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'config.dart';
import 'native-crash.g.dart';

/// The previous run's native deaths, as the platform reports them.
///
/// This is the seam [NativeCrashDrain] depends on rather than the generated
/// Pigeon client directly, so a test can stand in for the platform without a
/// method channel and without a device.
abstract interface class NativeCrashSource {
  /// Every report the OS holds that has not been acknowledged yet, oldest
  /// first.
  Future<List<NativeCrashReport>> pending();

  /// Marks [ids] as delivered.
  Future<void> acknowledge(List<String> ids);
}

/// [NativeCrashSource] backed by the Pigeon client the platform registers.
class PigeonNativeCrashSource implements NativeCrashSource {
  /// Wraps [api], or the plugin's default channel when it is omitted.
  PigeonNativeCrashSource([NativeCrashApi? api])
    : _api = api ?? NativeCrashApi();

  final NativeCrashApi _api;

  @override
  Future<List<NativeCrashReport>> pending() => _api.pending();

  @override
  Future<void> acknowledge(List<String> ids) => _api.acknowledge(ids);
}

/// Turns the previous run's native deaths into FATAL log records, exports
/// them, and acknowledges each report only once it is durable.
///
/// A crash report does **not** travel through the `Talker` bridge: a record of
/// the process dying is not a breadcrumb, and it must not be gated by the
/// [ExportFloor] that decides what a *live* app is worth sending.
class NativeCrashDrain {
  /// Drains [source], exporting through [exporter] and warning through
  /// [onWarning].
  ///
  /// [loggerName] is the instrumentation scope the records are emitted under.
  /// [isWeb] exists so the web no-op can be tested off the web; it defaults to
  /// the real platform flag.
  NativeCrashDrain({
    required this.source,
    required this.exporter,
    required this.loggerName,
    required this.onWarning,
    this.redact,
    bool? isWeb,
  }) : _isWeb = isWeb ?? kIsWeb;

  /// Where the reports come from.
  final NativeCrashSource source;

  /// Where the records go. The spooling exporter when one is configured, so a
  /// crash recovered offline is durable before it is acknowledged.
  final LogRecordExporter exporter;

  /// The instrumentation scope the records carry.
  final String loggerName;

  /// Called with one line when a step fails. Never throws.
  final void Function(String message) onWarning;

  /// Scrub a report's text before it leaves the device.
  ///
  /// A native stack trace is the densest PII the package ever handles — file
  /// paths, hostnames, parameter values — so it goes through the same
  /// [Redactor] as every other exported string.
  final Redactor? redact;

  final bool _isWeb;

  /// The OTel event name for a crash.
  static const String eventCrash = 'device.crash';

  /// The OTel event name for an ANR.
  static const String eventAnr = 'device.anr';

  /// Drains once and returns how many reports were made durable.
  ///
  /// A report is acknowledged only after [exporter] has accepted it, so a
  /// failed export leaves the OS record to be read again on the next launch.
  /// Nothing here throws.
  Future<int> drain() async {
    // The plugin is not registered on web, so asking would only produce a
    // MissingPluginException on every launch.
    if (_isWeb) return 0;

    final List<NativeCrashReport>? reports = await _pending();
    if (reports == null || reports.isEmpty) return 0;

    final List<ReadableLogRecord> records = <ReadableLogRecord>[];
    for (final NativeCrashReport report in reports) {
      final ReadableLogRecord? record = _toLogRecord(report);
      if (record != null) records.add(record);
    }
    if (records.isEmpty) return 0;

    if (await _export(records) != ExportResult.success) return 0;

    try {
      await source.acknowledge(
        reports.map((NativeCrashReport report) => report.id).toList(),
      );
    } on Object catch (error) {
      // The records are durable but the platform does not know it, so they
      // will be read again and re-exported. A duplicate is better than a
      // loss, and this is the one place that trade is made.
      onWarning(
        'Native crash reports were exported but not acknowledged: $error',
      );
    }
    return records.length;
  }

  Future<List<NativeCrashReport>?> _pending() async {
    try {
      return await source.pending();
    } on Object catch (error) {
      onWarning('Native crash reports could not be read: $error');
      return null;
    }
  }

  Future<ExportResult> _export(List<ReadableLogRecord> records) async {
    try {
      return await exporter.export(records);
    } on Object {
      return ExportResult.failure;
    }
  }

  /// Maps one report, or returns `null` when the [redact] throws — the same
  /// fail-closed rule the bridge applies, so nothing unredacted is exported.
  ReadableLogRecord? _toLogRecord(NativeCrashReport report) {
    try {
      final String? type = _scrub(report.type);
      final String? message = _scrub(report.message);
      final String? stacktrace = _scrub(report.stacktrace);
      final Map<String, Object> attributes = <String, Object>{
        'event.name': _eventName(report.kind),
        'device.crash.kind': report.kind,
        if (report.attributes != null)
          for (final MapEntry<String, String> attribute
              in report.attributes!.entries)
            attribute.key: _scrub(attribute.value) ?? '',
      };
      if (type != null) attributes['exception.type'] = type;
      if (message != null) attributes['exception.message'] = message;
      if (stacktrace != null) attributes['exception.stacktrace'] = stacktrace;
      if (report.sessionId != null) {
        attributes['session.id'] = report.sessionId!;
      }
      final List<String>? threads = report.threads;
      if (threads != null && threads.isNotEmpty) {
        attributes['device.crash.threads'] = threads
            .map((String frame) => _scrub(frame) ?? '')
            .join('\n');
      }

      return SDKLogRecord(
        instrumentationScope: OTel.instrumentationScope(name: loggerName),
        resource: OTel.defaultResource,
        timestamp: Int64(report.timestampMicros),
        severityNumber: Severity.FATAL,
        severityText: 'fatal',
        body: message ?? type ?? 'Native crash',
        attributes: OTel.attributesFromMap(attributes),
        eventName: _eventName(report.kind),
      );
    } on Object {
      return null;
    }
  }

  String? _scrub(String? value) {
    if (value == null) return null;
    final Redactor? redact = this.redact;
    return redact == null ? value : redact(value);
  }

  /// An ANR is its own event; a hang, a signal and a JVM or Obj-C exception
  /// are all a process coming down, and the kind attribute tells them apart.
  static String _eventName(String kind) =>
      kind == 'anr' ? eventAnr : eventCrash;
}
