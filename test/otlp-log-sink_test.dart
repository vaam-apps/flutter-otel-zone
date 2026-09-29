// The crash harness reads what an app put on the wire, so the reader has to be
// right. It is checked against the SDK's own encoder — the same generated
// messages the app under test serialises with — rather than against bytes this
// file wrote by hand, which would only prove the decoder agrees with itself.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/otlp-log-sink.dart';

pb.KeyValue _string(String key, String value) => pb.KeyValue(
  key: key,
  value: pb.AnyValue(stringValue: value),
);

Uint8List _request() => pb.ExportLogsServiceRequest(
  resourceLogs: <pb.ResourceLogs>[
    pb.ResourceLogs(
      scopeLogs: <pb.ScopeLogs>[
        pb.ScopeLogs(
          logRecords: <pb.LogRecord>[
            pb.LogRecord(
              severityNumber: pb.SeverityNumber.SEVERITY_NUMBER_FATAL,
              body: pb.AnyValue(stringValue: 'crash'),
              attributes: <pb.KeyValue>[
                _string('device.crash.kind', 'native'),
                _string('event.name', 'device.crash'),
                pb.KeyValue(
                  key: 'a.number',
                  value: pb.AnyValue(intValue: Int64(7)),
                ),
              ],
            ),
            pb.LogRecord(
              severityNumber: pb.SeverityNumber.SEVERITY_NUMBER_WARN,
              body: pb.AnyValue(stringValue: 'ordinary'),
            ),
          ],
        ),
      ],
    ),
  ],
).writeToBuffer();

void main() {
  test('reads severity, body and string attributes from protobuf', () {
    final List<SinkRecord> records = decodeLogsProtobuf(_request());

    expect(records, hasLength(2));
    expect(records.first.isFatal, isTrue);
    expect(records.first.crashKind, 'native');
    expect(records.first.eventName, 'device.crash');
    expect(records.first.body, 'crash');
    // A non-string attribute is skipped, not mistaken for an empty string.
    expect(records.first.attributes.containsKey('a.number'), isFalse);
    expect(records.last.isFatal, isFalse);
    expect(records.last.crashKind, isNull);
  });

  test('an empty request decodes to no records', () {
    expect(decodeLogsProtobuf(Uint8List(0)), isEmpty);
  });

  test('a truncated request throws instead of returning a partial list', () {
    final Uint8List whole = _request();
    expect(
      () =>
          decodeLogsProtobuf(Uint8List.sublistView(whole, 0, whole.length - 5)),
      throwsFormatException,
    );
  });

  test('reads the JSON encoding too', () {
    final List<SinkRecord> records = decodeLogsJson(<String, Object?>{
      'resourceLogs': <Object?>[
        <String, Object?>{
          'scopeLogs': <Object?>[
            <String, Object?>{
              'logRecords': <Object?>[
                <String, Object?>{
                  'severityNumber': 21,
                  'body': <String, Object?>{'stringValue': 'boom'},
                  'attributes': <Object?>[
                    <String, Object?>{
                      'key': 'device.crash.kind',
                      'value': <String, Object?>{'stringValue': 'jvm'},
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
    });

    expect(records.single.crashKind, 'jvm');
    expect(records.single.isFatal, isTrue);
  });

  group('OtlpLogSink', () {
    late OtlpLogSink sink;
    late HttpClient client;

    setUp(() async {
      sink = await OtlpLogSink.bind(0);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await sink.close();
    });

    Future<int> post(
      String path,
      List<int> body, {
      bool gzipped = false,
    }) async {
      final HttpClientRequest request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${sink.port}$path'),
      );
      request.headers.contentType = ContentType('application', 'x-protobuf');
      if (gzipped) request.headers.set('content-encoding', 'gzip');
      request.add(body);
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    test(
      'keeps log records, and acknowledges traces without keeping them',
      () async {
        expect(await post('/v1/logs', _request()), HttpStatus.ok);
        expect(await post('/v1/traces', <int>[1, 2, 3]), HttpStatus.ok);

        expect(sink.records, hasLength(2));
        sink.clear();
        expect(sink.records, isEmpty);
      },
    );

    test('understands a gzipped body', () async {
      expect(
        await post('/v1/logs', gzip.encode(_request()), gzipped: true),
        HttpStatus.ok,
      );
      expect(sink.records.first.crashKind, 'native');
    });

    test('refuses a body it cannot read', () async {
      expect(
        await post('/v1/logs', utf8.encode('not protobuf')),
        HttpStatus.badRequest,
      );
      expect(sink.records, isEmpty);
    });
  });
}
