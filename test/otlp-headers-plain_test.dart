// Headers in a build with no spool: dartastic's own exporter carries the live
// records and this package builds the crash drain's. Its own file because a
// successful `start()` has to be the first one in its isolate.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

import 'support/local-collector.dart';

class _FakeCrashSource implements NativeCrashSource {
  final List<List<String>> acknowledged = <List<String>>[];

  @override
  Future<List<NativeCrashReport>> pending() async => <NativeCrashReport>[
    NativeCrashReport(
      id: 'a',
      kind: 'native',
      timestampMicros: 1700000000000000,
    ),
  ];

  @override
  Future<void> acknowledge(List<String> ids) async => acknowledged.add(ids);
}

void main() {
  test('the live path and the crash drain carry the same headers', () async {
    EnvironmentService.testOverrides = <String, String>{
      'OTEL_EXPORTER_OTLP_HEADERS': 'x-test=1',
    };
    addTearDown(() => EnvironmentService.testOverrides = null);
    final LocalCollector collector = await LocalCollector.start();
    addTearDown(collector.close);
    final _FakeCrashSource source = _FakeCrashSource();
    final OtelZone subject = OtelZone(
      OtelZoneConfig(
        serviceName: 'test-app',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
      ),
      // No test sink: a live record has to take the real path to the wire.
      nativeCrashSource: source,
    );

    await subject.start(serviceVersion: '1.2.3');
    expect(subject.isReady, isTrue);
    subject.talker.warning('live record');
    await OTel.loggerProvider().forceFlush();
    await collector.waitForRequests(2);

    for (final String needle in <String>[
      'live record',
      NativeCrashDrain.eventCrash,
    ]) {
      final CollectedRequest request = collector.requests.firstWhere(
        (CollectedRequest request) => request.body.contains(needle),
      );
      expect(request.headers['x-test'], '1', reason: 'the $needle request');
    }
    // With no spool the acknowledgement follows the accepted export.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(source.acknowledged, <List<String>>[
      <String>['a'],
    ]);
  });
}
