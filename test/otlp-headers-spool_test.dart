// Headers on every path a spooling build sends by, in its own file because a
// successful `start()` has to be the first one in its isolate (see
// `native-crash-start_test.dart`).
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

import 'support/local-collector.dart';

class _FakeCrashSource implements NativeCrashSource {
  @override
  Future<List<NativeCrashReport>> pending() async => <NativeCrashReport>[
    NativeCrashReport(
      id: 'a',
      kind: 'native',
      timestampMicros: 1700000000000000,
    ),
  ];

  @override
  Future<void> acknowledge(List<String> ids) async {}
}

void main() {
  test(
    'the spool, its replay and the crash drain all carry the OTLP headers',
    () async {
      EnvironmentService.testOverrides = <String, String>{
        'OTEL_EXPORTER_OTLP_HEADERS': 'x-test=1,authorization=Bearer abc=',
      };
      addTearDown(() => EnvironmentService.testOverrides = null);
      final Directory directory = await Directory.systemTemp.createTemp(
        'otel_zone_headers',
      );
      addTearDown(() => directory.delete(recursive: true));
      final LocalCollector collector = await LocalCollector.start();
      addTearDown(collector.close);
      // What a previous launch left behind, for the replay path to find.
      await File(
        '${directory.path}/0000000000000001-0-1.spool.json',
      ).writeAsString(
        '{"v":1,"resource":{},"records":'
        '[{"body":"seeded batch","severity":"WARN"}]}',
      );

      final OtelZone subject = OtelZone(
        OtelZoneConfig(
          serviceName: 'test-app',
          endpoint: collector.endpoint,
          useConsoleLogs: false,
          spoolDirectory: () => directory,
        ),
        // No test sink: a live record has to take the real path to the wire.
        nativeCrashSource: _FakeCrashSource(),
      );
      await subject.start(serviceVersion: '1.2.3');
      expect(subject.isReady, isTrue);

      // A live record, which goes through the batch processor and then the
      // spool's `export`.
      subject.talker.warning('live record');
      await OTel.loggerProvider().forceFlush();
      await collector.waitForRequests(3);

      CollectedRequest carrying(String needle) => collector.requests.firstWhere(
        (CollectedRequest request) => request.body.contains(needle),
      );
      for (final String needle in <String>[
        'live record',
        'seeded batch',
        NativeCrashDrain.eventCrash,
      ]) {
        final Map<String, String> headers = carrying(needle).headers;
        expect(headers['x-test'], '1', reason: 'the $needle request');
        // The value is kept whole, `=` and all, and never altered on the way.
        expect(
          headers['authorization'],
          'Bearer abc=',
          reason: 'the $needle request',
        );
      }
    },
  );
}
