import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/src/otlp-exporter.dart';

import 'support/local-collector.dart';

void main() {
  setUpAll(() async {
    await OTel.initialize(
      serviceName: 'otlp-exporter-test',
      serviceVersion: '0.0.1',
      enableLogs: false,
      enableMetrics: false,
    );
  });

  tearDown(() => EnvironmentService.testOverrides = null);

  group('resolveOtlpHeaders', () {
    test('is empty when nothing is configured', () {
      EnvironmentService.testOverrides = <String, String>{};

      expect(resolveOtlpHeaders(), isEmpty);
    });

    test('reads the general variable', () {
      EnvironmentService.testOverrides = <String, String>{
        'OTEL_EXPORTER_OTLP_HEADERS': 'x-test=1, x-other=two',
      };

      expect(resolveOtlpHeaders(), <String, String>{
        'x-test': '1',
        'x-other': 'two',
      });
    });

    test('the logs variable wins over the general one', () {
      EnvironmentService.testOverrides = <String, String>{
        'OTEL_EXPORTER_OTLP_HEADERS': 'x-test=general',
        'OTEL_EXPORTER_OTLP_LOGS_HEADERS': 'x-test=logs',
      };

      expect(resolveOtlpHeaders(), <String, String>{'x-test': 'logs'});
    });

    test('accepts the semicolon form --dart-define needs', () {
      EnvironmentService.testOverrides = <String, String>{
        'OTEL_EXPORTER_OTLP_HEADERS': 'x-a=1;x-b=2',
      };

      expect(resolveOtlpHeaders(), <String, String>{'x-a': '1', 'x-b': '2'});
    });

    test('drops an empty entry instead of failing the exporter', () {
      EnvironmentService.testOverrides = <String, String>{
        'OTEL_EXPORTER_OTLP_HEADERS': 'x-test=1,x-empty= ,=novalue',
      };

      final Map<String, String> headers = resolveOtlpHeaders();

      expect(headers, <String, String>{'x-test': '1'});
      // The point of dropping: the config that would have thrown builds.
      expect(
        () => buildOtlpLogExporter(
          endpoint: 'http://127.0.0.1:4318',
          headers: headers,
        ),
        returnsNormally,
      );
    });
  });

  group('buildOtlpLogExporter', () {
    ReadableLogRecord record() => SDKLogRecord(
      instrumentationScope: OTel.instrumentationScope(name: 'test'),
      resource: OTel.defaultResource,
      timestamp: Int64(1700000000000000),
      severityNumber: Severity.WARN,
      body: 'hello',
    );

    test('sends the headers it is given', () async {
      final LocalCollector collector = await LocalCollector.start();
      addTearDown(collector.close);

      final LogRecordExporter exporter = buildOtlpLogExporter(
        endpoint: collector.endpoint,
        headers: <String, String>{'x-test': '1'},
      );
      final ExportResult result = await exporter.export(<ReadableLogRecord>[
        record(),
      ]);

      expect(result, ExportResult.success);
      expect(collector.requests.single.headers['x-test'], '1');
    });

    test('sends no extra header when none are configured', () async {
      final LocalCollector collector = await LocalCollector.start();
      addTearDown(collector.close);

      final LogRecordExporter exporter = buildOtlpLogExporter(
        endpoint: collector.endpoint,
      );
      await exporter.export(<ReadableLogRecord>[record()]);

      expect(collector.requests.single.headers, isNot(contains('x-test')));
      expect(
        collector.requests.single.headers,
        isNot(contains('authorization')),
      );
    });
  });
}
