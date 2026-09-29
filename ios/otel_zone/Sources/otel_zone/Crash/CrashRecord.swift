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

/// The version and build of the app that was running, as a crash record names
/// them.
///
/// A record is exported by the *next* launch, under that launch's resource, so
/// after an app update `service.version` and `app.build_id` name the build that
/// reported the crash, not the one that died. These two attributes say which
/// binary died, so symbols are fetched for the right one. The names are the
/// same on every platform (Android writes them too).
enum CrashedBuildAttribute {
  static let serviceVersion = "otel_zone.crashed.service.version"
  static let buildId = "otel_zone.crashed.app.build_id"
}

/// The running app's `CFBundleShortVersionString` and `CFBundleVersion`, read
/// once.
///
/// Either half is `nil` when it is not known, and a `nil` is never replaced by
/// a made-up value: an absent attribute is honest, a wrong one sends someone to
/// symbolicate against another binary.
struct AppBuild: Equatable {
  var version: String?
  var build: String?

  static let unknown = AppBuild(version: nil, build: nil)

  /// From what a bundle's Info.plist says. A blank or non-string entry is
  /// unknown.
  static func read(from bundle: Bundle = .main) -> AppBuild {
    let info = bundle.infoDictionary
    return AppBuild(
      version: clean(info?["CFBundleShortVersionString"]),
      build: clean(info?["CFBundleVersion"]))
  }

  /// The two attributes, only for the halves that are known.
  var attributes: [String: String] {
    var attributes: [String: String] = [:]
    if let version { attributes[CrashedBuildAttribute.serviceVersion] = version }
    if let build { attributes[CrashedBuildAttribute.buildId] = build }
    return attributes
  }

  /// [value] as a non-blank string, or `nil`. Read from JSON or a plist, so
  /// the type is not trusted either.
  static func clean(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasControl = trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    return trimmed.isEmpty || hasControl ? nil : trimmed
  }
}
