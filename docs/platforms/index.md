# Support and the Pigeon channel

`otel_zone` is a Flutter plugin registered on Android and iOS. The Dart half
runs everywhere Flutter does; the native half — crash capture — only where
there is a process for the OS to remember dying.

## What runs where

| Feature                                    | Android                   | iOS                            | Web                      | Desktop               |
| ------------------------------------------ | ------------------------- | ------------------------------ | ------------------------ | --------------------- |
| `runGuarded`: framework and zone errors    | yes                       | yes                            | yes                      | yes                   |
| `runGuarded`: `PlatformDispatcher.onError` | yes                       | yes                            | reaches the zone instead | yes                   |
| `runGuarded`: `Isolate.addErrorListener`   | yes                       | yes                            | not installed            | yes                   |
| Export floor, breadcrumbs, `redact`        | yes                       | yes                            | yes                      | yes                   |
| Flush when the app is hidden or paused     | yes                       | yes                            | on `hidden`              | as Flutter reports it |
| Native crash recovery                      | JVM; API 30+ exit records | MetricKit (14+), `NSException` | no-op                    | no-op                 |
| `setCrashScreen` reaches the platform      | yes                       | yes                            | kept, not sent           | kept, not sent        |

Details: [Android](./android), [iOS](./ios), [Web and desktop](./web-desktop).

## The Pigeon channel

Everything between Dart and the native code goes over one
[Pigeon](https://pub.dev/packages/pigeon) contract,
[`pigeons/native_crash.dart`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/pigeons/native_crash.dart).
It is generated, not written by hand, into three committed files:

| Output                                                           | Language |
| ---------------------------------------------------------------- | -------- |
| `lib/src/native-crash.g.dart`                                    | Dart     |
| `android/src/main/kotlin/com/vaam/otel_zone/NativeCrashApi.g.kt` | Kotlin   |
| `ios/otel_zone/Sources/otel_zone/NativeCrashApi.g.swift`         | Swift    |

`pigeon` is a dev dependency only: the output is committed, so building an
app does not need it. To regenerate after changing the contract:

```bash
dart run pigeon --input pigeons/native_crash.dart && dart format .
```

### `NativeCrashApi` — reading the previous run's deaths

| Method                          | What it does                                                                       |
| ------------------------------- | ---------------------------------------------------------------------------------- |
| `pending()`                     | every report the OS holds that has not been acknowledged yet, oldest first (async) |
| `acknowledge(List<String> ids)` | marks reports as delivered — called only once they are durable (async)             |

The OS's list cannot be cleared, so the platform side deduplicates by a
persisted watermark; Dart only ever sees reports that are new to it.

### `CrashContextApi` — naming the current screen

| Method                           | What it does                                                                                  |
| -------------------------------- | --------------------------------------------------------------------------------------------- |
| `setCrashScreen(String? screen)` | records the route pattern this process shows (`null` clears it), on a serial background queue |

### `NativeCrashReport` — one death

| Field             | Type                   | Meaning                                                                  |
| ----------------- | ---------------------- | ------------------------------------------------------------------------ |
| `id`              | `String`               | the platform's own id, opaque to Dart, stable across launches            |
| `kind`            | `String`               | `jvm`, `native`, `anr`, `nsexception`, `signal` or `hang`                |
| `timestampMicros` | `int`                  | when the process died, in microseconds since the Unix epoch              |
| `type`            | `String?`              | the signal name, the exception class, the exit reason                    |
| `message`         | `String?`              | the human-readable reason, where the platform keeps one                  |
| `stacktrace`      | `String?`              | the stack trace, symbolised as far as the OS got                         |
| `threads`         | `List<String>?`        | per-thread frames, for a crash whose stack is only meaningful per thread |
| `sessionId`       | `String?`              | the app session the death happened in                                    |
| `attributes`      | `Map<String, String>?` | anything else the platform knows, flattened                              |

`kind` is a string rather than an enum so that an unknown future value from a
newer OS arrives intact instead of failing the whole call.

On the Dart side, `NativeCrashSource` is the seam the drain depends on rather
than the generated client, and `PigeonNativeCrashSource` is its default
implementation. Likewise `CrashScreenSink` and `PigeonCrashScreenSink` for the
screen. Both are injection points — see [Testing](/guide/testing).
