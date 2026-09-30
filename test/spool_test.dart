import 'dart:async';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';

/// A delegate whose acceptance is a switch, so a test can be offline for one
/// call and online for the next.
class _FakeExporter implements LogRecordExporter {
  /// Starts offline, which is the state every spooling test is about.
  bool failing = true;

  /// Bodies this delegate refuses even while it is otherwise online — a
  /// collector that will never take one particular batch.
  final Set<String> refused = <String>{};

  /// When set, every export waits for it before answering, so a test can hold
  /// a delivery in flight. A future that never completes is a killed process.
  Future<void>? hold;

  final List<List<ReadableLogRecord>> batches = <List<ReadableLogRecord>>[];

  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    batches.add(logRecords);
    await hold;
    final bool refusing = logRecords.any(
      (ReadableLogRecord record) => refused.contains(record.body),
    );
    return failing || refusing ? ExportResult.failure : ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

ReadableLogRecord _record({
  String body = 'boom',
  Severity severity = Severity.WARN,
  int? timestampMicros,
  Attributes? attributes,
  Resource? resource,
}) {
  return SDKLogRecord(
    instrumentationScope: OTel.instrumentationScope(name: 'package.talker'),
    resource:
        resource ??
        OTel.resource(Attributes.of(<String, Object>{'service.name': 'test'})),
    timestamp: timestampMicros == null ? null : Int64(timestampMicros),
    severityNumber: severity,
    severityText: severity.name.toLowerCase(),
    body: body,
    attributes: attributes,
  );
}

int _byName(File a, File b) => a.path.compareTo(b.path);

List<File> _spoolFiles(Directory directory) =>
    directory.listSync().whereType<File>().toList();

/// Waits for [condition], because a write-ahead file appears asynchronously
/// after `export` is called and nothing else signals it.
Future<void> _until(bool Function() condition) async {
  for (int i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'timed out waiting');
}

void main() {
  late Directory directory;
  late _FakeExporter delegate;
  late SpoolingLogRecordExporter spool;

  setUpAll(() async {
    // `OTel.resource` / `OTel.instrumentationScope` / `Attributes.of` all
    // answer with "OTel.initialize() must be called first" until the SDK has
    // an API factory. Both signals off: this is about the value types, not a
    // pipeline, and nothing here should reach the network.
    await OTel.initialize(
      serviceName: 'spool-test',
      serviceVersion: '0.0.1',
      enableLogs: false,
      enableMetrics: false,
    );
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('otel_zone_spool');
    delegate = _FakeExporter();
    spool = SpoolingLogRecordExporter(
      delegate: delegate,
      directory: directory,
      maxAge: null,
    );
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  group('export', () {
    test('a batch the delegate accepts leaves nothing on disk', () async {
      delegate.failing = false;

      final ExportResult result = await spool.export(<ReadableLogRecord>[
        _record(),
      ]);

      expect(result, ExportResult.success);
      expect(_spoolFiles(directory), isEmpty);
    });

    test('the batch is on disk before the delegate is called', () async {
      delegate.failing = false;
      final Completer<void> gate = Completer<void>();
      delegate.hold = gate.future;

      final Future<ExportResult> pending = spool.export(<ReadableLogRecord>[
        _record(body: 'in flight'),
      ]);
      await _until(() => delegate.batches.isNotEmpty);

      // The delegate has the batch and has not answered: this is the window
      // a killed process used to lose it in.
      expect(_spoolFiles(directory), hasLength(1));
      expect(
        _spoolFiles(directory).single.readAsStringSync(),
        contains('in flight'),
      );

      gate.complete();
      expect(await pending, ExportResult.success);
      expect(_spoolFiles(directory), isEmpty);
    });

    test('a process killed mid-export is replayed by the next one', () async {
      // The delegate never answers, which is what the first process's
      // request looks like from the disk once that process is gone.
      delegate.hold = Completer<void>().future;
      unawaited(
        spool.export(<ReadableLogRecord>[_record(body: 'lost in a tunnel')]),
      );
      // The renamed file, not merely a file: the write-ahead is a temp file and
      // then a rename, and the next spool sweeps any temp it does not own. Taking
      // the temp for the batch made this test lose the race on a slow disk.
      await _until(
        () => _spoolFiles(
          directory,
        ).any((File f) => f.path.endsWith('.spool.json')),
      );

      final _FakeExporter revived = _FakeExporter()..failing = false;
      final SpoolingLogRecordExporter next = SpoolingLogRecordExporter(
        delegate: revived,
        directory: directory,
        maxAge: null,
      );

      expect(await next.replay(), 1);
      expect(revived.batches.single.single.body, 'lost in a tunnel');
      expect(_spoolFiles(directory), isEmpty);
    });

    test('a refusal on export is not counted against the file', () async {
      final List<String> warnings = <String>[];
      final SpoolingLogRecordExporter once = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: directory,
        maxAttempts: 1,
        onWarning: warnings.add,
      );

      // Refused, and it may only mean there is no signal. Kept, and reported
      // as success because it is durable; only a later replay may count it.
      for (int i = 0; i < 3; i++) {
        expect(
          await once.export(<ReadableLogRecord>[_record(body: 'b$i')]),
          ExportResult.success,
        );
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }

      expect(_spoolFiles(directory), hasLength(3));
      expect(
        _spoolFiles(
          directory,
        ).every((File f) => f.path.endsWith('-0.spool.json')),
        isTrue,
      );
      expect(warnings, isEmpty);
    });

    test('an unwritable directory still delivers directly', () async {
      final File blocker = File('${directory.path}/blocker');
      await blocker.writeAsString('not a directory');
      delegate.failing = false;
      final SpoolingLogRecordExporter blocked = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: Directory('${blocker.path}/nested'),
      );

      final ExportResult result = await blocked.export(<ReadableLogRecord>[
        _record(body: 'no disk'),
      ]);

      expect(result, ExportResult.success);
      expect(delegate.batches.single.single.body, 'no disk');
    });

    test('a batch the delegate refuses is left on disk', () async {
      final ExportResult result = await spool.export(<ReadableLogRecord>[
        _record(),
      ]);

      // Success, not failure: the batch is durable, and reporting failure
      // would have the processor retry — and re-spool — the same records.
      expect(result, ExportResult.success);
      expect(_spoolFiles(directory), hasLength(1));
    });

    test('a delegate that throws is treated as a refusal', () async {
      final SpoolingLogRecordExporter throwing = SpoolingLogRecordExporter(
        delegate: _ThrowingExporter(),
        directory: directory,
      );

      final ExportResult result = await throwing.export(<ReadableLogRecord>[
        _record(),
      ]);

      expect(result, ExportResult.success);
      expect(_spoolFiles(directory), hasLength(1));
    });

    test('an orphaned temp file is reclaimed on the next spool', () async {
      // What a process death between write and rename leaves behind: a file
      // no `.spool.json` scan would ever see, so no cap would ever remove it.
      final File orphan = File(
        '${directory.path}/0000000000000001-0.spool.json.tmp',
      );
      await orphan.writeAsString('{"half":');

      await spool.export(<ReadableLogRecord>[_record()]);

      expect(orphan.existsSync(), isFalse);
      expect(_spoolFiles(directory), hasLength(1));
      expect(_spoolFiles(directory).single.path, endsWith('.spool.json'));
    });

    test('an empty batch is neither delegated nor written', () async {
      final ExportResult result = await spool.export(<ReadableLogRecord>[]);

      expect(result, ExportResult.success);
      expect(delegate.batches, isEmpty);
      expect(_spoolFiles(directory), isEmpty);
    });

    test('an unwritable directory falls back without throwing', () async {
      final File blocker = File('${directory.path}/blocker');
      await blocker.writeAsString('not a directory');
      final SpoolingLogRecordExporter blocked = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: Directory('${blocker.path}/nested'),
      );

      final ExportResult result = await blocked.export(<ReadableLogRecord>[
        _record(),
      ]);

      // The delegate's own answer, which is what a build without spooling
      // would have seen. Nothing is thrown into the app.
      expect(result, ExportResult.failure);
    });
  });

  group('replay', () {
    test(
      'delivers once, deletes the file, and keeps the record intact',
      () async {
        await spool.export(<ReadableLogRecord>[
          _record(
            body: 'offline fault',
            timestampMicros: 1700000000000000,
            attributes: Attributes.of(<String, Object>{'k': 'v'}),
          ),
        ]);
        expect(_spoolFiles(directory), hasLength(1));

        delegate.failing = false;
        final int replayed = await spool.replay();

        expect(replayed, 1);
        expect(_spoolFiles(directory), isEmpty);

        final ReadableLogRecord delivered = delegate.batches.last.single;
        expect(delivered.body, 'offline fault');
        expect(delivered.severityNumber, Severity.WARN);
        expect(delivered.timestamp, Int64(1700000000000000));
        expect(delivered.attributes?.getString('k'), 'v');
        // The replayed marker is added on the way out, not on the wire the
        // first time.
        expect(
          delivered.attributes?.getBool(
            SpoolingLogRecordExporter.replayedAttribute,
          ),
          isTrue,
        );
        // The resource captured when the fault happened rides along, so the
        // crash stays filed under the version that crashed.
        expect(
          delivered.resource?.attributes.getString('service.name'),
          'test',
        );

        // Nothing left to replay, so nothing is delivered twice.
        expect(await spool.replay(), 0);
        expect(delegate.batches, hasLength(2));
      },
    );

    test(
      'a file an older release wrote, with no count, still replays',
      () async {
        Future<void> seed(
          String name,
          String body,
        ) => File('${directory.path}/$name.spool.json').writeAsString(
          '{"v":1,"resource":{},"records":[{"body":"$body","severity":"WARN"}]}',
        );
        await seed('0000000000000001-0', 'old');
        await seed('0000000000000002-0', 'newer');
        // The collector takes one and refuses the other, so the refusal is
        // the file's own and is counted.
        delegate
          ..failing = false
          ..refused.add('old');

        expect(await spool.replay(), 1);
        expect(_spoolFiles(directory).single.path, endsWith('-0-1.spool.json'));

        delegate.refused.clear();
        expect(await spool.replay(), 1);
        expect(_spoolFiles(directory), isEmpty);
      },
    );

    test('stops at the first refusal and keeps every remaining file', () async {
      await spool.export(<ReadableLogRecord>[_record(body: 'one')]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await spool.export(<ReadableLogRecord>[_record(body: 'two')]);
      expect(_spoolFiles(directory), hasLength(2));

      expect(await spool.replay(), 0);
      expect(_spoolFiles(directory), hasLength(2));
    });

    test(
      'discards an undecodable file instead of retrying it forever',
      () async {
        final File corrupt = File(
          '${directory.path}/0000000000000001-0.spool.json',
        );
        await corrupt.writeAsString('{not json');

        delegate.failing = false;
        expect(await spool.replay(), 0);
        expect(corrupt.existsSync(), isFalse);
      },
    );

    test('ignores files that are not spool files', () async {
      await File('${directory.path}/notes.txt').writeAsString('leave me');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await spool.export(<ReadableLogRecord>[_record()]);

      delegate.failing = false;
      expect(await spool.replay(), 1);
      expect(File('${directory.path}/notes.txt').existsSync(), isTrue);
    });
  });

  group('the attempt cap', () {
    late List<String> warnings;

    SpoolingLogRecordExporter launch({int maxAttempts = 3}) =>
        SpoolingLogRecordExporter(
          delegate: delegate,
          directory: directory,
          maxAge: null,
          maxAttempts: maxAttempts,
          onWarning: warnings.add,
        );

    /// Spools [bodies] while the collector is unreachable.
    Future<void> spoolOffline(List<String> bodies) async {
      delegate.failing = true;
      final SpoolingLogRecordExporter writer = launch();
      for (final String body in bodies) {
        await writer.export(<ReadableLogRecord>[_record(body: body)]);
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }
    }

    /// The collector answers, but refuses the batch with this body for good.
    void poison(String body) {
      delegate
        ..failing = false
        ..refused.add(body)
        ..batches.clear();
    }

    setUp(() => warnings = <String>[]);

    test('offline for ten launches drops nothing', () async {
      await spoolOffline(<String>['one', 'two', 'three']);

      for (int launchNumber = 0; launchNumber < 10; launchNumber++) {
        expect(await launch().replay(), 0);
      }

      expect(_spoolFiles(directory), hasLength(3));
      expect(
        _spoolFiles(
          directory,
        ).every((File f) => f.path.endsWith('-0.spool.json')),
        isTrue,
        reason: 'no failure was counted while nothing was answering',
      );
      expect(warnings, isEmpty);
    });

    test('an offline pass tries the head and one probe, then stops', () async {
      await spoolOffline(<String>['one', 'two', 'three']);
      delegate.batches.clear();

      await launch().replay();

      // The head, and the one file that proves the network is down. Not the
      // third: that would spend the radio to learn the same thing.
      expect(delegate.batches, hasLength(2));
    });

    test(
      'a poisoned head is dropped after N passes and the next is delivered',
      () async {
        // A fresh exporter and a fresh healthy file behind the head on every
        // launch, so nothing but the probe rule can be what counts.
        await spoolOffline(<String>['poison']);

        for (int pass = 1; pass <= 3; pass++) {
          delegate.failing = true;
          await launch().export(<ReadableLogRecord>[_record(body: 'ok$pass')]);
          await Future<void>.delayed(const Duration(milliseconds: 3));
          poison('poison');
          expect(await launch().replay(), 1, reason: 'ok$pass was delivered');
          expect(warnings, hasLength(pass == 3 ? 1 : 0));
        }

        expect(warnings.single, contains('3 failed delivery attempts'));
        expect(_spoolFiles(directory), isEmpty);
      },
    );

    test(
      'the pass carries on past the probe once the collector works',
      () async {
        await spoolOffline(<String>['poison', 'two', 'three']);
        poison('poison');

        expect(await launch().replay(), 2);

        expect(_spoolFiles(directory).single.path, endsWith('-1.spool.json'));
        expect(
          delegate.batches.map((List<ReadableLogRecord> b) => b.single.body),
          <Object?>['poison', 'two', 'three'],
        );
      },
    );

    test(
      'a lone poisoned file is counted when this process just delivered',
      () async {
        await spoolOffline(<String>['poison']);
        final SpoolingLogRecordExporter live = launch();
        poison('poison');
        // Live traffic getting through is the probe there is no second file
        // for.
        expect(
          await live.export(<ReadableLogRecord>[_record(body: 'live')]),
          ExportResult.success,
        );
        expect(live.lastDeliverySuccessAt, isNotNull);

        for (int pass = 1; pass <= 3; pass++) {
          expect(await live.replay(), 0);
        }

        expect(_spoolFiles(directory), isEmpty);
        expect(warnings, hasLength(1));
      },
    );

    test('a lone file that has never seen a success is not counted', () async {
      await spoolOffline(<String>['alone']);

      for (int launchNumber = 0; launchNumber < 10; launchNumber++) {
        await launch().replay();
      }

      expect(_spoolFiles(directory).single.path, endsWith('-0.spool.json'));
      expect(warnings, isEmpty);
    });

    test('the count is on disk, so it carries across exporters', () async {
      await spoolOffline(<String>['poison', 'two']);
      poison('poison');
      await launch().replay();
      expect(_spoolFiles(directory).single.path, endsWith('-1.spool.json'));

      // A different launch, another healthy neighbour.
      delegate.failing = true;
      await launch().export(<ReadableLogRecord>[_record(body: 'three')]);
      poison('poison');
      await launch().replay();
      expect(_spoolFiles(directory).single.path, endsWith('-2.spool.json'));
    });

    test('a warning that throws does not stop the replay', () async {
      final SpoolingLogRecordExporter noisy = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: directory,
        maxAge: null,
        maxAttempts: 1,
        onWarning: (String _) => throw StateError('talker is down'),
      );
      await spoolOffline(<String>['poison', 'tail']);
      poison('poison');

      expect(await noisy.replay(), 1);
      expect(_spoolFiles(directory), isEmpty);
    });
  });

  group('concurrent delivery', () {
    test('replay skips a file an export is still delivering', () async {
      delegate.failing = false;
      final Completer<void> gate = Completer<void>();
      delegate.hold = gate.future;

      final Future<ExportResult> exporting = spool.export(<ReadableLogRecord>[
        _record(),
      ]);
      await _until(() => delegate.batches.isNotEmpty);

      expect(await spool.replay(), 0);
      expect(delegate.batches, hasLength(1));

      gate.complete();
      await exporting;
      expect(delegate.batches, hasLength(1));
      expect(_spoolFiles(directory), isEmpty);
    });

    test('two replays never send one file twice', () async {
      await spool.export(<ReadableLogRecord>[_record()]);
      delegate
        ..failing = false
        ..batches.clear();
      final Completer<void> gate = Completer<void>();
      delegate.hold = gate.future;

      final Future<int> first = spool.replay();
      final Future<int> second = spool.replay();
      await _until(() => delegate.batches.isNotEmpty);
      gate.complete();

      expect(await first + await second, 1);
      expect(delegate.batches, hasLength(1));
    });
  });

  group('enqueue', () {
    test('returns once the batch is durable, not once it is sent', () async {
      delegate.hold = Completer<void>().future;

      final bool durable = await spool.enqueue(<ReadableLogRecord>[
        _record(body: 'crash'),
      ]);

      expect(durable, isTrue);
      expect(_spoolFiles(directory), hasLength(1));
    });

    test('delivers in the background and deletes on acceptance', () async {
      delegate.failing = false;

      await spool.enqueue(<ReadableLogRecord>[_record()]);
      await spool.settled();

      expect(delegate.batches, hasLength(1));
      expect(_spoolFiles(directory), isEmpty);
    });

    test('a failed background delivery is kept for replay', () async {
      await spool.enqueue(<ReadableLogRecord>[_record()]);
      await spool.settled();

      expect(_spoolFiles(directory), hasLength(1));
      delegate.failing = false;
      expect(await spool.replay(), 1);
    });

    test('reports false, and sends nothing, when the disk refuses', () async {
      final File blocker = File('${directory.path}/blocker');
      await blocker.writeAsString('not a directory');
      final SpoolingLogRecordExporter blocked = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: Directory('${blocker.path}/nested'),
      );

      expect(await blocked.enqueue(<ReadableLogRecord>[_record()]), isFalse);
      expect(delegate.batches, isEmpty);
    });
  });

  group('the journal of handled reports', () {
    test('a report id is journalled before enqueue returns', () async {
      await spool.enqueue(
        <ReadableLogRecord>[_record(body: 'crash')],
        reportIds: <String>['exit-1', 'exit-2'],
      );

      expect(await spool.handledReports(), <String>{'exit-1', 'exit-2'});
    });

    test('a new exporter on the same directory reads it back', () async {
      // The relaunched engine builds its own exporter: what it knows about the
      // previous one has to come from disk.
      await spool.enqueue(
        <ReadableLogRecord>[_record()],
        reportIds: <String>['exit-1'],
      );

      final SpoolingLogRecordExporter next = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: directory,
        maxAge: null,
      );

      expect(await next.handledReports(), <String>{'exit-1'});
    });

    test('the journal is not a spool file, so replay never sends it', () async {
      delegate.failing = false;
      await spool.enqueue(
        <ReadableLogRecord>[_record()],
        reportIds: <String>['exit-1'],
      );
      await spool.settled();

      expect(await spool.replay(), 0);
      expect(delegate.batches, hasLength(1));
      expect(await spool.handledReports(), <String>{'exit-1'});
    });

    test('an enqueue that names no report writes no journal', () async {
      await spool.enqueue(<ReadableLogRecord>[_record()]);

      expect(await spool.handledReports(), isEmpty);
      expect(
        directory.listSync().whereType<File>().where(
          (File f) => f.path.endsWith('handled-reports.json'),
        ),
        isEmpty,
      );
    });

    test('forgetting the last id removes the file', () async {
      delegate.failing = false;
      await spool.enqueue(
        <ReadableLogRecord>[_record()],
        reportIds: <String>['exit-1', 'exit-2'],
      );
      await spool.settled();

      await spool.forgetHandled(<String>['exit-1']);
      expect(await spool.handledReports(), <String>{'exit-2'});

      await spool.forgetHandled(<String>['exit-2']);
      expect(await spool.handledReports(), isEmpty);
      expect(_spoolFiles(directory), isEmpty);
    });

    test('keeps only the newest ids once it passes its cap', () async {
      delegate.failing = false;
      for (int i = 0; i < 70; i++) {
        await spool.enqueue(
          <ReadableLogRecord>[_record()],
          reportIds: <String>['exit-$i'],
        );
      }
      await spool.settled();

      final Set<String> journal = await spool.handledReports();
      expect(journal, hasLength(64));
      expect(journal, contains('exit-69'));
      expect(journal, isNot(contains('exit-0')));
    });

    test('an unreadable journal is an empty one', () async {
      await Directory(directory.path).create(recursive: true);
      await File(
        '${directory.path}/handled-reports.json',
      ).writeAsString('{ not json');

      expect(await spool.handledReports(), isEmpty);
    });

    test(
      'a journal that cannot be written does not fail the enqueue',
      () async {
        // A directory where the journal file should be: the rename cannot land.
        await Directory('${directory.path}/handled-reports.json').create();

        final bool durable = await spool.enqueue(
          <ReadableLogRecord>[_record()],
          reportIds: <String>['exit-1'],
        );

        expect(durable, isTrue);
        // The batch on disk still names its report, which is what matters
        // while the batch is there.
        expect(await spool.handledReports(), <String>{'exit-1'});
      },
    );

    test('a batch on disk names its own reports, with no journal', () async {
      // The file and the journal are two writes; a kill between them must not
      // leave a durable batch whose report nobody recognises.
      await spool.enqueue(
        <ReadableLogRecord>[_record()],
        reportIds: <String>['exit-1'],
      );
      await spool.settled();
      File('${directory.path}/handled-reports.json').deleteSync();

      expect(await spool.handledReports(), <String>{'exit-1'});
    });

    test('once the batch is delivered only the journal remembers it', () async {
      delegate.failing = false;
      await spool.enqueue(
        <ReadableLogRecord>[_record()],
        reportIds: <String>['exit-1'],
      );
      await spool.settled();

      expect(
        _spoolFiles(
          directory,
        ).where((File f) => f.path.endsWith('.spool.json')),
        isEmpty,
      );
      expect(await spool.handledReports(), <String>{'exit-1'});
    });

    test('an orphaned journal temp file is reclaimed', () async {
      await spool.enqueue(
        <ReadableLogRecord>[_record()],
        reportIds: <String>['exit-1'],
      );
      final File orphan = File('${directory.path}/handled-reports.json.tmp')
        ..writeAsStringSync('[]');

      await spool.replay();

      expect(orphan.existsSync(), isFalse);
      expect(await spool.handledReports(), <String>{'exit-1'});
    });
  });

  group('cap', () {
    test('evicts the oldest batch once the cap is exceeded', () async {
      final SpoolingLogRecordExporter capped = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: directory,
        maxBatches: 2,
        maxAge: null,
      );

      for (final String body in <String>['one', 'two', 'three']) {
        await capped.export(<ReadableLogRecord>[_record(body: body)]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final List<File> files = _spoolFiles(directory);
      expect(files, hasLength(2));
      final String kept = files
          .map((File f) => f.readAsStringSync())
          .join('\n');
      expect(kept, isNot(contains('one')));
      expect(kept, contains('two'));
      expect(kept, contains('three'));
    });

    test('a crash batch is evicted only after every ordinary one', () async {
      final SpoolingLogRecordExporter capped = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: directory,
        maxBatches: 2,
        maxAge: null,
      );

      // The oldest file, and the only one marked.
      await capped.enqueue(<ReadableLogRecord>[
        _record(body: 'crash'),
      ], evictLast: true);
      await capped.settled();
      for (final String body in <String>['one', 'two']) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await capped.export(<ReadableLogRecord>[_record(body: body)]);
      }

      final String kept = _spoolFiles(
        directory,
      ).map((File f) => f.readAsStringSync()).join('\n');
      expect(_spoolFiles(directory), hasLength(2));
      expect(kept, contains('crash'));
      expect(kept, isNot(contains('one')));
      expect(kept, contains('two'));
    });

    test(
      'crash batches are evicted oldest-first once nothing else is left',
      () async {
        final SpoolingLogRecordExporter capped = SpoolingLogRecordExporter(
          delegate: delegate,
          directory: directory,
          maxBatches: 1,
          maxAge: null,
        );

        for (final String body in <String>['first', 'second']) {
          await capped.enqueue(<ReadableLogRecord>[
            _record(body: body),
          ], evictLast: true);
          await capped.settled();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        final String kept = _spoolFiles(
          directory,
        ).map((File f) => f.readAsStringSync()).join('\n');
        expect(kept, contains('second'));
        expect(kept, isNot(contains('first')));
      },
    );

    test('drops a file older than the age cap', () async {
      final String staleStamp = DateTime.now()
          .subtract(const Duration(days: 30))
          .microsecondsSinceEpoch
          .toString()
          .padLeft(16, '0');
      final File stale = File('${directory.path}/$staleStamp-0.spool.json');
      await stale.writeAsString(
        '{"v":1,"resource":{},"records":[{"body":"stale"}]}',
      );
      final SpoolingLogRecordExporter aged = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: directory,
        maxAge: const Duration(days: 7),
      );

      delegate.failing = true;
      await aged.export(<ReadableLogRecord>[_record(body: 'fresh')]);

      final List<String> kept = _spoolFiles(
        directory,
      ).map((File f) => f.readAsStringSync()).toList();
      expect(kept, hasLength(1));
      expect(kept.single, contains('fresh'));
    });
  });
  group('byte cap', () {
    // Every batch is the same size to the byte: same-length tag, same-length
    // padding, and no timestamps. `_size` measures it rather than guessing, so
    // the caps below say "room for two files" and not a magic number.
    ReadableLogRecord batch(String tag, {int padding = 2000}) =>
        _record(body: '$tag${'x' * padding}');

    late int size;
    late List<String> warnings;

    SpoolingLogRecordExporter capped({
      required int files,
      int maxBatches = 32,
      Duration? maxAge,
      bool nullCap = false,
    }) => SpoolingLogRecordExporter(
      delegate: delegate,
      directory: directory,
      maxBatches: maxBatches,
      maxAge: maxAge,
      // Room for `files` files and a little over, never enough for one more.
      maxBytes: nullCap ? null : size * files + size ~/ 2,
      onWarning: warnings.add,
    );

    String contents() => (_spoolFiles(
      directory,
    )..sort(_byName)).map((File f) => f.readAsStringSync()).join('\n');

    setUp(() async {
      warnings = <String>[];
      final Directory probeDirectory = await Directory.systemTemp.createTemp(
        'otel_zone_size',
      );
      final SpoolingLogRecordExporter probe = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: probeDirectory,
        maxAge: null,
        maxBytes: null,
      );
      await probe.export(<ReadableLogRecord>[batch('aa')]);
      size = _spoolFiles(probeDirectory).single.lengthSync();
      await probeDirectory.delete(recursive: true);
    });

    test('evicts the oldest ordinary batch first', () async {
      final SpoolingLogRecordExporter subject = capped(files: 2);

      for (final String tag in <String>['a1', 'b2', 'c3']) {
        await subject.export(<ReadableLogRecord>[batch(tag)]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(_spoolFiles(directory), hasLength(2));
      expect(contents(), isNot(contains('a1x')));
      expect(contents(), contains('b2x'));
      expect(contents(), contains('c3x'));
    });

    test('keeps a crash report while an ordinary batch remains', () async {
      final SpoolingLogRecordExporter subject = capped(files: 2);

      // The oldest file, and the only one marked.
      await subject.enqueue(<ReadableLogRecord>[batch('cr')], evictLast: true);
      await subject.settled();
      for (final String tag in <String>['a1', 'b2']) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await subject.export(<ReadableLogRecord>[batch(tag)]);
      }

      expect(_spoolFiles(directory), hasLength(2));
      expect(contents(), contains('crx'));
      expect(contents(), isNot(contains('a1x')));
      expect(contents(), contains('b2x'));
    });

    test('evicts the oldest crash report once crash reports alone exceed '
        'it', () async {
      final SpoolingLogRecordExporter subject = capped(files: 2);

      for (final String tag in <String>['c1', 'c2', 'c3']) {
        await subject.enqueue(<ReadableLogRecord>[batch(tag)], evictLast: true);
        await subject.settled();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(_spoolFiles(directory), hasLength(2));
      expect(contents(), isNot(contains('c1x')));
      expect(contents(), contains('c2x'));
      expect(contents(), contains('c3x'));
    });

    test('a single batch larger than the cap is not spooled, warns once and '
        'evicts nothing', () async {
      final SpoolingLogRecordExporter subject = capped(files: 2);
      await subject.enqueue(<ReadableLogRecord>[batch('cr')], evictLast: true);
      await subject.settled();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await subject.export(<ReadableLogRecord>[batch('a1')]);
      final String before = contents();

      await subject.export(<ReadableLogRecord>[batch('big', padding: 20000)]);
      final bool enqueued = await subject.enqueue(<ReadableLogRecord>[
        batch('big', padding: 20000),
      ]);
      await subject.settled();

      expect(enqueued, isFalse, reason: 'the caller still owns it');
      expect(contents(), before);
      expect(directory.listSync(), hasLength(2), reason: 'and no temp file');
      // One warning per refused batch, counts only, never the body.
      expect(warnings, hasLength(2));
      expect(warnings.first, contains('spoolMaxBytes'));
      expect(warnings.first, isNot(contains('xxxx')));
    });

    test('null is no byte cap', () async {
      final SpoolingLogRecordExporter subject = capped(files: 1, nullCap: true);

      for (final String tag in <String>['a1', 'b2', 'c3']) {
        await subject.export(<ReadableLogRecord>[batch(tag, padding: 20000)]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(_spoolFiles(directory), hasLength(3));
      expect(warnings, isEmpty);
    });

    test(
      'is enforced at replay for a directory already over the cap',
      () async {
        // What an older release, with no byte cap, could have left behind.
        final SpoolingLogRecordExporter older = capped(files: 1, nullCap: true);
        await older.enqueue(<ReadableLogRecord>[batch('cr')], evictLast: true);
        await older.settled();
        for (final String tag in <String>['a1', 'b2', 'c3']) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await older.export(<ReadableLogRecord>[batch(tag)]);
        }
        expect(_spoolFiles(directory), hasLength(4));

        // What `older` tried live is not what replay sends.
        delegate.batches.clear();
        final SpoolingLogRecordExporter subject = capped(files: 2);
        await subject.replay();

        expect(_spoolFiles(directory), hasLength(2));
        expect(contents(), contains('crx'));
        expect(contents(), contains('c3x'));
        // Evicted before it was tried, so the radio never carried a batch the
        // cap had already condemned.
        final String sent = delegate.batches
            .expand((List<ReadableLogRecord> b) => b)
            .map((ReadableLogRecord r) => '${r.body}')
            .join('\n');
        expect(sent, isNot(contains('a1x')));
        expect(sent, isNot(contains('b2x')));
      },
    );

    test('counts spool files only, never the journal or a temp file', () async {
      await File(
        '${directory.path}/handled-reports.json',
      ).writeAsString('["${'r' * (size * 4)}"]');
      final SpoolingLogRecordExporter subject = capped(files: 2);

      for (final String tag in <String>['a1', 'b2']) {
        await subject.export(<ReadableLogRecord>[batch(tag)]);
      }

      expect(
        _spoolFiles(
          directory,
        ).where((File f) => f.path.endsWith('.spool.json')),
        hasLength(2),
      );
    });

    test('works together with the count cap', () async {
      // Room for three files by bytes, two by count: the count wins.
      final SpoolingLogRecordExporter subject = capped(files: 3, maxBatches: 2);

      for (final String tag in <String>['a1', 'b2', 'c3']) {
        await subject.export(<ReadableLogRecord>[batch(tag)]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(_spoolFiles(directory), hasLength(2));
      expect(contents(), isNot(contains('a1x')));
    });

    test('works together with the age cap', () async {
      final String staleStamp = DateTime.now()
          .subtract(const Duration(days: 30))
          .microsecondsSinceEpoch
          .toString()
          .padLeft(16, '0');
      await File(
        '${directory.path}/$staleStamp-0.spool.json',
      ).writeAsString('{"v":1,"resource":{},"records":[{"body":"stale"}]}');
      // Room for two by bytes; the stale file is dropped by age and, being
      // tiny, would never have been what the byte cap removed.
      final SpoolingLogRecordExporter subject = capped(
        files: 2,
        maxAge: const Duration(days: 7),
      );

      for (final String tag in <String>['a1', 'b2', 'c3']) {
        await subject.export(<ReadableLogRecord>[batch(tag)]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(contents(), isNot(contains('stale')));
      expect(_spoolFiles(directory), hasLength(2));
      expect(contents(), contains('c3x'));
    });
  });
}

/// A delegate that fails by throwing, which an exporter is allowed to do.
class _ThrowingExporter implements LogRecordExporter {
  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    throw const SocketException('no route to host');
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}
