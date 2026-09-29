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
      await _until(() => _spoolFiles(directory).isNotEmpty);

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

    test('a refusal is counted in the file name', () async {
      await spool.export(<ReadableLogRecord>[_record()]);

      expect(_spoolFiles(directory).single.path, endsWith('-1.spool.json'));

      await spool.replay();
      expect(_spoolFiles(directory).single.path, endsWith('-2.spool.json'));
    });

    test('a failure that reaches the cap on export drops the batch', () async {
      final List<String> warnings = <String>[];
      final SpoolingLogRecordExporter once = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: directory,
        maxAttempts: 1,
        onWarning: warnings.add,
      );

      final ExportResult result = await once.export(<ReadableLogRecord>[
        _record(),
      ]);

      // Not spooled, so the delegate's own answer is what the caller sees.
      expect(result, ExportResult.failure);
      expect(_spoolFiles(directory), isEmpty);
      expect(warnings, hasLength(1));
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
        final File legacy = File(
          '${directory.path}/0000000000000001-0.spool.json',
        );
        await legacy.writeAsString(
          '{"v":1,"resource":{},"records":[{"body":"old","severity":"WARN"}]}',
        );

        expect(await spool.replay(), 0);
        // Refused once, so it now carries a count of one.
        expect(_spoolFiles(directory).single.path, endsWith('-0-1.spool.json'));

        delegate.failing = false;
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

  group('a batch that is never accepted', () {
    late List<String> warnings;
    late SpoolingLogRecordExporter capped;

    setUp(() {
      warnings = <String>[];
      capped = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: directory,
        maxAge: null,
        maxAttempts: 3,
        onWarning: warnings.add,
      );
    });

    Future<void> spoolHeadAndTail() async {
      // Offline for both, so both are on disk; the head is then refused for
      // good while the collector takes anything else.
      await capped.export(<ReadableLogRecord>[_record(body: 'head')]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await capped.export(<ReadableLogRecord>[_record(body: 'tail')]);
      delegate
        ..failing = false
        ..refused.add('head')
        ..batches.clear();
    }

    test('is dropped after the cap and no longer blocks the next', () async {
      await spoolHeadAndTail();

      // One failure was the export itself, so the second is the last.
      expect(await capped.replay(), 0);
      expect(warnings, isEmpty);
      // Stopping at the head is deliberate: the tail has not been tried.
      expect(delegate.batches, hasLength(1));

      expect(await capped.replay(), 1);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('3 failed delivery attempts'));
      expect(_spoolFiles(directory), isEmpty);
      expect(
        delegate.batches.last.single.body,
        'tail',
        reason: 'the head was dropped and replay moved on to the tail',
      );
    });

    test('is dropped exactly once, however many replays follow', () async {
      await spoolHeadAndTail();

      for (int i = 0; i < 6; i++) {
        await capped.replay();
      }

      expect(warnings, hasLength(1));
    });

    test(
      'keeps counting across exporters, because the count is on disk',
      () async {
        await spoolHeadAndTail();
        await capped.replay();

        final SpoolingLogRecordExporter next = SpoolingLogRecordExporter(
          delegate: delegate,
          directory: directory,
          maxAge: null,
          maxAttempts: 3,
          onWarning: warnings.add,
        );
        expect(await next.replay(), 1);
        expect(warnings, hasLength(1));
      },
    );

    test('a warning that throws does not stop the replay', () async {
      final SpoolingLogRecordExporter noisy = SpoolingLogRecordExporter(
        delegate: delegate,
        directory: directory,
        maxAge: null,
        maxAttempts: 2,
        onWarning: (String _) => throw StateError('talker is down'),
      );
      await noisy.export(<ReadableLogRecord>[_record(body: 'head')]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await noisy.export(<ReadableLogRecord>[_record(body: 'tail')]);
      delegate
        ..failing = false
        ..refused.add('head');

      expect(await noisy.replay(), 1);
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
