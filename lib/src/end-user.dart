import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

/// The attribute `OtelZone.setEndUser` stamps: the semantic convention's
/// `enduser.id`.
///
/// Read from the SDK's generated registry rather than typed out, the way
/// `app.build_id` is, and pinned to its literal by a test, so a rename upstream
/// shows up as a failing test and not as a dashboard that quietly empties.
final String endUserIdKey = Enduser.enduserId.key;

/// Stamps [endUserIdKey] on every span as it starts.
///
/// Only a span that starts after the id is set carries it. The stamp is made in
/// `onStart` and never again, so a span already running when the id is set or
/// cleared keeps what it started with: the identity on a span is the one that
/// was current when the work began.
///
/// It is appended to the tracer provider after `OTel.initialize`, behind
/// dartastic's own processors. That is early enough: a span is queued and
/// exported at `onEnd`, after every processor has seen it start, and
/// `RedactingSpanExporter` exempts the key when it scrubs at export.
///
/// Never throws and never returns a failed future. The SDK calls `onStart`
/// without awaiting it, so an error here would surface as an uncaught zone
/// error, in the app's own error handler.
final class EndUserSpanProcessor implements SpanProcessor {
  /// Creates a processor that stamps whatever [currentId] answers when a span
  /// starts, or nothing when it answers `null`.
  EndUserSpanProcessor(this._currentId);

  final String? Function() _currentId;

  @override
  Future<void> onStart(Span span, Context? parentContext) {
    try {
      final String? id = _currentId();
      if (id != null) span.setStringAttribute<String>(endUserIdKey, id);
    } on Object {
      // Instrumentation is never in the functional path. A span without the
      // id is a span that is not linked to an account, which is the safe way
      // for this to fail.
    }
    return Future<void>.value();
  }

  @override
  Future<void> onEnd(Span span) => Future<void>.value();

  @override
  Future<void> onNameUpdate(Span span, String newName) => Future<void>.value();

  @override
  Future<void> shutdown() => Future<void>.value();

  @override
  Future<void> forceFlush() => Future<void>.value();
}

/// Stamps [endUserIdKey] on every log record as it is emitted.
///
/// **This one has to come first.** `BatchLogRecordProcessor.onEmit` queues a
/// *clone* of the record, so a stamp made by a processor that runs after it
/// lands on an original nobody exports. `OtelZone.start` therefore hands this
/// processor to `OTel.initialize` ahead of the pipeline and builds that
/// pipeline behind it; the provider's list is append-only, so there is no
/// adding it later. Spans do not need this, because a span is not cloned.
///
/// It runs after the bridge, so it never meets `OtelZoneConfig.redact`: the
/// id goes on the record as an attribute the redactor is not handed, and a
/// log record is exempt from scrubbing without a rule saying so.
///
/// An `enduser.id` the record already carries is replaced, not repeated: the
/// key stays unique and the zone's identity is the one that is exported.
///
/// Never throws and never returns a failed future, for the reason
/// [EndUserSpanProcessor] gives.
final class EndUserLogRecordProcessor implements LogRecordProcessor {
  /// Creates a processor that stamps whatever [currentId] answers when a
  /// record is emitted, or nothing when it answers `null`.
  EndUserLogRecordProcessor(this._currentId);

  final String? Function() _currentId;

  @override
  Future<void> onEmit(ReadWriteLogRecord logRecord, Context? context) {
    try {
      final String? id = _currentId();
      if (id != null) {
        logRecord
          ..removeAttribute(endUserIdKey)
          ..addAttribute(OTel.attributeString(endUserIdKey, id));
      }
    } on Object {
      // See [EndUserSpanProcessor.onStart].
    }
    return Future<void>.value();
  }

  @override
  bool enabled({
    Context? context,
    InstrumentationScope? instrumentationScope,
    Severity? severityNumber,
    String? eventName,
  }) => true;

  @override
  Future<void> shutdown() => Future<void>.value();

  @override
  Future<void> forceFlush() => Future<void>.value();
}
