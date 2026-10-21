# The guarded zone

```dart
Future<void> main() => observability.runGuarded(() async {
  WidgetsFlutterBinding.ensureInitialized();
  await observability.start(serviceVersion: '1.2.3');
  runApp(const MyApp());
});
```

`runGuarded(body)` runs `body` — which must include
`WidgetsFlutterBinding.ensureInitialized()` **and** `runApp` — inside a
guarded zone, with every uncaught-error channel wired to `reportError`.

## Four channels, not one

Flutter scatters uncaught errors across four channels. Each has a different
default — some print, some are silently swallowed — so anything less than all
four means a class of crash never reaches the logs.

| Channel                               | What arrives there                                                    | Reported with context   |
| ------------------------------------- | --------------------------------------------------------------------- | ----------------------- |
| `FlutterError.onError`                | Framework errors: build, layout and paint failures, failed assertions | the error's own context |
| `PlatformDispatcher.instance.onError` | Errors escaping engine callbacks: gesture handlers, channel replies   | `PlatformDispatcher`    |
| The zone's own handler                | Uncaught async errors                                                 | `Uncaught zone error`   |
| `Isolate.addErrorListener`            | Errors the root isolate raises outside any zone                       | `Root isolate`          |

All four call `reportError`, which hands the error to `talker.handle` — the
same function an app calls for an error it caught itself.

## Chained, not replaced

A handler installed before `runGuarded` — by a plugin, or by the app — keeps
running:

- **`FlutterError.onError`** reports the error, then calls
  `FlutterError.presentError` if and only if
  [`presentFlutterErrors`](/reference/configuration#presentfluttererrors) is
  set (the red screen and the console dump; on by default in debug builds),
  then calls the previous handler — unless that previous handler _was_
  `presentError`, Flutter's default, which would present it twice.
- **`PlatformDispatcher.onError`** reports the error, then calls the previous
  handler. A previous handler that throws is swallowed: it must not cost the
  report, nor propagate out of the engine callback. It returns `true`
  (handled), or the engine would print every error a second time.

## Why the binding goes inside

Flutter records the zone that created the binding and warns — and can
mis-route errors — if `runApp` is later called from a different one. So
`ensureInitialized()` belongs inside the body, not before `runGuarded`.

## When the body fails

A throw before `body`, or out of it, is reported by the zone's handler, and
the future `runGuarded` returns then never completes: an error does not leave
its error zone. An error the body leaves uncaught is reported, and the body
carries on.

## On the web

Since 0.8.1 `runGuarded` runs on the web, so wrap `main()` the same way on
every platform. (Before 0.8.1 it opened a `ReceivePort`, which Dart's web
runtime does not support, and the body never ran: the page stayed blank. An
app that wrote `kIsWeb ? body() : observability.runGuarded(body)` can drop
the `kIsWeb` branch once it pins 0.8.1 or later.)

On the web, framework errors and uncaught async errors are reported.
`Isolate.addErrorListener` is not installed — there are no isolates — and the
web engine never calls `PlatformDispatcher.onError`: an error escaping one of
its callbacks goes to the zone the callback was registered from, which inside
`runGuarded` is this one. See [Web and desktop](/platforms/web-desktop).

## If the isolate listener is unavailable

Anywhere other than the web, a failure to install the root-isolate listener is
one warning on the talker — "Errors raised outside any zone on the root
isolate are not reported…" — and the app starts anyway. An error hook is never
the reason an app does not start.

## What the zone does not catch

A **native** crash — a signal, a JVM exception on a platform thread, an
`NSException`, an ANR — kills the process before Dart can see it. Those are
recovered on the next launch from the operating system's own record; see
[Native crashes](/guide/native-crashes).
