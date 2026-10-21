# Scrubbing with `redact`

Supply one `redact` function and every string an exported record carries is
scrubbed by it — log records, recovered crash reports and spans.

```dart
final OtelZone observability = OtelZone(
  OtelZoneConfig(
    serviceName: 'my-app',
    endpoint: Env.otelEndpoint,
    redact: (input) => input
        .replaceAll(RegExp(r'\d{9}'), '<phone>')
        .replaceAll(RegExp(r'Bearer \S+'), 'Bearer <redacted>'),
  ),
);
```

`redact` is a `Redactor`: `String Function(String input)`.

It lives here, at the one point every record crosses, rather than at each call
site: a rule bolted on per call site is a rule one call site eventually
misses.

## One field at a time

`redact` is handed **one field at a time**, never a rendered record. So a
whole-value pattern such as `^\+?\d{9,12}$` matches a phone-number field as it
would a string of its own.

| Record            | The fields `redact` sees                                                                                              |
| ----------------- | --------------------------------------------------------------------------------------------------------------------- |
| Log record        | the message, the title, the error/exception text, the stack trace's text                                              |
| Breadcrumb line   | the whole line, `time [title] message` — before it is cut to `breadcrumbLineLimit`                                    |
| `[riverpod-fail]` | the error and the stack trace (from `RiverpodFailLog`'s own fields), one by one, then laid out as it lays them out    |
| Span              | each attribute value (each element of a string list), each event and link attribute, the status description, the name |
| Native crash      | the type, the message, the stack trace, each thread's frames, each platform attribute                                 |

A record kind that renders more than `TalkerData` does (an HTTP logger's
headers or response body) sends only the title, time, message and stack trace
when `redact` is set.

It runs **before** truncation and before the record reaches the exporter, so
nothing unredacted can be persisted or sent.

## Spans are scrubbed too

Attribute values, the attributes of each span event — which is where a
recorded exception's message and stack trace are — and of each link, the
status description, and the span name all go through `redact`. Attribute
keys, event names and non-text values (ids, times, kind, status code,
numbers) are the span's schema and are left alone.

To do this the package builds the trace pipeline itself when `redact` is set,
from the same `OTEL_TRACES_EXPORTER` and `OTEL_EXPORTER_OTLP_*` variables
dartastic reads (`otlp` over HTTP or gRPC, and `console`); without `redact` it
is dartastic's own, untouched. `RedactingSpanExporter` is the piece that does
the scrubbing: a span is already ended by the time anything can see it, so
the exporter hands its delegate a read-only, scrubbed view rather than
rewriting the span.

Spans do not go through the export floor or the spool.

::: warning Keep it cheap
`redact` runs synchronously, on the isolate that exports — the UI isolate in
a Flutter app. A review measured about 38 ms for a 512-span batch with three
regular expressions.
:::

## Fail closed

A `redact` that throws **drops** the record instead of letting it through
unredacted, and it never throws into the app:

- a log record is dropped;
- one breadcrumb line that cannot be scrubbed drops the whole trail (a trail
  is only useful as a set), but not the fault it decorates;
- a span is dropped, and the first such drop is one warning on the talker
  (its error's type, never its text);
- a native crash report is dropped rather than exported raw, and is not
  acknowledged — the platform keeps it for the next launch.

## What it does not touch

- **Resource attributes.** They are set by the app at `start()` and are not
  records; give them already-scrubbed values.
- **`enduser.id`.** The one attribute
  [`setEndUser`](/guide/end-user#the-id-is-exempt-from-redact) stamps on
  purpose is exempt — on spans and on log records. Only that exact key.
- **The platforms' own crash files.** They are written before Dart runs and
  hold the raw text. See
  [What the platforms store before Dart runs](/guide/native-crashes#what-the-platforms-store-before-dart-runs).
- **`talker.history`.** The redacted copy is what goes to the sink; the
  original stays on the device, where it is not a disclosure.
- **What it cannot know.** `redact` is a pattern match on text. A value shaped
  like nothing it looks for gets through, which is why the observers record
  no provider values, family arguments or route arguments to begin with.

The crash attributes are scrubbed like any other:
`otel_zone.crashed.service.version` and `otel_zone.crashed.app.build_id`
would be rewritten by a redactor that rewrites version-shaped strings — leave
them out of its rules — and `otel_zone.crashed.screen` is app text that a
redactor may empty (which removes the attribute) or rewrite.
