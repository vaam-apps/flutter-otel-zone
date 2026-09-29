// A redactor that throws on a span, through `OtelZone.start()`: the app is
// told once, on its talker, and the span is not exported.
//
// In its own file: `OTel.initialize()` may only be called once per isolate.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

import 'support/local-collector.dart';

void main() {
  test(
    'warns once when a throwing redactor drops spans, and drops them',
    () async {
      final LocalCollector collector = await LocalCollector.start();
      addTearDown(collector.close);
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelZone zone = OtelZone(
        OtelZoneConfig(
          serviceName: 'span-drop-test',
          endpoint: collector.endpoint,
          useConsoleLogs: false,
          enableLogs: false,
          redact: (String input) => input.contains('boom')
              ? throw StateError('cannot scrub $input')
              : input,
        ),
        sink: sink,
      );
      await zone.start(serviceVersion: '1.2.3');
      expect(zone.isReady, isTrue);

      final Tracer tracer = OTel.tracerProvider().getTracer('span-drop-test');
      tracer.startSpan('boom one').end();
      tracer.startSpan('boom two').end();
      tracer.startSpan('fine').end();
      await OTel.tracerProvider().forceFlush();
      await collector.waitForRequests(1);

      final String wire = collector.requests.map((r) => r.body).join('\n');
      expect(wire, contains('fine'));
      expect(wire, isNot(contains('boom')));
      expect(
        sink.records.where(
          (r) => (r.message ?? '').contains('dropped because redact threw'),
        ),
        hasLength(1),
        reason: 'once, not once per span',
      );
      // The reason names the type of the failure, never its text, which may
      // hold what the redactor was looking at.
      expect(
        sink.records.map((r) => r.message ?? '').join('\n'),
        isNot(contains('cannot scrub')),
      );
    },
  );
}
