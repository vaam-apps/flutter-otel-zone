# How it fits together

`otel_zone` is four things that are only correct together.

| Piece         | What it is                                                       | Where                        |
| ------------- | ---------------------------------------------------------------- | ---------------------------- |
| **The zone**  | `runGuarded`: every uncaught-error channel wired to one function | [The guarded zone][zone]     |
| **The sink**  | One `Talker` that everything in the app writes to                | [below](#the-sink)           |
| **The floor** | `OtelBridge`: decides which records are worth the radio          | [The export floor][floor]    |
| **The guard** | `safely()` and the lazy observers: instrumentation cannot throw  | [Never blocks the app][safe] |

[zone]: ./guarded-zone
[floor]: ./export-floor
[safe]: ./never-blocks

## The path a record takes

```text
 uncaught error ──► runGuarded's handlers ─┐
 caught error ────► reportError ───────────┤
 talker.info/…, Riverpod, routes ──────────┤
                                           ▼
                                    Talker (one sink) ──► talker.history (everything, on device)
                                           │
                                           ▼
                                    OtelBridge
                                      · below the floor? stop here
                                      · error/critical? emit the breadcrumb trail first
                                      · redact, fail closed
                                           │
                                           ▼
                                    OTelTalkerObserver ──► OTel logs pipeline
                                                              │ (optional) spool on disk
                                                              ▼
                                                           OTLP collector
```

Spans take a separate path: the Riverpod and navigation observers (and any
instrumentation the app writes) go through the OpenTelemetry SDK's trace
pipeline, scrubbed by `redact` when one is set. Spans do not go through the
export floor or the spool.

Native crashes from the previous run take a third: `start()` drains them from
the platform and emits them as `FATAL` log records straight onto the export
path. They do not go through `Talker` and are not gated by the floor — see
[Native crashes](/guide/native-crashes).

## The sink

One `Talker`. Riverpod transitions, route changes, classified failures and
uncaught errors all land on it, so there is no second reporting path to keep
in sync. `OtelZone.talker` exists from the moment the `OtelZone` does —
before `start()`, before the binding — so nothing logged early is lost.

Everything stays in `talker.history`, on the device, whatever the floor says.
Records made inside a `Tracer.startActiveSpan` block inherit its trace and
span ids, so a log lands correlated with the operation that produced it.

The package depends on `talker`, not `talker_flutter`: nothing here renders.
An app that wants `TalkerScreen` adds it for its own reasons.

## What is configuration and what is not

The split between `OtelZoneConfig` and `start()` is deliberate, and it is the
only one in the package:

- **What is compiled in** lives in [`OtelZoneConfig`](/reference/configuration):
  the service name, the endpoint, the floor, the redactor, the spool.
- **What has to be read off the running device** — the installed artifact's
  version and build, the phone's model, the OS — is an argument to
  [`start()`](/reference/configuration#start-arguments), because none of it
  can be known until the Flutter binding exists.

## Where the defaults come from

Every default is the value the Vaam Store mobile app ships, and a caller that
names only `serviceName` and `endpoint` gets that behaviour. The reasoning for
each is in the doc comment next to it in
[`lib/src/config.dart`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/lib/src/config.dart),
and summarised on the [configuration page](/reference/configuration).
