// The one Dart<->native contract for crash capture.
//
// A native crash kills the Dart VM before Dart can see it, so the platforms
// read the OS's own record of why the process died. This file is the whole
// interface between that record and Dart: the two platform tickets implement
// [NativeCrashApi], and `lib/src/native-crash.dart` consumes it.
//
// Generate with:
//
//     dart run pigeon --input pigeons/native_crash.dart
//
// which writes the Dart client, the Kotlin interface and the Swift protocol.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/native-crash.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/src/main/kotlin/com/vaam/otel_zone/NativeCrashApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.vaam.otel_zone'),
    swiftOut: 'ios/otel_zone/Sources/otel_zone/NativeCrashApi.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'otel_zone',
  ),
)
/// One native death from a previous run, as the OS remembers it.
class NativeCrashReport {
  /// Creates a report. [id] and [kind] are the only fields every platform can
  /// guarantee.
  const NativeCrashReport({
    required this.id,
    required this.kind,
    required this.timestampMicros,
    this.type,
    this.message,
    this.stacktrace,
    this.threads,
    this.sessionId,
    this.attributes,
  });

  /// The platform's own identifier for this record, opaque to Dart. It is
  /// what [NativeCrashApi.acknowledge] takes, and it must be stable across
  /// launches so a report is acknowledged exactly once.
  final String id;

  /// One of `jvm`, `native`, `anr`, `nsexception`, `signal`, `hang`.
  ///
  /// A string rather than an enum so an unknown future value from a newer OS
  /// arrives intact instead of failing the whole call.
  final String kind;

  /// When the process died, in microseconds since the Unix epoch.
  final int timestampMicros;

  /// The platform's classification: the signal name, the exception class, the
  /// exit reason.
  final String? type;

  /// The human-readable reason, where the platform keeps one.
  final String? message;

  /// The stack trace, already symbolised as far as the OS got.
  final String? stacktrace;

  /// Per-thread frames for a crash whose stack is only meaningful per thread.
  final List<String>? threads;

  /// The app session the death happened in, where the OS groups by one.
  final String? sessionId;

  /// Anything else the platform knows, flattened.
  final Map<String, String>? attributes;
}

/// Reads and acknowledges the previous run's native deaths.
@HostApi()
abstract class NativeCrashApi {
  /// Every report the OS holds that has not been acknowledged yet, oldest
  /// first.
  ///
  /// The OS's list cannot be cleared, so the platform side deduplicates by a
  /// persisted watermark; Dart only ever sees the reports that are new to it.
  @async
  List<NativeCrashReport> pending();

  /// Marks [ids] as delivered.
  ///
  /// Called only once the reports are durable, so that an unreachable
  /// collector leaves them to be re-read on the next launch rather than
  /// dropping them.
  @async
  void acknowledge(List<String> ids);
}
