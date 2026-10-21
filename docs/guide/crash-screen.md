# Which screen it died on

A native crash record can say which screen the app was showing when it died,
as `otel_zone.crashed.screen`. The app says so with one call, on every
navigation:

```dart
observability.setCrashScreen('/orders/:id'); // a pattern, never '/orders/1234?ref=mail'
observability.setCrashScreen(null);
```

Pass the route **pattern**, the way the router names the page — never a
location with an id, a query or any user text in it. `crashScreen` reads back
the value last recorded, once normalised.

::: tip With fespalier
With fespalier 0.19.0 or later, `FespalierOtel(onScreen: observability.setCrashScreen)`
makes that call for every navigation. fespalier makes it when the navigation
commits, before the new page's `initState` and first `build`, so a crash while
that page opens names that page.
:::

## When to call it

The call needs no SDK, so it is safe before `start()`. It does need the
Flutter binding: make it after `WidgetsFlutterBinding.ensureInitialized()`.
Before that the channel throws, the first screen is lost, and one warning is
logged. The value is process-wide, and the last call wins.

## Limits

A screen is trimmed, then kept if it is at most 64 UTF-8 bytes
(`maxCrashScreenBytes`) and holds no control character (U+0000 to U+001F,
U+007F to U+009F). Anything else — and `null`, an empty or a blank string — is
`null`: it clears the previous value, and it is never cut to fit, because a
cut route is a wrong route. `normalizeCrashScreen` is that rule, exported.

## Where each record gets its screen

The attribute is present only when the platform knows the screen. It is
never guessed: a crash that names no screen is "unknown", not the screen of
this launch. Live records never carry it, and a recovered crash is not stamped
with the screen the app shows now.

| Source                                            | How it gets there                                       |
| ------------------------------------------------- | ------------------------------------------------------- |
| Android JVM                                       | in memory, written by the handler                       |
| Android native, ANR, signal, low memory (API 30+) | process state summary                                   |
| Android below API 30                              | JVM only                                                |
| iOS `NSException`                                 | in memory, written by the handler                       |
| iOS MetricKit crash                               | per-run file matched by pid, iOS 17+, exactly one match |
| iOS hang                                          | never                                                   |
| merged records                                    | the handler's value wins                                |

**ANR, hang and background.** An Android ANR carries the last screen the
platform received: the frozen main thread cannot navigate, so that is the
screen the app was on when it froze. An iOS hang never carries a screen: the
process lived on, and the run's last screen is not the screen during the hang.
On Android, a kill in the background — by a signal or by the low-memory
killer — carries the screen the app was left on.

The platform details — the 128-byte process state summary on Android, the
per-run files and pid matching on iOS — are on the
[Android](/platforms/android#the-process-state-summary) and
[iOS](/platforms/ios#the-screen-of-a-metrickit-crash) pages.

## Cost

`setCrashScreen` never throws and needs no SDK. It keeps the value in memory,
and when the value changed it sends one message to the platform, on a serial
background task queue, so the platform thread only dispatches it. At most one
message is in flight: a change made while one is out is sent once it lands,
and only the latest value is sent. On Android a change is one call to the OS
(`setProcessStateSummary`), which the OS may refuse under rapid navigation;
the next change tries again. On iOS it is one small atomic write to the run's
own file. Nothing is written to disk on Android for the screen, and there is
no timer anywhere.

## Where nothing is sent

On the web and on desktop the call keeps the value and sends nothing. Under
`flutter test` the default sink is none, so a test sends nothing unless it
passes a `crashScreenSink` (see [Testing](/guide/testing#the-crash-screen)).
A platform with no channel (`MissingPluginException`, or a `channel-error`)
stops the forwarding for the process, quietly. Any other failure is warned
about once, by its type, and never with the screen.

## It is scrubbed like everything else

The screen is app text, so [`redact`](/guide/redaction) scrubs it at export.
It is **not** exempt, unlike `enduser.id`: a redactor that empties it removes
the attribute, and a pattern that a redactor rewrites reaches the collector
rewritten.

## Not yet checked on a device

The Dart tests run anywhere, and the Android and iOS tests and the crash
harness run in CI on each pull request. Per the README, nothing has yet seen
the screen on a phone: a native crash, an ANR and a background low-memory kill
at API 30 to 36; the refusals of `setProcessStateSummary` under rapid
navigation; an `NSException` on a simulator and on a device; a MetricKit crash
matched by its pid up to a day later, and whether 64 files and seven days are
enough; the iOS 26 and 27 payloads still carrying `pid`; and an iOS build
before 17, which has no screen at all.
