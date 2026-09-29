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
      expect(exported.instrumentationScope, span.instrumentationScope);
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

  group('the pipeline OtelZone builds when redact is set', () {
    tearDown(() => EnvironmentService.testOverrides = null);

    test('is a batch processor by default', () {
      EnvironmentService.testOverrides = <String, String>{};

      expect(
        buildRedactingSpanProcessor(
          endpoint: 'http://127.0.0.1:4318',
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

      expect(
        buildRedactingSpanProcessor(
          endpoint: 'http://127.0.0.1:4318',
          secure: false,
          redact: scrub,
        ),
        isNull,
      );
    });

    test('honours the console exporter, the gRPC protocol and an unknown '
        'name like dartastic does', () {
      for (final Map<String, String> env in <Map<String, String>>[
        <String, String>{'OTEL_TRACES_EXPORTER': 'console'},
        <String, String>{'OTEL_TRACES_EXPORTER': 'otlp,console'},
        <String, String>{'OTEL_EXPORTER_OTLP_PROTOCOL': 'grpc'},
        <String, String>{'OTEL_EXPORTER_OTLP_PROTOCOL': 'http/json'},
        <String, String>{'OTEL_TRACES_EXPORTER': 'zipkin'},
      ]) {
        EnvironmentService.testOverrides = env;
        expect(
          buildRedactingSpanProcessor(
            endpoint: 'http://127.0.0.1:4318',
            secure: false,
            redact: scrub,
          ),
          isA<BatchSpanProcessor>(),
          reason: '$env',
        );
      }
    });
  });
}
