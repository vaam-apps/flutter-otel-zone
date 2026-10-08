// Why the log stamper has to be the first log processor.
//
// `BatchLogRecordProcessor.onEmit` queues a *clone* of the record. A stamper
// that runs after it writes to the original, and the clone is what is
// exported, so the id never leaves the device. `OtelZone.start` builds the
// logs pipeline behind the stamper for this reason (and `addLogRecordProcessor`
// is append-only, so a stamper cannot be slipped in front afterwards).
//
// This test is the proof that the constraint is real. It is meant to be able to
// fail the other way: if dartastic stops cloning, the stamper could go
// anywhere, `start()`'s two-step logs pipeline is then needless, and this test
// is the signal to simplify it.
//
// In its own file: `OTel.initialize()` may only be called once per isolate.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/src/end-user.dart';

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

void main() {
  test(
    'a stamper behind the batch processor stamps a record nobody exports',
    () async {
      final _LogCapture exported = _LogCapture();
      await OTel.initialize(
        serviceName: 'end-user-order-test',
        serviceVersion: '0.0.1',
        enableMetrics: false,
        detectPlatformResources: false,
        // The exporting processor first, as it would be if the stamper were
        // simply added after `OTel.initialize` built dartastic's own pipeline.
        logRecordProcessor: BatchLogRecordProcessor(
          exported,
          const BatchLogRecordProcessorConfig(),
        ),
      );
      OTel.loggerProvider().addLogRecordProcessor(
        EndUserLogRecordProcessor(() => 'user-1'),
      );

      OTel.loggerProvider()
          .getLogger('end-user-order-test')
          .emit(severityNumber: Severity.WARN, body: 'too late');
      await OTel.loggerProvider().forceFlush();

      expect(exported.records, hasLength(1));
      expect(
        (exported.records.single.attributes?.toList() ?? <Attribute<Object>>[])
            .map((Attribute<Object> a) => a.key),
        isNot(contains('enduser.id')),
        reason:
            'the exported record is a clone taken before the stamper ran. If '
            'this fails, dartastic no longer clones and the stamper no longer '
            'has to come first.',
      );
    },
  );
}
