import 'package:talker/talker.dart';

/// The severity a record has to reach before it leaves the device, together
/// with the record of a configuration string that did not name one.
///
/// It is a type rather than a bare [LogLevel] because a build's floor is
/// almost always read from somewhere untyped — a `--dart-define`, a `.env`
/// key compiled in by `envied`, a remote value — and a typo there must not
/// quietly change what the build sends. [parse] keeps the fallback *and*
/// what was actually written, so `OtelZone.start` can say both in the one
/// line it logs at start-up.
///
/// ```dart
/// ExportFloor.parse('warning').level;      // LogLevel.warning
/// ExportFloor.parse('loud').level;         // LogLevel.warning — the fallback
/// ExportFloor.parse('loud').unrecognised;  // 'loud'
/// ```
final class ExportFloor {
  const ExportFloor._(this.level, this.unrecognised);

  /// A floor chosen in code, where there is nothing to misspell.
  const ExportFloor.of(LogLevel level) : this._(level, null);

  /// The floor [name] asks for, or [fallback] when it names no level this
  /// package knows.
  ///
  /// [fallback] defaults to the quiet end deliberately. A misconfigured
  /// build that defaults to *loud* bills its users for the mistake, on
  /// whatever connection they are paying for; one that defaults to quiet
  /// loses debug breadcrumbs from the wire and keeps every fault, which is
  /// the cheaper way to be wrong.
  factory ExportFloor.parse(
    String name, {
    LogLevel fallback = defaultLevel,
  }) {
    final LogLevel? parsed = parseLogLevel(name);
    return ExportFloor._(parsed ?? fallback, parsed == null ? name : null);
  }

  /// What an unreadable floor falls back to: the quiet end.
  static const LogLevel defaultLevel = LogLevel.warning;

  /// The floor in force.
  final LogLevel level;

  /// What the build asked for when it did not name a level, or `null` when
  /// the value was understood.
  ///
  /// Non-null is not an error — the floor is usable either way. It is the
  /// material for the one warning `OtelZone.start` emits, so a typo reports
  /// itself instead of silently changing what a build sends.
  final String? unrecognised;

  /// Whether a record at [recordLevel] clears this floor.
  ///
  /// A record with no level is treated as `info`, matching what
  /// `OTelTalkerObserver` would have stamped on it.
  bool carries(LogLevel? recordLevel) =>
      priorityOf(recordLevel) <= priorityOf(level);

  /// Whether a fault's breadcrumb trail would carry anything the collector
  /// does not already have.
  ///
  /// `false` from `debug` downwards: at that point every record a trail
  /// could be built from is already on the wire, and emitting the trail as
  /// well would be a second copy of it.
  bool get withholdsBreadcrumbs =>
      priorityOf(level) < priorityOf(LogLevel.debug);

  /// Talker's own severity ranking.
  ///
  /// `logLevelPriorityList` rather than the enum's own index: `LogLevel` is
  /// declared `error, critical, info, debug, verbose, warning`, so comparing
  /// `LogLevel.index` would put `warning` below `verbose` and export
  /// everything.
  static int priorityOf(LogLevel? level) =>
      logLevelPriorityList.indexOf(level ?? LogLevel.info);

  @override
  String toString() => unrecognised == null
      ? 'ExportFloor(${level.name})'
      : 'ExportFloor(${level.name}, unrecognised: "$unrecognised")';
}

/// The [LogLevel] [name] names, case- and whitespace-insensitively, or
/// `null` when it names none.
///
/// ```dart
/// parseLogLevel('  WARNING ');  // LogLevel.warning
/// parseLogLevel('chatty');      // null
/// ```
LogLevel? parseLogLevel(String name) {
  final String wanted = name.trim().toLowerCase();
  for (final LogLevel level in LogLevel.values) {
    if (level.name == wanted) return level;
  }
  return null;
}
