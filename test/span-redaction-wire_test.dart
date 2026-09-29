// `redact` on the wire, for spans: what a collector actually receives.
//
// Real sockets, through `OtelZone.start()`, because the fake-exporter tests
// prove the scrubber and cannot prove it is the thing `start()` installs. A
// span pipeline built without it would pass every one of them.
//
// In its own file: `OTel.initialize()` may only be called once per isolate.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:riverpod/riverpod.dart';

import 'support/local-collector.dart';

final Provider<int> _dialing = Provider.family<int, String>(
  (Ref ref, String who) => throw StateError('could not reach 699887766'),
)('someone');

void main() {
  test('a span with PII in it reaches the collector scrubbed', () async {
    final LocalCollector collector = await LocalCollector.start();
    addTearDown(collector.close);
    // The credentials the collector needs. The rebuilt trace pipeline has to
    // read them from the same variables dartastic's own does, or spans reach a
    // collector that wants a token without it.
    EnvironmentService.testOverrides = <String, String>{
      'OTEL_EXPORTER_OTLP_TRACES_HEADERS': 'x-trace-token=s3cret',
    };
    addTearDown(() => EnvironmentService.testOverrides = null);
    final OtelZone zone = OtelZone(
      OtelZoneConfig(
        serviceName: 'span-wire-test',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
        enableLogs: false,
        redact: (String input) => input.replaceAll(RegExp(r'\d{9}'), '<phone>'),
      ),
      sink: RecordingTalkerObserver(),
    );
    await zone.start(serviceVersion: '1.2.3');
    // Without this the test could pass on a zone whose SDK never came up.
    expect(zone.isReady, isTrue);

    final Span span = OTel.tracerProvider()
        .getTracer('span-wire-test')
        .startSpan(
          'lookup 699887766',
          attributes: OTel.attributesFromMap(<String, Object>{
            'user.phone': '699887766',
          }),
        );
    span.recordException(
      StateError('bad number 699887766'),
      stackTrace: StackTrace.fromString('#0 dial(699887766)'),
    );
    span.setStatus(SpanStatusCode.Error, 'unreachable 699887766');
    span.end();

    // A failed provider, through the observer an app installs: this is the
    // path that sent a user's data to a collector in the field.
    final ProviderContainer container = ProviderContainer(
      observers: <ProviderObserver>[?zone.riverpodObserver()],
    );
    addTearDown(container.dispose);
    expect(() => container.read(_dialing), throwsA(anything));

    await OTel.tracerProvider().forceFlush();
    await collector.waitForRequests(1);

    final String wire = collector.requests.map((r) => r.body).join('\n');
    // The scrubbed form is there, so the assertion below is about the
    // redactor having run and not about nothing having been sent.
    expect(wire, contains('lookup <phone>'));
    expect(wire, contains('user.phone'));
    expect(wire, contains('unreachable <phone>'));
    expect(wire, contains('provider.failed:'));
    expect(wire, isNot(contains('699887766')));

    // The spans travelled with the credentials.
    expect(
      collector.requests.any(
        (CollectedRequest r) => r.headers['x-trace-token'] == 's3cret',
      ),
      isTrue,
      reason: 'no request carried OTEL_EXPORTER_OTLP_TRACES_HEADERS',
    );
  });
}
