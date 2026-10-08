// `setEndUser` on the wire, through `OtelZone.start()` and a real socket.
//
// The SDK-level tests next door prove what the stampers do once they are in
// place. This is the proof that `start()` puts them there, in front of a
// pipeline that scrubs: a build with `redact` set, spans and logs both on.
// A start-up that forgot the stampers, or put the log stamper behind the batch
// processor, would pass every one of them.
//
// In its own file: `OTel.initialize()` may only be called once per isolate.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

import 'support/local-collector.dart';
import 'support/otlp-wire.dart';

/// A cuid with a nine-digit run in it, which the phone redactor below masks.
const String _cuid = 'cmg20000000009abcd1234efgh';

void main() {
  test('spans and logs carry the id from the call to the clear, scrubbed '
      'around it but not the id', () async {
    final LocalCollector collector = await LocalCollector.start();
    addTearDown(collector.close);
    final OtelZone observability = OtelZone(
      OtelZoneConfig(
        serviceName: 'end-user-wire-test',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
        presentFlutterErrors: false,
        redact: (String input) => input.replaceAll(RegExp(r'\d{9}'), '<phone>'),
      ),
    );
    await observability.start(serviceVersion: '1.2.3');
    // Without this the test could pass on a zone whose SDK never came up.
    expect(observability.isReady, isTrue);

    final Tracer tracer = OTel.tracerProvider().getTracer('end-user-wire-test');
    Future<void> span(String name) async {
      tracer
          .startSpan(
            name,
            attributes: OTel.attributesFromMap(<String, Object>{
              'user.phone': '699887766',
            }),
          )
          .end();
      await OTel.tracerProvider().forceFlush();
    }

    // The path an app takes: Talker, the bridge, the redactor, the SDK.
    Future<void> log(String message) async {
      observability.talker.warning(message);
      await OTel.loggerProvider().forceFlush();
    }

    // Before anyone is linked, then linked, then not.
    await span('span-before');
    await log('log-before 699887766');
    observability.setEndUser(_cuid);
    await span('span-during');
    await log('log-during 699887766');
    observability.setEndUser(null);
    await span('span-after');
    await log('log-after 699887766');

    final Map<String, pb.Span> spans = <String, pb.Span>{
      for (final pb.Span s in collector.wireSpans) s.name: s,
    };
    expect(
      spans.keys,
      containsAll(<String>['span-before', 'span-during', 'span-after']),
    );
    expect(wireString(spans['span-before']!.attributes, 'enduser.id'), isNull);
    expect(
      wireString(spans['span-during']!.attributes, 'enduser.id'),
      _cuid,
      reason: 'the redactor masks nine digits in a row; the id must not be',
    );
    expect(wireString(spans['span-after']!.attributes, 'enduser.id'), isNull);
    // The redactor was running throughout: everything else is scrubbed.
    for (final pb.Span s in spans.values) {
      expect(wireString(s.attributes, 'user.phone'), '<phone>');
    }

    final Map<String, pb.LogRecord> logs = <String, pb.LogRecord>{
      for (final pb.LogRecord r in collector.wireLogs)
        for (final String key in <String>['before', 'during', 'after'])
          if (r.body.stringValue.contains('log-$key')) key: r,
    };
    expect(logs.keys, containsAll(<String>['before', 'during', 'after']));
    expect(wireString(logs['before']!.attributes, 'enduser.id'), isNull);
    expect(wireString(logs['during']!.attributes, 'enduser.id'), _cuid);
    expect(wireCount(logs['during']!.attributes, 'enduser.id'), 1);
    expect(wireString(logs['after']!.attributes, 'enduser.id'), isNull);
    // The bridge's redactor scrubbed the message, and the id was untouched.
    for (final pb.LogRecord r in logs.values) {
      expect(r.body.stringValue, contains('<phone>'));
      expect(r.body.stringValue, isNot(contains('699887766')));
    }
  });
}
