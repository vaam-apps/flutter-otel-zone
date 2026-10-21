# API overview

Everything is imported from one library:

```dart
import 'package:otel_zone/otel_zone.dart';
```

Start at `OtelZone`. `OtelZoneConfig` is everything a build knows about its
own telemetry before it runs; `OtelBridge` is what decides which records leave
the device.

::: info No hosted API docs
`otel_zone` is not published to pub.dev (`publish_to: 'none'`), so there is
no pub.dev API page. Every public member has a doc comment in
[`lib/src`](https://github.com/vaam-apps/flutter-otel-zone/tree/main/lib/src);
`dart doc` in a checkout renders them into `doc/api/`, which is git-ignored.
:::

## The entry point

### `OtelZone`

One `Talker`, one OpenTelemetry SDK, and one guarded zone. Build it once,
before `runApp`, and hold it where the whole app can reach it.
[Source](https://github.com/vaam-apps/flutter-otel-zone/blob/main/lib/src/otel-zone.dart).

| Member                                                                 | What it does                                                                       |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `OtelZone(config, {talker, sink, nativeCrashSource, crashScreenSink})` | creates the talker and the bridge; starts nothing                                  |
| `config`                                                               | the `OtelZoneConfig` this build was configured with                                |
| `talker`                                                               | the one log and error sink; exists from construction                               |
| `bridge`                                                               | the `OtelBridge` in front of the OTel logs pipeline                                |
| `isReady`                                                              | whether the SDK came up; `false` before `start()` and after a failed one           |
| `runGuarded(body)`                                                     | runs `body` in a zone with all four uncaught-error channels wired to `reportError` |
| `start({serviceVersion, buildId, resourceAttributes})`                 | brings up the SDK, drains native crashes, replays the spool; never throws          |
| `reportError(error, stackTrace, {context})`                            | the single reporting entry point for an error the app caught itself                |
| `safely(emit)`                                                         | runs `emit` only if the SDK is up, and never lets it throw                         |
| `riverpodObserver({recordValues, recordArguments})`                    | the OTel `ProviderObserver`, or `null` when the SDK is not up                      |
| `routeObserver({recordArguments})`                                     | the OTel `NavigatorObserver`, or `null` when the SDK is not up                     |
| `setEndUser(id)` / `endUserId`                                         | stamps `enduser.id` on spans and records from now on; `null` stops it              |
| `setCrashScreen(screen)` / `crashScreen`                               | names the screen a native crash would report as `otel_zone.crashed.screen`         |
| `startupSummary(serviceVersion, buildId, {replayed, nativeCrashes})`   | the one line `start()` logs on success                                             |

Guides: [Getting started](/guide/getting-started),
[The guarded zone](/concepts/guarded-zone),
[Linking to an account](/guide/end-user),
[Which screen it died on](/guide/crash-screen).

## Configuration

| Symbol           | Kind     | What it is                                                                        |
| ---------------- | -------- | --------------------------------------------------------------------------------- |
| `OtelZoneConfig` | class    | everything about a build's telemetry known before it runs — [all options][config] |
| `Redactor`       | typedef  | `String Function(String input)`, the scrubber — [guide][redact]                   |
| `ExportFloor`    | class    | the severity floor, plus what an unparseable value said — [concept][floor]        |
| `parseLogLevel`  | function | the `LogLevel` a string names, case- and whitespace-insensitively, or `null`      |

[config]: /reference/configuration
[redact]: /guide/redaction
[floor]: /concepts/export-floor

`ExportFloor` members: `ExportFloor.parse(name, {fallback})`,
`ExportFloor.of(level)`, `ExportFloor.defaultLevel` (`warning`), `level`,
`unrecognised`, `carries(level)`, `withholdsBreadcrumbs`,
`ExportFloor.priorityOf(level)`.

## Log pipeline building blocks

| Symbol                      | What it is                                                                                                  |
| --------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `OtelBridge`                | the `TalkerObserver` that applies the floor, emits breadcrumbs, redacts, and forwards only once `ready`     |
| `SpoolingLogRecordExporter` | a `LogRecordExporter` decorator that writes each batch to disk before sending, and `replay()`s what is left |
| `RedactingSpanExporter`     | a `SpanExporter` that hands its delegate a scrubbed, read-only view of every span                           |

`OtelZone` builds all three for you. They are public so they can be tested,
and composed by an app that wires its own SDK.

Notable members:

- `OtelBridge({floor, history, loggerName, breadcrumbCount, breadcrumbLineLimit, redact, sink})`,
  `ready`, `carries(level)`.
- `SpoolingLogRecordExporter({delegate, directory, maxBatches, maxAge, maxBytes, maxAttempts, onWarning})`,
  `export`, `enqueue`, `replay`, `handledReports`, `forgetHandled`, and
  `SpoolingLogRecordExporter.replayedAttribute` (`otel_zone.replayed`).
- `RedactingSpanExporter({delegate, redact, onDropped})`.

## Native crashes

| Symbol                    | What it is                                                                                |
| ------------------------- | ----------------------------------------------------------------------------------------- |
| `NativeCrashSource`       | interface: `pending()` and `acknowledge(ids)` — the seam the drain is tested through      |
| `PigeonNativeCrashSource` | the default `NativeCrashSource`, over the plugin's Pigeon channel                         |
| `NativeCrashDrain`        | turns the previous run's deaths into FATAL records, makes them durable, acknowledges them |
| `NativeCrashReport`       | one death, as the platform reports it (generated)                                         |
| `NativeCrashApi`          | the generated Pigeon client for `pending` and `acknowledge`                               |

`NativeCrashDrain` constants: `eventCrash` (`device.crash`), `eventAnr`
(`device.anr`), `crashedServiceVersion`, `crashedBuildId`, `crashedScreen`.
See [Native crashes](/guide/native-crashes) and
[the Pigeon channel](/platforms/#the-pigeon-channel).

## The crash screen

| Symbol                     | What it is                                                                            |
| -------------------------- | ------------------------------------------------------------------------------------- |
| `CrashScreenSink`          | interface: where `setCrashScreen`'s value goes                                        |
| `PigeonCrashScreenSink`    | the default sink, over the plugin's Pigeon channel                                    |
| `RecordingCrashScreenSink` | a test fake that keeps every screen in `screens`                                      |
| `CrashContextApi`          | the generated Pigeon client for `setCrashScreen`                                      |
| `normalizeCrashScreen`     | trims a screen, or returns `null` if it is empty, too long or has a control character |
| `maxCrashScreenBytes`      | `64`, the longest screen kept, in UTF-8 bytes                                         |

## Testing

| Symbol                     | What it is                                                                 |
| -------------------------- | -------------------------------------------------------------------------- |
| `RecordingTalkerObserver`  | a `TalkerObserver` that keeps what it was given in `records`, oldest first |
| `RecordingCrashScreenSink` | see above                                                                  |

See [Testing against it](/guide/testing).
