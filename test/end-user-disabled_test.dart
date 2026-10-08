// `OTEL_SDK_DISABLED` with logs on: `OTel.initialize` builds neither pipeline,
// so neither stamper may be left behind, and `setEndUser` stays a harmless
// call. The sibling `span-redaction-disabled_test.dart` covers the trace side
// with a `redact` configured; this is the logs side.
//
// In its own file: `OTel.initialize()` may only be called once per isolate.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

void main() {
  test('a disabled SDK leaves no stamper in either provider', () async {
    EnvironmentService.testOverrides = <String, String>{
      'OTEL_SDK_DISABLED': 'true',
    };
    addTearDown(() => EnvironmentService.testOverrides = null);
    final OtelZone observability = OtelZone(
      const OtelZoneConfig(
        serviceName: 'end-user-disabled-test',
        endpoint: 'http://127.0.0.1:4318',
        useConsoleLogs: false,
      ),
      sink: RecordingTalkerObserver(),
    );

    await observability.start(serviceVersion: '1.2.3');

    expect(observability.isReady, isTrue);
    expect(OTel.tracerProvider().spanProcessors, isEmpty);
    expect(OTel.loggerProvider().logRecordProcessors, isEmpty);
    expect(() => observability.setEndUser('user-1'), returnsNormally);
    expect(observability.endUserId, 'user-1');
  });
}
