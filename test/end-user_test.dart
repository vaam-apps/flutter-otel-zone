// `OtelZone.setEndUser`: what the span and log-record processors stamp.
//
// A real SDK and capturing exporters, assembled in the order `OtelZone.start`
// assembles them: the log stamper first, the exporting log processor behind
// it, the span stamper appended after the span pipeline. The wire tests next
// door prove `start()` builds exactly that; this file is about what the
// stampers do once it has.
//
// `OTel.initialize()` may only be called once per isolate, so this file
// initialises once and every test makes its own spans and records.
import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:otel_zone/src/end-user.dart';

/// Keeps every span it is handed.
final class _SpanCapture implements SpanExporter {
  final List<Span> spans = <Span>[];

  @override
  Future<void> export(List<Span> spans) async => this.spans.addAll(spans);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

/// Keeps every log record it is handed.
final class _LogCapture implements LogRecordExporter {
  final List<ReadableLogRecord> records = <ReadableLogRecord>[];

  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    records.addAll(logRecords);
    return ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

const OtelZoneConfig _config = OtelZoneConfig(
  serviceName: 'end-user-test',
  endpoint: 'http://127.0.0.1:4318',
  useConsoleLogs: false,
);

/// A cuid, the shape of id the app this package was written for uses. Its
/// nine-digit run is deliberate: a pattern written for phone numbers masks it.
const String _cuid = 'cmg20000000009abcd1234efgh';

String phoneScrub(String input) =>
    input.replaceAll(RegExp(r'\d{9}'), '<phone>');

List<Attribute<Object>> attributesOf(Attributes? attributes) =>
    attributes?.toList() ?? <Attribute<Object>>[];

Object? spanAttribute(Span span, String key) {
  for (final Attribute<Object> a in attributesOf(span.attributes)) {
    if (a.key == key) return a.value;
  }
  return null;
}

Object? recordAttribute(ReadableLogRecord record, String key) {
  for (final Attribute<Object> a in attributesOf(record.attributes)) {
    if (a.key == key) return a.value;
  }
  return null;
}

int countOf(Attributes? attributes, String key) => attributesOf(
  attributes,
).where((Attribute<Object> a) => a.key == key).length;

void main() {
  final _SpanCapture spans = _SpanCapture();
  final _LogCapture logs = _LogCapture();
  final OtelZone observability = OtelZone(
    _config,
    sink: RecordingTalkerObserver(),
  );

  setUpAll(() async {
    await OTel.initialize(
      serviceName: 'end-user-test',
      serviceVersion: '0.0.1',
      enableMetrics: false,
      detectPlatformResources: false,
      // The pipeline `start()` builds when `redact` is set: scrubbing at the
      // exporter, so the exemption is exercised in the chain it protects.
      spanProcessor: SimpleSpanProcessor(
        RedactingSpanExporter(delegate: spans, redact: phoneScrub),
      ),
      logRecordProcessor: EndUserLogRecordProcessor(
        () => observability.endUserId,
      ),
    );
    OTel.loggerProvider().addLogRecordProcessor(
      BatchLogRecordProcessor(logs, const BatchLogRecordProcessorConfig()),
    );
    OTel.tracerProvider().addSpanProcessor(
      EndUserSpanProcessor(() => observability.endUserId),
    );
  });

  setUp(() {
    spans.spans.clear();
    logs.records.clear();
    observability.setEndUser(null);
  });

  Span startSpan(String name, {Attributes? attributes}) => OTel.tracerProvider()
      .getTracer('end-user-test')
      .startSpan(name, attributes: attributes);

  Future<List<ReadableLogRecord>> emit(List<String> bodies) async {
    final OTelLogger logger = OTel.loggerProvider().getLogger('end-user-test');
    for (final String body in bodies) {
      logger.emit(
        severityNumber: Severity.WARN,
        severityText: 'warning',
        body: body,
      );
    }
    await OTel.loggerProvider().forceFlush();
    return List<ReadableLogRecord>.of(logs.records);
  }

  test('the attribute is the semantic convention enduser.id', () {
    // Pinned to the literal: the key is read from the SDK's registry, so a
    // rename upstream has to fail here and not on a dashboard.
    expect(endUserIdKey, 'enduser.id');
  });

  group('spans', () {
    test('a span started after setEndUser carries the id', () {
      observability.setEndUser('user-1');
      startSpan('after').end();

      expect(spanAttribute(spans.spans.single, 'enduser.id'), 'user-1');
      expect(observability.endUserId, 'user-1');
    });

    test('a span started before the call does not, however late it ends', () {
      final Span before = startSpan('before');
      observability.setEndUser('user-1');
      final Span after = startSpan('after');
      before.end();
      after.end();

      final Span exportedBefore = spans.spans.firstWhere(
        (Span s) => s.name == 'before',
      );
      final Span exportedAfter = spans.spans.firstWhere(
        (Span s) => s.name == 'after',
      );
      expect(spanAttribute(exportedBefore, 'enduser.id'), isNull);
      expect(spanAttribute(exportedAfter, 'enduser.id'), 'user-1');
    });

    test('setEndUser(null) clears it for later spans only', () {
      observability.setEndUser('user-1');
      final Span running = startSpan('running');
      observability.setEndUser(null);
      final Span later = startSpan('later');
      running.end();
      later.end();

      expect(observability.endUserId, isNull);
      // The span started while the id was set keeps it: clearing does not
      // recall, it stops.
      expect(
        spanAttribute(
          spans.spans.firstWhere((Span s) => s.name == 'running'),
          'enduser.id',
        ),
        'user-1',
      );
      expect(
        spanAttribute(
          spans.spans.firstWhere((Span s) => s.name == 'later'),
          'enduser.id',
        ),
        isNull,
      );
    });

    test('a second id replaces the first for spans that start after it', () {
      observability.setEndUser('user-1');
      startSpan('one').end();
      observability.setEndUser('user-2');
      startSpan('two').end();

      expect(spanAttribute(spans.spans[0], 'enduser.id'), 'user-1');
      expect(spanAttribute(spans.spans[1], 'enduser.id'), 'user-2');
    });

    test('an empty id clears it, since an attribute cannot be empty', () {
      observability.setEndUser('user-1');
      observability.setEndUser('');
      startSpan('empty').end();

      expect(observability.endUserId, isNull);
      expect(spanAttribute(spans.spans.single, 'enduser.id'), isNull);
    });

    test('an enduser.id the app set itself is replaced, not repeated', () {
      observability.setEndUser('user-1');
      startSpan(
        'by-hand',
        attributes: OTel.attributesFromMap(<String, Object>{
          'enduser.id': 'someone-else',
        }),
      ).end();

      final Span exported = spans.spans.single;
      expect(countOf(exported.attributes, 'enduser.id'), 1);
      expect(spanAttribute(exported, 'enduser.id'), 'user-1');
    });

    test('with no id set, one the app set itself is left alone', () {
      startSpan(
        'by-hand',
        attributes: OTel.attributesFromMap(<String, Object>{
          'enduser.id': 'someone-else',
        }),
      ).end();

      expect(spanAttribute(spans.spans.single, 'enduser.id'), 'someone-else');
    });

    test('the id survives a redactor that would mask it', () {
      // The id has nine digits in a row, and `phoneScrub` masks that. The
      // pipeline under test scrubs at the exporter, as `start()` does with a
      // `redact`.
      expect(phoneScrub(_cuid), contains('<phone>'));

      observability.setEndUser(_cuid);
      startSpan(
        'redacted',
        attributes: OTel.attributesFromMap(<String, Object>{
          'user.phone': '699887766',
        }),
      ).end();

      final Span exported = spans.spans.single;
      expect(spanAttribute(exported, 'enduser.id'), _cuid);
      expect(spanAttribute(exported, 'user.phone'), '<phone>');
    });
  });

  group('log records', () {
    test('a record emitted after setEndUser carries the id', () async {
      observability.setEndUser('user-1');
      final List<ReadableLogRecord> exported = await emit(<String>['after']);

      expect(recordAttribute(exported.single, 'enduser.id'), 'user-1');
    });

    test('a record emitted before the call does not', () async {
      final List<ReadableLogRecord> before = await emit(<String>['before']);
      observability.setEndUser('user-1');
      final List<ReadableLogRecord> after = await emit(<String>['after']);

      expect(recordAttribute(before.first, 'enduser.id'), isNull);
      expect(recordAttribute(after.last, 'enduser.id'), 'user-1');
    });

    test('setEndUser(null) clears it for later records only', () async {
      observability.setEndUser('user-1');
      await emit(<String>['while set']);
      observability.setEndUser(null);
      final List<ReadableLogRecord> all = await emit(<String>['cleared']);

      expect(recordAttribute(all.first, 'enduser.id'), 'user-1');
      expect(recordAttribute(all.last, 'enduser.id'), isNull);
    });

    test('a record that already carries an enduser.id keeps one', () async {
      observability.setEndUser('user-1');
      OTel.loggerProvider()
          .getLogger('end-user-test')
          .emit(
            severityNumber: Severity.WARN,
            body: 'by hand',
            attributes: OTel.attributesFromMap(<String, Object>{
              'enduser.id': 'someone-else',
            }),
          );
      await OTel.loggerProvider().forceFlush();

      final ReadableLogRecord exported = logs.records.single;
      expect(countOf(exported.attributes, 'enduser.id'), 1);
      expect(recordAttribute(exported, 'enduser.id'), 'user-1');
    });

    test('the id is not run through the bridge redactor', () async {
      // A record is scrubbed by the bridge before it is emitted, and the
      // stamp is made after, so a log record needs no exemption.
      observability.setEndUser(_cuid);
      final List<ReadableLogRecord> exported = await emit(<String>['x']);

      expect(recordAttribute(exported.single, 'enduser.id'), _cuid);
    });
  });

  group('when stamping itself fails', () {
    // The SDK calls `onStart` and `onEmit` without awaiting them, so a failed
    // future would be an uncaught error in the app's own handler.
    test('a span processor swallows it and completes', () async {
      final Span span = startSpan('victim');
      final EndUserSpanProcessor broken = EndUserSpanProcessor(
        () => throw StateError('no id for you'),
      );

      await expectLater(broken.onStart(span, null), completes);
      expect(spanAttribute(span, 'enduser.id'), isNull);
      span.end();
    });

    test('a log processor swallows it and completes', () async {
      final SDKLogRecord record = SDKLogRecord(
        instrumentationScope: OTel.instrumentationScope(name: 'end-user-test'),
        body: 'victim',
      );
      final EndUserLogRecordProcessor broken = EndUserLogRecordProcessor(
        () => throw StateError('no id for you'),
      );

      await expectLater(broken.onEmit(record, null), completes);
      expect(recordAttribute(record, 'enduser.id'), isNull);
    });

    test('a span started under a guarded zone reports nothing', () async {
      final List<Object> uncaught = <Object>[];
      runZonedGuarded(() {
        final EndUserSpanProcessor broken = EndUserSpanProcessor(
          () => throw StateError('no id for you'),
        );
        final Span span = startSpan('victim');
        // The way the SDK calls it: not awaited.
        unawaited(broken.onStart(span, null));
        span.end();
      }, (Object error, StackTrace stack) => uncaught.add(error));
      await Future<void>.delayed(Duration.zero);

      expect(uncaught, isEmpty);
    });
  });

  group('zones', () {
    test('the last call wins, whichever zone makes it', () {
      runZoned(
        () => observability.setEndUser('a'),
        zoneValues: <Object?, Object?>{#k: 1},
      );
      runZonedGuarded(
        () => observability.setEndUser('b'),
        (Object error, StackTrace stack) {},
      );
      Zone.root.run(() => observability.setEndUser('c'));
      Zone.current.fork().run(() => observability.setEndUser('d'));

      expect(observability.endUserId, 'd');
    });

    test('a span is stamped with the id in force, whatever its zone', () {
      runZoned(
        () => observability.setEndUser('set-in-zone'),
        zoneValues: <Object?, Object?>{#who: 'a'},
      );
      // Started in another zone from the one that set the id, and in a third
      // that set nothing at all.
      final Span inRoot = Zone.root.run(() => startSpan('root'));
      final Span inFork = Zone.current
          .fork(zoneValues: <Object?, Object?>{#who: 'b'})
          .run(() => startSpan('fork'));
      inRoot.end();
      inFork.end();

      for (final Span span in spans.spans) {
        expect(spanAttribute(span, 'enduser.id'), 'set-in-zone');
      }
      expect(spans.spans, hasLength(2));
    });

    test(
      'calls interleaved across zones settle on the last scheduled',
      () async {
        final List<Future<void>> pending = <Future<void>>[];
        for (int i = 0; i < 200; i++) {
          final Zone fork = Zone.current.fork(
            zoneValues: <Object?, Object?>{#zone: i},
          );
          // Alternating how each call reaches the event loop: a microtask, a
          // timer and a future, each owned by a zone of its own.
          pending.add(switch (i % 3) {
            0 => fork.run(
              () => Future<void>.microtask(
                () => observability.setEndUser('id-$i'),
              ),
            ),
            1 => fork.run(
              () => Future<void>.delayed(
                Duration.zero,
                () => observability.setEndUser('id-$i'),
              ),
            ),
            _ => fork.run(() async => observability.setEndUser('id-$i')),
          });
        }
        await Future.wait(pending);

        // Timers run after microtasks, so the order is not i; what must hold is
        // that one whole id from the set won, not a torn or missing one.
        expect(observability.endUserId, matches(RegExp(r'^id-\d+$')));
        startSpan('settled').end();
        expect(
          spanAttribute(spans.spans.single, 'enduser.id'),
          observability.endUserId,
        );
      },
    );

    test('a zone that forbids scheduling cannot make it throw', () {
      // `setEndUser` touches no timer, microtask or print, which is what
      // makes it callable from anywhere, an error handler included.
      final ZoneSpecification hostile = ZoneSpecification(
        scheduleMicrotask:
            (Zone self, ZoneDelegate parent, Zone zone, void Function() f) =>
                throw StateError('no microtasks here'),
        createTimer:
            (
              Zone self,
              ZoneDelegate parent,
              Zone zone,
              Duration d,
              void Function() f,
            ) => throw StateError('no timers here'),
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) =>
            throw StateError('no printing here'),
      );

      expect(
        () => runZoned(
          () => observability.setEndUser('from-hostile-zone'),
          zoneSpecification: hostile,
        ),
        returnsNormally,
      );
      expect(observability.endUserId, 'from-hostile-zone');
    });
  });
}
