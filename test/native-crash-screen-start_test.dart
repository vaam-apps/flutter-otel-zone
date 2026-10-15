// A recovered crash is never stamped with the screen of this launch, through
// `start()`.
//
// In its own file for the reason `native-crash-start_test.dart` gives:
// `OTel.initialize()` may only be called once per isolate, so a test that needs
// a successful `start()` is the first and only one in its file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

import 'support/local-collector.dart';

/// The previous run's reports, handed straight to the drain.
class _FakeCrashSource implements NativeCrashSource {
  _FakeCrashSource(this.reports);

  final List<NativeCrashReport> reports;

  @override
  Future<List<NativeCrashReport>> pending() async => reports;

  @override
  Future<void> acknowledge(List<String> ids) async {}
}

void main() {
  test('a recovered crash keeps the screen the platform wrote and is not '
      'stamped with the screen this launch shows', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'otel_zone_native_screen',
    );
    addTearDown(() => directory.delete(recursive: true));
    // Never answers, so the spool file is still on disk to read.
    final LocalCollector collector = await LocalCollector.start(hang: true);
    addTearDown(collector.close);
    final _FakeCrashSource source = _FakeCrashSource(<NativeCrashReport>[
      // The platform knew the screen of the launch that died.
      NativeCrashReport(
        id: 'a',
        kind: 'native',
        timestampMicros: 1700000000000000,
        attributes: <String, String>{
          NativeCrashDrain.crashedScreen: '/earlier',
        },
      ),
      // The platform did not: this one is "unknown".
      NativeCrashReport(
        id: 'b',
        kind: 'anr',
        timestampMicros: 1700000000000001,
      ),
    ]);
    final RecordingCrashScreenSink crashScreen = RecordingCrashScreenSink();
    final OtelZone subject = OtelZone(
      OtelZoneConfig(
        serviceName: 'test-app',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
        spoolDirectory: () => directory,
      ),
      nativeCrashSource: source,
      crashScreenSink: crashScreen,
    );
    // The screen of this launch, named before the drain runs.
    subject.setCrashScreen('/now');
    await pumpEventQueue();
    expect(crashScreen.screens, <String?>['/now']);

    await subject.start(serviceVersion: '1.2.3');

    // Without this the test could pass on a zone whose SDK never came up.
    expect(subject.isReady, isTrue);
    await collector.waitForRequests(1);
    final List<File> files = directory.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    final Map<String, Object?> spooled =
        jsonDecode(await files.single.readAsString()) as Map<String, Object?>;
    final List<Map<String, Object?>> records =
        (spooled['records']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .toList();
    expect(records, hasLength(2));
    final Map<String, Object?> crash =
        records.first['attributes']! as Map<String, Object?>;
    final Map<String, Object?> anr =
        records.last['attributes']! as Map<String, Object?>;
    expect(crash[NativeCrashDrain.crashedScreen], '/earlier');
    expect(anr.containsKey(NativeCrashDrain.crashedScreen), isFalse);
    expect(jsonEncode(anr), isNot(contains('/now')));
  });
}
