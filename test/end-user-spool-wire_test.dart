// `setEndUser` on the wire through the other pipeline shapes: no `redact`, so
// dartastic's own trace pipeline, and a spooling log exporter, which `start()`
// hands to the logs pipeline it builds behind the stamper. It also pins three
// things the docs promise: an id set before `start()` is kept and applied once
// the SDK is up, the spooling exporter carries the id through to the collector,
// and a recovered native crash is not stamped with the person who happens to
// be signed in now.
//
// In its own file: `OTel.initialize()` may only be called once per isolate.
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

import 'support/local-collector.dart';
import 'support/otlp-wire.dart';

const String _cuid = 'cmg20000000009abcd1234efgh';

class _OneCrash implements NativeCrashSource {
  @override
  Future<List<NativeCrashReport>> pending() async => <NativeCrashReport>[
    NativeCrashReport(
      id: 'previous-run',
      kind: 'native',
      timestampMicros: 1700000000000000,
    ),
  ];

  @override
  Future<void> acknowledge(List<String> ids) async {}
}

/// Polls until [done] holds, so a test waits for delivery that carries on
/// after `start()` returns, without a fixed sleep.
Future<void> until(bool Function() done) async {
  for (int i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  if (!done()) throw StateError('timed out waiting for the collector');
}

void main() {
  test('an id set before start() is applied after it, to spans and spooled '
      'logs, but not to a crash recovered from the previous run', () async {
    final Directory spool = await Directory.systemTemp.createTemp(
      'otel_zone_end_user',
    );
    addTearDown(() => spool.delete(recursive: true));
    final LocalCollector collector = await LocalCollector.start();
    addTearDown(collector.close);
    final OtelZone observability = OtelZone(
      OtelZoneConfig(
        serviceName: 'end-user-spool-test',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
        presentFlutterErrors: false,
        spoolDirectory: () => spool,
      ),
      nativeCrashSource: _OneCrash(),
    );

    // Before the SDK exists. Nothing can be stamped yet, and the call neither
    // throws nor forgets.
    expect(() => observability.setEndUser(_cuid), returnsNormally);
    expect(observability.isReady, isFalse);
    expect(observability.endUserId, _cuid);

    await observability.start(serviceVersion: '1.2.3');
    expect(observability.isReady, isTrue);

    observability.talker.warning('ordinary');
    await OTel.loggerProvider().forceFlush();
    OTel.tracerProvider()
        .getTracer('end-user-spool-test')
        .startSpan('first span')
        .end();
    await OTel.tracerProvider().forceFlush();

    bool hasCrash() => collector.wireLogs.any(
      (pb.LogRecord r) => wireString(r.attributes, 'device.crash.kind') != null,
    );
    bool hasOrdinary() => collector.wireLogs.any(
      (pb.LogRecord r) => r.body.stringValue.contains('ordinary'),
    );
    await until(() => hasCrash() && hasOrdinary());

    final pb.LogRecord ordinary = collector.wireLogs.firstWhere(
      (pb.LogRecord r) => r.body.stringValue.contains('ordinary'),
    );
    expect(wireString(ordinary.attributes, 'enduser.id'), _cuid);

    final pb.LogRecord crash = collector.wireLogs.firstWhere(
      (pb.LogRecord r) => wireString(r.attributes, 'device.crash.kind') != null,
    );
    expect(
      wireString(crash.attributes, 'enduser.id'),
      isNull,
      reason: 'it describes the previous run, not whoever is signed in now',
    );

    final pb.Span span = collector.wireSpans.firstWhere(
      (pb.Span s) => s.name == 'first span',
    );
    expect(wireString(span.attributes, 'enduser.id'), _cuid);
    expect(wireCount(span.attributes, 'enduser.id'), 1);
  });
}
