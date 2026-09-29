// `OTEL_SDK_DISABLED` makes `OTel.initialize` skip the trace pipeline, so the
// batch processor `start()` built for `redact` is never installed. It must not
// be left running.
//
// In its own file: `OTel.initialize()` may only be called once per isolate.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

void main() {
  test('start still completes, and no processor is left installed', () async {
    EnvironmentService.testOverrides = <String, String>{
      'OTEL_SDK_DISABLED': 'true',
    };
    addTearDown(() => EnvironmentService.testOverrides = null);
    final OtelZone zone = OtelZone(
      OtelZoneConfig(
        serviceName: 'span-disabled-test',
        endpoint: 'http://127.0.0.1:4318',
        useConsoleLogs: false,
        enableLogs: false,
        redact: (String input) => input,
      ),
      sink: RecordingTalkerObserver(),
    );

    await zone.start(serviceVersion: '1.2.3');

    expect(zone.isReady, isTrue);
    expect(OTel.tracerProvider().spanProcessors, isEmpty);
  });
}
