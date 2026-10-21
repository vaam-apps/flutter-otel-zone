# Example walkthrough

[`example/lib/main.dart`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/example/lib/main.dart)
is the smallest correct wiring, in one file, in the order it has to happen.
This page walks through it.

## Run it

The repository carries the example's platform code that matters —
`MainActivity`, `AppDelegate`, the crash harness, `Debug.xcconfig` — but not
the generated scaffolding (the Gradle wrapper, the iOS runner project).
Generate it first, as the README and CI do:

```bash
cd example
flutter pub get
flutter create --platforms=android .   # and/or --platforms=ios
flutter run --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://<your collector>:4318
```

Without a collector the app still runs: the screen says
"No collector — logging locally only".

## 1. The `OtelZone`, at the top level

```dart
final OtelZone observability = OtelZone(
  OtelZoneConfig(
    serviceName: 'otel-zone-example',
    endpoint: const String.fromEnvironment(
      'OTEL_EXPORTER_OTLP_ENDPOINT',
      defaultValue: 'http://localhost:4318',
    ),
    deploymentEnvironmentName: 'development',
    spoolDirectory: () => Directory('${Directory.systemTemp.path}/otel-zone'),
    exportFloor: ExportFloor.parse(
      const String.fromEnvironment(
        'OTEL_LOG_EXPORT_LEVEL',
        defaultValue: 'warning',
      ),
    ),
  ),
);
```

- **The endpoint** comes from `--dart-define`, defaulting to a local
  collector over plain HTTP. `secure` is not set, so it follows the scheme:
  `http://` here means no TLS.
- **`deploymentEnvironmentName`** becomes `deployment.environment.name` on the
  resource. One `serviceName` per service, not per flavour; the environment
  is what tells flavours apart.
- **The spool** is on. A recovered native crash is acknowledged once it is on
  disk there and delivered from there, so it survives the app being killed or
  relaunched before the collector answers. The example uses the temp
  directory only to stay free of `path_provider`; a real app passes
  `getApplicationSupportDirectory` (or better, a non-backed-up directory —
  see [Where the spool lives](/guide/spool#where-the-spool-lives)).
- **The floor** is read from somewhere untyped, which is exactly what
  `ExportFloor.parse` is for: `--dart-define=OTEL_LOG_EXPORT_LEVEL=loud`
  falls back to `warning` and says so in the start-up line, rather than
  quietly changing what the build sends.

## 2. The zone, the binding, the screen

```dart
Future<void> main() => observability.runGuarded(() async {
  WidgetsFlutterBinding.ensureInitialized();

  observability.setCrashScreen('/home');
```

`WidgetsFlutterBinding.ensureInitialized()` runs **inside** `runGuarded`:
Flutter records the zone that created the binding and warns if `runApp`
arrives from another one.

`setCrashScreen('/home')` comes next. A real app calls it on every
navigation, with the route pattern. It needs the binding (the platform
channel throws without one) but not the SDK, so it is safe before `start()`
— and it comes first here so that a slow start cannot let the crash harness's
crash beat it. See [Which screen it died on](/guide/crash-screen).

## 3. `start()`

```dart
  await observability.start(
    serviceVersion: const String.fromEnvironment(
      'APP_VERSION',
      defaultValue: '1.0.0',
    ),
    buildId: const String.fromEnvironment('APP_BUILD', defaultValue: '1'),
    resourceAttributes: const <String, String>{'os.type': 'android'},
  );

  runApp(const ExampleApp());
});
```

In a real app `serviceVersion` and `buildId` come from `package_info_plus`
and the resource attributes from `device_info_plus`, read off the installed
artifact. Here `--dart-define` stands in for that read, so the
[crash harness](/development/crash-harness) can install two builds and tell
their identities apart.

## 4. The app

```dart
MaterialApp(
  navigatorObservers: <NavigatorObserver>[?observability.routeObserver()],
  home: Scaffold(
    // ...
    Text(
      observability.isReady
          ? 'Exporting to ${observability.config.endpoint}'
          : 'No collector — logging locally only',
    ),
    ElevatedButton(
      onPressed: () => observability.talker.warning('The button was pressed'),
      child: const Text('Log a warning'),
    ),
    ElevatedButton(
      // Nothing catches this: the zone does.
      onPressed: () => throw StateError('Something impossible'),
      child: const Text('Throw'),
    ),
    const CrashHarnessPanel(),
```

- **`routeObserver()`** is spread null-aware: it is `null` when the SDK never
  came up.
- **`isReady`** says whether `start()` succeeded.
- **"Log a warning"** writes to the one `Talker`. At the default `warning`
  floor it is exported.
- **"Throw"** throws from a gesture handler with nothing to catch it. The
  zone's handlers report it as an error, and the error brings the records
  before it along as a breadcrumb record.
- **`CrashHarnessPanel`** shows one "Crash: kind" button per kind the
  platform accepts — `jvm`, `native`, `anr` on Android; `nsexception`,
  `signal` on iOS — in debug builds only. It is how a person verifies native
  capture on a real device with no tooling attached. See
  [Crash harness](/development/crash-harness).

## The integration test

[`example/integration_test/crash-channel_test.dart`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/example/integration_test/crash-channel_test.dart)
proves the half of the harness a process can outlive: the crash channel is
registered, and refuses an unknown kind with a `PlatformException` whose code
is `unknown-kind`. It never sends a valid kind — that would kill the test
process.

```bash
cd example && flutter test integration_test -d <device>
```
