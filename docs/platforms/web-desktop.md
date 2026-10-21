# Web and desktop

The plugin's native half is registered on Android and iOS only — the
`pubspec.yaml` says why: "web has no process to have died, and desktop is not
a target". The Dart half works on both.

## On the web

Since otel_zone 0.8.1 `runGuarded` runs on the web, so wrap `main()` the same
way on every platform.

Before 0.8.1 it never ran its body there and the page stayed blank: it opened
a `ReceivePort`, Dart's web runtime throws `UnsupportedError` for that, and
the zone's own handler took the error. An app that wrote
`kIsWeb ? body() : observability.runGuarded(body)` drops the `kIsWeb` branch
once it pins 0.8.1 or later.

### What is reported

Framework errors and uncaught async errors. `Isolate.addErrorListener` is not
installed, and the web engine never calls `PlatformDispatcher.onError`: an
error escaping one of its callbacks goes to the zone the callback was
registered from, which inside `runGuarded` is this one.

### Flushing a tab

Since 0.8.1 the queued records are also flushed when the tab is hidden —
switching to another tab, minimising the window, or closing it. (They already
were when the host page removes the app's last view.) The web engine never
reports `paused`, so `hidden` is the state that does it. A flush still in
flight when the page unloads can be cut short by the browser, so records sent
as a tab closes are best effort.

### What does nothing

Native crash capture and `setCrashScreen` do nothing on the web: the drain
makes no platform call, and `setCrashScreen` keeps the value and sends
nothing.

### Tested in a browser

`test/run-guarded-web_test.dart` needs a browser. CI's `web` job runs it under
both the JavaScript and the wasm compilers:

```bash
flutter test --platform chrome test/run-guarded-web_test.dart
flutter test --platform chrome --wasm test/run-guarded-web_test.dart
```

Plain `flutter test` skips it.

## On desktop

macOS, Linux and Windows get Dart-level capture only: all four `runGuarded`
channels, the floor, the breadcrumbs and `redact`. The native crash drain
makes no platform call and logs nothing there, and `setCrashScreen` keeps its
value without sending it.
