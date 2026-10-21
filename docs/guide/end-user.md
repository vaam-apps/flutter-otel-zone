# Linking telemetry to an account

```dart
observability.setEndUser('cmg2x8k4a0000abcd1234efgh'); // signed in, opted in
observability.setEndUser(null); // signed out, or opted out
```

`OtelZone.setEndUser(String? id)` stamps the semantic convention's
`enduser.id` on every span that starts and every log record that is emitted
from then on, until it is called again. `null` stops it, and so does an empty
string, because an attribute may not be empty. `endUserId` reads back what
the next span and record will carry.

The package never sets it by itself. An app that does not call `setEndUser`
exports no `enduser.id` anywhere, and whether, when and for whom to call it is
the app's decision — a consent, a sign-in — not something this package asks.

## From the next one, and no further back

A span is stamped as it starts and a record as it is emitted, so the identity
on telemetry is the one that was current when it was made:

- A span already running when the id is set does not gain it, and one running
  when it is cleared keeps it. A span that wraps a sign-in, started before it,
  stays unlinked.
- Nothing already emitted, queued or spooled is rewritten. Clearing the id
  stops linking; it does not recall.
- Recovered native crash reports are not stamped. They describe the previous
  run, and whoever is signed in now is not necessarily who was then.

## The id is exempt from `redact`

On a span the id is passed through whole while every other attribute is
scrubbed as before; a log record's is added after the bridge has scrubbed the
record, so `redact` never meets it. Only the exact key `enduser.id` is exempt.

The exemption is there because masking happens. Over 200,000 random ids of
each kind, the unanchored `\d{9}` used as the README's example masks about
1 in 10,000 cuids and 1 in 33 UUIDs; an anchored `^\+?\d{9,12}$` masks
neither. A masked id unlinks its span with nothing to say so.

::: danger Pass an opaque account id
The price of the exemption is that it trusts the app. Pass an opaque account
id — never a phone number, an e-mail address or a name, which `redact` would
otherwise have caught.
:::

## It never throws, and any zone may call it

It is one field assignment, with no lock, no timer and no I/O. The id lives on
the `OtelZone` and in no `Zone`, so it does not matter which zone sets it or
which later starts a span; the last call wins. It belongs to the isolate, like
the rest of Dart's state: a background isolate has its own `OtelZone` and its
own id.

It is safe at any time, before `start()` included. Before the SDK is up there
is nothing to stamp, so the call has no visible effect; the id is kept, and
the first span and record after a successful `start()` carry it. If the SDK
never starts, nothing is ever stamped. Stamping itself never throws into the
SDK either: the SDK calls its processors without awaiting them, and a failure
there would otherwise surface as an uncaught error in the app's own handler.
It fails towards an unlinked span.

## How it is wired

The order is not arbitrary.

- **Spans** are stamped by `EndUserSpanProcessor` in `onStart`, appended
  behind the trace pipeline. A span is exported at its end, after every
  processor has seen it start, so appending is early enough.
- **Log records** are stamped by `EndUserLogRecordProcessor` in `onEmit`, and
  that one has to be **first**: the batch processor queues a _clone_ of each
  record, and a stamp made after it lands on an original nobody exports.
  `addLogRecordProcessor` only appends, so `start()` hands the stamper to
  `OTel.initialize` and builds the rest of the logs pipeline behind it, with
  the SDK's own `LogsConfiguration` function and the arguments
  `OTel.initialize` would have passed — so `OTEL_LOGS_EXPORTER`, the
  `OTEL_EXPORTER_OTLP_*` headers and the spool behave as they did. An
  `enduser.id` a record already carries is replaced, not repeated.

## On sign-out

Clear the id **and** the spool (see
[Where the spool lives](/guide/spool#where-the-spool-lives)): a batch spooled
while the id was set keeps it, and is delivered with it on the next launch.
