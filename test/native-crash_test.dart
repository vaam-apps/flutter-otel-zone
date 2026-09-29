import 'dart:async';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

/// A platform that returns what a test tells it to.
class _FakeSource implements NativeCrashSource {
  _FakeSource(this.reports);

  List<NativeCrashReport> reports;
  bool pendingThrows = false;
  bool acknowledgeThrows = false;
  int pendingCalls = 0;
  final List<List<String>> acknowledged = <List<String>>[];

  @override
  Future<List<NativeCrashReport>> pending() async {
    pendingCalls++;
    if (pendingThrows) throw StateError('MissingPluginException');
    return reports;
  }

  @override
  Future<void> acknowledge(List<String> ids) async {
    if (acknowledgeThrows) throw StateError('MissingPluginException');
    acknowledged.add(ids);
  }
}

/// An exporter whose acceptance is a switch.
class _RecordingExporter implements LogRecordExporter {
  _RecordingExporter({this.result = ExportResult.success});

  ExportResult result;

  /// When set, an export waits for it — and never answering is a collector
  /// that has stopped responding.
  Future<void>? hold;

  final List<List<ReadableLogRecord>> batches = <List<ReadableLogRecord>>[];

  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    batches.add(logRecords);
    await hold;
    return result;
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

NativeCrashReport _report({
  String id = 'a',
  String kind = 'native',
  int timestampMicros = 1700000000000000,
  String? type = 'SIGSEGV',
  String? message = 'segfault at 0x0',
  String? stacktrace = '#0 java.lang.Object',
  List<String>? threads,
  String? sessionId,
  Map<String, String>? attributes,
}) {
  return NativeCrashReport(
    id: id,
    kind: kind,
    timestampMicros: timestampMicros,
    type: type,
    message: message,
    stacktrace: stacktrace,
    threads: threads,
    sessionId: sessionId,
    attributes: attributes,
  );
}

void main() {
  setUpAll(() async {
    // `OTel.instrumentationScope` / `OTel.defaultResource` /
    // `OTel.attributesFromMap` all need an API factory.
    await OTel.initialize(
      serviceName: 'native-crash-test',
      serviceVersion: '0.0.1',
      enableLogs: false,
      enableMetrics: false,
    );
  });

  NativeCrashDrain drain(
    _FakeSource source,
    LogRecordExporter exporter, {
    List<String>? warnings,
    Redactor? redact,
    bool? isWeb,
    TargetPlatform? platform,
  }) {
    return NativeCrashDrain(
      source: source,
      exporter: exporter,
      loggerName: 'test-app',
      redact: redact,
      isWeb: isWeb,
      platform: platform,
      onWarning: (String message) => warnings?.add(message),
    );
  }

  test(
    'two reports become two FATAL records and both ids are acknowledged',
    () async {
      final _FakeSource source = _FakeSource(<NativeCrashReport>[
        _report(id: 'a'),
        _report(id: 'b', kind: 'jvm', type: 'IllegalStateException'),
      ]);
      final _RecordingExporter exporter = _RecordingExporter();

      final NativeCrashDrain subject = drain(source, exporter);
      expect(await subject.drain(), 2);
      await subject.settled();

      final List<ReadableLogRecord> records = exporter.batches.single;
      expect(records, hasLength(2));
      for (final ReadableLogRecord record in records) {
        expect(record.severityNumber, Severity.FATAL);
        expect(record.severityText, 'fatal');
        expect(record.timestamp, Int64(1700000000000000));
        expect(record.eventName, NativeCrashDrain.eventCrash);
        expect(
          record.attributes?.getString('event.name'),
          NativeCrashDrain.eventCrash,
        );
        expect(record.attributes?.getString('exception.type'), isNotNull);
      }
      expect(
        records.first.attributes?.getString('device.crash.kind'),
        'native',
      );
      expect(source.acknowledged, <List<String>>[
        <String>['a', 'b'],
      ]);
    },
  );

  test('an ANR is its own event name', () async {
    final _FakeSource source = _FakeSource(<NativeCrashReport>[
      _report(kind: 'anr'),
    ]);
    final _RecordingExporter exporter = _RecordingExporter();

    final NativeCrashDrain subject = drain(source, exporter);
    await subject.drain();
    await subject.settled();

    expect(
      exporter.batches.single.single.attributes?.getString('event.name'),
      NativeCrashDrain.eventAnr,
    );
  });

  test(
    'nothing pending reaches neither the exporter nor acknowledge',
    () async {
      final _FakeSource source = _FakeSource(<NativeCrashReport>[]);
      final _RecordingExporter exporter = _RecordingExporter();

      expect(await drain(source, exporter).drain(), 0);
      expect(exporter.batches, isEmpty);
      expect(source.acknowledged, isEmpty);
    },
  );

  test('a failed export acknowledges nothing', () async {
    final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);
    final _RecordingExporter exporter = _RecordingExporter(
      result: ExportResult.failure,
    );

    final NativeCrashDrain subject = drain(source, exporter);
    // Handed off, not delivered: the count is of reports taken on, and the
    // acknowledgement is what a refusal withholds.
    expect(await subject.drain(), 1);
    await subject.settled();
    expect(source.acknowledged, isEmpty);
  });

  test('an exporter that never answers does not hold drain up', () async {
    final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);
    final _RecordingExporter exporter = _RecordingExporter()
      ..hold = Completer<void>().future;

    expect(
      await drain(source, exporter).drain().timeout(const Duration(seconds: 1)),
      1,
    );
    // Nowhere durable to put it, so it is not acknowledged before it is
    // accepted.
    expect(source.acknowledged, isEmpty);
  });

  test('a report is acknowledged once the plain exporter accepts it', () async {
    final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);
    final Completer<void> gate = Completer<void>();
    final _RecordingExporter exporter = _RecordingExporter()
      ..hold = gate.future;
    final NativeCrashDrain subject = drain(source, exporter);

    await subject.drain();
    expect(source.acknowledged, isEmpty);

    gate.complete();
    await subject.settled();
    expect(source.acknowledged, <List<String>>[
      <String>['a'],
    ]);
  });

  group('with a spool', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('otel_zone_native');
    });

    tearDown(() => directory.delete(recursive: true));

    test(
      'a never-answering delegate holds neither drain nor the ack',
      () async {
        final _RecordingExporter delegate = _RecordingExporter()
          ..hold = Completer<void>().future;
        final SpoolingLogRecordExporter spool = SpoolingLogRecordExporter(
          delegate: delegate,
          directory: directory,
          maxAge: null,
        );
        final _FakeSource source = _FakeSource(<NativeCrashReport>[
          _report(id: 'a'),
          _report(id: 'b'),
        ]);

        final int count = await drain(
          source,
          spool,
        ).drain().timeout(const Duration(seconds: 1));

        expect(count, 2);
        // Durable, so acknowledged: the platform's copy is no longer needed.
        expect(source.acknowledged, <List<String>>[
          <String>['a', 'b'],
        ]);
        expect(directory.listSync().whereType<File>(), hasLength(1));
      },
    );

    test(
      'a delegate that refuses still leaves the report acknowledged',
      () async {
        final SpoolingLogRecordExporter spool = SpoolingLogRecordExporter(
          delegate: _RecordingExporter(result: ExportResult.failure),
          directory: directory,
          maxAge: null,
        );
        final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);

        await drain(source, spool).drain();
        await spool.settled();

        expect(source.acknowledged, hasLength(1));
        expect(directory.listSync().whereType<File>(), hasLength(1));
      },
    );

    test('the spooled crash batch is marked to be evicted last', () async {
      final SpoolingLogRecordExporter spool = SpoolingLogRecordExporter(
        delegate: _RecordingExporter(result: ExportResult.failure),
        directory: directory,
        maxAge: null,
      );

      await drain(_FakeSource(<NativeCrashReport>[_report()]), spool).drain();
      await spool.settled();

      // The acknowledged report may be the only copy left, so the count cap
      // must not evict it before ordinary telemetry.
      expect(
        directory.listSync().whereType<File>().single.path,
        contains('-evict-'),
      );
    });

    /// The drain a relaunched activity runs: a new engine has a new exporter
    /// and a new platform channel, and shares only the directory.
    NativeCrashDrain relaunched(_FakeSource source, List<String> warnings) =>
        drain(
          source,
          SpoolingLogRecordExporter(
            delegate: _RecordingExporter(result: ExportResult.failure),
            directory: directory,
            maxAge: null,
          ),
          warnings: warnings,
        );

    List<File> spoolFiles() => directory
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.spool.json'))
        .toList();

    test('a report whose acknowledge was lost with its engine is acknowledged '
        'again, not spooled twice', () async {
      // The first engine spools the report and is torn down with the
      // acknowledge still in flight, so the platform still holds it.
      final List<String> warnings = <String>[];
      final _FakeSource first = _FakeSource(<NativeCrashReport>[_report()])
        ..acknowledgeThrows = true;
      expect(await relaunched(first, warnings).drain(), 1);
      expect(first.acknowledged, isEmpty);
      expect(spoolFiles(), hasLength(1));

      // The relaunched engine is offered the same report.
      final _FakeSource second = _FakeSource(<NativeCrashReport>[_report()]);
      final int count = await relaunched(second, warnings).drain();

      expect(count, 0, reason: 'nothing new was taken responsibility for');
      expect(second.acknowledged, <List<String>>[
        <String>['a'],
      ]);
      expect(spoolFiles(), hasLength(1), reason: 'one copy, not two');
    });

    test('the journal is cleared once the platform has acknowledged', () async {
      final SpoolingLogRecordExporter spool = SpoolingLogRecordExporter(
        delegate: _RecordingExporter(),
        directory: directory,
        maxAge: null,
      );

      await drain(_FakeSource(<NativeCrashReport>[_report()]), spool).drain();
      await spool.settled();

      expect(await spool.handledReports(), isEmpty);
      expect(directory.listSync(), isEmpty);
    });

    test(
      'a delivered report stays journalled until the platform acknowledges',
      () async {
        // The batch is delivered and deleted, so only the journal is left to
        // say the report was handled.
        final _RecordingExporter delegate = _RecordingExporter();
        final SpoolingLogRecordExporter spool = SpoolingLogRecordExporter(
          delegate: delegate,
          directory: directory,
          maxAge: null,
        );
        final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()])
          ..acknowledgeThrows = true;

        await drain(source, spool).drain();
        await spool.settled();
        await drain(source, spool).drain();
        await spool.settled();

        expect(spoolFiles(), isEmpty);
        expect(await spool.handledReports(), <String>{'a'});
        expect(delegate.batches, hasLength(1), reason: 'delivered once');

        source.acknowledgeThrows = false;
        await drain(source, spool).drain();

        expect(source.acknowledged, <List<String>>[
          <String>['a'],
        ]);
        expect(await spool.handledReports(), isEmpty);
        expect(delegate.batches, hasLength(1), reason: 'still once');
      },
    );

    test(
      'a new report beside an already-spooled one is spooled alone',
      () async {
        final List<String> warnings = <String>[];
        await relaunched(
          _FakeSource(<NativeCrashReport>[_report()])..acknowledgeThrows = true,
          warnings,
        ).drain();

        final _FakeSource second = _FakeSource(<NativeCrashReport>[
          _report(),
          _report(id: 'b'),
        ]);
        final int count = await relaunched(second, warnings).drain();

        expect(count, 1, reason: 'only b is new');
        expect(second.acknowledged.single, unorderedEquals(<String>['a', 'b']));
        expect(spoolFiles(), hasLength(2));
      },
    );

    test(
      'an acknowledged report is delivered once, and the file goes',
      () async {
        final _RecordingExporter delegate = _RecordingExporter();
        final SpoolingLogRecordExporter spool = SpoolingLogRecordExporter(
          delegate: delegate,
          directory: directory,
          maxAge: null,
        );

        await drain(_FakeSource(<NativeCrashReport>[_report()]), spool).drain();
        await spool.settled();

        expect(delegate.batches, hasLength(1));
        expect(directory.listSync().whereType<File>(), isEmpty);
      },
    );
  });

  test(
    'a spool that cannot be written leaves the reports unacknowledged',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'otel_zone_native',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File blocker = File('${directory.path}/blocker');
      await blocker.writeAsString('not a directory');
      final SpoolingLogRecordExporter spool = SpoolingLogRecordExporter(
        delegate: _RecordingExporter(result: ExportResult.failure),
        directory: Directory('${blocker.path}/nested'),
        maxAge: null,
      );
      final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);

      final NativeCrashDrain subject = drain(source, spool);
      expect(await subject.drain(), 1);
      await subject.settled();
      expect(source.acknowledged, isEmpty);
    },
  );

  test('a platform read that throws warns once and completes', () async {
    final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()])
      ..pendingThrows = true;
    final _RecordingExporter exporter = _RecordingExporter();
    final List<String> warnings = <String>[];

    expect(await drain(source, exporter, warnings: warnings).drain(), 0);
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('could not be read'));
  });

  test('an acknowledge that throws does not undo the export', () async {
    final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()])
      ..acknowledgeThrows = true;
    final _RecordingExporter exporter = _RecordingExporter();
    final List<String> warnings = <String>[];
    final NativeCrashDrain subject = drain(
      source,
      exporter,
      warnings: warnings,
    );

    expect(await subject.drain(), 1);
    await subject.settled();
    expect(exporter.batches, hasLength(1));
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('not acknowledged'));
  });

  test('on web the platform is never asked', () async {
    final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);
    final _RecordingExporter exporter = _RecordingExporter();

    expect(await drain(source, exporter, isWeb: true).drain(), 0);
    expect(source.pendingCalls, 0);
    expect(exporter.batches, isEmpty);
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.fuchsia,
  ]) {
    test('on ${platform.name} the platform is never asked and nothing is '
        'warned', () async {
      final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);
      final _RecordingExporter exporter = _RecordingExporter();
      final List<String> warnings = <String>[];

      final NativeCrashDrain subject = drain(
        source,
        exporter,
        warnings: warnings,
        platform: platform,
      );

      expect(await subject.drain(), 0);
      expect(source.pendingCalls, 0);
      expect(exporter.batches, isEmpty);
      expect(warnings, isEmpty);
    });
  }

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    test('on ${platform.name} the platform is read', () async {
      final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);
      final _RecordingExporter exporter = _RecordingExporter();

      final NativeCrashDrain subject = drain(
        source,
        exporter,
        platform: platform,
      );

      expect(await subject.drain(), 1);
      await subject.settled();
      expect(source.pendingCalls, 1);
    });
  }

  test('the default platform is defaultTargetPlatform', () async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);

    expect(await drain(source, _RecordingExporter()).drain(), 0);
    expect(source.pendingCalls, 0);
  });

  group('the crashed build', () {
    Future<ReadableLogRecord> exported(NativeCrashReport report) async {
      final _RecordingExporter exporter = _RecordingExporter();
      final NativeCrashDrain subject = drain(
        _FakeSource(<NativeCrashReport>[report]),
        exporter,
      );
      await subject.drain();
      await subject.settled();
      return exporter.batches.single.single;
    }

    test('the record names the build that crashed and the resource the build '
        'that reported it', () async {
      // The crash is from build 1.0.0+1; this launch is `0.0.1`, the
      // version the test initialised the SDK with.
      final ReadableLogRecord record = await exported(
        _report(
          attributes: <String, String>{
            'otel_zone.crashed.service.version': '1.0.0',
            'otel_zone.crashed.app.build_id': '1',
          },
        ),
      );

      expect(
        record.attributes?.getString(NativeCrashDrain.crashedServiceVersion),
        '1.0.0',
      );
      expect(
        record.attributes?.getString(NativeCrashDrain.crashedBuildId),
        '1',
      );
      expect(record.resource?.attributes.getString('service.version'), '0.0.1');
    });

    test('the two attribute names are the ones the platforms write', () {
      expect(
        NativeCrashDrain.crashedServiceVersion,
        'otel_zone.crashed.service.version',
      );
      expect(NativeCrashDrain.crashedBuildId, 'otel_zone.crashed.app.build_id');
    });

    test(
      'a report that does not know its build has neither attribute',
      () async {
        final ReadableLogRecord record = await exported(
          _report(attributes: <String, String>{'process.pid': '1'}),
        );
        final ReadableLogRecord noAttributes = await exported(_report());

        for (final ReadableLogRecord r in <ReadableLogRecord>[
          record,
          noAttributes,
        ]) {
          expect(
            r.attributes?.getString(NativeCrashDrain.crashedServiceVersion),
            isNull,
          );
          expect(
            r.attributes?.getString(NativeCrashDrain.crashedBuildId),
            isNull,
          );
        }
      },
    );

    test(
      'a blank value is omitted rather than exported as an empty string',
      () async {
        final ReadableLogRecord record = await exported(
          _report(
            attributes: <String, String>{
              'otel_zone.crashed.service.version': '',
              'otel_zone.crashed.app.build_id': '  ',
            },
          ),
        );

        expect(
          record.attributes?.getString(NativeCrashDrain.crashedServiceVersion),
          isNull,
        );
        expect(
          record.attributes?.getString(NativeCrashDrain.crashedBuildId),
          isNull,
        );
      },
    );

    test('one known half is kept without the other', () async {
      final ReadableLogRecord record = await exported(
        _report(
          attributes: <String, String>{'otel_zone.crashed.app.build_id': '7'},
        ),
      );

      expect(
        record.attributes?.getString(NativeCrashDrain.crashedBuildId),
        '7',
      );
      expect(
        record.attributes?.getString(NativeCrashDrain.crashedServiceVersion),
        isNull,
      );
    });
  });

  test('the redactor scrubs the record it produces', () async {
    final _FakeSource source = _FakeSource(<NativeCrashReport>[
      _report(
        message: 'user 123456789',
        attributes: <String, String>{'path': '/home/123456789'},
      ),
    ]);
    final _RecordingExporter exporter = _RecordingExporter();

    await drain(
      source,
      exporter,
      redact: (String input) => input.replaceAll('123456789', '<redacted>'),
    ).drain();

    final ReadableLogRecord record = exporter.batches.single.single;
    expect(record.body, 'user <redacted>');
    expect(
      record.attributes?.getString('exception.message'),
      'user <redacted>',
    );
    expect(record.attributes?.getString('path'), '/home/<redacted>');
  });

  test(
    'a redactor that throws drops the report instead of exporting it raw',
    () async {
      final _FakeSource source = _FakeSource(<NativeCrashReport>[_report()]);
      final _RecordingExporter exporter = _RecordingExporter();

      expect(
        await drain(
          source,
          exporter,
          redact: (String input) => throw StateError('bad rule'),
        ).drain(),
        0,
      );
      expect(exporter.batches, isEmpty);
      expect(source.acknowledged, isEmpty);
    },
  );

  test(
    'a dropped report is not acknowledged alongside a delivered one',
    () async {
      final _FakeSource source = _FakeSource(<NativeCrashReport>[
        _report(id: 'kept'),
        _report(id: 'dropped', message: 'secret token'),
      ]);
      final _RecordingExporter exporter = _RecordingExporter();

      final NativeCrashDrain subject = drain(
        source,
        exporter,
        redact: (String input) =>
            input.contains('secret') ? throw StateError('bad rule') : input,
      );
      expect(await subject.drain(), 1);
      await subject.settled();
      expect(exporter.batches.single, hasLength(1));
      // Acknowledging the dropped report would mark its OS record delivered
      // and lose the crash, which is worse than losing the export.
      expect(source.acknowledged, <List<String>>[
        <String>['kept'],
      ]);
    },
  );
}
