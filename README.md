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

## Native crashes

A native crash kills the process before Dart can see it, so the platforms read
the OS's own record of the death — `ApplicationExitInfo` on Android, MetricKit
on iOS — and hand it to Dart over one Pigeon channel. `start()` drains it:

```text
pending() -> redact -> FATAL LogRecord -> spool -> acknowledge
```

- **FATAL, and not a breadcrumb.** A recovered crash is emitted straight onto
  the export path as a `Severity.FATAL` record with `event.name` of
  `device.crash` or `device.anr`; it does not go through `Talker` and is not
  gated by `exportFloor`. A record of the process dying is not something the
  live-app floor gets to drop.
- **Acknowledged only when durable.** The reports are acknowledged only after
  the exporter has accepted the batch, so an offline phone re-reads them on the
  next launch rather than dropping them. With `spoolDirectory` set they are on
  disk first; without it they go straight to the collector.
- **Redacted like everything else.** `redact` is applied to the message, the
  stack trace and the attributes, because a native stack is the densest PII the
  package ever handles. A redactor that throws drops the report rather than
  exporting it raw.
- **Web is a no-op**, and a platform read that fails is one warning on the
  talker, never a thrown error.

On Android both sources are live, and they are joined so a crash is one record:

- **JVM crashes** — a chained `Thread.setDefaultUncaughtExceptionHandler`,
  installed through androidx.startup before `Application.onCreate`, writes one
  JSON report per uncaught exception into `noBackupFilesDir/otel_zone/crashes`.
- **The OS's own record (API 30+)** — `getHistoricalProcessExitReasons` returns
  the same ring buffer on every launch and cannot be cleared, so records are
  deduplicated by a watermark persisted in `noBackupFilesDir/otel_zone`. It
  moves only in `acknowledge`, to the newest acknowledged record. Native crashes
  (with the crashing thread's frames from the tombstone on API 31+), ANRs,
  low-memory kills and other signals are reported once each. `EXIT_SELF`,
  `USER_REQUESTED` and the other deliberate stops (app update, permission
  change, user stop) are skipped. Below API 30 this source contributes nothing.
- **Sessions** — each process run tags itself with a random session id through
  `setProcessStateSummary`, so the next launch's exit record says which run it
  ended (`session.id`).
- **One crash, one record** — a `REASON_CRASH` exit record and the JVM report
  for the same crash (same pid, timestamps within 30 s) are merged: the JVM
  report's stack trace, the OS record's id and session.

On iOS two sources feed `pending()`, both started in `register(with:)`, both
stored under `Application Support/otel_zone/` (excluded from backup), and
neither a signal handler:

- **MetricKit** (iOS 14+). An `MXMetricManagerSubscriber` writes each
  `MXDiagnosticPayload`'s JSON to `diagnostics/` the moment it arrives, because
  it can arrive before Dart is running and is never delivered twice. `pending()`
  maps its crash diagnostics to `signal` (or `nsexception`, when iOS 17 names
  the exception) reports and its hang diagnostics to `hang` reports, each with
  the crashing thread's frames as binary UUID plus offset. Nothing is
  symbolicated on the device.
- **Uncaught `NSException`** (all supported iOS). A chained
  `NSSetUncaughtExceptionHandler` writes the name, reason and
  `callStackSymbols` to `exceptions/` and then calls the handler that was
  installed before it, so a crash looks exactly as it did without this package.
  It exists because MetricKit only carries the reason from iOS 17.

One crash can be in both, so `pending()` merges them: an exception report whose
time falls inside a MetricKit payload's window (plus a minute of slack), and
whose diagnostic is `SIGABRT` or already names an exception, becomes **one**
`nsexception` record with the exception's reason and throw-site stack and
MetricKit's crashing thread attached. When only one side has arrived — MetricKit
is not delivered on a simulator or a debug build — that side is returned alone.
The exception report always exists first, so it is usually exported before
MetricKit's diagnostic of the same crash turns up. Acknowledging an exception
report on its own therefore leaves a small entry (id, name, time; 32 at most,
forgotten after a week) in `acknowledged-exceptions.json`, and a MetricKit
crash that matches one by the same rule is still returned — its frames carry
the symbolicatable binary UUIDs — but tagged `otel_zone.duplicate_of` (the
exception report's id) and `otel_zone.late_metrickit`, so a backend can
collapse the pair. The merge rule is documented on `NativeCrashRepository` and
tested there.

The Flutter-free half of the iOS code is unit-tested with `swift test` from
`ios/otel_zone/CrashTests`, against fixture payloads shaped like Apple's
documented JSON. On both platforms `NativeCrashSource` is the seam the drain is
tested through.

### Crash harness

Native capture is the OS's behaviour, not ours, so it is proven by dying on
purpose. `example/` carries a **debug-only** way to do that, and host scripts
that crash it, relaunch it and read what the drain sent.

The harness has two doors that end in the same code. A method channel,
`otel_zone_example/crash`, takes `crash(kind)` and backs a small "Crash harness"
panel in the debug UI (there so a person can verify on a real device with no
tooling attached). And a launch request — an `otel_crash` intent extra on
Android, an `-otel_crash` launch argument on iOS — lets a host script trigger a
death from outside a process that is about to stop answering.

| Platform | Kind | What happens |
| --- | --- | --- |
| Android | `jvm` | an uncaught exception on the main thread |
| Android | `native` | `Process.sendSignal(myPid(), SIGSEGV)` (no JNI) |
| Android | `anr` | the main thread is held for 60 s |
| iOS | `nsexception` | an uncaught `NSException` |
| iOS | `signal` | `raise(SIGABRT)` |

**Debug only, and proved absent from release.** Android keeps the real
`CrashHarness` in `src/debug` and a refusing stand-in in `src/release` and
`src/profile`, so `MainActivity` is identical in every build type and a release
APK contains neither the channel name nor the crash code. iOS wraps it in
`#if DEBUG`; Flutter's Xcode template does not define `DEBUG` for the Runner
target, so `example/ios/Flutter/Debug.xcconfig` does. The Dart side returns
`false` without touching the channel outside `kDebugMode`. (Dart's AOT snapshot
still carries the channel-name string; with no native handler it is inert.)
`--release-refusal` (Android) and the `ios` job (iOS) check this rather than
assume it.

#### Android: host-driven, on an emulator

`integration_test` cannot survive its own process dying, so the driver is on the
host. For each kind, from a fresh install, `tool/android-crash-harness.dart`:
launches the app and waits for `start()` to finish; asks for the crash with
`adb shell am start --es otel_crash <kind>`; waits for the process to be gone;
relaunches and requires **exactly one** FATAL record of that kind to have
reached its own OTLP receiver (and the app's start-up line to say it recovered
one); then relaunches again and requires none. It reads the wire, not a marker
the app prints about itself.

```bash
cd example && flutter pub get && flutter create --platforms=android . && cd ..
dart run tool/android-crash-harness.dart --device emulator-5554
dart run tool/android-crash-harness.dart --device emulator-5554 --release-refusal
cd example && flutter test integration_test -d emulator-5554   # channel is present, refuses an unknown kind
```

`--kinds jvm,native` narrows it; `--retries` (default 1) re-runs a failed kind
from a fresh install. The receiver (`tool/otlp-log-sink.dart`) decodes OTLP by
hand and is unit-tested against the SDK's own encoder.

**The ANR needs two things a bare block does not give.** An ANR is declared
only when something is *waiting* on the blocked main thread, so the script sends
a tap 1.5 s after asking for the block; the OS declares the ANR 5 s after the
tap (about 7 s in all). And the OS shows an "isn't responding" dialog and keeps
the process alive until someone taps "Close app", so for the `anr` kind the
script sets `hide_error_dialogs`, which makes the OS kill the process itself
(recorded as `REASON_ANR`), and restores the previous value afterwards.

`.github/workflows/crash-harness.yml` runs all of it on API 30 and API 34
emulators on every pull request, push to `main`, nightly, and on demand.

#### iOS: what a simulator can and cannot show

MetricKit is not delivered on a simulator, so the signal and hang paths cannot
be triggered there. The uncaught-`NSException` path can: the plugin's handler
writes its JSON at the moment of the throw, so raise, relaunch, drain works
without MetricKit.

```bash
cd example && flutter pub get && flutter create --platforms=ios . && cd ..
dart run tool/ios-crash-harness.dart --device <booted simulator udid>
```

**Manual device verification** (not run in CI; a real-device farm is out of
scope):

1. Run the example from Xcode on a physical device, Debug configuration.
2. `nsexception`: tap "Crash: nsexception", relaunch the app. The start-up line
   says `recovered 1 native crash` and the collector shows a FATAL
   `device.crash` with `device.crash.kind = nsexception`, the exception's reason
   and its throw-site stack.
3. MetricKit: with the app running, choose Xcode's **Debug > Simulate MetricKit
   Payloads**. The subscriber writes the payload on arrival; stop and relaunch,
   and the drain reports the sample crash and hang diagnostics
   (`signal`/`nsexception` and `hang`), once each; a further launch reports none.
4. A real signal: tap "Crash: signal", relaunch, and wait. iOS delivers the real
   diagnostic up to a day later, on a later launch.

The channel is generated, not written by hand:

```bash
dart run pigeon --input pigeons/native_crash.dart && dart format .
```

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
