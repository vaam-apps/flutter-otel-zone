// `runGuarded` in a browser. The VM tests cannot stand in for this: `kIsWeb`
// is a constant there and `dart:isolate` works. Before 0.8.1 runGuarded opened
// a ReceivePort ahead of its body, a browser throws UnsupportedError for that,
// the zone's own handler took it, and the body never ran: a blank page.
// ci.yml's `web` job runs this file; plain `flutter test` skips it.
@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:talker/talker.dart';

const OtelZoneConfig _config = OtelZoneConfig(
  serviceName: 'test-app',
  endpoint: 'http://127.0.0.1:4318',
  useConsoleLogs: false,
  presentFlutterErrors: false,
);

OtelZone _zone() => OtelZone(
  _config,
  sink: RecordingTalkerObserver(),
  crashScreenSink: RecordingCrashScreenSink(),
);

bool _reported(OtelZone zone, String text) => zone.talker.history.any(
  (TalkerData entry) => entry.error?.toString().contains(text) ?? false,
);

/// [OtelZone.runGuarded], but a run that never returns fails the test instead
/// of hanging it until the framework's own timeout.
Future<void> _guarded(OtelZone zone, Future<void> Function() body) => zone
    .runGuarded(body)
    .timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('runGuarded never returned: its body did not run'),
    );

void main() {
  late FlutterExceptionHandler? flutterOnError;
  late bool Function(Object, StackTrace)? platformOnError;

  setUp(() {
    flutterOnError = FlutterError.onError;
    platformOnError = PlatformDispatcher.instance.onError;
  });

  tearDown(() {
    FlutterError.onError = flutterOnError;
    PlatformDispatcher.instance.onError = platformOnError;
  });

  test('runs its body, returns, and reports nothing on the way', () async {
    final OtelZone subject = _zone();
    var ran = false;

    await _guarded(subject, () async {
      ran = true;
    });

    expect(ran, isTrue);
    expect(
      subject.talker.history,
      isEmpty,
      reason:
          'no UnsupportedError from dart:isolate and no warning: the web '
          'skips that hook',
    );
  });

  test('an uncaught async error inside the body reaches the talker', () async {
    final OtelZone subject = _zone();

    await _guarded(subject, () async {
      unawaited(Future<void>.error(StateError('escaped')));
      // Let the microtask queue deliver it before the body returns.
      await Future<void>.delayed(Duration.zero);
    });

    expect(_reported(subject, 'escaped'), isTrue);
  });

  test('a framework error reaches the talker', () async {
    final OtelZone subject = _zone();
    // Detach the ambient handler first: runGuarded chains to whatever it
    // replaced, and here that is the test framework's own reporter.
    FlutterError.onError = null;

    await _guarded(subject, () async {
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('a build failed'),
          context: ErrorDescription('while laying out'),
        ),
      );
    });

    expect(_reported(subject, 'a build failed'), isTrue);
  });
}
