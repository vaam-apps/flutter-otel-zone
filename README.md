# otel_zone

One `Talker`, one OpenTelemetry SDK, and one guarded zone that funnels every
uncaught error in a Flutter app into both — with a severity floor so a phone
on a metered connection is not billed for telemetry nobody reads.

Extracted from the Vaam Store mobile app, where all of it was measured
against a real collector and a real prepaid network in Cameroon. Every
default in this package is the value that app ships, and the reasoning for
each is in the doc comment next to it rather than here.

## What it is

Four things that are only correct together:

- **The zone** — `runGuarded` wires all four of Flutter's uncaught-error
  channels — `FlutterError.onError`, `PlatformDispatcher.onError`, the zone's
  own handler and `Isolate.addErrorListener` — to one reporting function. Each
  has a different default and some swallow silently, so anything less than all
  four means a class of crash never reaches the logs.
- **The sink** — One `Talker`. Riverpod transitions, route changes, classified
  failures and uncaught errors all land on it, so there is no second reporting
  path to keep in sync.
- **The floor** — `OtelBridge` decides which of those records are worth the
  radio, and attaches the withheld ones to a fault as breadcrumbs.
- **The guard** — `safely()`, and the lazy observers. Every dartastic entry
  point resolves its tracer eagerly and throws when the SDK never started, so
  instrumentation that is not guarded takes features down with it.

## Install

```yaml
dependencies:
  otel_zone:
    git:
      url: https://github.com/vaam-apps/flutter-otel-zone.git
      ref: <a commit sha>
```

Pinned to a commit, not a branch. This package is not on pub.dev.

## Use

```dart
import 'package:flutter/material.dart';
import 'package:otel_zone/otel_zone.dart';

// Built at the top level, so anything that logs before start-up finishes —
// including start-up's own failure — has a sink to land on.
final OtelZone observability = OtelZone(
  OtelZoneConfig(
    serviceName: 'my-app',
    endpoint: Env.otelEndpoint,
    deploymentEnvironmentName: Env.deploymentEnvironment,
    exportFloor: ExportFloor.parse(Env.otelLogExportLevel),
  ),
);

Future<void> main() => observability.runGuarded(() async {
  // Inside the zone, not before it: Flutter records the zone that created
  // the binding and warns if `runApp` arrives from a different one.
  WidgetsFlutterBinding.ensureInitialized();

  final build = await PackageInfo.fromPlatform();
  await observability.start(
    serviceVersion: build.version,
    buildId: build.buildNumber,
    resourceAttributes: await deviceResourceAttributes(),
  );

  runApp(const MyApp());
});
```

Then, wherever the app already had an observer slot:

```dart
ProviderScope(
  observers: [
    TalkerRiverpodObserver(talker: observability.talker),
    ?observability.riverpodObserver(),
  ],
  ...
)

GoRouter(
  observers: [TalkerRouteObserver(observability.talker), ?observability.routeObserver()],
  ...
)
```

Both return `null` when the SDK is not up, which is why they are spread
null-aware rather than listed plainly.

And around anything that emits a span of its own:

```dart
observability.safely(() => recordConnectivityResults(results));
```

`example/lib/main.dart` is the whole thing in one file.

## What leaves the device, and what stays

Everything is recorded locally. Only records at or above
`OtelZoneConfig.exportFloor` are exported, plus — for an `error` or
`critical` only — one extra record carrying the last
`breadcrumbCount` entries that were withheld.

The floor exists because the alternative was measured. 7,715 records off one
set of release builds: 3,020 `riverpod-add`, 2,773 `riverpod-update`, 1,498
`route`, 261 `exception`, 158 `info`. **96.5% chatter**, one record per
provider initialisation, one per provider state change, one per navigation —
a cost that scales with how much someone *uses the app*, on a prepaid metered
connection.

Dropping the observers in release is the wrong fix: those records are exactly
what answers "which screen was this, and what had just changed". So they stay
attached in every build, stay in `talker.history`, and ride along with a
fault instead of going one at a time.

`ExportFloor.parse` falls back to `warning` when it cannot read the value it
was given, and keeps what was written so `start()` can say so out loud. The
direction of that fallback is deliberate: a misconfigured build that defaults
to *loud* bills its users for the mistake.

## Scrubbing what leaves the device

Supply one `redact` function and every string an exported record carries is
scrubbed by it: the message, the title, the error/exception text, the stack
trace, and each breadcrumb line. It runs *before* truncation and before the
record reaches the exporter, so nothing unredacted can be persisted or sent.

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

It lives here, at the one point every record crosses, rather than at each call
site: a rule bolted on per call site is a rule one call site eventually misses.

What it does **not** touch:

- **Resource attributes.** They are set by the app at `start()` and are not
  records; give them already-scrubbed values.
- **`talker.history`.** The redacted copy is what goes to the sink; the
  original record stays on the device, where it is not a disclosure.

A `redact` that throws drops the record instead of letting it through
unredacted — it fails closed, and it never throws into the app.

## Faults recorded offline

A batch the collector refuses is retried in memory and then dropped. Point
`spoolDirectory` at app-private storage and it is written to disk instead, and
replayed on the next `start()`:

```dart
final OtelZone observability = OtelZone(
  OtelZoneConfig(
    serviceName: 'my-app',
    endpoint: Env.otelEndpoint,
    // `getApplicationSupportDirectory` from `path_provider`, read after the
    // binding exists.
    spoolDirectory: getApplicationSupportDirectory,
  ),
);

await observability.start(serviceVersion: '1.2.3');
```

- **Write-ahead.** The exporter is tried first, so a healthy collector never
  pays for a disk write. Only a refused batch is spooled, and it is written to
  a temp file and renamed, so a process death leaves a whole batch or none.
- **Deleted on acceptance.** A file is removed only once the collector has
  taken it. `start()` replays oldest first and stops at the first refusal,
  keeping that file and the rest for the launch after.
- **Bounded.** `spoolMaxBatches` (default 32) evicts the oldest file past the
  cap and `spoolMaxAge` (default 7 days) drops files past their age; a phone
  that never reconnects must not fill its disk with telemetry nobody collected.
- **Failure is not fatal.** An unwritable directory falls back to the plain
  exporter's own result, and nothing is thrown into the app.
- **The original resource rides along**, so a crash stays filed under the
  version that crashed rather than whichever one was running when it was
  finally delivered. Replayed records carry `otel_zone.replayed = true`.

## Telemetry never blocks the app

Two rules, and both are load-bearing rather than defensive dressing.

**`start()` never throws.** A phone with no route to the collector — the
normal case on a bad connection, and the case on every developer machine
without a collector running — gets one warning on the `Talker` and an app
that runs with local logging only.

**Instrumentation is never in the functional path.** `OTel.tracerProvider()`
and `Context.current.span` both throw `StateError: OTel.initialize() must be
called first` when the SDK is absent. Unguarded, that propagates out of
whatever callback it was in. In the app this came from it took down a
connectivity subscription — leaving the app permanently unable to notice the
network returning — and silently stopped a secure-storage write. `safely()`
and the two lazy observers are what stop a failed span costing a feature.

## Metrics are off, on purpose

`OtelZoneConfig.enableMetrics` defaults to `false` and flipping it is a
product decision, not a tidy-up.

`PeriodicExportingMetricReader` is a bare `Timer.periodic` on the spec's 60s
default. It skips an export only while *no instrument exists at all*, and a
cumulative counter or a gauge is required to keep reporting its last value —
so the first instrument anyone registers turns this into a 60s heartbeat for
the life of the process. Traces and logs reach the radio only when the user
did something. The timer also keeps firing when the collector is unreachable,
so the battery is spent whether or not anything arrives.

Little is given up. Call rate, error rate and latency per operation are
already on the wire as spans; deriving them belongs in the collector's
`spanmetrics` connector, which costs the device nothing. Turn metrics on only
for something a span cannot express — battery level, offline-queue depth —
and then with an explicit long interval and a named list of instruments.

## Two dependency notes

**`otel_go_router` declares `go_router: ^17.0.0`, and the bound is spurious.**
That package's only go_router mentions are in doc comments —
`OTelGoRouterObserver extends NavigatorObserver`, which is a
`package:flutter/widgets.dart` class — and it never imports go_router at all.
`routeObserver()` therefore works with any router, or none. An app on
go_router 18 needs a `dependency_overrides:` entry naming **go_router** (the
constrained package, not the one doing the constraining) until a release
carrying [Dartastic/otel_go_router#2](https://github.com/Dartastic/otel_go_router/pull/2)
is out.

**`riverpod`, not `flutter_riverpod` or `hooks_riverpod`.** Only the
`ProviderObserver` type is needed. An app on either of the other two already
has this; an app on neither is not asked to take them.

## Testing against it

`RecordingTalkerObserver` is exported for this. `OTelTalkerObserver` cannot be
observed at all — it resolves `OTel.loggerProvider()` and throws without a
live SDK, and `OtelBridge` swallows that, so "exported" and "dropped" look
identical from outside. Pass a recording sink and the floor, the breadcrumbs
and the start-up summary all become assertable with no SDK and no collector:

```dart
final sink = RecordingTalkerObserver();
final zone = OtelZone(config, sink: sink);
```

`flutter test` in this repository is the whole contract above — the floor, the
breadcrumbs, the redaction and the start-up summary — and needs no device.

## Licence

MIT. See [LICENSE](LICENSE).
