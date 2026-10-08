// The logs pipeline `start()` builds behind the stamper still obeys the
// environment: `OTEL_LOGS_EXPORTER=none` means no log leaves the device, and
// the stamper being in the provider changes nothing about that. Spans have
// their own exporter variable and are unaffected.
//
// In its own file: `OTel.initialize()` may only be called once per isolate.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

import 'support/local-collector.dart';
import 'support/otlp-wire.dart';

void main() {
  test(
    'OTEL_LOGS_EXPORTER=none sends no logs, and spans still carry the id',
    () async {
      EnvironmentService.testOverrides = <String, String>{
        'OTEL_LOGS_EXPORTER': 'none',
      };
      addTearDown(() => EnvironmentService.testOverrides = null);
      final LocalCollector collector = await LocalCollector.start();
      addTearDown(collector.close);
      final OtelZone observability = OtelZone(
        OtelZoneConfig(
          serviceName: 'end-user-env-test',
          endpoint: collector.endpoint,
          useConsoleLogs: false,
          presentFlutterErrors: false,
        ),
      );
      await observability.start(serviceVersion: '1.2.3');
      expect(observability.isReady, isTrue);

      observability.setEndUser('user-1');
      observability.talker.warning('goes nowhere');
      await OTel.loggerProvider().forceFlush();
      OTel.tracerProvider()
          .getTracer('end-user-env-test')
          .startSpan('still sent')
          .end();
      await OTel.tracerProvider().forceFlush();
      await collector.waitForRequests(1);
      // Logs would have been flushed with the line above; give any stray one the
      // same moment to arrive before saying none did.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(collector.requests.where((r) => r.path == '/v1/logs'), isEmpty);
      expect(collector.wireSpans.single.name, 'still sent');
    },
  );
}
