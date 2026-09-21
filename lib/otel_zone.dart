/// One `Talker`, one OpenTelemetry SDK, and one guarded zone that funnels
/// every uncaught error in a Flutter app into both — with a severity floor
/// so a phone on a metered connection is not billed for telemetry nobody
/// reads.
///
/// Start at `OtelZone`. `OtelZoneConfig` is everything a build knows about
/// its own telemetry before it runs; `OtelBridge` is what decides which
/// records leave the device.
library;

export 'src/bridge.dart';
export 'src/config.dart';
export 'src/export-floor.dart';
export 'src/otel-zone.dart';
export 'src/recording-observer.dart';
