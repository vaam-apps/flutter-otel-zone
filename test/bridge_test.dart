// What actually leaves the phone.
//
// Every assertion here is about the wire, not about `talker.history` — a
// record withheld from the exporter is still recorded locally, and
// confusing the two is exactly the mistake `useConsoleLogs: kDebugMode`
// invites.
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:talker/talker.dart';

void main() {
  OtelBridge bridgeWith({
    LogLevel floor = LogLevel.warning,
    required RecordingTalkerObserver sink,
    List<TalkerData> history = const <TalkerData>[],
    int breadcrumbCount = 12,
    int breadcrumbLineLimit = 160,
  }) => OtelBridge(
    floor: ExportFloor.of(floor),
    history: () => history,
    sink: sink,
    breadcrumbCount: breadcrumbCount,
    breadcrumbLineLimit: breadcrumbLineLimit,
  );

  group('the export floor', () {
    test('a below-floor record never reaches the exporter', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = bridgeWith(sink: sink)..ready = true;

      bridge.onLog(
        TalkerData('a route change', logLevel: LogLevel.info, title: 'route'),
      );
      bridge.onLog(
        TalkerData('a provider', logLevel: LogLevel.debug, title: 'riverpod'),
      );

      expect(sink.records, isEmpty);
    });

    test('an at-or-above-floor record does', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = bridgeWith(sink: sink)..ready = true;

      bridge.onLog(TalkerData('offline', logLevel: LogLevel.warning));

      expect(sink.records.single.message, 'offline');
    });

    test('nothing at all is exported before the SDK is up', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = bridgeWith(sink: sink);

      bridge.onLog(TalkerData('a warning', logLevel: LogLevel.warning));

      expect(sink.records, isEmpty, reason: 'ready is false');
    });

    test('carries() is the floor the bridge was given', () {
      final OtelBridge bridge = bridgeWith(sink: RecordingTalkerObserver());
      expect(bridge.carries(LogLevel.info), isFalse);
      expect(bridge.carries(LogLevel.error), isTrue);
    });
  });

  group('breadcrumbs', () {
    List<TalkerData> trail(int count) => <TalkerData>[
      for (int i = 0; i < count; i++)
        TalkerData('record $i', logLevel: LogLevel.info, title: 'route'),
    ];

    test('a fault takes the withheld records with it, as one extra record', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = bridgeWith(sink: sink, history: trail(3))
        ..ready = true;

      bridge.onError(TalkerError(StateError('boom'), message: 'it broke'));

      expect(sink.records.length, 2, reason: 'the trail, then the fault');
      expect(sink.records.first.title, 'breadcrumbs');
      expect(sink.records.first.message, contains('record 0'));
      expect(sink.records.first.message, contains('record 2'));
      expect(
        sink.records.first.logLevel,
        LogLevel.error,
        reason: 'a trail filtered out by severity is a trail nobody reads',
      );
      expect(sink.records.last.message, 'it broke');
    });

    test('never more than breadcrumbCount of them, newest last', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = bridgeWith(
        sink: sink,
        history: trail(17),
        breadcrumbCount: 12,
      )..ready = true;

      bridge.onError(TalkerError(StateError('boom')));

      final List<String> lines = sink.records.first.message!.split('\n');
      expect(lines.length, 12);
      expect(lines.first, contains('record 5'));
      expect(lines.last, contains('record 16'));
    });

    test('breadcrumbCount is configurable', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = bridgeWith(
        sink: sink,
        history: trail(10),
        breadcrumbCount: 3,
      )..ready = true;

      bridge.onError(TalkerError(StateError('boom')));

      expect(sink.records.first.message!.split('\n').length, 3);
    });

    test('a long line is truncated to breadcrumbLineLimit', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = bridgeWith(
        sink: sink,
        history: <TalkerData>[
          TalkerData('x' * 500, logLevel: LogLevel.info, title: 'huge'),
        ],
        breadcrumbLineLimit: 40,
      )..ready = true;

      bridge.onError(TalkerError(StateError('boom')));

      final String line = sink.records.first.message!;
      expect(line.length, 41, reason: '40 characters plus the ellipsis');
      expect(line, endsWith('…'));
    });

    test('a warning gets none — it is an expected state, not a fault', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = bridgeWith(sink: sink, history: trail(3))
        ..ready = true;

      bridge.onLog(TalkerData('offline', logLevel: LogLevel.warning));

      expect(sink.records.length, 1);
      expect(sink.records.single.title, isNot('breadcrumbs'));
    });

    test(
      'none when the floor withholds nothing — they would be duplicates',
      () {
        final RecordingTalkerObserver sink = RecordingTalkerObserver();
        final OtelBridge bridge = bridgeWith(
          floor: LogLevel.debug,
          sink: sink,
          history: trail(3),
        )..ready = true;

        bridge.onError(TalkerError(StateError('boom')));

        expect(
          sink.records.length,
          1,
          reason: 'the trail is already on the wire',
        );
      },
    );

    test('an exception carries them too', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = bridgeWith(sink: sink, history: trail(2))
        ..ready = true;

      bridge.onException(TalkerException(Exception('nope')));

      expect(sink.records.first.title, 'breadcrumbs');
      expect(sink.records.length, 2);
    });
  });

  group('a sink that throws', () {
    test('never costs the caller anything', () {
      // The whole contract: a logging path that can fail is worse than no
      // logging path, because it takes the thing it was supposed to report
      // down with it.
      final OtelBridge bridge = OtelBridge(
        floor: const ExportFloor.of(LogLevel.warning),
        history: () => const <TalkerData>[],
        sink: _ThrowingObserver(),
      )..ready = true;

      expect(
        () => bridge.onError(TalkerError(StateError('boom'))),
        returnsNormally,
      );
    });

    test('a trail that cannot be built does not cost the fault', () {
      final RecordingTalkerObserver sink = RecordingTalkerObserver();
      final OtelBridge bridge = OtelBridge(
        floor: const ExportFloor.of(LogLevel.warning),
        history: () => throw StateError('no history'),
        sink: sink,
      )..ready = true;

      bridge.onError(TalkerError(StateError('boom'), message: 'it broke'));

      expect(
        sink.records.single.message,
        'it broke',
        reason:
            'the breadcrumbs and the record they decorate are forwarded '
            'in two separate guarded calls for exactly this case',
      );
    });
  });
}

class _ThrowingObserver extends TalkerObserver {
  @override
  void onLog(TalkerData log) => throw StateError('OTel.initialize() first');

  @override
  void onError(TalkerError err) => throw StateError('OTel.initialize() first');

  @override
  void onException(TalkerException err) =>
      throw StateError('OTel.initialize() first');
}
