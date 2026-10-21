# Native crashes

A native crash kills the process before Dart can see it, so the platforms read
the operating system's own record of the death — `ApplicationExitInfo` (plus a
JVM crash handler) on Android, MetricKit (plus an `NSException` handler) on
iOS — and hand it to Dart over one [Pigeon channel](/platforms/#the-pigeon-channel).
`start()` drains it:

```text
pending() -> redact -> FATAL LogRecord -> spool -> acknowledge -> return
```

`start()` returns once that local work is done; delivery carries on in the
background, so a crash report on a bad connection never delays the first
frame. The start-up line then says `recovered N native crashes`.

There is nothing to call. The native side installs itself — through
androidx.startup on Android, when the plugin registers on iOS — and `start()`
drains whenever the logs pipeline is on
([`enableLogs`](/reference/configuration#enablelogs)) and the app runs on
Android or iOS. The platform pages say what each source captures:
[Android](/platforms/android), [iOS](/platforms/ios).

## FATAL, and not a breadcrumb

A recovered crash is emitted straight onto the export path as a
`Severity.FATAL` record. It does not go through `Talker` and is not gated by
`exportFloor`: a record of the process dying is not something the live-app
floor gets to drop.

| Field                               | Value                                                         |
| ----------------------------------- | ------------------------------------------------------------- |
| severity                            | `FATAL` (`fatal`)                                             |
| `event.name`                        | `device.anr` for an ANR, `device.crash` for everything else   |
| `device.crash.kind`                 | `jvm`, `native`, `anr`, `nsexception`, `signal` or `hang`     |
| body                                | the message, else the type, else `Native crash`               |
| `exception.type`                    | the signal name, exception class or exit reason, when known   |
| `exception.message`                 | the reason, when the platform keeps one                       |
| `exception.stacktrace`              | the stack, as far as the OS symbolised it                     |
| `device.crash.threads`              | per-thread frames, one per line, when the crash has them      |
| `session.id`                        | the run the death happened in, where the platform tracks one  |
| `otel_zone.crashed.service.version` | the version that died — see [Which build crashed][build]      |
| `otel_zone.crashed.app.build_id`    | the build that died                                           |
| `otel_zone.crashed.screen`          | the screen it died on — see [Which screen it died on][screen] |
| timestamp                           | when the process died                                         |

[build]: #which-build-crashed
[screen]: /guide/crash-screen

Platform-specific attributes ride along too — for example
`otel_zone.duplicate_of` and `otel_zone.late_metrickit` on iOS. MetricKit
**hang** diagnostics are read, exported (kind `hang`) and stored like a crash,
though nothing died.

## The exported record is redacted

[`redact`](/guide/redaction) is applied to the type, the message, the stack
trace, the thread frames and every platform attribute, because a native stack
is the densest PII the package ever handles. A redactor that throws drops the
report rather than exporting it raw — and does not acknowledge it, so the
platform keeps it. That covers what leaves the phone; the platforms' own files
are [another matter](#what-the-platforms-store-before-dart-runs).

Recovered crash reports are not stamped with
[`enduser.id`](/guide/end-user): they describe the previous run.

## Acknowledged only when durable

- **With [`spoolDirectory`](/guide/spool)**, a report is acknowledged as soon
  as it is on disk, and the spool delivers it.
- **Without a spool** there is nowhere durable to put it, so it is sent in the
  background and acknowledged only once the collector has accepted it; a phone
  that is offline re-reads it on the next launch. The start-up line's count is
  then of reports handed off, not of reports the collector has taken.

Acknowledging on durability means the spool's limits then apply to the report,
and the file may be the only copy. They are narrow: being offline is never
counted against it, a file is dropped by count only when the collector is
accepting other batches and refusing this one, `spoolMaxBatches` and
`spoolMaxBytes` evict every ordinary batch before a crash report, and
`spoolMaxAge` is the one unconditional bound.

The pending reports are spooled together. If that is refused (together they
are over a cap), each is spooled on its own, newest first, and never by
evicting a crash report already on disk — that one was acknowledged, so the
file is its only copy. One that does not fit, or is over the byte cap by
itself, is sent directly and stays with the platform until the collector has
taken it.

## Delivered once, even when the engine is torn down

The acknowledgement is a message to the platform. Android destroys and
recreates an activity — and its Flutter engine — in the same process whenever
an asset path or the package's application info changes, which is routine in
the first seconds after an install or a boot. `main()` then runs again, the
platform still holds the report, and it would be delivered a second time.

So the spool writes the ids of the reports a batch holds into the batch
itself, and into a small journal until the platform confirms the
acknowledgement. A drain that is offered a report it already made durable
only repeats the acknowledgement. Without a spool the report is re-read and
re-sent — the duplicate the spool exists to prevent: **prefer a spool**.

## Which build crashed

A crash is reported by the **next** launch, and the record leaves under _that_
launch's resource. After an app update `service.version` and `app.build_id`
name the build that reported the crash, not the one that died, and symbols
get fetched for the wrong binary. So every native crash record carries two
attributes of its own:

| Attribute                           | Android           | iOS                          |
| ----------------------------------- | ----------------- | ---------------------------- |
| `otel_zone.crashed.service.version` | `versionName`     | `CFBundleShortVersionString` |
| `otel_zone.crashed.app.build_id`    | `longVersionCode` | `CFBundleVersion`            |

A crash from 1.0.0+1 recovered by 1.0.1+2 has
`otel_zone.crashed.service.version=1.0.0` and
`otel_zone.crashed.app.build_id=1`, under a resource that says `1.0.1` and
`2`. (OTel resources are per batch, so the record cannot be re-resourced; that
is why this is an attribute.)

Each is present only when it is known and **omitted otherwise, never
guessed**. A report written before these existed has neither, and a reader
must treat "absent" as "unknown", not as "the current build". How each
platform knows is on the [Android](/platforms/android#which-build-crashed) and
[iOS](/platforms/ios#which-build-crashed) pages.

## What the platforms store before Dart runs

`redact` cannot reach these files: the platforms write them before Dart is
running, and they hold the **raw** text. Say so plainly to whoever reviews
what the app keeps on the phone.

| Platform | What                       | Where, and what it holds                                                                                                                         |
| -------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Android  | An uncaught JVM exception  | one JSON report per exception in `noBackupFilesDir/otel_zone/crashes`: class, raw message, raw stack trace, thread name, pid, session id, screen |
| Android  | The process state summary  | not a file: up to 128 bytes the OS keeps for the process — session id, version, build, screen                                                    |
| Android  | The exit-record watermark  | `noBackupFilesDir/otel_zone`; the OS's own `ApplicationExitInfo` record is read on each launch and not copied                                    |
| iOS      | MetricKit                  | the `MXDiagnosticPayload` JSON, verbatim, in `Application Support/otel_zone/diagnostics/`, saved before it is parsed                             |
| iOS      | An uncaught `NSException`  | name, reason, `callStackSymbols` and screen in `Application Support/otel_zone/exceptions/`, plus a small ledger of acknowledged reports          |
| iOS      | The screen each run showed | one small JSON file per run (pid, launch time, last screen) in `Application Support/otel_zone/screens/`                                          |

All of it is app-private and in no-backup storage: `noBackupFilesDir` on
Android, and on iOS a directory marked `isExcludedFromBackup` (best effort: if
the flag cannot be set, the directory is backed up). A file is deleted when
the report it holds is acknowledged, and at most 16 of each kind are kept, so
a report the collector never takes stays until the cap evicts it. The per-run
screen files on iOS have their own bounds: at most 64, none older than seven
days. An `NSException`'s reason is free text and often carries app data.

## Where it runs

Android and iOS only. Web is a no-op, and desktop (macOS, Linux, Windows) gets
Dart-level capture only: the drain makes no platform call and logs nothing
there. A platform read that fails is one warning on the talker, never a thrown
error.
