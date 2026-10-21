# Testing against it

## The sink: `RecordingTalkerObserver`

`OTelTalkerObserver` — what the bridge forwards to — cannot be observed at
all: it resolves `OTel.loggerProvider()` and throws without a live SDK, and
`OtelBridge` swallows that, so "exported" and "dropped" look identical from
outside. Pass a recording sink instead, and the floor, the breadcrumbs and the
start-up summary all become assertable with no SDK and no collector:

```dart
final sink = RecordingTalkerObserver();
final zone = OtelZone(config, sink: sink);
```

`sink.records` is everything forwarded to it, oldest first. The bridge on its
own works the same way:

```dart
final sink = RecordingTalkerObserver();
final bridge = OtelBridge(
  floor: const ExportFloor.of(LogLevel.warning),
  history: () => const <TalkerData>[],
  sink: sink,
)..ready = true;

bridge.onLog(TalkerData('a route change', logLevel: LogLevel.info));
sink.records; // empty — info is below the floor
```

`ready` is what `start()` sets on success; nothing is forwarded while it is
`false`, so a bridge under test sets it by hand.

## The start-up line

`startupSummary` is public, so the line a build will log can be asserted
without starting anything:

```dart
const config = OtelZoneConfig(
  serviceName: 'my-app',
  endpoint: 'https://otel.example.com',
  deploymentEnvironmentName: 'production',
);
final zone = OtelZone(config, sink: RecordingTalkerObserver());
zone.startupSummary('1.2.3', '48');
// 'OpenTelemetry: exporting to https://otel.example.com as my-app '
// '1.2.3 build 48 (production), records at warning and above'
```

## The crash screen

The screen `setCrashScreen` gives the platform goes to a `crashScreenSink`, and
`RecordingCrashScreenSink` is its fake. Pass one to see what the platform
would have been told:

```dart
final crashScreen = RecordingCrashScreenSink();
final zone = OtelZone(config, sink: sink, crashScreenSink: crashScreen);
zone.setCrashScreen('/orders/:id');
crashScreen.screens; // ['/orders/:id'], once the message has been sent
```

Under `flutter test` the default sink is none, so without one nothing is sent.

## Native crashes: `NativeCrashSource`

`OtelZone`'s `nativeCrashSource:` parameter is the seam the crash drain is
tested through. Implement `pending()` and `acknowledge(ids)` to stand in for
the platform without a method channel or a device:

```dart
class FakeCrashSource implements NativeCrashSource {
  final List<String> acknowledged = <String>[];

  @override
  Future<List<NativeCrashReport>> pending() async => <NativeCrashReport>[
    NativeCrashReport(id: 'a', kind: 'native', timestampMicros: 1700000000000000),
  ];

  @override
  Future<void> acknowledge(List<String> ids) async => acknowledged.addAll(ids);
}
```

## Injection points, all together

| Parameter           | Default                                            | Replace it with                      |
| ------------------- | -------------------------------------------------- | ------------------------------------ |
| `talker`            | a `Talker` with the bridge as its observer         | your own (give it `bridge` yourself) |
| `sink`              | `OTelTalkerObserver`                               | `RecordingTalkerObserver`            |
| `nativeCrashSource` | `PigeonNativeCrashSource` (the plugin's channel)   | any `NativeCrashSource`              |
| `crashScreenSink`   | `PigeonCrashScreenSink`, none under `flutter test` | `RecordingCrashScreenSink`           |

A caller that supplies its own `talker` is responsible for having given it the
zone's `bridge` as an observer.

## Testing this package

`flutter test` in the repository is the whole contract — the floor, the
breadcrumbs, the redaction and the start-up summary — and needs no device. See
[Building and testing](/development/) for the web, Kotlin and Swift suites.
