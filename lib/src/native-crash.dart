import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

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
  /// The drain reads the platform only on Android and iOS, the two platforms
  /// the plugin registers. [isWeb] and [platform] exist so the no-op on every
  /// other platform can be tested off it; they default to the real platform
  /// flag and to `defaultTargetPlatform`.
  NativeCrashDrain({
    required this.source,
    required this.exporter,
    required this.loggerName,
    required this.onWarning,
    this.redact,
    bool? isWeb,
    TargetPlatform? platform,
  }) : _supported =
           !(isWeb ?? kIsWeb) &&
           _nativePlatforms.contains(platform ?? defaultTargetPlatform);

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

  /// The platforms the plugin registers a crash source on.
  static const Set<TargetPlatform> _nativePlatforms = <TargetPlatform>{
    TargetPlatform.android,
    TargetPlatform.iOS,
  };

  final bool _supported;

  /// The OTel event name for a crash.
  static const String eventCrash = 'device.crash';

  /// The OTel event name for an ANR.
  static const String eventAnr = 'device.anr';

  /// The version of the app that crashed, on a native crash record.
  ///
  /// A record is exported by the *next* launch, under that launch's resource,
  /// so after an app update the resource's `service.version` names the build
  /// that reported the crash, not the one that died. This names the one that
  /// died, which is the binary a symbolicator needs. The platform writes it
  /// (Android `versionName`, iOS `CFBundleShortVersionString`); it is absent
  /// when the platform could not say, and never filled in with the current
  /// version, because a wrong one is worse than none.
  static const String crashedServiceVersion =
      'otel_zone.crashed.service.version';

  /// The build of the app that crashed, on a native crash record: Android's
  /// `longVersionCode`, iOS's `CFBundleVersion`. The counterpart of
  /// [crashedServiceVersion] for the resource's `app.build_id`, with the same
  /// absence rule.
  static const String crashedBuildId = 'otel_zone.crashed.app.build_id';

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
  /// it from then on, and the file may be the only copy. Those limits are
  /// narrow on purpose. Being offline never counts against the file, so it is
  /// dropped after `spoolMaxAttempts` failures only when the collector is
  /// demonstrably accepting other batches and still refusing this one, with
  /// one warning. The bounds that remain are `spoolMaxAge`, which is
  /// unconditional, `spoolMaxBatches` and `spoolMaxBytes`, which evict every
  /// ordinary batch before they touch one marked here as a crash report, and a
  /// crash report evicted that way is warned about and taken off the journal, so
  /// the platform hands it over again rather than treating it as delivered.
  ///
  /// The reports are spooled as one batch. If that is refused, as it is when
  /// the reports together are larger than `spoolMaxBytes`, each is spooled on
  /// its own, so one that fits is durable however many others are pending. A
  /// report that is over `spoolMaxBytes` by itself is not spooled: it is
  /// exported directly, with one warning, and acknowledged only once the
  /// collector has taken it, so the platform's copy stays the durable one.
  ///
  /// The acknowledgement is a message to the platform, and the engine that
  /// sends it can be torn down with the message in flight — an activity
  /// relaunch does exactly that. So the spool journals the reports it made
  /// durable, and a drain that is offered one of them again only repeats the
  /// acknowledgement: the report is delivered once, not once per engine.
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
    // The plugin is registered on Android and iOS only, so on web or desktop
    // asking would only produce a missing-plugin or channel-error warning,
    // exported, on every launch.
    if (!_supported) return 0;

    final List<NativeCrashReport>? reports = await _pending();
    if (reports == null || reports.isEmpty) return 0;

    final LogRecordExporter target = exporter;
    final SpoolingLogRecordExporter? spool = target is SpoolingLogRecordExporter
        ? target
        : null;

    // Reports an earlier drain already made durable but whose acknowledgement
    // never landed. See [SpoolingLogRecordExporter.handledReports]: they are
    // acknowledged again, and not spooled again.
    final Set<String> handled = await spool?.handledReports() ?? <String>{};

    final List<ReadableLogRecord> records = <ReadableLogRecord>[];
    // Only the reports that made a record. One whose redactor threw is
    // dropped rather than exported raw, and a dropped report must not be
    // acknowledged — its OS record has to stay readable for the next launch.
    final List<String> delivered = <String>[];
    final List<String> alreadyDurable = <String>[];
    // Oldest first, so that when a byte cap cannot hold every report it is
    // the oldest that goes: the spool evicts by write order. The index keeps
    // the sort stable for reports that share a timestamp.
    final List<NativeCrashReport> oldestFirst = <NativeCrashReport>[
      for (final MapEntry<int, NativeCrashReport> entry
          in (reports.asMap().entries.toList()..sort((
            MapEntry<int, NativeCrashReport> a,
            MapEntry<int, NativeCrashReport> b,
          ) {
            final int byTime = a.value.timestampMicros.compareTo(
              b.value.timestampMicros,
            );
            return byTime != 0 ? byTime : a.key.compareTo(b.key);
          })))
        entry.value,
    ];
    for (final NativeCrashReport report in oldestFirst) {
      if (handled.contains(report.id)) {
        alreadyDurable.add(report.id);
        continue;
      }
      final ReadableLogRecord? record = _toLogRecord(report);
      if (record == null) continue;
      records.add(record);
      delivered.add(report.id);
    }

    // Durable once it is on disk. A spool that cannot be written leaves the
    // reports with the platform and the plain exporter below.
    final List<String> durable = <String>[];
    List<ReadableLogRecord> unspooled = records;
    List<String> unspooledIds = delivered;
    if (spool != null && records.isNotEmpty) {
      if (await spool.enqueue(records, evictLast: true, reportIds: delivered)) {
        durable.addAll(delivered);
        unspooled = <ReadableLogRecord>[];
        unspooledIds = <String>[];
      } else if (records.length > 1) {
        // The whole batch was refused, which with a byte cap can mean only that
        // the reports together are too big. Each report is its own batch then,
        // so that one that fits is durable however many others are pending,
        // and only a report that is over the cap on its own takes the direct
        // path below.
        unspooled = <ReadableLogRecord>[];
        unspooledIds = <String>[];
        for (int i = 0; i < records.length; i++) {
          if (await spool.enqueue(
            <ReadableLogRecord>[records[i]],
            evictLast: true,
            reportIds: <String>[delivered[i]],
          )) {
            durable.add(delivered[i]);
          } else {
            unspooled.add(records[i]);
            unspooledIds.add(delivered[i]);
          }
        }
      }
    }
    if (spool != null) {
      final List<String> ids = <String>[...durable, ...alreadyDurable];
      if (ids.isNotEmpty && await _acknowledge(ids)) {
        await spool.forgetHandled(ids);
      }
    }
    if (unspooled.isNotEmpty) {
      late final Future<void> export;
      export = _exportThenAcknowledge(
        unspooled,
        unspooledIds,
      ).whenComplete(() => _background.remove(export));
      _background.add(export);
    }
    return records.length;
  }

  Future<void> _exportThenAcknowledge(
    List<ReadableLogRecord> records,
    List<String> ids,
  ) async {
    if (await _export(records) != ExportResult.success) return;
    await _acknowledge(ids);
  }

  /// Acknowledges [ids] and says whether the platform took it.
  Future<bool> _acknowledge(List<String> ids) async {
    try {
      await source.acknowledge(ids);
      return true;
    } on Object catch (error) {
      // The records are safe but the platform does not know it, so they will
      // be read again. With a spool the journal recognises them and only the
      // acknowledgement is repeated; without one they are exported again. A
      // duplicate is better than a loss, and this is the one place that
      // trade is made.
      onWarning('Native crash reports were kept but not acknowledged: $error');
      return false;
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
      // The crashed build is either known or absent: a platform that has
      // nothing to say must not leave an empty string that reads as a value.
      for (final String key in _crashedBuildKeys) {
        if (attributes[key] case final String value when value.trim().isEmpty) {
          attributes.remove(key);
        }
      }
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

  static const List<String> _crashedBuildKeys = <String>[
    crashedServiceVersion,
    crashedBuildId,
  ];

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
