import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:otel_riverpod/otel_riverpod.dart';
import 'package:riverpod/riverpod.dart'
    show ProviderObserver, ProviderObserverContext;

/// Marks the call stack of an observer callback whose spans must not carry
/// the provider's family argument. A zone value, so it is scoped to exactly
/// the spans that observer starts and to nothing else in the process.
const Symbol _dropArgument = #otelZoneDropRiverpodArgument;

/// Wraps [inner] so that the spans it starts do not carry
/// `riverpod.provider.argument`.
///
/// `otel_riverpod` 0.2.0 records `argument.toString()` on every provider span
/// whether or not `recordValues` is set, and offers no option to turn it off
/// (reported upstream). A family argument is often what a user typed, so this
/// package drops the attribute itself until that is fixed there.
///
/// The drop is a span processor that removes the attribute in `onStart`, while
/// the span is still open; it acts only on spans started inside a callback of
/// the returned observer, so a second observer built with the opt-in in the
/// same process is unaffected. The processor is added to the tracer provider
/// once.
ProviderObserver withoutProviderArguments(ProviderObserver inner) {
  final TracerProvider provider = OTel.tracerProvider();
  if (!provider.spanProcessors.any(
    (SpanProcessor p) => p is _ProviderArgumentStripper,
  )) {
    provider.addSpanProcessor(_ProviderArgumentStripper());
  }
  return _ArgumentlessProviderObserver(inner);
}

/// Removes `riverpod.provider.argument` from a span started under
/// [_dropArgument].
final class _ProviderArgumentStripper implements SpanProcessor {
  @override
  Future<void> onStart(Span span, Context? parentContext) async {
    // No `await` before this line: `Tracer.startSpan` calls `onStart` without
    // waiting, and the zone value is only visible on its synchronous part.
    if (Zone.current[_dropArgument] != true) return;
    // ignore: invalid_use_of_visible_for_testing_member
    final Attributes attributes = span.attributes;
    final String key = RiverpodSemantics.providerArgument.key;
    if (attributes.keys.contains(key)) {
      span.attributes = attributes.copyWithout(key);
    }
  }

  @override
  Future<void> onEnd(Span span) async {}

  @override
  Future<void> onNameUpdate(Span span, String newName) async {}

  @override
  Future<void> shutdown() async {}

  @override
  Future<void> forceFlush() async {}
}

/// Runs the callbacks of [_inner] under [_dropArgument].
///
/// Exactly the four `OTelRiverpodObserver` 0.2.0 overrides, which are also the
/// four every `riverpod` 3.x has; the lifecycle and mutation callbacks were
/// added to `ProviderObserver` in later 3.x releases, and overriding one this
/// package's `riverpod: ^3.0.0` floor does not have would not compile there.
/// `otel_riverpod` starts no span from any of them.
final class _ArgumentlessProviderObserver extends ProviderObserver {
  _ArgumentlessProviderObserver(this._inner);

  final ProviderObserver _inner;

  R _within<R>(R Function() body) =>
      runZoned<R>(body, zoneValues: <Object?, Object?>{_dropArgument: true});

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) =>
      _within(() => _inner.didAddProvider(context, value));

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) => _within(() => _inner.providerDidFail(context, error, stackTrace));

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) =>
      _within(() => _inner.didUpdateProvider(context, previousValue, newValue));

  @override
  void didDisposeProvider(ProviderObserverContext context) =>
      _within(() => _inner.didDisposeProvider(context));
}
