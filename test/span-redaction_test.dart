// What a span carries when it reaches the exporter behind `redact`.
//
// A real SDK and a capturing exporter, not a fake span: the view the exporter
// hands its delegate is built from a real `Span`, and the point is what the
// delegate reads off it — the same getters `OtlpHttpSpanExporter` reads.
//
// `OTel.initialize()` may only be called once per isolate, so this file
// initialises once and every test makes its own spans.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:otel_zone/src/span-redaction.dart';

/// Keeps every span it is handed.
final class _Capture implements SpanExporter {
  final List<Span> spans = <Span>[];

  @override
  Future<void> export(List<Span> spans) async => this.spans.addAll(spans);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

String scrub(String input) => input.replaceAll(RegExp(r'\d{9}'), '<phone>');

Object? attribute(Span span, String key) {
  for (final Attribute<Object> a in span.attributes.toList()) {
    if (a.key == key) return a.value;
  }
  return null;
}

Object? eventAttribute(SpanEvent event, String key) {
  for (final Attribute<Object> a in event.attributes!.toList()) {
    if (a.key == key) return a.value;
  }
  return null;
}

void main() {
  final _Capture capture = _Capture();
  // Swapped per test, so one test's redactor is not another's.
  Redactor redactor = scrub;

  setUpAll(() async {
    await OTel.initialize(
      serviceName: 'span-redaction-test',
      serviceVersion: '0.0.1',
      enableLogs: false,
      enableMetrics: false,
      detectPlatformResources: false,
      spanProcessor: SimpleSpanProcessor(
        RedactingSpanExporter(
          delegate: capture,
          redact: (String input) => redactor(input),
        ),
      ),
    );
  });

  setUp(() {
    capture.spans.clear();
    redactor = scrub;
  });

  Span start(String name, {Attributes? attributes}) => OTel.tracerProvider()
      .getTracer('span-redaction-test')
      .startSpan(name, attributes: attributes);

  group('RedactingSpanExporter', () {
    test('scrubs string attributes and each element of a string list', () {
      final Span span = start(
        'lookup',
        attributes: OTel.attributes(<Attribute<Object>>[
          OTel.attributeString('user.phone', 'call 699887766 now'),
          OTel.attributeStringList('user.contacts', <String>[
            '699887766',
            'nobody',
          ]),
          OTel.attributeInt('retry.count', 3),
          OTel.attributeBool('cache.hit', true),
        ]),
      );
      span.end();

      final Span exported = capture.spans.single;
      expect(attribute(exported, 'user.phone'), 'call <phone> now');
      expect(attribute(exported, 'user.contacts'), <String>[
        '<phone>',
        'nobody',
      ]);
      // Not text, so not the redactor's: same value, same type.
      expect(attribute(exported, 'retry.count'), 3);
      expect(attribute(exported, 'cache.hit'), true);
    });

    test('scrubs a recorded exception: its message and its stack trace', () {
      final Span span = start('send');
      span.recordException(
        StateError('could not reach 699887766'),
        stackTrace: StackTrace.fromString('#0 dial(699887766)'),
      );
      span.end();

      final SpanEvent event = capture.spans.single.spanEvents!.single;
      expect(event.name, 'exception');
      final String message =
          eventAttribute(event, 'exception.message')! as String;
      final String stack =
          eventAttribute(event, 'exception.stacktrace')! as String;
      expect(message, contains('<phone>'));
      expect(message, isNot(contains('699887766')));
      expect(stack, contains('<phone>'));
      expect(stack, isNot(contains('699887766')));
      // The type is what makes the event useful, and it is not user data.
      expect(eventAttribute(event, 'exception.type'), 'StateError');
    });

    test('scrubs the status description and the span name', () {
      final Span span = start('provider.failed:user 699887766');
      span.setStatus(SpanStatusCode.Error, 'no route to 699887766');
      span.end();

      final Span exported = capture.spans.single;
      expect(exported.name, 'provider.failed:user <phone>');
      expect(exported.statusDescription, 'no route to <phone>');
      expect(exported.status, SpanStatusCode.Error);
    });

    test('scrubs the attributes of an event and of a link', () {
      final Span span = start('checkout');
      span.addEventNow(
        'address.entered',
        OTel.attributesFromMap(<String, Object>{'address': 'flat 699887766'}),
      );
      span.addSpanLink(
        OTel.spanLink(
          span.spanContext,
          attributes: OTel.attributesFromMap(<String, Object>{
            'peer': '699887766',
          }),
        ),
      );
      span.end();

      final Span exported = capture.spans.single;
      expect(
        eventAttribute(exported.spanEvents!.single, 'address'),
        'flat <phone>',
      );
      expect(exported.spanEvents!.single.name, 'address.entered');
      final SpanLink link = exported.spanLinks!.single;
      expect(link.attributes.toList().single.value, '<phone>');
    });

    test('leaves the span\'s identity and timing exactly as it was', () {
      final Span span = start('checkout');
      span.end();

      final Span exported = capture.spans.single;
      expect(exported.spanContext, span.spanContext);
      expect(exported.kind, span.kind);
      expect(exported.startTime, span.startTime);
      expect(exported.endTime, span.endTime);
      expect(
        exported.instrumentationScope.name,
        span.instrumentationScope.name,
      );
      expect(
        exported.instrumentationScope.version,
        span.instrumentationScope.version,
      );
      expect(exported.resource, span.resource);
    });

    test('a value the redactor empties is dropped, not an error', () {
      redactor = (String input) => input.contains('699887766') ? '' : input;
      final Span span = start(
        'lookup',
        attributes: OTel.attributes(<Attribute<Object>>[
          OTel.attributeString('user.phone', '699887766'),
          OTel.attributeString('user.locale', 'fr-CM'),
        ]),
      );
      span.end();

      final Span exported = capture.spans.single;
      expect(attribute(exported, 'user.phone'), isNull);
      expect(attribute(exported, 'user.locale'), 'fr-CM');
    });

    test('a redactor that throws drops the span and throws nothing', () {
      redactor = (String input) => throw StateError('no scrubber today');

      expect(() => start('lookup').end(), returnsNormally);

      expect(
        capture.spans,
        isEmpty,
        reason: 'fail closed: an unscrubbed span must not reach the exporter',
      );
    });

    test('the unscrubbed original is untouched', () {
      final Span span = start(
        'lookup 699887766',
        attributes: OTel.attributesFromMap(<String, Object>{
          'user.phone': '699887766',
        }),
      );
      span.end();

      // What a span kept on the device says is not the exporter's to change.
      expect(span.name, 'lookup 699887766');
      expect(attribute(span, 'user.phone'), '699887766');
    });
  });

  group('what the view does not hand on', () {
    test('its toString is scrubbed, for the exporters that log `\$spans`', () {
      final Span span = start(
        'lookup 699887766',
        attributes: OTel.attributesFromMap(<String, Object>{
          'user.phone': '699887766',
        }),
      );
      span.recordException(StateError('bad 699887766'));
      span.setStatus(SpanStatusCode.Error, 'no route to 699887766');
      span.end();

      final String printed = '${capture.spans}';
      expect(printed, contains('<phone>'));
      expect(printed, isNot(contains('699887766')));
    });

    test('has no parent object, and the OTLP parent id is still there', () {
      final Span parent = start('parent 699887766');
      final Span child = OTel.tracerProvider()
          .getTracer('span-redaction-test')
          .startSpan('child', context: Context.current.withSpan(parent));
      child.end();
      parent.end();

      final Span exported = capture.spans.firstWhere(
        (Span s) => s.name == 'child',
      );
      // The raw parent carries the unscrubbed name and attributes; the view
      // must not hand it on.
      expect(exported.parentSpan, isNull);
      // What the OTLP exporters actually send: the transformer they share.
      expect(
        OtlpSpanTransformer.transformSpan(exported).parentSpanId,
        parent.spanContext.spanId.bytes,
      );
    });
  });

  group('a redactor that throws', () {
    test('is reported once, however many spans it drops', () async {
      final List<Object> reported = <Object>[];
      final RedactingSpanExporter exporter = RedactingSpanExporter(
        delegate: capture,
        redact: (String input) => throw StateError('no scrubber today'),
        onDropped: reported.add,
      );
      final Span first = start('one')..end();
      final Span second = start('two')..end();
      capture.spans.clear();

      await exporter.export(<Span>[first]);
      await exporter.export(<Span>[second]);

      expect(capture.spans, isEmpty);
      expect(reported, hasLength(1));
      expect(reported.single, isA<StateError>());
    });

    test('and a reporter that throws costs the export nothing', () async {
      final RedactingSpanExporter exporter = RedactingSpanExporter(
        delegate: capture,
        redact: (String input) => throw StateError('no scrubber today'),
        onDropped: (Object error) => throw StateError('no reporter either'),
      );
      final Span span = start('one')..end();
      capture.spans.clear();

      await expectLater(exporter.export(<Span>[span]), completes);
    });
  });

  group('the pipeline OtelZone builds when redact is set', () {
    const String endpoint = 'http://127.0.0.1:4318';
    tearDown(() => EnvironmentService.testOverrides = null);

    RedactingSpanExporter? exporter() => buildRedactingTraceExporter(
      endpoint: endpoint,
      secure: false,
      redact: scrub,
    );

    test('puts the redactor in front of the exporter, and a batch processor '
        'around that', () {
      EnvironmentService.testOverrides = <String, String>{};

      expect(exporter(), isA<RedactingSpanExporter>());
      expect(
        buildRedactingSpanProcessor(
          endpoint: endpoint,
          secure: false,
          redact: scrub,
        ),
        isA<BatchSpanProcessor>(),
      );
    });

    test('leaves dartastic\'s own alone when traces are turned off', () {
      EnvironmentService.testOverrides = <String, String>{
        'OTEL_TRACES_EXPORTER': 'none',
      };

      expect(exporter(), isNull);
      expect(
        buildRedactingSpanProcessor(
          endpoint: endpoint,
          secure: false,
          redact: scrub,
        ),
        isNull,
      );
    });

    test('a console exporter, or an unknown name, still gets the redactor', () {
      for (final String names in <String>[
        'console',
        'otlp,console',
        'zipkin',
      ]) {
        EnvironmentService.testOverrides = <String, String>{
          'OTEL_TRACES_EXPORTER': names,
        };

        expect(exporter(), isA<RedactingSpanExporter>(), reason: names);
      }
    });

    test('picks the exporter by protocol', () {
      EnvironmentService.testOverrides = <String, String>{};
      expect(
        buildOtlpTraceExporter(endpoint: endpoint, secure: false),
        isA<OtlpHttpSpanExporter>(),
      );

      EnvironmentService.testOverrides = <String, String>{
        'OTEL_EXPORTER_OTLP_PROTOCOL': 'grpc',
      };
      expect(
        buildOtlpTraceExporter(endpoint: endpoint, secure: false),
        isA<OtlpGrpcSpanExporter>(),
      );
    });

    // The two configurations below are what the exporters are built from.
    // Each field is read from a variable dartastic's own pipeline honours, so
    // a field dropped here would send spans without the credentials, the
    // trust or the wire format the rest of the app's telemetry has.
    test('the HTTP exporter carries headers, TLS, timeout, compression, '
        'protocol and endpoint', () {
      EnvironmentService.testOverrides = <String, String>{
        'OTEL_EXPORTER_OTLP_HEADERS': 'x-general=1',
        'OTEL_EXPORTER_OTLP_TRACES_HEADERS': 'x-traces=2',
        'OTEL_EXPORTER_OTLP_CERTIFICATE': 'test://ca',
        'OTEL_EXPORTER_OTLP_CLIENT_KEY': 'test://key',
        'OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE': 'test://cert',
        'OTEL_EXPORTER_OTLP_TIMEOUT': '1234',
        'OTEL_EXPORTER_OTLP_COMPRESSION': 'gzip',
        'OTEL_EXPORTER_OTLP_PROTOCOL': 'http/json',
        'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT': 'http://collector.test:4318',
      };

      final OtlpHttpExporterConfig config = traceHttpConfig(endpoint: endpoint);

      expect(config.headers, <String, String>{'x-traces': '2'});
      expect(config.certificate, 'test://ca');
      expect(config.clientKey, 'test://key');
      expect(config.clientCertificate, 'test://cert');
      expect(config.timeout, const Duration(milliseconds: 1234));
      expect(config.compression, isTrue);
      expect(config.protocol, OtlpHttpProtocol.httpJson);
      expect(config.endpoint, 'http://collector.test:4318');
    });

    test('and falls back to the configured endpoint and the defaults', () {
      EnvironmentService.testOverrides = <String, String>{};

      final OtlpHttpExporterConfig config = traceHttpConfig(endpoint: endpoint);

      expect(config.endpoint, endpoint);
      expect(config.headers, isEmpty);
      expect(config.protocol, OtlpHttpProtocol.httpProtobuf);
      expect(config.compression, isFalse);
      expect(config.timeout, const Duration(seconds: 10));
    });

    test('the gRPC exporter carries headers, TLS, timeout and compression', () {
      EnvironmentService.testOverrides = <String, String>{
        'OTEL_EXPORTER_OTLP_PROTOCOL': 'grpc',
        'OTEL_EXPORTER_OTLP_HEADERS': 'x-general=1',
        'OTEL_EXPORTER_OTLP_CERTIFICATE': 'test://ca',
        'OTEL_EXPORTER_OTLP_CLIENT_KEY': 'test://key',
        'OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE': 'test://cert',
        'OTEL_EXPORTER_OTLP_TIMEOUT': '1234',
        'OTEL_EXPORTER_OTLP_COMPRESSION': 'gzip',
      };

      final OtlpGrpcExporterConfig config = traceGrpcConfig(
        endpoint: 'collector.test:4317',
        secure: true,
      );

      expect(config.headers, <String, String>{'x-general': '1'});
      expect(config.certificate, 'test://ca');
      expect(config.clientKey, 'test://key');
      expect(config.clientCertificate, 'test://cert');
      expect(config.timeout, const Duration(milliseconds: 1234));
      expect(config.compression, isTrue);
      expect(config.insecure, isFalse);
    });

    test('gRPC is insecure exactly when the config says it is not secure', () {
      EnvironmentService.testOverrides = <String, String>{};

      expect(
        traceGrpcConfig(
          endpoint: 'collector.test:4317',
          secure: false,
        ).insecure,
        isTrue,
      );
      expect(
        traceGrpcConfig(endpoint: 'collector.test:4317', secure: true).insecure,
        isFalse,
      );
    });
  });
}
