import 'package:otel_talker/otel_talker.dart';
import 'package:talker/talker.dart';
import 'package:talker_riverpod_logger/talker_riverpod_logger.dart'
    show RiverpodFailLog;

import 'config.dart';
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
    this.redact,
    TalkerObserver? sink,
  }) : _history = history,
       _sink = sink ?? OTelTalkerObserver(loggerName: loggerName);

  /// The severity a record has to reach to leave the device.
  final ExportFloor floor;

  /// How many withheld records ride along with a fault.
  final int breadcrumbCount;

  /// The length one breadcrumb line is truncated to.
  final int breadcrumbLineLimit;

  /// Scrubs every exported record, or `null` for none.
  ///
  /// Applied to the message, the title, the error/exception text, the stack
  /// trace and each breadcrumb line, before truncation and before the sink
  /// sees any of it. A [redact] that throws drops the record instead of
  /// letting it through (fail closed).
  final Redactor? redact;

  final TalkerObserver _sink;
  final List<TalkerData> Function() _history;

  /// Set to `true` only on a successful `OTel.initialize`, by
  /// `OtelZone.start`. Nothing is forwarded while it is `false`.
  bool ready = false;

  @override
  void onLog(TalkerData log) => _handle(
    log,
    () => _sink.onLog(log),
    (TalkerData redacted) => _sink.onLog(redacted),
  );

  @override
  void onError(TalkerError err) => _handle(
    err,
    () => _sink.onError(err),
    (TalkerData redacted) => _sink.onError(_errorOf(redacted)),
  );

  @override
  void onException(TalkerException err) => _handle(
    err,
    () => _sink.onException(err),
    (TalkerData redacted) => _sink.onException(_exceptionOf(redacted)),
  );

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

  /// Applies the floor, then forwards the record — redacted when a [redact]
  /// is configured, untouched otherwise.
  ///
  /// [forwardOriginal] and [forwardRedacted] are separate because the sink's
  /// fault channels are typed (`onError`/`onException`), so a scrubbed record
  /// has to be rebuilt as the matching `TalkerError`/`TalkerException`. With
  /// no [redact] the original object goes straight through, so nothing about
  /// the wire changes for a build that does not scrub.
  void _handle(
    TalkerData data,
    void Function() forwardOriginal,
    void Function(TalkerData redacted) forwardRedacted,
  ) {
    if (!carries(data.logLevel)) return;
    // Two separate guarded calls: a trail that cannot be built must never
    // cost the fault it was decorating.
    _forward(() => _emitBreadcrumbs(data));
    final TalkerData? redacted = _redact(data);
    // Fail closed: a redactor that throws drops the record rather than
    // letting unscrubbed text reach the sink.
    if (redacted == null) return;
    _forward(
      identical(redacted, data)
          ? forwardOriginal
          : () => forwardRedacted(redacted),
    );
  }

  /// A copy of [data] with every string field scrubbed on its own, the
  /// original object when there is no [redact], or `null` when the redactor
  /// threw — which drops the record.
  ///
  /// Only ever called for a record that clears the floor, so a build's
  /// scrubbing cost is proportional to what it actually exports.
  TalkerData? _redact(TalkerData data) {
    final Redactor? redact = this.redact;
    if (redact == null) return data;
    try {
      // The two fault fields are scrubbed independently: a record may carry
      // both, and deriving one wrapper from `error ?? exception` would then
      // cast it to the other type and drop the whole record.
      final Error? error = data.error == null
          ? null
          : _RedactedError(
              data.error!.runtimeType.toString(),
              redact(data.error!.toString()),
            );
      final Object? exception = data.exception == null
          ? null
          : _RedactedException(
              data.exception!.runtimeType.toString(),
              redact(data.exception!.toString()),
            );
      final String message = redact(data.message ?? '');
      final String? title = data.title == null ? null : redact(data.title!);
      final StackTrace? stackTrace = data.stackTrace == null
          ? null
          : _RedactedStackTrace(redact(data.stackTrace.toString()));
      if (data is RiverpodFailLog) {
        return _redactedFailLog(data, redact, message: message, title: title);
      }
      return TalkerData(
        message,
        logLevel: data.logLevel,
        error: error,
        exception: exception,
        stackTrace: stackTrace,
        title: title,
        time: data.time,
        key: data.key,
      );
    } on Object {
      return null;
    }
  }

  TalkerError _errorOf(TalkerData redacted) => TalkerError(
    redacted.error!,
    message: redacted.message,
    stackTrace: redacted.stackTrace,
    title: redacted.title,
    logLevel: redacted.logLevel,
  );

  TalkerException _exceptionOf(TalkerData redacted) => TalkerException(
    redacted.exception! as Exception,
    message: redacted.message,
    stackTrace: redacted.stackTrace,
    title: redacted.title,
    logLevel: redacted.logLevel,
  );

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

    final List<String> lines = <String>[];
    for (final TalkerData entry in trail) {
      final String? line = _breadcrumb(entry);
      // Fail closed: one line the redactor cannot scrub drops the whole
      // trail, because a trail is only useful as a set.
      if (line == null) return;
      lines.add(line);
    }

    _sink.onLog(
      TalkerData(
        lines.join('\n'),
        logLevel: level,
        time: data.time,
        title: 'breadcrumbs',
      ),
    );
  }

  /// One breadcrumb line, redacted *before* truncation, or `null` when the
  /// redactor throws.
  ///
  /// Before truncation matters: truncating first would let a redactor miss
  /// the part of a value that the limit cut off.
  String? _breadcrumb(TalkerData entry) {
    final String line =
        '${entry.displayTime()} [${entry.title}] ${entry.message ?? ''}';
    String scrubbed = line;
    final Redactor? redact = this.redact;
    if (redact != null) {
      try {
        scrubbed = redact(line);
      } on Object {
        return null;
      }
    }
    return scrubbed.length <= breadcrumbLineLimit
        ? scrubbed
        : '${scrubbed.substring(0, breadcrumbLineLimit)}…';
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

/// A scrubbed `[riverpod-fail]` record.
///
/// `talker_riverpod_logger`'s `RiverpodFailLog` keeps its error and stack
/// trace in fields of its own, `providerError` and `providerStackTrace`, that
/// exist nowhere on `TalkerData`, and renders them in `generateTextMessage()`,
/// which is what the sink puts on the wire as the body. A plain copy of the
/// base fields therefore sends "xProvider failed" and nothing else, so this
/// keeps the rendering — composed from the pieces, each scrubbed on its own,
/// never by scrubbing one rendered blob (an anchored redactor such as
/// `^\d{9}$` matches a whole value, not a paragraph).
class _RedactedFailLog extends TalkerData {
  _RedactedFailLog(
    super.message, {
    required this.rendered,
    super.logLevel,
    super.title,
    super.time,
    super.key,
  });

  /// The record's rendering, composed from scrubbed parts.
  final String rendered;

  @override
  String generateTextMessage({
    TimeFormat timeFormat = TimeFormat.timeAndSeconds,
  }) => rendered;
}

/// [log] as a [_RedactedFailLog], in the shape `RiverpodFailLog` renders:
/// title and time, the message, `ERROR:` and the error (its type alone when
/// the logger's `printFailFullData` is off), `STACK TRACE:` and the trace.
TalkerData _redactedFailLog(
  RiverpodFailLog log,
  Redactor redact, {
  required String message,
  required String? title,
}) {
  final String error = log.settings.printFailFullData
      ? '\n${redact(log.providerError.toString())}'
      : log.providerError.runtimeType.toString();
  final String stackTrace = redact(log.providerStackTrace.toString());
  return _RedactedFailLog(
    message,
    rendered:
        '[$title] | ${log.displayTime()} | '
        '\n$message'
        '\nERROR: \n$error'
        '\nSTACK TRACE: \n$stackTrace',
    logLevel: log.logLevel,
    title: title,
    time: log.time,
    key: log.key,
  );
}

/// A scrubbed stand-in for an `Error`, carrying only redacted text.
///
/// `OTelTalkerObserver` reads the fault's `runtimeType` for `exception.type`
/// and its `toString()` for `exception.message`. A wrapper cannot report the
/// original `runtimeType`, so [type] is prefixed onto the rendered text
/// instead — the type survives inside `exception.message` rather than being
/// lost with the stringification.
class _RedactedError extends Error {
  _RedactedError(this.type, this.text);

  final String type;
  final String text;

  @override
  String toString() => '$type: $text';
}

/// The `Exception` counterpart of [_RedactedError].
class _RedactedException implements Exception {
  _RedactedException(this.type, this.text);

  final String type;
  final String text;

  @override
  String toString() => '$type: $text';
}

/// A scrubbed stand-in for a [StackTrace], for `exception.stacktrace`.
class _RedactedStackTrace implements StackTrace {
  _RedactedStackTrace(this.text);

  final String text;

  @override
  String toString() => text;
}
