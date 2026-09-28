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

  final List<List<ReadableLogRecord>> batches = <List<ReadableLogRecord>>[];

  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    batches.add(logRecords);
    return failing ? ExportResult.failure : ExportResult.success;
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
    test('a batch the delegate accepts never touches the disk', () async {
      delegate.failing = false;

      final ExportResult result = await spool.export(<ReadableLogRecord>[
        _record(),
      ]);

      expect(result, ExportResult.success);
      expect(_spoolFiles(directory), isEmpty);
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
