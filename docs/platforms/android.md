# Android

The Android side lives in
[`android/src/main/kotlin/com/vaam/otel_zone`](https://github.com/vaam-apps/flutter-otel-zone/tree/main/android/src/main/kotlin/com/vaam/otel_zone)
(Kotlin, package `com.vaam.otel_zone`, `minSdk = 24`, `compileSdk = 36`,
Java/JVM target 17). It adds two libraries to the app:
`kotlinx-coroutines-android` (the Pigeon handler's suspend functions) and
`androidx.startup:startup-runtime`.

Two crash sources are live, and they are joined so a crash is one record.

## JVM crashes

A chained `Thread.setDefaultUncaughtExceptionHandler`, installed through
**androidx.startup before `Application.onCreate`**, writes one JSON report per
uncaught exception into `noBackupFilesDir/otel_zone/crashes`. The app writes
no line of code for it, and a crash during start-up is still captured.

The library's manifest merges its initializer into androidx.startup's own
`InitializationProvider` (authority `${applicationId}.androidx-startup`,
`tools:node="merge"`), because androidx.lifecycle declares the same provider
and two declarations with different authorities would be a manifest-merger
error.

The handler reads `versionName` and `longVersionCode` once at start-up and
holds them in memory, so it writes them into the report without asking the
package manager while the process is dying.

## The OS's own record (API 30+)

`getHistoricalProcessExitReasons` returns the same ring buffer on every launch
and cannot be cleared, so records are deduplicated by a watermark persisted in
`noBackupFilesDir/otel_zone`. It moves only in `acknowledge`, to the newest
acknowledged record.

| Exit reason                  | `device.crash.kind` | What the record carries                                                       |
| ---------------------------- | ------------------- | ----------------------------------------------------------------------------- |
| `REASON_CRASH_NATIVE`        | `native`            | the signal; on API 31+ the crashing thread's frames from the tombstone        |
| `REASON_ANR`                 | `anr`               | the ANR trace when the OS has one                                             |
| `REASON_CRASH`               | `jvm`               | merged with the JVM handler's report of the same crash                        |
| `REASON_SIGNALED`            | `signal`            | the signal name; a SIGKILL is flagged when low-memory reports are unsupported |
| low memory and other reasons | `signal`            | the reason's name                                                             |

`EXIT_SELF`, `USER_REQUESTED`, `USER_STOPPED`, `PACKAGE_UPDATED`,
`PACKAGE_STATE_CHANGE` and `PERMISSION_CHANGE` — the deliberate stops — are
skipped. Every record also carries `exit.reason`, `exit.status`,
`exit.importance` and `process.pid`. **Below API 30 this source contributes
nothing**, and only JVM crashes are captured.

### One crash, one record

A `REASON_CRASH` exit record and the JVM report for the same crash (same pid,
timestamps within 30 s) are merged: the JVM report's stack trace, the OS
record's id and session.

## Sessions

Each process run tags itself with a random session id through
`setProcessStateSummary`, so the next launch's exit record says which run it
ended (`session.id`).

## The process state summary

The OS keeps up to 128 bytes per process and hands them back with the exit
record. It is the only place the crashed build and screen survive a native
death, so the summary is a compact, length-prefixed format that starts with a
marker byte:

```text
0x01 | len | session id | len | versionName | len | buildId
0x02 | len | session id | len | versionName | len | buildId | len | screen
```

Each `len` is one byte and each field is UTF-8; a field that is not known is
written with length 0.

The session is never dropped. When the rest do not fit, the screen goes
first, then the version, then the build — each dropped whole, never
truncated. A summary with a screen starts with `0x02`; one without starts with
`0x01`, which is byte for byte what 0.6.0 wrote. A summary from before 0.6.0
(the bare session id) decodes to a session with no version and no build, and a
0.6.0 summary decodes with no screen. A build older than 0.7.0 cannot read a
`0x02` summary, so the exit record it came from loses its session tag; the
crash itself is still reported.

Nothing is written to disk for the summary.

## Which build crashed

- **JVM crashes** carry the `versionName` and `longVersionCode` the handler
  read at start-up.
- **Exit records** (native crashes, ANRs, signals) get them from the crashed
  process's own process state summary.

Either is omitted when unknown, never filled in with the current build. See
[Which build crashed](/guide/native-crashes#which-build-crashed).

## The screen

`setCrashScreen` is one call to the OS (`setProcessStateSummary`) per change.
The OS may refuse it under rapid navigation; the next change tries again. A
JVM crash gets the screen from memory, written by the handler; a native crash,
ANR, signal or low-memory kill (API 30+) gets it from the summary. Below API
30 only JVM crashes carry one. See [Which screen it died on](/guide/crash-screen).

## What is stored on the device

- One JSON report per uncaught JVM exception in
  `noBackupFilesDir/otel_zone/crashes` — class, raw message, raw stack trace,
  thread name, pid, session id, screen. At most 16 are kept, and each is
  deleted when its report is acknowledged.
- The exit-record watermark, in `noBackupFilesDir/otel_zone`.

`noBackupFilesDir` is app-private and excluded from Auto Backup.

## Tests

The Kotlin side has JVM unit tests in
[`android/src/test`](https://github.com/vaam-apps/flutter-otel-zone/tree/main/android/src/test/kotlin/com/vaam/otel_zone),
including a tombstone fixture decoded against a subset of the tombstone
protobuf. CI runs them through the example's Gradle project:

```bash
cd example && flutter pub get && flutter create --platforms=android . && cd android
./gradlew :otel_zone:testDebugUnitTest --console=plain
```

End-to-end capture on an emulator is the [crash harness](/development/crash-harness).
