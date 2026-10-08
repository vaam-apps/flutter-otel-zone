import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'config.dart';
import 'end-user.dart';
import 'otlp-exporter.dart';

/// A [SpanExporter] that hands its delegate a scrubbed copy of every span, so
/// `OtelZoneConfig.redact` covers what a span carries as well as what a log
/// record does.
///
/// Every string a span exports goes through [redact]: attribute values (and
/// each element of a string-list value), the attributes of each event — which
/// is where `recordException` puts the exception message and stack trace — the
/// attributes of each link, the status description, and the span name.
/// Attribute keys, event names and everything that is not text (ids, times,
/// kind, status code, numbers) are left alone: they are the span's schema, not
/// data an app put there.
///
/// **One attribute is exempt: `enduser.id`.** It is the id `OtelZone.setEndUser`
/// stamps, put there on purpose by an app that has decided the id may leave the
/// device, and a redactor that masks it unlinks the span without a word. It
/// happens: over 200,000 random ids of each kind, an unanchored `\d{9}` (the
/// README's own example) masked about 1 in 10,000 cuids and 1 in 33 UUIDs, while an
/// anchored whole-value pattern masked neither. Every other attribute, on a
/// span, an event or a link, is scrubbed exactly as before, so an app that
/// hands a phone number to `setEndUser` is the one thing this lets through.
///
/// ## Why an exporter, and why a view
///
/// A processor cannot do this. A span is already ended when a processor's
/// `onEnd` sees it, and the SDK ignores every mutator on an ended span, so
/// nothing can be rewritten in place. `Span`'s constructor is private as well,
/// so a scrubbed copy cannot be built. What the delegate gets instead is a
/// read-only view that implements `Span` and answers the text-bearing getters
/// with scrubbed values. It is made when the batch is exported, so the cost is
/// paid only for spans that are actually leaving.
///
/// ## Failing closed
///
/// A [redact] that throws for a span drops that span. It never lets the
/// unscrubbed one through and never throws into the SDK.
///
/// ## Cost
///
/// [redact] runs synchronously, on the isolate that exports, which in a
/// Flutter app is the UI isolate. A reviewer measured about 38 ms for a
/// 512-span batch with three regular expressions. Keep the redactor cheap.
final class RedactingSpanExporter implements SpanExporter {
  /// Wraps [delegate], scrubbing every span with [redact] first.
  ///
  /// [onDropped] is told about the first span a throwing [redact] made this
  /// exporter drop, and never again: a redactor that always throws would
  /// otherwise report once per span.
  RedactingSpanExporter({
    required SpanExporter delegate,
    required this.redact,
    void Function(Object error)? onDropped,
  }) : _delegate = delegate,
       _onDropped = onDropped;

  /// The scrubber applied to every string a span carries.
  final Redactor redact;

  final SpanExporter _delegate;
  final void Function(Object error)? _onDropped;
  bool _reportedDrop = false;

  @override
  Future<void> export(List<Span> spans) {
    final List<Span> scrubbed = <Span>[];
    for (final Span span in spans) {
      try {
        scrubbed.add(_RedactedSpan(span, redact));
      } on Object catch (error) {
        // Fail closed: one span the redactor cannot scrub is not exported.
        _reportDrop(error);
      }
    }
    if (scrubbed.isEmpty) return Future<void>.value();
    return _delegate.export(scrubbed);
  }

  void _reportDrop(Object error) {
    if (_reportedDrop) return;
    _reportedDrop = true;
    try {
      _onDropped?.call(error);
    } on Object {
      // Reporting is best-effort and never costs the export.
    }
  }

  @override
  Future<void> forceFlush() => _delegate.forceFlush();

  @override
  Future<void> shutdown() => _delegate.shutdown();
}

/// A read-only `Span` whose text is scrubbed and everything else is the
/// original's. Only the exporter side of the SDK reads it; the mutators are
/// forwarded and, on an ended span, ignored, exactly as they are on the
/// original.
final class _RedactedSpan implements Span {
  _RedactedSpan(this._span, Redactor redact)
    : name = redact(_span.name),
      instrumentationScope = _scrubScope(_span.instrumentationScope, redact),
      // ignore: invalid_use_of_visible_for_testing_member
      attributes = _scrubAttributes(_span.attributes, redact),
      spanEvents = _scrubEvents(_span.spanEvents, redact),
      spanLinks = _scrubLinks(_span.spanLinks, redact),
      statusDescription = _span.statusDescription == null
          ? null
          : redact(_span.statusDescription!);

  final Span _span;

  @override
  final String name;

  @override
  final Attributes attributes;

  @override
  final List<SpanEvent>? spanEvents;

  @override
  final List<SpanLink>? spanLinks;

  @override
  final String? statusDescription;

  @override
  Resource? get resource => _span.resource;

  @override
  void end({DateTime? endTime, SpanStatusCode? spanStatus}) =>
      _span.end(endTime: endTime, spanStatus: spanStatus);

  @override
  set attributes(Attributes newAttributes) => _span.attributes = newAttributes;

  @override
  void addAttributes(Attributes attributes) => _span.addAttributes(attributes);

  @override
  void addEvent(SpanEvent spanEvent) => _span.addEvent(spanEvent);

  @override
  void addEventNow(String name, [Attributes? attributes]) =>
      _span.addEventNow(name, attributes);

  @override
  void addEvents(Map<String, Attributes?> spanEvents) =>
      _span.addEvents(spanEvents);

  @override
  void addLink(SpanContext spanContext, [Attributes? attributes]) =>
      _span.addLink(spanContext, attributes);

  @override
  void addSpanLink(SpanLink spanLink) => _span.addSpanLink(spanLink);

  @override
  DateTime? get endTime => _span.endTime;

  @override
  bool get isEnded => _span.isEnded;

  @override
  bool get isRecording => _span.isRecording;

  @override
  SpanKind get kind => _span.kind;

  /// `null`, not the raw parent: the parent is another span whose text has not
  /// been scrubbed. The OTLP transformer takes the parent's id from
  /// `spanContext.parentSpanId` when there is no parent object, so the link
  /// survives.
  @override
  APISpan? get parentSpan => null;

  @override
  void recordException(
    Object exception, {
    StackTrace? stackTrace,
    Attributes? attributes,
    bool? escaped,
  }) => _span.recordException(
    exception,
    stackTrace: stackTrace,
    attributes: attributes,
    escaped: escaped,
  );

  @override
  void setBoolAttribute(String name, bool value) =>
      _span.setBoolAttribute(name, value);

  @override
  void setBoolListAttribute(String name, List<bool> value) =>
      _span.setBoolListAttribute(name, value);

  @override
  void setDoubleAttribute(String name, double value) =>
      _span.setDoubleAttribute(name, value);

  @override
  void setDoubleListAttribute(String name, List<double> value) =>
      _span.setDoubleListAttribute(name, value);

  @override
  void setIntAttribute(String name, int value) =>
      _span.setIntAttribute(name, value);

  @override
  void setIntListAttribute(String name, List<int> value) =>
      _span.setIntListAttribute(name, value);

  @override
  void setStatus(SpanStatusCode statusCode, [String? description]) =>
      _span.setStatus(statusCode, description);

  @override
  void setStringAttribute<T>(String name, String value) =>
      _span.setStringAttribute<T>(name, value);

  @override
  void setStringListAttribute<T>(String name, List<String> value) =>
      _span.setStringListAttribute<T>(name, value);

  @override
  void setDateTimeAsStringAttribute(String name, DateTime value) =>
      _span.setDateTimeAsStringAttribute(name, value);

  @override
  SpanContext get spanContext => _span.spanContext;

  @override
  SpanId get spanId => _span.spanId;

  @override
  DateTime get startTime => _span.startTime;

  @override
  SpanStatusCode get status => _span.status;

  @override
  void updateName(String name) => _span.updateName(name);

  /// A copy whose attributes are scrubbed. The OTLP exporters send only the
  /// scope's name and version, but they log the whole span on request, and
  /// dartastic fills a span's scope attributes from the ones the span started
  /// with.
  @override
  final InstrumentationScope instrumentationScope;

  @override
  SpanContext? get parentSpanContext => _span.parentSpanContext;

  @override
  bool get isValid => _span.isValid;

  @override
  bool isInstanceOf(Type type) => _span.isInstanceOf(type);

  /// Scrubbed like everything else: the OTLP exporters log `$spans` when
  /// `OTEL_DART_LOG_SPANS` is set, and that must not print the raw span.
  @override
  String toString() =>
      'Span { name: $name, spanContext: $spanContext, kind: $kind, '
      'instrumentationScope: $instrumentationScope, startTime: $startTime, '
      'endTime: $endTime, status: $status, '
      'statusDescription: $statusDescription, attributes: $attributes, '
      'spanEvents: $spanEvents, spanLinks: $spanLinks }';
}

InstrumentationScope _scrubScope(InstrumentationScope scope, Redactor redact) {
  final Attributes? attributes = scope.attributes;
  if (attributes == null) return scope;
  return _ScrubbedScope(scope, _scrubAttributes(attributes, redact));
}

/// [_scope] with scrubbed [attributes], and everything else as it was. It
/// implements the class rather than building one, because dartastic's factory
/// turns an absent version into `1.0.0`, and the version is part of what
/// groups spans on the wire.
final class _ScrubbedScope implements InstrumentationScope {
  _ScrubbedScope(this._scope, this.attributes);

  final InstrumentationScope _scope;

  @override
  final Attributes attributes;

  @override
  String get name => _scope.name;

  @override
  String? get version => _scope.version;

  @override
  String? get schemaUrl => _scope.schemaUrl;

  @override
  String toString() =>
      'InstrumentationScope{name: $name, version: $version, '
      'schemaUrl: $schemaUrl, attributes: $attributes}';
}

/// [attributes] with every string value, and every element of a string-list
/// value, run through [redact]. A value the redactor empties is dropped,
/// because an attribute may not be an empty string.
///
/// The attribute named [endUserIdKey] is passed through as it is.
Attributes _scrubAttributes(Attributes attributes, Redactor redact) {
  final List<Attribute<Object>> scrubbed = <Attribute<Object>>[];
  for (final Attribute<Object> attribute in attributes.toList()) {
    final Object value = attribute.value;
    if (attribute.key == endUserIdKey) {
      scrubbed.add(attribute);
    } else if (value is String) {
      final String text = redact(value);
      if (text.isNotEmpty) {
        scrubbed.add(OTel.attributeString(attribute.key, text));
      }
    } else if (value is List<String>) {
      final List<String> texts = <String>[
        for (final String element in value)
          if (redact(element) case final String text when text.isNotEmpty) text,
      ];
      if (texts.isNotEmpty) {
        scrubbed.add(OTel.attributeStringList(attribute.key, texts));
      }
    } else {
      scrubbed.add(attribute);
    }
  }
  return OTel.attributes(scrubbed);
}

List<SpanEvent>? _scrubEvents(List<SpanEvent>? events, Redactor redact) {
  if (events == null) return null;
  return <SpanEvent>[
    for (final SpanEvent event in events)
      OTel.spanEvent(
        event.name,
        event.attributes == null
            ? null
            : _scrubAttributes(event.attributes!, redact),
        event.timestamp,
      ),
  ];
}

List<SpanLink>? _scrubLinks(List<SpanLink>? links, Redactor redact) {
  if (links == null) return null;
  return <SpanLink>[
    for (final SpanLink link in links)
      OTel.spanLink(
        link.spanContext,
        attributes: _scrubAttributes(link.attributes, redact),
      ),
  ];
}

/// The OTLP/HTTP configuration for the trace exporter, read from the
/// environment the way `TracesConfiguration.configureTracerProvider` reads it.
OtlpHttpExporterConfig traceHttpConfig({required String endpoint}) {
  final OtlpEnvironmentValues env = OTelEnv.getOtlpConfig(signal: 'traces');
  return OtlpHttpExporterConfig(
    endpoint: env.endpoint ?? endpoint,
    headers: resolveOtlpHeaders(signal: 'traces'),
    timeout: env.timeout ?? const Duration(seconds: 10),
    compression: env.compression == 'gzip',
    certificate: env.certificate,
    clientKey: env.clientKey,
    clientCertificate: env.clientCertificate,
    protocol:
        otlpHttpProtocolFromString(env.protocol ?? 'http/protobuf') ??
        OtlpHttpProtocol.httpProtobuf,
  );
}

/// The OTLP/gRPC counterpart of [traceHttpConfig].
OtlpGrpcExporterConfig traceGrpcConfig({
  required String endpoint,
  required bool secure,
}) {
  final OtlpEnvironmentValues env = OTelEnv.getOtlpConfig(signal: 'traces');
  final String resolved = env.endpoint ?? endpoint;
  return OtlpGrpcExporterConfig(
    endpoint: resolved,
    insecure: !OTelEnv.resolveOtlpSecure(
      envInsecure: env.insecure,
      endpoint: resolved,
      explicitSecure: secure,
    ),
    headers: resolveOtlpHeaders(signal: 'traces'),
    timeout: env.timeout ?? const Duration(seconds: 10),
    compression: env.compression == 'gzip',
    certificate: env.certificate,
    clientKey: env.clientKey,
    clientCertificate: env.clientCertificate,
  );
}

/// The OTLP trace exporter the environment asks for: gRPC when
/// `OTEL_EXPORTER_OTLP_[TRACES_]PROTOCOL` says `grpc`, HTTP otherwise.
SpanExporter buildOtlpTraceExporter({
  required String endpoint,
  required bool secure,
}) {
  final String protocol =
      OTelEnv.getOtlpConfig(signal: 'traces').protocol ?? 'http/protobuf';
  return protocol == 'grpc'
      ? OtlpGrpcSpanExporter(
          traceGrpcConfig(endpoint: endpoint, secure: secure),
        )
      : OtlpHttpSpanExporter(traceHttpConfig(endpoint: endpoint));
}

/// The exporter for the trace pipeline [buildRedactingSpanProcessor] builds:
/// every exporter `OTEL_TRACES_EXPORTER` names, behind one
/// [RedactingSpanExporter], or `null` when it says `none`.
///
/// Names are `otlp` and `console`. One that is neither is ignored, and an
/// empty result falls back to `otlp`, as dartastic's does.
RedactingSpanExporter? buildRedactingTraceExporter({
  required String endpoint,
  required bool secure,
  required Redactor redact,
  void Function(Object error)? onDropped,
}) {
  final List<String> names =
      OTelEnv.getExporters(signal: 'traces') ?? const <String>['otlp'];
  if (names.contains('none')) return null;

  final List<SpanExporter> exporters = <SpanExporter>[
    for (final String name in names)
      if (name == 'otlp')
        buildOtlpTraceExporter(endpoint: endpoint, secure: secure)
      else if (name == 'console')
        ConsoleExporter(),
  ];
  if (exporters.isEmpty) {
    exporters.add(buildOtlpTraceExporter(endpoint: endpoint, secure: secure));
  }
  return RedactingSpanExporter(
    delegate: exporters.length == 1
        ? exporters.single
        : CompositeExporter(exporters),
    redact: redact,
    onDropped: onDropped,
  );
}

/// The trace pipeline to hand `OTel.initialize` when [redact] is set, or
/// `null` when dartastic's own should stand (`OTEL_TRACES_EXPORTER=none`).
///
/// dartastic offers no hook to wrap the exporter it builds from the
/// environment: `OTel.initialize(spanProcessor: ...)` *replaces* that whole
/// pipeline. So this rebuilds what `TracesConfiguration.configureTracerProvider`
/// builds — the same variables, the same defaults — with one difference, the
/// [RedactingSpanExporter] in front of every exporter. It is used only when a
/// [redact] is configured; a build without one keeps dartastic's own pipeline
/// untouched.
///
/// The returned processor starts a timer, so a caller that ends up not
/// installing it has to `shutdown()` it.
SpanProcessor? buildRedactingSpanProcessor({
  required String endpoint,
  required bool secure,
  required Redactor redact,
  void Function(Object error)? onDropped,
}) {
  final RedactingSpanExporter? exporter = buildRedactingTraceExporter(
    endpoint: endpoint,
    secure: secure,
    redact: redact,
    onDropped: onDropped,
  );
  if (exporter == null) return null;
  return BatchSpanProcessor(
    exporter,
    BatchSpanProcessorConfig.fromBspEnvironmentValues(OTelEnv.getBspConfig()),
  );
}
