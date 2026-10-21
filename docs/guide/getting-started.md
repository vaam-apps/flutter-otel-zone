# Getting started

## Requirements

From the package's own manifests:

| What               | Minimum                                               |
| ------------------ | ----------------------------------------------------- |
| Dart SDK           | `>=3.8.0 <4.0.0`                                      |
| Flutter            | `>=3.24.0`                                            |
| Android            | `minSdk = 24` (the OS exit records need API 30+)      |
| iOS                | 13.0 (MetricKit diagnostics need iOS 14+)             |
| Web, desktop       | Dart-level capture only; see [Web and desktop][webdt] |
| OpenTelemetry SDK  | `dartastic_opentelemetry: ^1.1.0-beta.17`             |
| Logger             | `talker: ^5.1.20`                                     |
| Riverpod (types)   | `riverpod: ^3.0.0`                                    |
| Navigator observer | `otel_go_router: ^0.3.1` (go_router 17 and 18)        |

[webdt]: /platforms/web-desktop

`otel_zone` is a Flutter **plugin**, not a plain package: crash capture needs
native code, registered on Android (`com.vaam.otel_zone.OtelZonePlugin`) and
iOS (`OtelZonePlugin`).

## Install

The package is not on pub.dev (`publish_to: 'none'`). Depend on it from Git,
pinned to a commit — not a branch:

```yaml
dependencies:
  otel_zone:
    git:
      url: https://github.com/vaam-apps/flutter-otel-zone.git
      ref: <a commit sha>
```

Releases are tagged `vX.Y.Z` by release-please, so the commit a release tag
points at is a natural choice for `ref`. What changed between releases is in
the [changelog](https://github.com/vaam-apps/flutter-otel-zone/blob/main/CHANGELOG.md).

::: tip Riverpod, not flutter_riverpod
The package depends on the core `riverpod` package for the `ProviderObserver`
type alone. An app on `flutter_riverpod` or `hooks_riverpod` already has it;
an app on neither is not asked to take them.
:::

## The minimal wiring

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

`Env`, `PackageInfo` (from `package_info_plus`) and `deviceResourceAttributes()`
are the app's own: wherever its build configuration and device information
come from. The order is the part that matters:

1. **The `OtelZone` is built at the top level.** Constructing it starts
   nothing and reaches no network, but its `talker` exists from that moment,
   so anything logged before `start()` — including `start()`'s own failure —
   is recorded.
2. **The guarded zone opens**, and `WidgetsFlutterBinding.ensureInitialized()`
   and `runApp` both run inside it.
3. **`start()` runs** with what only the running device can say: the
   installed artifact's version and build, and the resource attributes. It
   never throws.

::: warning serviceVersion must not be empty
`OTel.initialize` throws `ArgumentError` on an empty version, and `start()`'s
own `catch` turns that into "telemetry is off" for the whole process. Read it
off the installed artifact — never hardcode it, or every build ever shipped
reports the same identity.
:::

## Attach the observers

Wherever the app already has an observer slot:

```dart
ProviderScope(
  observers: [
    TalkerRiverpodObserver(talker: observability.talker),
    ?observability.riverpodObserver(),
  ],
  child: const MyApp(),
)

GoRouter(
  observers: [TalkerRouteObserver(observability.talker), ?observability.routeObserver()],
  routes: [...],
)
```

`TalkerRiverpodObserver` and `TalkerRouteObserver` are Talker's own loggers,
from the app's dependencies; they put Riverpod transitions and route changes
on the one `Talker`. `riverpodObserver()` and `routeObserver()` are the
OpenTelemetry span observers. Both return `null` when the SDK is not up, which
is why they are spread null-aware (`?`) rather than listed plainly.

Neither span observer records what the app's data looks like unless asked:
`riverpodObserver()` leaves out provider values (`recordValues`), family
arguments and mutation keys (`recordArguments`), and `routeObserver()` leaves
out route arguments (`recordArguments`). See
[What reaches the collector](/reference/telemetry#spans-from-the-observers).

## Guard your own instrumentation

Around anything that emits a span of its own:

```dart
observability.safely(() => recordConnectivityResults(results));
```

`safely` runs its callback only when the SDK is up, and never lets it throw.
[Telemetry never blocks the app](/concepts/never-blocks) explains why that is
load-bearing rather than defensive.

## Report what you catch yourself

```dart
try {
  await placeOrder();
} on Object catch (error, stackTrace) {
  observability.reportError(error, stackTrace, context: 'placeOrder');
}
```

`reportError` is the same function the zone's handlers call — it hands the
error to `talker.handle` — so a caught error and an uncaught one travel the
same path.

## Check it is working

On a successful `start()` the talker logs one line, at `warning` so that it
clears the shipped floor:

```text
OpenTelemetry: exporting to https://otel.example.com as my-app 1.2.3 build 48 (production), records at warning and above
```

It grows `, recovered N native crashes` when the previous run died natively,
`, replayed N spooled batches` when a [spool](/guide/spool) is configured,
and — when the configured export level was a typo — says what was written and
what it fell back to. A build that cannot reach its collector logs instead:

```text
OpenTelemetry did not start (<endpoint>); logging locally only.
```

and carries on with local logging. `observability.isReady` reports which of
the two happened.

## Next

- [Example walkthrough](/guide/example) — the same wiring, running.
- [Configuration](/reference/configuration) — every option and its default.
- [Scrubbing with redact](/guide/redaction) — before anything leaves a real
  user's phone.
