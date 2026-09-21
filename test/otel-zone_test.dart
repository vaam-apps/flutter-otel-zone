// The wiring tests.
//
// These are not "does Talker work" tests. Each one covers a channel that,
// if it silently detached, would look exactly like "no errors are
// happening".
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:talker/talker.dart';

const OtelZoneConfig _config = OtelZoneConfig(
  serviceName: 'test-app',
  endpoint: 'http://127.0.0.1:4318',
  deploymentEnvironmentName: 'development',
  useConsoleLogs: false,
  presentFlutterErrors: false,
);

OtelZone zone([OtelZoneConfig config = _config]) =>
    OtelZone(config, sink: RecordingTalkerObserver());

void main() {
  group('configuration', () {
    test('loggerName defaults to the service name', () {
      expect(_config.loggerName, 'test-app');
      expect(
        const OtelZoneConfig(
          serviceName: 'test-app',
          endpoint: 'http://127.0.0.1:4318',
          loggerName: 'vaam.mobile',
        ).loggerName,
        'vaam.mobile',
      );
    });

    test('secure follows the endpoint scheme unless it is set', () {
      expect(_config.secure, isFalse);
      expect(
        const OtelZoneConfig(
          serviceName: 'a',
          endpoint: 'https://otel.example.com',
        ).secure,
        isTrue,
      );
      expect(
        const OtelZoneConfig(
          serviceName: 'a',
          endpoint: 'grpc://otel.example.com',
          secure: true,
        ).secure,
        isTrue,
      );
    });

    test('metrics are off by default, and that is the decision', () {
      // Not a tautology. A `PeriodicExportingMetricReader` is a 60s
      // `Timer.periodic` that keeps firing whether or not the collector is
      // reachable — a heartbeat on a metered prepaid connection for the
      // life of the process. Flipping this default is a product decision,
      // not a tidy-up.
      expect(_config.enableMetrics, isFalse);
      expect(_config.enableLogs, isTrue);
    });

    test('the console and the wire are separate switches', () {
      // `useConsoleLogs` gates the console and nothing else. Reading it as
      // a second export switch is how a build ships with a debug-only
      // console and a wide-open exporter.
      const OtelZoneConfig quiet = OtelZoneConfig(
        serviceName: 'a',
        endpoint: 'http://127.0.0.1:4318',
        useConsoleLogs: false,
      );
      expect(quiet.useConsoleLogs, isFalse);
      expect(quiet.exportFloor.level, LogLevel.warning);
    });

    test('the default floor is the quiet end', () {
      expect(_config.exportFloor.level, LogLevel.warning);
    });
  });

  group('the start-up summary', () {
    test('names the endpoint, the identity and the floor', () {
      // This is the one record that has to survive its own subject: a build
      // reporting under the wrong environment, or exporting far more or far
      // less than intended, is visible on the very first record rather than
      // only once somebody notices.
      expect(
        zone().startupSummary('1.2.3', '48'),
        'OpenTelemetry: exporting to http://127.0.0.1:4318 as test-app 1.2.3 '
        'build 48 (development), records at warning and above',
      );
    });

    test('omits the parts a build did not supply', () {
      final OtelZone bare = zone(
        const OtelZoneConfig(
          serviceName: 'test-app',
          endpoint: 'http://127.0.0.1:4318',
          useConsoleLogs: false,
        ),
      );
      expect(
        bare.startupSummary('1.2.3', null),
        'OpenTelemetry: exporting to http://127.0.0.1:4318 as test-app 1.2.3, '
        'records at warning and above',
      );
    });

    test('an unreadable export level reports itself', () {
      final OtelZone typo = zone(
        OtelZoneConfig(
          serviceName: 'test-app',
          endpoint: 'http://127.0.0.1:4318',
          exportFloor: ExportFloor.parse('loud'),
          useConsoleLogs: false,
        ),
      );
      expect(
        typo.startupSummary('1.2.3', null),
        contains('"loud", which is not a level; fell back to warning'),
      );
    });
  });

  group('start', () {
    test('never throws, even with no collector', () async {
      // The whole point of the try/catch: a phone with no route to the
      // collector must still open the app.
      final OtelZone subject = zone();
      await expectLater(subject.start(serviceVersion: '1.2.3'), completes);
    });

    test('nothing is exported while the SDK is down', () {
      final OtelZone subject = zone();
      expect(subject.isReady, isFalse);
      expect(subject.riverpodObserver(), isNull);
      expect(subject.routeObserver(), isNull);
    });

    test('safely() runs nothing while the SDK is down', () {
      var ran = false;
      zone().safely(() => ran = true);
      expect(ran, isFalse);
    });

    test('safely() swallows what it runs', () {
      final OtelZone subject = zone()..bridge.ready = true;
      expect(
        () => subject.safely(() => throw StateError('no tracer')),
        returnsNormally,
      );
    });

    test('a failed start is a warning on the talker, not a thrown error',
        () async {
      final OtelZone subject = zone(
        const OtelZoneConfig(
          serviceName: 'test-app',
          // An empty version makes OTel.initialize throw ArgumentError, which
          // is the cheapest way to exercise the failure path without a
          // network.
          endpoint: 'http://127.0.0.1:4318',
          useConsoleLogs: false,
        ),
      );
      await subject.start(serviceVersion: '');
      expect(subject.isReady, isFalse);
      expect(
        subject.talker.history.map((TalkerData e) => e.message).join('\n'),
        contains('OpenTelemetry did not start'),
      );
    });
  });

  group('the error zone', () {
    test('an error reported by hand reaches the talker', () {
      final OtelZone subject = zone();

      try {
        throw StateError('a button did something impossible');
      } on Object catch (error, stackTrace) {
        subject.reportError(error, stackTrace, context: 'test callback');
      }

      expect(
        subject.talker.history.any(
          (TalkerData entry) =>
              entry.exception.toString().contains('impossible') ||
              (entry.error?.toString().contains('impossible') ?? false) ||
              entry.message?.contains('test callback') == true,
        ),
        isTrue,
        reason: 'reportError must put the failure on this zone\'s talker',
      );
    });

    test('an uncaught async error inside the zone reaches the talker',
        () async {
      final OtelZone subject = zone();

      await subject.runGuarded(() async {
        unawaited(Future<void>.error(StateError('escaped')));
        // Let the microtask queue deliver it before the body returns.
        await Future<void>.delayed(Duration.zero);
      });

      expect(
        subject.talker.history.any(
          (TalkerData entry) =>
              entry.error?.toString().contains('escaped') ?? false,
        ),
        isTrue,
        reason: 'the zone handler is the only thing that catches this one',
      );
    });

    test('a framework error reaches the talker', () async {
      final OtelZone subject = zone();
      final FlutterExceptionHandler? outer = FlutterError.onError;
      addTearDown(() => FlutterError.onError = outer);
      // Detach the ambient handler first: runGuarded chains to whatever it
      // replaced, and here that is the test framework's own reporter.
      FlutterError.onError = null;

      await subject.runGuarded(() async {
        FlutterError.onError!(
          FlutterErrorDetails(
            exception: StateError('a build failed'),
            context: ErrorDescription('while laying out'),
          ),
        );
      });

      expect(
        subject.talker.history.any(
          (TalkerData entry) =>
              entry.error?.toString().contains('a build failed') ?? false,
        ),
        isTrue,
      );
    });

    test('runGuarded returns only once the body has finished', () async {
      // Awaiting `runZonedGuarded`'s own future is what makes a start-up
      // failure surface rather than showing as a silent blank screen.
      final OtelZone subject = zone();
      var finished = false;

      await subject.runGuarded(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        finished = true;
      });

      expect(finished, isTrue);
    });
  });
}
