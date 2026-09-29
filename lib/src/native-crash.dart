import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'config.dart';
import 'native-crash.g.dart';
import 'spool.dart';

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

/// Turns the previous run's native deaths into FATAL log records, makes them
/// durable, and acknowledges each report only once they are.
///
/// Durable is the bar, not delivered: waiting for the collector would put the
/// network on the boot path, and `OtelZone.start` is awaited before `runApp`.
/// The report is written to the spool, acknowledged, and left to the spool to
/// deliver.
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
  ///
  /// Any other exporter has nowhere durable to put a report, so the report is
  /// acknowledged only after that exporter has accepted it. That still
  /// happens off the caller's path: the export is started and not awaited,
  /// and a report that is never accepted stays with the OS to be read again
  /// on the next launch.
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

  /// Deliveries still running after [drain] returned, so a test can wait.
  final Set<Future<void>> _background = <Future<void>>{};

  /// Completes when every export [drain] left running has finished.
  @visibleForTesting
  Future<void> settled() => Future.wait(_background.toList());

  /// Drains once and returns how many reports it took responsibility for.
  ///
  /// Only local work is awaited: reading the platform's reports, writing the
  /// spool file, and acknowledging. With a spool, the report is acknowledged
  /// as soon as it is on disk and the spool delivers it in its own time.
  ///
  /// That moves the point of no return: the platform's copy is released
  /// before the collector has the report, so the spool's own limits apply to
  /// it from then on. A file dropped after `spoolMaxAttempts` failed
  /// deliveries, or evicted by `spoolMaxBatches` or `spoolMaxAge`, takes its
  /// crash reports with it — with one warning for the first, none for the
  /// second. This is the accepted trade for keeping the network off the boot
  /// path, and it is the same one every other spooled batch already makes.
  ///
  /// Without a spool, or when it cannot be written, the export is started
  /// without being awaited and the acknowledgement follows only if the
  /// collector accepts it, so the platform's copy stays the durable one. In
  /// that case the count is of reports handed off, not of reports the
  /// collector has taken, and a report whose export fails is counted again on
  /// the launch that re-reads it.
  ///
  /// Nothing here throws, and nothing here waits on the network.
  Future<int> drain() async {
    // The plugin is not registered on web, so asking would only produce a
    // MissingPluginException on every launch.
    if (_isWeb) return 0;

    final List<NativeCrashReport>? reports = await _pending();
    if (reports == null || reports.isEmpty) return 0;

    final List<ReadableLogRecord> records = <ReadableLogRecord>[];
    // Only the reports that made a record. One whose redactor threw is
    // dropped rather than exported raw, and a dropped report must not be
    // acknowledged — its OS record has to stay readable for the next launch.
    final List<String> delivered = <String>[];
    for (final NativeCrashReport report in reports) {
      final ReadableLogRecord? record = _toLogRecord(report);
      if (record == null) continue;
      records.add(record);
      delivered.add(report.id);
    }
    if (records.isEmpty) return 0;

    final LogRecordExporter target = exporter;
    if (target is SpoolingLogRecordExporter && await target.enqueue(records)) {
      await _acknowledge(delivered);
      return records.length;
    }

    late final Future<void> export;
    export = _exportThenAcknowledge(
      records,
      delivered,
    ).whenComplete(() => _background.remove(export));
    _background.add(export);
    return records.length;
  }

  Future<void> _exportThenAcknowledge(
    List<ReadableLogRecord> records,
    List<String> ids,
  ) async {
    if (await _export(records) != ExportResult.success) return;
    await _acknowledge(ids);
  }

  Future<void> _acknowledge(List<String> ids) async {
    try {
      await source.acknowledge(ids);
    } on Object catch (error) {
      // The records are safe but the platform does not know it, so they will
      // be read again and exported again. A duplicate is better than a loss,
      // and this is the one place that trade is made.
      onWarning('Native crash reports were kept but not acknowledged: $error');
    }
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
