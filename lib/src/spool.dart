import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// A [LogRecordExporter] decorator that puts a batch on disk *before* the
/// network is tried, and replays what is left when the app next starts.
///
/// dartastic's exporter answers `ExportResult`, but a failure is only ever
/// final: the processor retries in memory and then drops the batch, and a
/// process killed while a request is in flight never gets to answer at all.
/// That is how a fault recorded in a tunnel is lost. This wraps the exporter
/// so that "the collector has not taken it yet" always means "it is on disk".
///
/// The order in [export] is deliberate, and it is the opposite of a cache:
/// the batch is written (temp file + rename) first, delivered second, and
/// deleted only once the delegate has accepted it. Trying the delegate first
/// looked cheaper — a healthy collector never pays for a disk write — but the
/// delegate's own retries can hold a batch in memory for tens of seconds,
/// which is exactly the window a dying process needs the batch to be safe in.
/// The extra write is small at the volumes this sees, since only records
/// above the export floor get this far.
///
/// A batch that stays spooled reports [ExportResult.success]. Reporting
/// failure instead would have the processor retry a batch that is already
/// durable, and each retry that failed would spool the same records again.
class SpoolingLogRecordExporter implements LogRecordExporter {
  /// Wraps [delegate], spooling into [directory].
  ///
  /// [maxBatches] is the hard cap on spool files; once it is exceeded the
  /// oldest file is evicted. [maxAge] drops files older than it, so a phone
  /// that never reconnects does not accumulate forever. Both exist because
  /// the alternative to a bounded spool is unbounded disk use.
  ///
  /// [maxAttempts] is how many *counted* failures a file survives before it is
  /// dropped, and is treated as at least 1. A failure is counted only in a
  /// [replay] pass in which the collector demonstrably works — another file
  /// was delivered in the same pass, or this process delivered something
  /// moments ago. The delegate only says `failure`, never *why*, so a batch
  /// the collector refuses for good (a 400, a 413) looks exactly like one
  /// refused because the phone is in a tunnel. Counting every failure would
  /// make being offline the thing that destroys data; counting only the ones
  /// that happen while the collector is answering others isolates the batch
  /// that is the problem.
  ///
  /// [onWarning] receives one line when a file is dropped for that reason. It
  /// is never given anything but counts, and never throws into the exporter.
  SpoolingLogRecordExporter({
    required this.delegate,
    required this.directory,
    this.maxBatches = 32,
    this.maxAge = const Duration(days: 7),
    this.maxAttempts = 5,
    this.onWarning,
  });

  /// The exporter this decorates.
  final LogRecordExporter delegate;

  /// Where spool files are written. Created on first use if it is missing.
  final Directory directory;

  /// The most spool files kept; the oldest are evicted past this.
  final int maxBatches;

  /// The age past which a spool file is discarded, or `null` for no age cap.
  final Duration? maxAge;

  /// The counted failures a spool file survives before it is dropped.
  final int maxAttempts;

  /// Told once each time a file is dropped after [maxAttempts] failures.
  final void Function(String message)? onWarning;

  /// Marks a record as having been replayed, so a backend can tell a
  /// late arrival from an on-time one.
  static const String replayedAttribute = 'otel_zone.replayed';

  static const String _suffix = '.spool.json';
  static const String _tempSuffix = '.tmp';

  /// The journal of crash reports made durable here; see [handledReports].
  /// Not a `*.spool.json`, so replay, eviction and the age cap never see it.
  static const String _handledFile = 'handled-reports.json';

  /// The most report ids the journal keeps. The platform holds a few dozen
  /// unacknowledged reports at most, so this is far above what a real launch
  /// needs; it only bounds a journal whose acknowledgements keep failing.
  static const int _handledCap = 64;

  /// Distinguishes two batches written in the same microsecond.
  static int _sequence = 0;

  /// Temp files this instance is currently writing.
  final Set<String> _writing = <String>{};

  /// The stems of the files this instance is delivering right now.
  ///
  /// A stem, not a path, because the path changes every time a failure is
  /// recorded. A file is claimed before it can be seen by [replay] and stays
  /// claimed until its delivery has finished, which is what stops [export]
  /// and [replay] — or two [replay]s — from sending one batch twice at the
  /// same time.
  final Set<String> _delivering = <String>{};

  /// Deliveries started by [enqueue], so a test can wait for them.
  final Set<Future<void>> _background = <Future<void>>{};

  /// How long ago a success may be and still stand in for a probe.
  static const Duration _freshSuccess = Duration(minutes: 5);

  /// When the delegate last accepted a batch, by any path, in this process.
  ///
  /// It is what lets [replay] tell "the collector refused this file" from
  /// "there is no collector" when there is no second file to try.
  @visibleForTesting
  DateTime? lastDeliverySuccessAt;

  /// Exports [logRecords], having put them on disk first.
  ///
  /// Never throws: an unwritable directory falls back to the delegate's own
  /// result, which is the behaviour without this decorator at all.
  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    if (logRecords.isEmpty) return ExportResult.success;

    final _SpoolEntry? entry = await _writeAhead(logRecords);
    if (entry == null) return _deliverDirectly(logRecords);
    return _deliver(entry, logRecords);
  }

  /// Makes [logRecords] durable and returns without waiting for the network.
  ///
  /// Returns `true` once the batch is on disk, at which point the caller may
  /// treat it as delivered: delivery carries on in the background, and a
  /// failure is recorded against the file exactly as it is for [export].
  /// Returns `false` when the batch could not be written, in which case
  /// nothing has been sent and the caller still owns it.
  ///
  /// [evictLast] marks the file so the cap on [maxBatches] evicts it only
  /// after every unmarked file. The crash drain sets it: once a report is
  /// acknowledged this file may be the only copy of it, and a run of ordinary
  /// telemetry must not push it out.
  ///
  /// This is what lets the crash drain acknowledge a report and return while
  /// the network is still being tried: durable is the promise, delivered is
  /// the aim.
  ///
  /// [reportIds] are the platform reports the batch holds. They are written to
  /// the journal [handledReports] reads once the batch is on disk and before
  /// this returns, so the caller can acknowledge them knowing that a lost
  /// acknowledgement will be recognised rather than spooled a second time.
  Future<bool> enqueue(
    List<ReadableLogRecord> logRecords, {
    bool evictLast = false,
    List<String> reportIds = const <String>[],
  }) async {
    if (logRecords.isEmpty) return true;

    final _SpoolEntry? entry = await _writeAhead(
      logRecords,
      evictLast: evictLast,
      reportIds: reportIds,
    );
    if (entry == null) return false;
    // After the file and before delivery: the file carries the ids until it is
    // deleted, and delivery is what deletes it, so the ids are always in one
    // place or the other.
    if (reportIds.isNotEmpty) await _rememberHandled(reportIds);

    late final Future<void> delivery;
    delivery = _deliver(entry, logRecords)
        .then<void>((ExportResult _) {})
        .whenComplete(() => _background.remove(delivery));
    _background.add(delivery);
    return true;
  }

  /// Completes when every delivery [enqueue] started has finished.
  @visibleForTesting
  Future<void> settled() => Future.wait(_background.toList());

  /// The platform reports [enqueue] made durable and [forgetHandled] has not
  /// yet been told the platform acknowledged.
  ///
  /// The crash drain acknowledges a report right after [enqueue], but that is
  /// a message to the platform, and the engine that sent it can be torn down
  /// with the message still in flight — Android relaunches an activity, and
  /// with it the Flutter engine, whenever an asset path or a package's
  /// application info changes, which is routine in the first seconds after an
  /// install or a boot. The relaunched app runs `start()` again, the platform
  /// still holds the report, and without this it would be spooled and
  /// delivered a second time. With it, the drain sees that the spool already
  /// has the report and only repeats the acknowledgement.
  ///
  /// Empty when nothing is journalled, and when the journal cannot be read:
  /// the fallback is the old behaviour, a report re-read and re-spooled, which
  /// is a duplicate and never a loss.
  Future<Set<String>> handledReports() async {
    final Set<String> handled = <String>{};
    // A batch still on disk names its own reports; it is the journal that
    // covers one already delivered and deleted.
    for (final File file in await _oldestFirst()) {
      handled.addAll(await _reportsIn(file));
    }
    handled.addAll(await _journal());
    return handled;
  }

  Future<Set<String>> _journal() async {
    try {
      final File file = File('${directory.path}/$_handledFile');
      if (!await file.exists()) return <String>{};
      return _strings(jsonDecode(await file.readAsString()));
    } on Object {
      return <String>{};
    }
  }

  Future<Set<String>> _reportsIn(File file) async {
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic>
          ? _strings(decoded['reports'])
          : <String>{};
    } on Object {
      return <String>{};
    }
  }

  static Set<String> _strings(Object? decoded) => <String>{
    if (decoded is List)
      for (final Object? id in decoded)
        if (id is String) id,
  };

  /// Removes [reportIds] from the journal, because the platform has
  /// acknowledged them and will not offer them again. Never throws.
  Future<void> forgetHandled(Iterable<String> reportIds) =>
      _editHandled((Set<String> journal) => journal..removeAll(reportIds));

  Future<void> _rememberHandled(Iterable<String> reportIds) =>
      _editHandled((Set<String> journal) => journal..addAll(reportIds));

  /// Serialised so two edits in this isolate cannot overwrite each other, and
  /// written like a spool file (temp + rename) so a kill leaves the old
  /// journal or the new one, never half of either.
  Future<void> _editHandled(Set<String> Function(Set<String>) edit) {
    return _handledEdits = _handledEdits.then((_) async {
      try {
        Set<String> journal = edit(await _journal());
        if (journal.length > _handledCap) {
          journal = journal.skip(journal.length - _handledCap).toSet();
        }
        final File target = File('${directory.path}/$_handledFile');
        if (journal.isEmpty) {
          await _delete(target);
          return;
        }
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final File temp = File('${target.path}$_tempSuffix');
        _writing.add(temp.path);
        try {
          await temp.writeAsString(jsonEncode(journal.toList()), flush: true);
          await temp.rename(target.path);
        } finally {
          _writing.remove(temp.path);
        }
      } on Object {
        // A journal that cannot be written costs a possible duplicate later,
        // which is not worth failing the drain over.
      }
    });
  }

  /// The last journal edit, so the next one waits for it.
  Future<void> _handledEdits = Future<void>.value();

  @override
  Future<void> forceFlush() => delegate.forceFlush();

  @override
  Future<void> shutdown() => delegate.shutdown();

  /// Replays every spool file, oldest first, and returns how many batches the
  /// delegate accepted.
  ///
  /// A file is deleted only once the delegate has accepted it. When one is
  /// refused, exactly one more file is tried as a probe, because a single
  /// refusal cannot say whether the file or the network is at fault:
  ///
  /// * if the probe is accepted the collector works, so the refusal is the
  ///   file's own. It is counted against it — dropped, with one warning, once
  ///   it reaches [maxAttempts] — and the pass carries on past the probe;
  /// * if the probe is refused too, the phone is offline. Nothing is counted
  ///   and the pass stops, so being offline never spends a file's attempts
  ///   and never spends the radio on the rest;
  /// * with no second file, a batch this process delivered within the last
  ///   few minutes ([lastDeliverySuccessAt]) stands in for the probe. With
  ///   none, nothing is counted: a lone file that has never seen the
  ///   collector answer is not evidence against it.
  ///
  /// The price is that a lone poisoned file with no traffic behind it is
  /// never dropped by count; [maxAge] is its bound.
  ///
  /// Files another delivery already owns are skipped, not counted, so this is
  /// safe to run while [export] or [enqueue] is still working.
  ///
  /// A file that cannot be decoded is deleted rather than retried: it can
  /// never be delivered, and leaving it would push a real batch out of the
  /// cap every time.
  Future<int> replay() async {
    await _sweepTemps();
    final List<File> files = await _oldestFirst();
    int delivered = 0;
    for (int i = 0; i < files.length; i++) {
      final _Replayed head = await _replayFile(files[i]);
      if (head.outcome == _Outcome.delivered) {
        delivered++;
        continue;
      }
      if (head.outcome == _Outcome.skipped) continue;

      final _SpoolEntry failed = head.entry!;
      try {
        bool collectorWorks = false;
        bool probed = false;
        int probe = i + 1;
        for (; probe < files.length; probe++) {
          final _Replayed next = await _replayFile(files[probe]);
          if (next.outcome == _Outcome.skipped) continue;
          probed = true;
          if (next.outcome == _Outcome.delivered) {
            delivered++;
            collectorWorks = true;
          } else {
            _release(next.entry!);
          }
          break;
        }
        if (!probed) collectorWorks = _succeededRecently();
        if (!collectorWorks) break;

        await _recordFailure(failed, head.recordCount);
        i = probe;
      } finally {
        _release(failed);
      }
    }
    return delivered;
  }

  bool _succeededRecently() {
    final DateTime? last = lastDeliverySuccessAt;
    return last != null && DateTime.now().difference(last) <= _freshSuccess;
  }

  void _release(_SpoolEntry entry) => _delivering.remove(entry.stem);

  /// Claims and sends one spool file.
  ///
  /// A refused file keeps its claim, and the caller must [_release] it once
  /// it has decided what the refusal means.
  Future<_Replayed> _replayFile(File file) async {
    final _SpoolEntry entry = _SpoolEntry.parse(file);
    // Claimed before the first await, so nothing else can pick it up between
    // the listing and the send.
    if (!_delivering.add(entry.stem)) return const _Replayed.skipped();
    bool keepClaim = false;
    try {
      // Another replay may have finished with it since it was listed.
      if (!await file.exists()) return const _Replayed.skipped();

      final List<ReadableLogRecord>? records = await _read(file);
      if (records == null) {
        await _delete(file);
        return const _Replayed.skipped();
      }

      if (await _deliverDirectly(records) == ExportResult.success) {
        await _delete(file);
        return const _Replayed.delivered();
      }
      keepClaim = true;
      return _Replayed.failed(entry, records.length);
    } finally {
      if (!keepClaim) _release(entry);
    }
  }

  /// Sends [logRecords] and settles what is on disk for [entry].
  ///
  /// A refusal here is not counted against the file. It may only mean the
  /// phone is offline, and only a later [replay], which can check that the
  /// collector works, is in a position to say otherwise. The file simply
  /// stays, and the batch is reported as success because it is durable.
  ///
  /// Never throws. Releases the claim on [entry] however it ends.
  Future<ExportResult> _deliver(
    _SpoolEntry entry,
    List<ReadableLogRecord> logRecords,
  ) async {
    try {
      final ExportResult result = await _deliverDirectly(logRecords);
      if (result == ExportResult.success) {
        await _delete(entry.file);
        return result;
      }
      await _evict();
      return ExportResult.success;
    } finally {
      _release(entry);
    }
  }

  Future<ExportResult> _deliverDirectly(
    List<ReadableLogRecord> logRecords,
  ) async {
    ExportResult result;
    try {
      result = await delegate.export(logRecords);
    } on Object {
      result = ExportResult.failure;
    }
    if (result == ExportResult.success) lastDeliverySuccessAt = DateTime.now();
    return result;
  }

  /// Writes [logRecords] to a new spool file and claims it for delivery.
  ///
  /// Returns `null` when the disk would not take it, with nothing left behind
  /// and no claim held.
  Future<_SpoolEntry?> _writeAhead(
    List<ReadableLogRecord> logRecords, {
    bool evictLast = false,
    List<String> reportIds = const <String>[],
  }) async {
    final String micros = DateTime.now().microsecondsSinceEpoch
        .toString()
        .padLeft(16, '0');
    final String stem = evictLast
        ? '$micros-${_SpoolEntry.evictLastMarker}-${_sequence++}'
        : '$micros-${_sequence++}';
    final _SpoolEntry entry = _SpoolEntry(directory, stem, 0);
    // Claimed before the file exists, so `replay` never sees it unowned.
    _delivering.add(stem);
    try {
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      // Temp file + rename, so a process death mid-write leaves either the
      // previous state or a complete batch — never half a JSON document that
      // replay would have to understand.
      final File temp = File('${entry.file.path}$_tempSuffix');
      // Tracked so the sweep can tell an in-flight write from one a dead
      // process left behind.
      _writing.add(temp.path);
      try {
        await temp.writeAsString(_encode(logRecords, reportIds), flush: true);
        await temp.rename(entry.file.path);
      } finally {
        _writing.remove(temp.path);
      }
      return entry;
    } on Object {
      _delivering.remove(stem);
      // A write that failed part-way leaves its temp behind, so reclaim it
      // now rather than waiting for the next sweep.
      await _sweepTemps();
      return null;
    }
  }

  /// Counts one more failed delivery against [entry].
  ///
  /// The count lives in the file's name and is changed by a rename, which is
  /// atomic: a process killed here leaves the file under its old name or its
  /// new one, never in between, and never needs a sidecar file to agree with.
  Future<void> _recordFailure(_SpoolEntry entry, int recordCount) async {
    final int attempts = entry.attempts + 1;
    if (attempts >= (maxAttempts < 1 ? 1 : maxAttempts)) {
      await _delete(entry.file);
      _warn(
        'Dropped a spooled log batch of $recordCount '
        '${recordCount == 1 ? 'record' : 'records'} after $attempts failed '
        'delivery ${attempts == 1 ? 'attempt' : 'attempts'} while the '
        'collector was accepting others',
      );
      return;
    }
    try {
      await entry.file.rename(entry.withAttempts(directory, attempts).path);
    } on Object {
      // Evicted while it was in flight, or the directory went read-only. The
      // file keeps its old count and is simply tried again next time.
    }
    await _evict();
  }

  void _warn(String message) {
    try {
      onWarning?.call(message);
    } on Object {
      // A warning is never worth failing an export over.
    }
  }

  /// Enforces the two bounds on the spool: [maxBatches] and [maxAge].
  ///
  /// Past the count cap the oldest ordinary file goes first, and a file
  /// marked `evictLast` only once none is left — it may be the only copy of
  /// an acknowledged crash report. The age cap has no such preference: it is
  /// the one bound that is unconditional, so a phone that never reconnects
  /// still cannot keep anything forever.
  Future<void> _evict() async {
    await _sweepTemps();
    final List<File> files = await _oldestFirst();
    final int excess = files.length - maxBatches;
    if (excess > 0) {
      final List<File> ordered = <File>[
        ...files.where((File f) => !_SpoolEntry.parse(f).evictLast),
        ...files.where((File f) => _SpoolEntry.parse(f).evictLast),
      ];
      for (final File file in ordered.take(excess)) {
        await _delete(file);
      }
    }
    final Duration? age = maxAge;
    if (age == null) return;
    final DateTime now = DateTime.now();
    for (final File file in files) {
      final DateTime? written = _writtenAt(file);
      if (written != null && now.difference(written) > age) {
        await _delete(file);
      }
    }
  }

  /// Deletes temp files no live write owns.
  ///
  /// A `.tmp` file is only visible here because a process died between write
  /// and rename, or because a write failed part-way — a healthy write renames
  /// immediately. Without this they accumulate forever: neither [_evict] nor
  /// [replay] looks at anything but `*.spool.json`, so the caps would never
  /// see them.
  Future<void> _sweepTemps() async {
    try {
      if (!await directory.exists()) return;
      await for (final FileSystemEntity entity in directory.list()) {
        if (entity is File &&
            entity.path.endsWith(_tempSuffix) &&
            !_writing.contains(entity.path)) {
          await _delete(entity);
        }
      }
    } on Object {
      // Nothing useful to do.
    }
  }

  Future<List<File>> _oldestFirst() async {
    try {
      if (!await directory.exists()) return const <File>[];
      final List<File> files = <File>[];
      await for (final FileSystemEntity entity in directory.list()) {
        if (entity is File && entity.path.endsWith(_suffix)) {
          files.add(entity);
        }
      }
      // The name leads with the write time, so lexical order is age order.
      files.sort((File a, File b) => a.path.compareTo(b.path));
      return files;
    } on Object {
      return const <File>[];
    }
  }

  DateTime? _writtenAt(File file) {
    final String name = file.uri.pathSegments.last;
    final int? micros = int.tryParse(name.split('-').first);
    return micros == null ? null : DateTime.fromMicrosecondsSinceEpoch(micros);
  }

  Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on Object {
      // Already gone, or the directory is read-only. Either way there is
      // nothing useful to do and nothing worth throwing at the app.
    }
  }

  String _encode(List<ReadableLogRecord> logRecords, List<String> reportIds) {
    final Resource? resource = logRecords.first.resource;
    return jsonEncode(<String, Object?>{
      'v': 1,
      'resource': _encodeAttributes(resource?.attributes),
      'records': logRecords.map(_encodeRecord).toList(),
      // The platform reports this batch holds, in the same file as the batch
      // so that "the batch is durable" and "these reports are handled" are one
      // atomic rename and never two.
      if (reportIds.isNotEmpty) 'reports': reportIds,
    });
  }

  Map<String, Object?> _encodeRecord(ReadableLogRecord logRecord) {
    return <String, Object?>{
      'time': logRecord.timestamp?.toString(),
      'observed': logRecord.observedTimestamp?.toString(),
      'severity': logRecord.severityNumber?.name,
      'severityText': logRecord.severityText,
      'body': _encodeBody(logRecord.body),
      'eventName': logRecord.eventName,
      'attributes': _encodeAttributes(logRecord.attributes),
      'scope': logRecord.instrumentationScope.name,
      'scopeVersion': logRecord.instrumentationScope.version,
      'scopeSchemaUrl': logRecord.instrumentationScope.schemaUrl,
      'traceId': logRecord.traceId?.toString(),
      'spanId': logRecord.spanId?.toString(),
      'traceFlags': logRecord.traceFlags?.asByte,
    };
  }

  /// A record's body is `dynamic`, but what survives a round trip is what
  /// JSON has: the primitives as themselves, anything else rendered. The
  /// alternative — refusing to spool a batch because one body was an object —
  /// loses the fault this exists to keep.
  Object? _encodeBody(Object? body) {
    if (body == null || body is String || body is num || body is bool) {
      return body;
    }
    return body.toString();
  }

  /// Attributes are kept only where `Attributes.fromJson` can rebuild them,
  /// so replay never has to guess a type it cannot express.
  Map<String, Object?> _encodeAttributes(Attributes? attributes) {
    final Map<String, Object?> encoded = <String, Object?>{};
    if (attributes == null) return encoded;
    for (final Attribute<Object> attribute
        in attributes.toList().cast<Attribute<Object>>()) {
      final Object value = attribute.value;
      if (_isJsonScalar(value) || _isJsonList(value)) {
        encoded[attribute.key] = value;
      }
    }
    return encoded;
  }

  static bool _isJsonScalar(Object? value) =>
      value is String || value is bool || value is int || value is double;

  static bool _isJsonList(Object? value) {
    if (value is! List) return false;
    return value.isNotEmpty && value.every(_isJsonScalar);
  }

  Future<List<ReadableLogRecord>?> _read(File file) async {
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final Resource resource = OTel.resource(
        Attributes.fromJson(_asJsonMap(decoded['resource'])),
      );
      final Object? encodedRecords = decoded['records'];
      if (encodedRecords is! List) return null;

      final List<ReadableLogRecord> logRecords = <ReadableLogRecord>[];
      for (final Object? entry in encodedRecords) {
        final ReadableLogRecord? logRecord = _decodeRecord(entry, resource);
        if (logRecord != null) logRecords.add(logRecord);
      }
      return logRecords.isEmpty ? null : logRecords;
    } on Object {
      return null;
    }
  }

  /// Rebuilds a record from its snapshot, carrying the resource captured when
  /// the fault happened rather than today's — a crash belongs to the version
  /// that crashed, and re-stamping would file it under a version that never
  /// ran that code.
  ReadableLogRecord? _decodeRecord(Object? value, Resource resource) {
    if (value is! Map<String, dynamic>) return null;
    final Map<String, dynamic> map = value;
    final Object? scope = map['scope'];
    final Object? severity = map['severity'];
    final SDKLogRecord logRecord = SDKLogRecord(
      instrumentationScope: OTel.instrumentationScope(
        name: scope is String ? scope : 'otel_zone',
        version: map['scopeVersion'] as String? ?? '1.0.0',
        schemaUrl: map['scopeSchemaUrl'] as String?,
      ),
      resource: resource,
      timestamp: _int64(map['time']),
      observedTimestamp: _int64(map['observed']),
      severityNumber: severity is String
          ? Severity.values.asNameMap()[severity]
          : null,
      severityText: map['severityText'] as String?,
      body: map['body'],
      attributes: _replayedAttributes(map['attributes']),
      eventName: map['eventName'] as String?,
    );
    logRecord.traceId = _traceId(map['traceId']);
    logRecord.spanId = _spanId(map['spanId']);
    final Object? flags = map['traceFlags'];
    logRecord.traceFlags = flags is int
        ? TraceFlags.fromString(flags.toRadixString(16))
        : null;
    return logRecord;
  }

  Attributes _replayedAttributes(Object? value) {
    final Map<String, dynamic> attributes = _asJsonMap(value);
    attributes[replayedAttribute] = true;
    return Attributes.fromJson(attributes);
  }

  static Map<String, dynamic> _asJsonMap(Object? value) {
    if (value is! Map) return <String, dynamic>{};
    return value.map(
      (Object? key, Object? entry) =>
          MapEntry<String, dynamic>(key.toString(), entry),
    );
  }

  static Int64? _int64(Object? value) {
    if (value is! String) return null;
    try {
      return Int64.parseInt(value);
    } on Object {
      return null;
    }
  }

  static TraceId? _traceId(Object? value) {
    if (value is! String) return null;
    try {
      return OTel.traceIdFrom(value);
    } on Object {
      return null;
    }
  }

  static SpanId? _spanId(Object? value) {
    if (value is! String) return null;
    try {
      return OTel.spanIdFrom(value);
    } on Object {
      return null;
    }
  }
}

/// One spool file, as its name describes it.
///
/// The name is `<microseconds>-<sequence>-<attempts>.spool.json`, or
/// `<microseconds>-evict-<sequence>-<attempts>.spool.json` for a file marked
/// to be evicted last. The leading part is the file's identity and
/// never changes; the trailing count is the failures counted so far, and is
/// the only part a rename rewrites. A file with no count — one an older
/// release wrote — has had none.
final class _SpoolEntry {
  _SpoolEntry(Directory directory, this.stem, this.attempts)
    : file = File(
        '${directory.path}/$stem-$attempts${SpoolingLogRecordExporter._suffix}',
      );

  _SpoolEntry._(this.file, this.stem, this.attempts);

  factory _SpoolEntry.parse(File file) {
    final String name = file.uri.pathSegments.last;
    final String base = name.substring(
      0,
      name.length - SpoolingLogRecordExporter._suffix.length,
    );
    final int? attempts = _trailingCount(base);
    if (attempts == null) return _SpoolEntry._(file, base, 0);
    return _SpoolEntry._(
      file,
      base.substring(0, base.lastIndexOf('-')),
      attempts,
    );
  }

  /// The count on the end of [base], or `null` for an older file without one.
  ///
  /// A name is `micros-seq` (old, no count), `micros-seq-n`, or
  /// `micros-evict-seq-n`; only the last of those parts can be the count,
  /// and only when there is one more part than the identity needs.
  static int? _trailingCount(String base) {
    final List<String> parts = base.split('-');
    final int identityLength = parts.length > 1 && parts[1] == evictLastMarker
        ? 3
        : 2;
    return parts.length == identityLength + 1 ? int.tryParse(parts.last) : null;
  }

  /// Sits between the timestamp and the sequence of an evict-last file.
  static const String evictLastMarker = 'evict';

  /// The file on disk, under the name it has now.
  final File file;

  /// What identifies the batch across renames.
  final String stem;

  /// The failures counted so far.
  final int attempts;

  /// Whether the count cap evicts this file only after every unmarked one.
  bool get evictLast => stem.split('-').length > 2;

  /// This file's path once it carries [count] failures.
  File withAttempts(Directory directory, int count) =>
      _SpoolEntry(directory, stem, count).file;
}

enum _Outcome { delivered, failed, skipped }

/// What [SpoolingLogRecordExporter.replay] learned from one file.
final class _Replayed {
  const _Replayed.delivered()
    : outcome = _Outcome.delivered,
      entry = null,
      recordCount = 0;
  const _Replayed.skipped()
    : outcome = _Outcome.skipped,
      entry = null,
      recordCount = 0;
  const _Replayed.failed(_SpoolEntry this.entry, this.recordCount)
    : outcome = _Outcome.failed;

  final _Outcome outcome;
  final _SpoolEntry? entry;
  final int recordCount;
}
