// `spoolMaxBytes` reaches the spool `OtelZone.start()` builds, in its own file
// because a successful `start()` has to be the first one in its isolate (see
// `native-crash-start_test.dart`).
import 'dart:io';

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
  test('the default is 5 MiB and null is allowed', () {
    expect(
      OtelZoneConfig(
        serviceName: 'a',
        endpoint: 'http://localhost:1',
      ).spoolMaxBytes,
      5 * 1024 * 1024,
    );
    expect(
      OtelZoneConfig(
        serviceName: 'a',
        endpoint: 'http://localhost:1',
        spoolMaxBytes: null,
      ).spoolMaxBytes,
      isNull,
    );
  });

  test('a spoolMaxBytes too small for the recovered crash batch leaves the '
      'spool empty', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'otel_zone_max_bytes',
    );
    addTearDown(() => directory.delete(recursive: true));
    // Never answers, so anything spooled would stay on disk to be counted.
    final LocalCollector collector = await LocalCollector.start(hang: true);
    addTearDown(collector.close);
    final RecordingTalkerObserver sink = RecordingTalkerObserver();

    final OtelZone subject = OtelZone(
      OtelZoneConfig(
        serviceName: 'test-app',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
        spoolDirectory: () => directory,
        spoolMaxBytes: 1,
      ),
      nativeCrashSource: _FakeCrashSource(),
      sink: sink,
    );

    await subject.start(serviceVersion: '1.2.3');

    expect(subject.isReady, isTrue);
    expect(directory.listSync().whereType<File>(), isEmpty);
  });
}
