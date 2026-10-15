// `OtelZone.setCrashScreen`: what reaches the platform, and when.
//
// The forwarder is the part with rules (one message in flight, the latest
// value after it, a failure that stops or warns once), so most of these tests
// hold the platform's answer back and count what was sent. The platform itself
// is never reached: the Pigeon test at the end mocks the channel.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:otel_zone/src/crash-screen.dart';
import 'package:talker/talker.dart';

const OtelZoneConfig _config = OtelZoneConfig(
  serviceName: 'test-app',
  endpoint: 'http://127.0.0.1:4318',
  useConsoleLogs: false,
  presentFlutterErrors: false,
);

const String _channel =
    'dev.flutter.pigeon.otel_zone.CrashContextApi.setCrashScreen';

/// A platform whose answers the test gives: each call's future completes
/// when the test completes it, and nothing is sent past the first one while
/// [holding] is set.
class _HeldSink implements CrashScreenSink {
  final List<String?> screens = <String?>[];
  final List<Completer<void>> pending = <Completer<void>>[];

  @override
  Future<void> setCrashScreen(String? screen) {
    screens.add(screen);
    final Completer<void> answer = Completer<void>();
    pending.add(answer);
    return answer.future;
  }
}

/// A platform that fails every call with [error], asynchronously.
class _FailingSink implements CrashScreenSink {
  _FailingSink(this.error);

  final Object error;
  final List<String?> screens = <String?>[];

  @override
  Future<void> setCrashScreen(String? screen) {
    screens.add(screen);
    return Future<void>.error(error);
  }
}

/// A platform whose method throws before it returns a future.
class _ThrowingSink implements CrashScreenSink {
  final List<String?> screens = <String?>[];

  @override
  Future<void> setCrashScreen(String? screen) {
    screens.add(screen);
    throw StateError('channel exploded');
  }
}

/// A zone whose talker records what it warns about, and whose screen goes to
/// [crashScreen].
OtelZone zoneWith(
  CrashScreenSink crashScreen,
  RecordingTalkerObserver observed,
) {
  return OtelZone(
    _config,
    talker: Talker(
      observer: observed,
      settings: TalkerSettings(useConsoleLogs: false),
    ),
    crashScreenSink: crashScreen,
  );
}

/// The messages the zone's talker warned with, in order.
List<String> warnings(RecordingTalkerObserver observed) => observed.records
    .where((TalkerData r) => r.logLevel == LogLevel.warning)
    .map((TalkerData r) => r.message ?? '')
    .toList();

void main() {
  setUp(() {
    // Every test below is an Android one: on any other platform nothing is
    // sent, and that is its own test.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('a screen is forwarded to the platform once', () async {
    final RecordingCrashScreenSink sink = RecordingCrashScreenSink();
    final OtelZone zone = zoneWith(sink, RecordingTalkerObserver());

    zone.setCrashScreen('/orders/:id');
    await pumpEventQueue();

    expect(sink.screens, <String?>['/orders/:id']);
    expect(zone.crashScreen, '/orders/:id');
  });

  test('the same screen twice is one message', () async {
    final RecordingCrashScreenSink sink = RecordingCrashScreenSink();
    final OtelZone zone = zoneWith(sink, RecordingTalkerObserver());

    zone.setCrashScreen('/a');
    await pumpEventQueue();
    zone.setCrashScreen('/a');
    await pumpEventQueue();

    expect(sink.screens, <String?>['/a']);
  });

  test(
    'a burst while a message is in flight sends only the latest after it',
    () async {
      final _HeldSink sink = _HeldSink();
      final OtelZone zone = zoneWith(sink, RecordingTalkerObserver());

      zone.setCrashScreen('/a');
      zone.setCrashScreen('/b');
      zone.setCrashScreen('/c');
      await pumpEventQueue();
      expect(sink.screens, <String?>['/a']);

      sink.pending.single.complete();
      await pumpEventQueue();
      expect(sink.screens, <String?>['/a', '/c']);

      sink.pending.last.complete();
      await pumpEventQueue();
      expect(sink.screens, <String?>['/a', '/c']);
    },
  );

  test('null, an empty and a blank screen clear it', () async {
    final RecordingCrashScreenSink sink = RecordingCrashScreenSink();
    final OtelZone zone = zoneWith(sink, RecordingTalkerObserver());

    zone.setCrashScreen('/a');
    zone.setCrashScreen(null);
    zone.setCrashScreen('');
    zone.setCrashScreen('   ');
    await pumpEventQueue();

    expect(zone.crashScreen, isNull);
    expect(sink.screens, <String?>['/a', null]);
  });

  test(
    'over 64 UTF-8 bytes or a control character is not recorded, and it clears the previous one',
    () async {
      final RecordingCrashScreenSink sink = RecordingCrashScreenSink();
      final OtelZone zone = zoneWith(sink, RecordingTalkerObserver());

      zone.setCrashScreen('é' * 32);
      expect(zone.crashScreen, 'é' * 32, reason: 'exactly 64 bytes is kept');

      zone.setCrashScreen('é' * 33);
      expect(zone.crashScreen, isNull, reason: '66 bytes is not cut to fit');

      zone.setCrashScreen('/a');
      zone.setCrashScreen('/a\nb');
      expect(zone.crashScreen, isNull);

      zone.setCrashScreen('/a');
      zone.setCrashScreen('/a\u009fb');
      expect(zone.crashScreen, isNull, reason: 'U+009F is a control character');
      await pumpEventQueue();
    },
  );

  test('a screen is trimmed before it is kept', () {
    final OtelZone zone = zoneWith(
      RecordingCrashScreenSink(),
      RecordingTalkerObserver(),
    );

    zone.setCrashScreen('  /orders/:id \n');

    expect(zone.crashScreen, '/orders/:id');
  });

  test(
    'it never throws, and a failing platform warns once by type, never with the screen',
    () async {
      final RecordingTalkerObserver observed = RecordingTalkerObserver();
      final _ThrowingSink sink = _ThrowingSink();
      final OtelZone zone = zoneWith(sink, observed);

      zone.setCrashScreen('/secret/:x');
      await pumpEventQueue();
      zone.setCrashScreen('/other/:y');
      await pumpEventQueue();

      expect(sink.screens, <String?>['/secret/:x', '/other/:y']);
      final List<String> logged = warnings(observed);
      expect(logged, hasLength(1));
      expect(logged.single, contains('StateError'));
      expect(logged.single, isNot(contains('/secret/:x')));
      expect(logged.single, isNot(contains('channel exploded')));
    },
  );

  test('a missing plugin stops forwarding silently', () async {
    final RecordingTalkerObserver observed = RecordingTalkerObserver();
    final _FailingSink sink = _FailingSink(MissingPluginException());
    final OtelZone zone = zoneWith(sink, observed);

    zone.setCrashScreen('/a');
    await pumpEventQueue();
    zone.setCrashScreen('/b');
    await pumpEventQueue();

    expect(sink.screens, <String?>['/a']);
    expect(warnings(observed), isEmpty);
  });

  test('a channel error stops forwarding silently too', () async {
    final RecordingTalkerObserver observed = RecordingTalkerObserver();
    final _FailingSink sink = _FailingSink(
      PlatformException(code: 'channel-error', message: 'no reply'),
    );
    final OtelZone zone = zoneWith(sink, observed);

    zone.setCrashScreen('/a');
    await pumpEventQueue();
    zone.setCrashScreen('/b');
    await pumpEventQueue();

    expect(sink.screens, <String?>['/a']);
    expect(warnings(observed), isEmpty);
  });

  test('on the web and on desktop nothing is sent', () async {
    final RecordingCrashScreenSink sink = RecordingCrashScreenSink();
    final List<String> warned = <String>[];

    CrashScreenForwarder(sink, onWarning: warned.add, isWeb: true).set('/a');
    CrashScreenForwarder(
      sink,
      onWarning: warned.add,
      isWeb: false,
      platform: TargetPlatform.linux,
    ).set('/a');
    await pumpEventQueue();

    expect(sink.screens, isEmpty);
    expect(warned, isEmpty);
  });

  test('under flutter test the default sink sends nothing', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    int calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(_channel, (ByteData? message) async {
          calls++;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(_channel, null),
    );

    final OtelZone zone = OtelZone(_config, talker: Talker());
    zone.setCrashScreen('/a');
    await pumpEventQueue();

    expect(calls, 0);
    expect(zone.crashScreen, '/a');
  });

  test('the Pigeon sink sends the screen on its channel', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final List<String?> received = <String?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(_channel, (ByteData? message) async {
          final List<Object?> args =
              CrashContextApi.pigeonChannelCodec.decodeMessage(message)!
                  as List<Object?>;
          received.add(args.single as String?);
          return CrashContextApi.pigeonChannelCodec.encodeMessage(<Object?>[
            null,
          ]);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(_channel, null),
    );

    await PigeonCrashScreenSink().setCrashScreen('/orders/:id');

    expect(received, <String?>['/orders/:id']);
  });

  testWidgets('the screen schedules no timer', (WidgetTester tester) async {
    // flutter_test checks that no foundation debug variable is left set when
    // the body returns, before `tearDown` runs, so the override is undone here.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      // A message is left in flight when the test ends: a pending timer would
      // fail the test, and nothing here starts one.
      final _HeldSink sink = _HeldSink();
      final OtelZone zone = zoneWith(sink, RecordingTalkerObserver());

      zone.setCrashScreen('/a');
      zone.setCrashScreen('/b');

      expect(sink.screens, <String?>['/a']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('a screen set before start is forwarded, and needs no SDK', () async {
    final RecordingCrashScreenSink sink = RecordingCrashScreenSink();
    final OtelZone zone = zoneWith(sink, RecordingTalkerObserver());

    expect(zone.isReady, isFalse);
    zone.setCrashScreen('/before/start');
    await pumpEventQueue();

    expect(sink.screens, <String?>['/before/start']);
  });
}
