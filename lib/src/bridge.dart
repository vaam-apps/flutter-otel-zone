import 'package:otel_talker/otel_talker.dart';
import 'package:talker/talker.dart';

import 'export-floor.dart';

/// Forwards Talker records to OpenTelemetry — the ones worth the radio,
/// only once the SDK is actually up, and never by throwing.
///
/// ## Why a floor at all
///
/// Measured on the records actually sitting in a collector, 7,715 of them
/// from one set of release builds of a Flutter app wired this way: 3,020
/// `[riverpod-add]`, 2,773 `[riverpod-update]`, 1,498 `[route]`, 261
/// `[exception]`, 158 `[info]`. That is 5,793 debug and 1,656 info against
/// 266 errors — **96.5% chatter**, one record per provider initialisation,
/// one per provider state change, one per navigation. It scales with how
/// much the user *uses the app*, which is the worst shape a cost can have
/// on a metered prepaid connection: the more someone does, the more they
/// pay to tell you they did.
///
/// ## Why not simply drop the observers in release
///
/// Because the breadcrumbs are the point. An `[exception]` record with no
/// preceding route or provider transitions is a stack trace with no story,
/// and the route log is exactly what answers "which screen was this". So
/// the observers stay attached in every build and every record still lands
/// in `talker.history`, where it costs nothing.
///
/// ## What actually goes
///
/// A record at or above the [floor], plus — for a fault only — one extra
/// record carrying the last [breadcrumbCount] entries that did *not* go. So
/// the wire carries context for the records it keeps and pays nothing for
/// the ones it discards, and volume scales with faults rather than with
/// interaction.
///
/// ## Why the readiness guard
///
/// `OTelTalkerObserver` resolves `OTel.loggerProvider()`, which throws
/// `StateError: OTel.initialize() must be called first` if the SDK was
/// never initialised — or if initialisation *failed*. Without [ready] the
/// consequences are backwards:
///
///   * anything logged before start-up completes crashes the logger rather
///     than being logged;
///   * and the start-up path's own `catch` — which reports an unreachable
///     collector with `talker.warning` — would itself throw, turning "no
///     collector on this network" into a failed start-up. That is the exact
///     opposite of the requirement that telemetry never block boot.
///
/// So: forward only when [ready], and swallow anything the bridge throws.
/// A logging path that can fail is worse than no logging path, because it
/// takes the thing it was supposed to report down with it.
class OtelBridge extends TalkerObserver {
  /// Creates the bridge.
  ///
  /// [history] is where a fault's breadcrumb trail comes from — normally
  /// the owning `Talker`'s own `history`. [sink] is where a record that
  /// clears the floor actually goes; it is injectable for one reason, that
  /// a test cannot observe `OTelTalkerObserver` at all (it resolves
  /// `OTel.loggerProvider()` and throws without a live SDK, and this class
  /// then swallows that, so "exported" and "dropped" look identical from
  /// outside). With a recording sink the floor and the breadcrumbs are
  /// assertable without an SDK or a collector.
  OtelBridge({
    required this.floor,
    required List<TalkerData> Function() history,
    String loggerName = 'package.talker',
    this.breadcrumbCount = 12,
    this.breadcrumbLineLimit = 160,
    TalkerObserver? sink,
  }) : _history = history,
       _sink = sink ?? OTelTalkerObserver(loggerName: loggerName);

  /// The severity a record has to reach to leave the device.
  final ExportFloor floor;

  /// How many withheld records ride along with a fault.
  final int breadcrumbCount;

  /// The length one breadcrumb line is truncated to.
  final int breadcrumbLineLimit;

  final TalkerObserver _sink;
  final List<TalkerData> Function() _history;

  /// Set to `true` only on a successful `OTel.initialize`, by
  /// `OtelZone.start`. Nothing is forwarded while it is `false`.
  bool ready = false;

  @override
  void onLog(TalkerData log) => _handle(log, () => _sink.onLog(log));

  @override
  void onError(TalkerError err) => _handle(err, () => _sink.onError(err));

  @override
  void onException(TalkerException err) =>
      _handle(err, () => _sink.onException(err));

  /// Whether a record at [level] is exported.
  ///
  /// A record with no level is treated as `info`, matching what
  /// `OTelTalkerObserver` would have stamped on it.
  ///
  /// ```dart
  /// final bridge = OtelBridge(
  ///   floor: const ExportFloor.of(LogLevel.warning),
  ///   history: () => const <TalkerData>[],
  ///   sink: RecordingTalkerObserver(),
  /// );
  /// bridge.carries(LogLevel.info);   // false
  /// bridge.carries(LogLevel.error);  // true
  /// ```
  bool carries(LogLevel? level) => floor.carries(level);

  void _handle(TalkerData data, void Function() forwardRecord) {
    if (!carries(data.logLevel)) return;
    // Two separate guarded calls: a trail that cannot be built must never
    // cost the fault it was decorating.
    _forward(() => _emitBreadcrumbs(data));
    _forward(forwardRecord);
  }

  /// The trail that goes with a fault, as one record.
  ///
  /// Only faults get one: a `warning` is an expected state — offline, a
  /// rejection the server explained, a declined permission prompt — and
  /// nobody opens a stack trace for it.
  ///
  /// The current record is *not* in the trail: `Talker` calls its observer
  /// before it writes history, so the history holds exactly what came
  /// before, which is what a breadcrumb is.
  void _emitBreadcrumbs(TalkerData data) {
    if (!floor.withholdsBreadcrumbs) return;
    final LogLevel? level = data.logLevel;
    if (level != LogLevel.error && level != LogLevel.critical) return;

    final List<TalkerData> recent = _history();
    if (recent.isEmpty) return;
    final Iterable<TalkerData> trail = recent.length > breadcrumbCount
        ? recent.sublist(recent.length - breadcrumbCount)
        : recent;

    _sink.onLog(
      TalkerData(
        trail.map(_breadcrumb).join('\n'),
        logLevel: level,
        time: data.time,
        title: 'breadcrumbs',
      ),
    );
  }

  String _breadcrumb(TalkerData entry) {
    final String line =
        '${entry.displayTime()} [${entry.title}] ${entry.message ?? ''}';
    return line.length <= breadcrumbLineLimit
        ? line
        : '${line.substring(0, breadcrumbLineLimit)}…';
  }

  void _forward(void Function() emit) {
    if (!ready) return;
    try {
      emit();
    } on Object {
      // Deliberately swallowed, and deliberately not reported through
      // Talker — doing so would re-enter this method and recurse. The
      // record is already in `talker.history` and, in debug, on the
      // console; losing its OTel copy is the smallest possible failure.
    }
  }
}
