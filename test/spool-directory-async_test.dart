// `spoolDirectory` accepts what `path_provider` hands back, in its own file
// because a successful `start()` has to be the first one in its isolate (see
// `native-crash-start_test.dart`).
//
// This file is also the compiled twin of the README's "Faults recorded
// offline" snippet. A README cannot be analysed, so the snippet's shape lives
// here where `flutter analyze` and `flutter test` compile it: if
// `spoolDirectory` ever stops accepting a `Future<Directory> Function()`, this
// file stops compiling and the README is known to be wrong.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

import 'support/local-collector.dart';

/// `getApplicationSupportDirectory`'s exact signature. Not imported from
/// `path_provider`, which this package does not depend on; its function is a
/// top-level `Future<Directory> Function()` and nothing more.
Future<Directory> Function() _getApplicationSupportDirectory(
  Directory directory,
) => () async {
  // A real platform-channel round trip is not instantaneous.
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return directory;
};

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
  test('a spoolDirectory that returns a Future is awaited before the spool is '
      'built', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'otel_zone_async_spool',
    );
    addTearDown(() => directory.delete(recursive: true));
    // Never answers, so the spooled file stays on disk to be counted.
    final LocalCollector collector = await LocalCollector.start(hang: true);
    addTearDown(collector.close);

    // The README's snippet, with `path_provider`'s function passed as it is.
    final Future<Directory> Function() getApplicationSupportDirectory =
        _getApplicationSupportDirectory(directory);
    final OtelZone subject = OtelZone(
      OtelZoneConfig(
        serviceName: 'test-app',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
        spoolDirectory: getApplicationSupportDirectory,
      ),
      nativeCrashSource: _FakeCrashSource(),
    );

    await subject.start(serviceVersion: '1.2.3');

    // Without this the test could pass on a zone whose SDK never came up.
    expect(subject.isReady, isTrue);
    // The recovered crash was written under the awaited directory, which
    // shows the resolved value, and not a pending future, reached the spool.
    expect(directory.listSync().whereType<File>(), isNotEmpty);
  });

  test('a spoolDirectory whose Future fails leaves telemetry off and does not '
      'throw', () async {
    final RecordingTalkerObserver sink = RecordingTalkerObserver();
    final OtelZone subject = OtelZone(
      OtelZoneConfig(
        serviceName: 'test-app',
        endpoint: 'http://localhost:1',
        useConsoleLogs: false,
        spoolDirectory: () async => throw const FileSystemException('no dir'),
      ),
      sink: sink,
    );

    await subject.start(serviceVersion: '1.2.3');

    expect(subject.isReady, isFalse);
  });
}
