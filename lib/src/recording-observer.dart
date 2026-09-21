import 'package:talker/talker.dart';

/// A [TalkerObserver] that keeps what it was given, so a test can assert on
/// the wire without a live OpenTelemetry SDK or a collector.
///
/// It exists because `OTelTalkerObserver` cannot be observed at all: it
/// resolves `OTel.loggerProvider()` and throws without a live SDK, and
/// `OtelBridge` then swallows that — so "exported" and "dropped" look
/// identical from outside. Pass one as `OtelBridge`'s or `OtelZone`'s
/// `sink` and the export floor, the breadcrumb trail and the start-up
/// summary all become assertable.
///
/// ```dart
/// final sink = RecordingTalkerObserver();
/// final bridge = OtelBridge(
///   floor: const ExportFloor.of(LogLevel.warning),
///   history: () => const <TalkerData>[],
///   sink: sink,
/// )..ready = true;
///
/// bridge.onLog(TalkerData('a route change', logLevel: LogLevel.info));
/// sink.records;  // empty — info is below the floor
/// ```
class RecordingTalkerObserver extends TalkerObserver {
  /// Everything forwarded to this observer, oldest first.
  final List<TalkerData> records = <TalkerData>[];

  @override
  void onLog(TalkerData log) => records.add(log);

  @override
  void onError(TalkerError err) => records.add(err);

  @override
  void onException(TalkerException err) => records.add(err);
}
