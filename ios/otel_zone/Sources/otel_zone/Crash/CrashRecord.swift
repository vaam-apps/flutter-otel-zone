import Foundation

/// One native death, in the shape `NativeCrashReport` has on the wire.
///
/// A separate struct rather than the Pigeon class because everything under
/// `Crash/` has to build without Flutter: `swift test` runs on a plain macOS
/// toolchain, and the generated `NativeCrashApi.g.swift` imports the Flutter
/// framework. `IosNativeCrashApi` is the one place the two meet.
struct CrashRecord: Equatable {
  var id: String
  var kind: String
  var timestampMicros: Int64
  var type: String?
  var message: String?
  var stacktrace: String?
  var threads: [String]?
  var sessionId: String?
  var attributes: [String: String]?
}

/// The `kind` strings this side of the contract produces.
enum CrashKind {
  static let nsexception = "nsexception"
  static let signal = "signal"
  static let hang = "hang"
}
