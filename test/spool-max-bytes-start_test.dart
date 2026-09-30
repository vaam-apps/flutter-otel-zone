// `spoolMaxBytes` reaches the spool `OtelZone.start()` builds, in its own file
// because a successful `start()` has to be the first one in its isolate (see
// `native-crash-start_test.dart`).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:talker/talker.dart';

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

  final List<List<String>> acknowledged = <List<String>>[];

  @override
  Future<void> acknowledge(List<String> ids) async => acknowledged.add(ids);
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
      'spool empty and the report unacknowledged', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'otel_zone_max_bytes',
    );
    addTearDown(() => directory.delete(recursive: true));
    // Never answers, so anything spooled would stay on disk to be counted.
    final LocalCollector collector = await LocalCollector.start(hang: true);
    addTearDown(collector.close);
    final RecordingTalkerObserver sink = RecordingTalkerObserver();
    final _FakeCrashSource source = _FakeCrashSource();

    final OtelZone subject = OtelZone(
      OtelZoneConfig(
        serviceName: 'test-app',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
        spoolDirectory: () => directory,
        spoolMaxBytes: 1,
      ),
      nativeCrashSource: source,
      sink: sink,
    );

    await subject.start(serviceVersion: '1.2.3');

    expect(subject.isReady, isTrue);
    expect(directory.listSync().whereType<File>(), isEmpty);
    // Never spooled, and the collector never answered, so the report is still
    // the platform's copy: acknowledging it would lose it.
    expect(source.acknowledged, isEmpty);
    // The oversize refusal is reported once, not once by `enqueue` and once
    // by the direct export that follows it.
    expect(
      sink.records.where(
        (TalkerData d) => '${d.message}'.contains('spoolMaxBytes'),
      ),
      hasLength(1),
    );
  });
}
