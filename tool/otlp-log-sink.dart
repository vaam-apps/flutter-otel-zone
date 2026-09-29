// A throwaway OTLP/HTTP log receiver, for tests that need to see what a real
// app sent.
//
// The crash harness asks one question of the app under test: "which native
// crashes did you recover on this launch?" The honest place to read the answer
// is the wire, because that is what a collector would receive — a marker the
// app prints about itself would only prove the app believes it sent something.
// So this listens on a port, accepts whatever the OTLP exporters post, and
// keeps the log records.
//
// It decodes just enough protobuf (or JSON) to read a log record's severity,
// body and string attributes. No SDK types are imported: the receiver must not
// share code with the sender it is checking.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One received log record: the fields a crash assertion reads.
class SinkRecord {
  /// Creates a record.
  const SinkRecord({
    required this.severityNumber,
    required this.attributes,
    this.resource = const <String, String>{},
    this.body,
    this.eventName,
  });

  /// The OTLP severity number; `21`-`24` is FATAL.
  final int severityNumber;

  /// The record's string-valued attributes.
  final Map<String, String> attributes;

  /// The string-valued attributes of the resource the record was exported
  /// under: for a crash recovered by a later launch, that launch's identity,
  /// not the crashed run's.
  final Map<String, String> resource;

  /// The record body, when it is a string.
  final String? body;

  /// The record's event name: the OTLP field when the sender set it, else the
  /// `event.name` attribute the package writes.
  final String? eventName;

  /// Whether this is a FATAL record.
  bool get isFatal => severityNumber >= 21;

  /// The `device.crash.kind` attribute, when this is a recovered native death.
  String? get crashKind => attributes['device.crash.kind'];

  @override
  String toString() =>
      'SinkRecord(severity: $severityNumber, event: $eventName, '
      'kind: $crashKind, type: ${attributes['exception.type']}, '
      'body: $body)';
}

/// Decodes an OTLP `ExportLogsServiceRequest` in protobuf wire format.
///
/// Field numbers are from `opentelemetry/proto/{collector/logs/v1/
/// logs_service,logs/v1/logs,common/v1/common}.proto`. Unknown fields are
/// skipped; a truncated message throws [FormatException].
List<SinkRecord> decodeLogsProtobuf(Uint8List bytes) {
  final List<SinkRecord> records = <SinkRecord>[];
  // ExportLogsServiceRequest.resource_logs = 1
  for (final Uint8List resourceLogs in _fields(bytes, 1)) {
    // ResourceLogs.resource = 1, Resource.attributes = 1
    final Map<String, String> resource = <String, String>{};
    for (final Uint8List message in _fields(resourceLogs, 1)) {
      for (final Uint8List attribute in _fields(message, 1)) {
        final (String key, String? value) = _keyValue(attribute);
        if (value != null) resource[key] = value;
      }
    }
    // ResourceLogs.scope_logs = 2
    for (final Uint8List scopeLogs in _fields(resourceLogs, 2)) {
      // ScopeLogs.log_records = 2
      for (final Uint8List record in _fields(scopeLogs, 2)) {
        records.add(_decodeRecord(record, resource));
      }
    }
  }
  return records;
}

SinkRecord _decodeRecord(Uint8List record, Map<String, String> resource) {
  int severity = 0;
  String? body;
  String? eventName;
  final Map<String, String> attributes = <String, String>{};
  final _Reader reader = _Reader(record);
  while (!reader.done) {
    final (int field, int wire) = reader.tag();
    switch ((field, wire)) {
      case (2, 0): // severity_number
        severity = reader.varint();
      case (5, 2): // body: AnyValue
        body = _anyValueString(reader.bytes());
      case (6, 2): // attributes: KeyValue
        final (String key, String? value) = _keyValue(reader.bytes());
        if (value != null) attributes[key] = value;
      case (12, 2): // event_name
        eventName = utf8.decode(reader.bytes());
      default:
        reader.skip(wire);
    }
  }
  return SinkRecord(
    severityNumber: severity,
    attributes: attributes,
    resource: resource,
    body: body,
    eventName: eventName ?? attributes['event.name'],
  );
}

(String, String?) _keyValue(Uint8List message) {
  String key = '';
  String? value;
  final _Reader reader = _Reader(message);
  while (!reader.done) {
    final (int field, int wire) = reader.tag();
    switch ((field, wire)) {
      case (1, 2):
        key = utf8.decode(reader.bytes());
      case (2, 2):
        value = _anyValueString(reader.bytes());
      default:
        reader.skip(wire);
    }
  }
  return (key, value);
}

/// `AnyValue.string_value` (field 1), or `null` for any other kind.
String? _anyValueString(Uint8List message) {
  final _Reader reader = _Reader(message);
  while (!reader.done) {
    final (int field, int wire) = reader.tag();
    if (field == 1 && wire == 2) return utf8.decode(reader.bytes());
    reader.skip(wire);
  }
  return null;
}

/// Every length-delimited occurrence of [field] in [message].
Iterable<Uint8List> _fields(Uint8List message, int field) sync* {
  final _Reader reader = _Reader(message);
  while (!reader.done) {
    final (int number, int wire) = reader.tag();
    if (number == field && wire == 2) {
      yield reader.bytes();
    } else {
      reader.skip(wire);
    }
  }
}

class _Reader {
  _Reader(this._data);

  final Uint8List _data;
  int _offset = 0;

  bool get done => _offset >= _data.length;

  (int, int) tag() {
    final int key = varint();
    return (key >> 3, key & 7);
  }

  int varint() {
    int result = 0;
    int shift = 0;
    while (true) {
      if (_offset >= _data.length || shift > 63) {
        throw const FormatException('truncated varint');
      }
      final int byte = _data[_offset++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final int length = varint();
    if (length < 0 || _offset + length > _data.length) {
      throw const FormatException('length runs past the message');
    }
    final Uint8List view = Uint8List.sublistView(
      _data,
      _offset,
      _offset + length,
    );
    _offset += length;
    return view;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        _advance(8);
      case 2:
        bytes();
      case 5:
        _advance(4);
      default:
        throw FormatException('unsupported wire type $wire');
    }
  }

  void _advance(int count) {
    if (_offset + count > _data.length) {
      throw const FormatException('truncated fixed-width field');
    }
    _offset += count;
  }
}

/// Decodes an OTLP/JSON `ExportLogsServiceRequest`.
List<SinkRecord> decodeLogsJson(Object? json) {
  final List<SinkRecord> records = <SinkRecord>[];
  for (final Object? resourceLogs in _list(
    (json as Map<String, Object?>)['resourceLogs'],
  )) {
    final Map<String, String> resource = _jsonAttributes(
      ((resourceLogs as Map<String, Object?>)['resource']
          as Map<String, Object?>?)?['attributes'],
    );
    for (final Object? scope in _list(resourceLogs['scopeLogs'])) {
      for (final Object? record in _list(
        (scope as Map<String, Object?>)['logRecords'],
      )) {
        final Map<String, Object?> map = record as Map<String, Object?>;
        final Map<String, String> attributes = _jsonAttributes(
          map['attributes'],
        );
        records.add(
          SinkRecord(
            severityNumber: (map['severityNumber'] as num?)?.toInt() ?? 0,
            attributes: attributes,
            resource: resource,
            body:
                (map['body'] as Map<String, Object?>?)?['stringValue']
                    as String?,
            eventName: map['eventName'] as String? ?? attributes['event.name'],
          ),
        );
      }
    }
  }
  return records;
}

/// The string-valued entries of an OTLP/JSON `KeyValue` list.
Map<String, String> _jsonAttributes(Object? list) {
  final Map<String, String> attributes = <String, String>{};
  for (final Object? attribute in _list(list)) {
    final Map<String, Object?> kv = attribute as Map<String, Object?>;
    final Object? value =
        (kv['value'] as Map<String, Object?>?)?['stringValue'];
    if (value is String) attributes[kv['key'] as String] = value;
  }
  return attributes;
}

List<Object?> _list(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

/// An HTTP server that answers every OTLP export with success and keeps the
/// log records it was sent.
class OtlpLogSink {
  OtlpLogSink._(this._server) {
    _server.listen(_handle);
  }

  /// Listens on [port] on the loopback interface. The caller reaches it from a
  /// device with `adb reverse`.
  static Future<OtlpLogSink> bind(int port) async =>
      OtlpLogSink._(await HttpServer.bind(InternetAddress.loopbackIPv4, port));

  final HttpServer _server;
  final List<SinkRecord> _records = <SinkRecord>[];

  /// Every log record received since the last [clear].
  List<SinkRecord> get records => List<SinkRecord>.unmodifiable(_records);

  /// The port actually bound.
  int get port => _server.port;

  /// Forgets what has been received.
  void clear() => _records.clear();

  /// Stops listening.
  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      final List<int> raw = <int>[
        for (final List<int> chunk in await request.toList()) ...chunk,
      ];
      // Only log exports matter; the SDK also posts traces to this endpoint,
      // and they are acknowledged and ignored.
      if (request.uri.path.endsWith('/v1/logs')) {
        final bool gzipped =
            request.headers.value('content-encoding') == 'gzip';
        final Uint8List body = Uint8List.fromList(
          gzipped ? gzip.decode(raw) : raw,
        );
        final bool json = (request.headers.contentType?.mimeType ?? '')
            .contains('json');
        _records.addAll(
          json
              ? decodeLogsJson(jsonDecode(utf8.decode(body)))
              : decodeLogsProtobuf(body),
        );
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'x-protobuf');
    } on Object {
      request.response.statusCode = HttpStatus.badRequest;
    }
    await request.response.close();
  }
}
