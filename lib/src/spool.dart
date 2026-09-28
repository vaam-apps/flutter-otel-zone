import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fixnum/fixnum.dart';

/// A [LogRecordExporter] decorator that puts a batch on disk *before* the
/// pipeline is allowed to forget it, and replays what is left when the app
/// next starts.
///
/// dartastic's exporter answers `ExportResult`, but a failure is only ever
/// final: the processor retries in memory and then drops the batch. That is
/// how a fault recorded in a tunnel is lost. This wraps the exporter and
/// turns "the collector did not take it" into "it is on disk", which is the
/// accepted-by-the-collector signal the pipeline lacked.
///
/// The order in [export] is deliberate: the delegate is tried first, so a
/// healthy collector never pays for a disk write, and disk is only touched
/// once the delegate has already refused the batch.
///
/// A batch that is spooled reports [ExportResult.success]. Reporting failure
/// instead would have the processor retry a batch that is already durable,
/// and each retry that failed would spool the same records again.
class SpoolingLogRecordExporter implements LogRecordExporter {
  /// Wraps [delegate], spooling into [directory].
  ///
  /// [maxBatches] is the hard cap on spool files; once it is exceeded the
  /// oldest file is evicted. [maxAge] drops files older than it, so a phone
  /// that never reconnects does not accumulate forever. Both exist because
  /// the alternative to a bounded spool is unbounded disk use.
  SpoolingLogRecordExporter({
    required this.delegate,
    required this.directory,
    this.maxBatches = 32,
    this.maxAge = const Duration(days: 7),
  });

  /// The exporter this decorates.
  final LogRecordExporter delegate;

  /// Where spool files are written. Created on first use if it is missing.
  final Directory directory;

  /// The most spool files kept; the oldest are evicted past this.
  final int maxBatches;

  /// The age past which a spool file is discarded, or `null` for no age cap.
  final Duration? maxAge;

  /// Marks a record as having been replayed, so a backend can tell a
  /// late arrival from an on-time one.
  static const String replayedAttribute = 'otel_zone.replayed';

  static const String _suffix = '.spool.json';

  /// Distinguishes two batches written in the same microsecond.
  static int _sequence = 0;

  /// Exports [logRecords], spooling them if the delegate refuses them.
  ///
  /// Never throws: an unwritable directory falls back to the delegate's own
  /// result, which is the behaviour without this decorator at all.
  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    if (logRecords.isEmpty) return ExportResult.success;

    ExportResult result;
    try {
      result = await delegate.export(logRecords);
    } on Object {
      result = ExportResult.failure;
    }
    if (result == ExportResult.success) return result;

    return await _spool(logRecords) ? ExportResult.success : result;
  }

  @override
  Future<void> forceFlush() => delegate.forceFlush();

  @override
  Future<void> shutdown() => delegate.shutdown();

  /// Replays every spool file, oldest first, and returns how many batches the
  /// delegate accepted.
  ///
  /// A file is deleted only once the delegate has accepted it. On the first
  /// refusal the loop stops and keeps that file and every later one — if the
  /// collector is unreachable, replaying the rest only spends the radio to
  /// learn the same thing.
  ///
  /// A file that cannot be decoded is deleted rather than retried: it can
  /// never be delivered, and leaving it would push a real batch out of the
  /// cap every time.
  Future<int> replay() async {
    final List<File> files = await _oldestFirst();
    int delivered = 0;
    for (final File file in files) {
      final List<ReadableLogRecord>? records = await _read(file);
      if (records == null) {
        await _delete(file);
        continue;
      }

      ExportResult result;
      try {
        result = await delegate.export(records);
      } on Object {
        result = ExportResult.failure;
      }
      if (result != ExportResult.success) break;

      await _delete(file);
      delivered++;
    }
    return delivered;
  }

  Future<bool> _spool(List<ReadableLogRecord> logRecords) async {
    try {
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final String stem =
          '${DateTime.now().microsecondsSinceEpoch.toString().padLeft(16, '0')}'
          '-${_sequence++}';
      final File target = File('${directory.path}/$stem$_suffix');
      // Temp file + rename, so a process death mid-write leaves either the
      // previous state or a complete batch — never half a JSON document that
      // replay would have to understand.
      final File temp = File('${target.path}.tmp');
      await temp.writeAsString(_encode(logRecords), flush: true);
      await temp.rename(target.path);
      await _evict();
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _evict() async {
    final List<File> files = await _oldestFirst();
    if (files.length > maxBatches) {
      for (final File file in files.take(files.length - maxBatches)) {
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

  String _encode(List<ReadableLogRecord> logRecords) {
    final Resource? resource = logRecords.first.resource;
    return jsonEncode(<String, Object?>{
      'v': 1,
      'resource': _encodeAttributes(resource?.attributes),
      'records': logRecords.map(_encodeRecord).toList(),
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
