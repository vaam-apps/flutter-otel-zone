// The smallest correct wiring, and the order it has to happen in.
//
//  1. The `OtelZone` is built at the top level, so anything that logs
//     before start-up finishes — including start-up's own failure — has a
//     sink to land on.
//  2. The guarded zone opens. `WidgetsFlutterBinding.ensureInitialized()`
//     and `runApp` both run inside it: Flutter records the zone that
//     created the binding and warns if `runApp` arrives from a different
//     one.
//  3. `start()` runs, with whatever the device could tell us about itself.
//     It never throws.
import 'package:flutter/material.dart';
import 'package:otel_zone/otel_zone.dart';

final OtelZone observability = OtelZone(
  OtelZoneConfig(
    serviceName: 'otel-zone-example',
    endpoint: const String.fromEnvironment(
      'OTEL_EXPORTER_OTLP_ENDPOINT',
      defaultValue: 'http://localhost:4318',
    ),
    deploymentEnvironmentName: 'development',
    // Read from somewhere untyped, so a typo has to report itself rather
    // than quietly change what this build sends.
    exportFloor: ExportFloor.parse(
      const String.fromEnvironment(
        'OTEL_LOG_EXPORT_LEVEL',
        defaultValue: 'warning',
      ),
    ),
  ),
);

Future<void> main() => observability.runGuarded(() async {
  WidgetsFlutterBinding.ensureInitialized();

  // In a real app these come from `package_info_plus` and
  // `device_info_plus`, read off the installed artifact — never
  // hardcoded, or every build ever shipped reports the same identity.
  await observability.start(
    serviceVersion: '1.0.0',
    buildId: '1',
    resourceAttributes: const <String, String>{'os.type': 'android'},
  );

  runApp(const ExampleApp());
});

/// A single screen with the three things worth demonstrating.
class ExampleApp extends StatelessWidget {
  /// Creates the example app.
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Navigation on the same timeline as everything else. `null` when the
      // SDK never came up, which is why this is a spread rather than a
      // plain element.
      navigatorObservers: <NavigatorObserver>[?observability.routeObserver()],
      home: Scaffold(
        appBar: AppBar(title: const Text('otel_zone')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                observability.isReady
                    ? 'Exporting to ${observability.config.endpoint}'
                    : 'No collector — logging locally only',
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () =>
                    observability.talker.warning('The button was pressed'),
                child: const Text('Log a warning'),
              ),
              ElevatedButton(
                // Nothing catches this: the zone does.
                onPressed: () => throw StateError('Something impossible'),
                child: const Text('Throw'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
