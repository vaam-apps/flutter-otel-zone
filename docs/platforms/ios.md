# iOS

The iOS side lives in
[`ios/otel_zone/Sources/otel_zone`](https://github.com/vaam-apps/flutter-otel-zone/tree/main/ios/otel_zone/Sources/otel_zone)
(Swift, iOS 13.0 minimum). It ships both a CocoaPods podspec
(`ios/otel_zone.podspec`) and a Swift package (`ios/otel_zone/Package.swift`),
and links the MetricKit system framework.

Two sources feed `pending()`, both started in `register(with:)`, both stored
under `Application Support/otel_zone/` (excluded from backup) — and neither is
a signal handler.

## MetricKit (iOS 14+)

An `MXMetricManagerSubscriber` writes each `MXDiagnosticPayload`'s JSON to
`diagnostics/` the moment it arrives, because it can arrive before Dart is
running and is never delivered twice. `pending()` maps its crash diagnostics
to `signal` reports (or `nsexception`, when iOS 17 names the exception) and
its hang diagnostics to `hang` reports, each with the crashing thread's frames
as binary UUID plus offset. **Nothing is symbolicated on the device.**

MetricKit is not delivered on a simulator or in a debug build, and a real
crash's diagnostic arrives up to a day later, on a later launch.

## Uncaught `NSException` (all supported iOS)

A chained `NSSetUncaughtExceptionHandler` writes the name, reason and
`callStackSymbols` to `exceptions/` and then calls the handler that was
installed before it, so a crash looks exactly as it did without this package.
It exists because MetricKit only carries the exception's reason from iOS 17.

## One crash, one record

One crash can be in both. `pending()` merges an exception report whose time
falls inside a MetricKit payload's window (plus a minute of slack), and whose
diagnostic is `SIGABRT` or already names an exception, into **one**
`nsexception` record: the exception's reason and throw-site stack, with
MetricKit's crashing thread attached. When only one side has arrived, that
side is returned alone.

The exception report always exists first, so it is usually exported before
MetricKit's diagnostic of the same crash turns up. Acknowledging an exception
report on its own therefore leaves a small entry (id, name, time; 32 at most,
forgotten after a week) in `acknowledged-exceptions.json`. A MetricKit crash
that matches one by the same rule is still returned — its frames carry the
symbolicatable binary UUIDs — but tagged `otel_zone.duplicate_of` (the
exception report's id) and `otel_zone.late_metrickit`, so a backend can
collapse the pair. The merge rule is documented on `NativeCrashRepository` and
tested there.

## Which build crashed

- **`NSException` reports** get `CFBundleShortVersionString` and
  `CFBundleVersion` from the handler, read when it is installed.
- **MetricKit** diagnostics already carry `appVersion` and `appBuildVersion`;
  they are mapped to the same two attributes,
  `otel_zone.crashed.service.version` and `otel_zone.crashed.app.build_id`.
  (The old `metrickit.app_version` and `metrickit.app_build_version` copies
  are gone: one fact under two names is how the two drift apart.)
- When the two merge into one record, the exception report's build wins,
  because the crashing process wrote it itself.

## The screen of a MetricKit crash

A MetricKit crash names only a pid and a time window. So each run keeps one
small JSON file — its pid, its launch time and its last screen — in
`screens/`, written at launch and replaced atomically on each
`setCrashScreen` change. Because it is written at launch, before Dart has
named any screen, a run that died before it did still leaves one, and an older
run that had the same pid cannot be taken for it.

A crash takes the screen of the **one** run with its pid whose launch falls in
the payload's window, from a day before it. Two runs with one pid, or none,
mean no screen. This needs iOS 17 or later, where the payload carries the pid.
An `NSException` report carries its own screen, which wins when the two are
merged. A hang never carries a screen. At most 64 run files are kept, a run
older than seven days is removed, and so is a half-written file a killed run
left behind.

::: info Looking ahead
iOS 27's own MetricKit state reporting (`StateReportingDomain`) is the
long-term replacement for those files. It needs the Xcode 27 SDK, so it is not
built here, and it is a possible follow-up. The pid in the payload's metadata
(`MXMetaData`) is deprecated from iOS 27.2, which is the other reason to plan
for it.
:::

## What is stored on the device

All under `Application Support/otel_zone/`, marked `isExcludedFromBackup`
(best effort: if the flag cannot be set the directory is backed up):

| Directory or file              | What it holds                                                         |
| ------------------------------ | --------------------------------------------------------------------- |
| `diagnostics/`                 | each MetricKit payload's JSON, verbatim, saved before it is parsed    |
| `exceptions/`                  | each uncaught `NSException`: name, reason, `callStackSymbols`, screen |
| `acknowledged-exceptions.json` | the ledger of acknowledged exception reports (id, name, time)         |
| `screens/`                     | one file per run: pid, launch time, last screen                       |

A report's file is deleted when it is acknowledged, and at most 16 of each
kind are kept. The raw text in these files is never redacted — see
[What the platforms store before Dart runs](/guide/native-crashes#what-the-platforms-store-before-dart-runs).

## Privacy manifest

The plugin carries a `PrivacyInfo.xcprivacy` template, but it is not wired up:
the podspec's `resource_bundles` line and the Swift package's `.process`
resource are both commented out.

## Tests

The Flutter-free half of the iOS code (`Sources/otel_zone/Crash`: the
MetricKit mapper, the merge rule, the stores) is unit-tested with `swift test`
against fixture payloads shaped like Apple's documented JSON:

```bash
cd ios/otel_zone/CrashTests && swift test
```

CI also builds the example for the simulator, which compiles the half that
links Flutter and MetricKit. The one path a simulator can exercise end to end
— an uncaught `NSException` — has its own host-driven
[crash harness](/development/crash-harness#ios-what-a-simulator-can-and-cannot-show),
and the rest has a manual runbook.
