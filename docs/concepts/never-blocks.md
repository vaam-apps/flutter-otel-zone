# Telemetry never blocks the app

Two rules, and both are load-bearing rather than defensive dressing.

## `start()` never throws

A phone with no route to the collector — the normal case on a bad connection,
and the case on every developer machine without a collector running — must
not be a phone that cannot open the app. Any failure inside `start()` becomes
one warning on the talker and an app that runs with local logging only:

```text
OpenTelemetry did not start (<endpoint>); logging locally only.
```

It is a warning, not an error: nothing the user does is affected, and an
unreachable collector is an expected state, not a fault.

`start()` is awaited before `runApp`, so nothing in it waits on the network
either. A native crash recovered from the last run is written to the spool
and acknowledged; its delivery, like the spool's replay, carries on in the
background. A crash report on a bad connection never delays the first frame.

## Instrumentation is never in the functional path

Every dartastic instrumentation entry point resolves its tracer or context
eagerly. `OTel.tracerProvider()` and `Context.current.span` both throw
`StateError: OTel.initialize() must be called first` when the SDK is absent,
and unguarded, that propagates out of whatever callback it was in. In the app
this package came from it took down a connectivity subscription — leaving the
app permanently unable to notice the network returning — and silently stopped
a secure-storage write.

### `safely()`

```dart
observability.safely(() => recordConnectivityResults(results));
```

Runs the callback only if OpenTelemetry is up, and never lets it throw. A
telemetry call that fails costs a span, never a feature. A failure is not
reported through the talker: the talker's own observer feeds the same
pipeline, and reporting a telemetry failure through telemetry is how you get
a loop.

### The lazy observers

`riverpodObserver()` and `routeObserver()` are built only when the SDK is up,
and return `null` otherwise, because each captures a `Tracer` _at
construction_ via `OTel.tracerProvider()`. Constructing one eagerly would turn
"no collector on this network" into "the app does not start". If building one
fails anyway, it is one warning on the talker and `null`.

```dart
observers: [TalkerRiverpodObserver(talker: observability.talker), ?observability.riverpodObserver()],
```

## Flushing before the OS kills the process

The batch processor holds records in memory for its scheduled delay. So the
first `start()` registers one `AppLifecycleListener` that flushes the logs
pipeline when the app is **hidden**, **paused** or **detached** — the moments
the OS may kill a backgrounded process with records still queued. On Android
and iOS `hidden` comes just before `paused`, so those flush twice, and the
second takes only what the first has not. The web engine never reports
`paused`, so on the web `hidden` is the state that flushes a tab (switching to
another tab, minimising the window, or closing it); a flush still in flight
when the page unloads can be cut short by the browser.

The flush is fire-and-forget, inside `safely`. Without a Flutter binding there
is nothing to attach the listener to, and that is never a reason `start()`
fails.

## Metrics are off, on purpose

[`enableMetrics`](/reference/configuration#enablemetrics) defaults to `false`,
and flipping it is a product decision, not a tidy-up.

Metrics are the only signal that costs a phone something when nothing
happens. `PeriodicExportingMetricReader` is a bare `Timer.periodic` on the
spec's 60 s default. It skips an export only while _no instrument exists at
all_, and a cumulative counter or a gauge is required to keep reporting its
last value — so the first instrument anyone registers turns it into a 60 s
heartbeat for the life of the process. Traces and logs reach the radio only
when the user did something. Every wake-up holds the cellular radio in its
high-power tail long after the bytes are gone, and the timer keeps firing when
the collector is unreachable, so the battery is spent whether or not anything
arrives.

Little is given up. Call rate, error rate and latency per operation are
already on the wire as spans; deriving them belongs in the collector's
`spanmetrics` connector, which costs the device nothing. Turn metrics on only
for something a span cannot express — battery level, offline-queue depth —
and then with an explicit long interval and a named list of instruments.
