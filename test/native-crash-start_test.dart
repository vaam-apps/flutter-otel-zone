// The drain through `start()`, in its own file on purpose.
//
// `OTel.initialize()` may only be called once per isolate — the SDK throws on
// a second call — so a test that needs a *successful* `start()` has to be the
// first one in its file. Every other test in `otel-zone_test.dart` starts
// zones whose SDK is already down, which is why this one lives here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

import 'support/local-collector.dart';

/// The previous run's reports, handed straight to the drain.
class _FakeCrashSource implements NativeCrashSource {
  _FakeCrashSource(this.reports);

  final List<NativeCrashReport> reports;
  final List<List<String>> acknowledged = <List<String>>[];

  @override
  Future<List<NativeCrashReport>> pending() async => reports;

  @override
  Future<void> acknowledge(List<String> ids) async => acknowledged.add(ids);
}

void main() {
  test('start spools and acknowledges the previous run without waiting on the '
      'network', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'otel_zone_native',
    );
    addTearDown(() => directory.delete(recursive: true));
    // Accepts the request and never answers: a collector on a stalled
    // connection, which is what used to hold `start()` for the whole of
    // dartastic's timeout-and-retry budget.
    final LocalCollector collector = await LocalCollector.start(hang: true);
    addTearDown(collector.close);
    final _FakeCrashSource source = _FakeCrashSource(<NativeCrashReport>[
      NativeCrashReport(
        id: 'a',
        kind: 'native',
        timestampMicros: 1700000000000000,
      ),
      NativeCrashReport(
        id: 'b',
        kind: 'anr',
        timestampMicros: 1700000000000001,
      ),
    ]);
    final RecordingTalkerObserver sink = RecordingTalkerObserver();
    final OtelZone subject = OtelZone(
      OtelZoneConfig(
        serviceName: 'test-app',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
        spoolDirectory: () => directory,
      ),
      sink: sink,
      nativeCrashSource: source,
    );

    final Stopwatch elapsed = Stopwatch()..start();
    await subject.start(serviceVersion: '1.2.3');
    elapsed.stop();

    // Without this the test could pass on a zone whose SDK never came up.
    expect(subject.isReady, isTrue);
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
    expect(source.acknowledged, <List<String>>[
      <String>['a', 'b'],
    ]);
    // The delivery is really in flight, not skipped: the collector has the
    // request and has not answered it, and the file is still on disk.
    await collector.waitForRequests(1);
    final List<File> files = directory.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    final Map<String, Object?> spooled =
        jsonDecode(await files.single.readAsString()) as Map<String, Object?>;
    final List<Object?> records = spooled['records']! as List<Object?>;
    expect(records, hasLength(2));
    expect((records.first! as Map<String, Object?>)['severity'], 'FATAL');
    expect(
      (records.first! as Map<String, Object?>)['eventName'],
      NativeCrashDrain.eventCrash,
    );
    expect(
      (records.last! as Map<String, Object?>)['eventName'],
      NativeCrashDrain.eventAnr,
    );
  });
}
