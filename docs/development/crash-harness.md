# Crash harness

Native capture is the operating system's behaviour, not this package's, so it
is proven by dying on purpose. `example/` carries a **debug-only** way to do
that, and host scripts in `tool/` crash it, relaunch it and read what the
drain sent — off the wire, not from a marker the app prints about itself.

## Two doors to the same code

- **A method channel**, `otel_zone_example/crash`, takes `crash(kind)` and
  backs a small "Crash harness" panel in the example's debug UI — there so a
  person can verify on a real device with no tooling attached.
- **A launch request** — an `otel_crash` intent extra on Android, an
  `-otel_crash` launch argument on iOS — lets a host script trigger a death
  from outside a process that is about to stop answering.

| Platform | Kind          | What happens                                    |
| -------- | ------------- | ----------------------------------------------- |
| Android  | `jvm`         | an uncaught exception on the main thread        |
| Android  | `native`      | `Process.sendSignal(myPid(), SIGSEGV)` (no JNI) |
| Android  | `anr`         | the main thread is held for 60 s                |
| iOS      | `nsexception` | an uncaught `NSException`                       |
| iOS      | `signal`      | `raise(SIGABRT)`                                |

### Debug only, and proved absent from release

Android keeps the real `CrashHarness` in `src/debug` and a refusing stand-in
in `src/release` and `src/profile`, so `MainActivity` is identical in every
build type and a release APK contains neither the channel name nor the crash
code. iOS wraps it in `#if DEBUG`; Flutter's Xcode template does not define
`DEBUG` for the Runner target, so `example/ios/Flutter/Debug.xcconfig` does.
The Dart side returns `false` without touching the channel outside
`kDebugMode`. (Dart's AOT snapshot still carries the channel-name string; with
no native handler it is inert.) `--release-refusal` (Android) and CI's `ios`
job check this rather than assume it.

## Android: host-driven, on an emulator

`integration_test` cannot survive its own process dying, so the driver is on
the host. For each kind, from a fresh install,
[`tool/android-crash-harness.dart`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/tool/android-crash-harness.dart):

1. launches the app and waits for `start()` to finish;
2. asks for the crash with `adb shell am start --es otel_crash <kind>`;
3. waits for the process to be gone **and for the OS to have filed its exit
   record** (the process being gone is not the OS knowing);
4. relaunches, and requires **exactly one** FATAL record of that kind to have
   reached its own OTLP receiver;
5. relaunches again, and requires none.

```bash
cd example && flutter pub get && flutter create --platforms=android . && cd ..
dart run tool/android-crash-harness.dart --device emulator-5554
dart run tool/android-crash-harness.dart --device emulator-5554 --release-refusal
cd example && flutter test integration_test -d emulator-5554   # channel is present, refuses an unknown kind
```

Each recovered record must also carry the crashed-build attributes and the
screen it died on: `otel_zone.crashed.screen` is `/home`, which the example
sets.

### Options

| Flag                      | Default          | What it does                                                                                 |
| ------------------------- | ---------------- | -------------------------------------------------------------------------------------------- |
| `--device <serial>`       |                  | the `adb` device to use                                                                      |
| `--kinds <list>`          | `jvm,native,anr` | narrows the kinds run                                                                        |
| `--port <n>`              | `4421`           | the local OTLP receiver's port                                                               |
| `--no-build`              |                  | uses an already-built APK                                                                    |
| `--release-refusal`       |                  | checks that a release build refuses the crash request                                        |
| `--settle <s>`            | `3`              | how long a launch must be quiet before it is judged                                          |
| `--retries <n>`           | `0`              | re-runs a failed kind from a fresh install; off by default — a failure is a defect           |
| `--repeat <n>`            | `1`              | runs every kind `n` times and requires every run to pass: how a flake is measured            |
| `--log-dir <path>`        |                  | keeps each run's whole logcat and exit-info dump                                             |
| `--relaunch-after <ms,…>` |                  | fires `adb shell am update-appinfo` that many ms into the recovery launch, one run per delay |
| `--upgrade-apk <apk>`     |                  | installs a second build over the first after the crash                                       |

**Settling, not first line.** Android relaunches an activity in the same
process, on its own, whenever an asset path or the package's application info
changes — routine in the first seconds after an install or a boot — and the
second engine runs `start()` again. So the assertion is on everything that
reached the receiver over the launch, and the start-up line's "recovered N" is
required to say exactly one only when the activity was not relaunched.

**`--relaunch-after`** provokes that relaunch on purpose. It is how the
duplicate the spool's journal guards against was found (a relaunch landing
between the spool and the acknowledgement made one crash arrive twice) and how
it stays fixed. The window is tens of milliseconds wide and moves with the
machine, so sweep it rather than trust one value.

**A fresh install includes the OS having forgotten the last one.**
`adb uninstall` returns before the activity manager has dropped the
uninstalled package's exit records, and it drops them by package _name_ — so a
slow drop can take the new install's record with it. The harness dumps the
exit history before uninstalling and, after, waits (every half second, at most
two minutes) until the dump lists no record and the OS has written its history
since. It prints `previous install left the exit history after <ms> ms`. That
wait is on the OS's own state, not a retry, and no assertion is relaxed by it.

**The ANR needs two things a bare block does not give.** An ANR is declared
only when something is _waiting_ on the blocked main thread, so the script
sends a tap 1.5 s after asking for the block; the OS declares the ANR 5 s
after the tap. And the OS shows an "isn't responding" dialog and keeps the
process alive until someone taps "Close app", so for `anr` the script sets
`hide_error_dialogs` — making the OS kill the process itself, recorded as
`REASON_ANR` — and restores the previous value afterwards.

### An update over a crash

`--upgrade-apk` adds the case the crashed-build attributes exist for: after
the crash, a second build is installed **over** the first without clearing its
data, and the record must then name the old build in `otel_zone.crashed.*` and
the new one in its resource. The example reads its `service.version` and
`build_id` from `--dart-define=APP_VERSION` and `APP_BUILD`:

```bash
cd example
flutter build apk --debug --build-name 1.0.1 --build-number 2 \
  --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4421 \
  --dart-define=APP_VERSION=1.0.1 --dart-define=APP_BUILD=2
cp build/app/outputs/flutter-apk/app-debug.apk /tmp/app-1.0.1-2.apk
flutter build apk --debug --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4421
cd .. && dart run tool/android-crash-harness.dart --no-build --kinds jvm,native \
  --upgrade-apk /tmp/app-1.0.1-2.apk
```

### The pieces it is built from

- [`tool/otlp-log-sink.dart`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/tool/otlp-log-sink.dart)
  — a throwaway OTLP/HTTP log receiver that decodes protobuf (or JSON) by
  hand, importing no SDK types, so the receiver shares no code with the sender
  it checks. Unit-tested against the SDK's own encoder.
- [`tool/exit-info.dart`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/tool/exit-info.dart)
  — what the harness reads out of `dumpsys activity exit-info`, unit-tested
  against dumps captured from the CI emulators.
- [`tool/log-window.dart`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/tool/log-window.dart)
  — which log lines belong to a launch.

`.github/workflows/crash-harness.yml` runs it on API 30 and API 34 emulators on
every pull request, push to `main`, nightly, and on demand.

## iOS: what a simulator can and cannot show

MetricKit is not delivered on a simulator, so the signal and hang paths cannot
be triggered there. The uncaught-`NSException` path can: the plugin's handler
writes its JSON at the moment of the throw, so raise, relaunch, drain works
without MetricKit.

```bash
cd example && flutter pub get && flutter create --platforms=ios . && cd ..
dart run tool/ios-crash-harness.dart --device <booted simulator udid>
```

It checks the crashed-build attributes too, and `--app <Runner.app>` with
`--upgrade-app <Runner.app>` runs the same update-over-a-crash case as Android
(`simctl install` over an installed app keeps its data). It is not run in CI.

### Manual device verification

Not run in CI; a real-device farm is out of scope.

1. Run the example from Xcode on a physical device, Debug configuration.
2. **`nsexception`**: tap "Crash: nsexception", relaunch the app. The start-up
   line says `recovered 1 native crash` and the collector shows a FATAL
   `device.crash` with `device.crash.kind = nsexception`, the exception's
   reason and its throw-site stack.
3. **MetricKit**: with the app running, choose Xcode's
   **Debug > Simulate MetricKit Payloads**. The subscriber writes the payload
   on arrival; stop and relaunch, and the drain reports the sample crash and
   hang diagnostics (`signal`/`nsexception` and `hang`), once each; a further
   launch reports none.
4. **A real signal**: tap "Crash: signal", relaunch, and wait. iOS delivers
   the real diagnostic up to a day later, on a later launch.
