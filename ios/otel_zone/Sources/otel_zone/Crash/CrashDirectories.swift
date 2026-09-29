import Foundation

/// Where iOS crash reports live: `Application Support/otel_zone/`.
///
/// Application Support rather than Caches, because the system may empty a
/// cache at any moment and a report it deletes before Dart has drained it is
/// a crash nobody hears about. Excluded from backup for the reason Android
/// uses `noBackupFilesDir`: a report is a fact about one run of one install,
/// and restoring it onto a new device would file someone else's crash under
/// this one.
struct CrashDirectories {
  let metricKit: URL
  let exceptions: URL

  /// `nil` when the system will not name an Application Support directory.
  /// Capture is then off, not an error: no reports, exactly as before.
  static func standard(fileManager: FileManager = .default) -> CrashDirectories? {
    guard
      let support = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return nil }
    return CrashDirectories(root: support.appendingPathComponent("otel_zone", isDirectory: true))
  }

  init(root: URL) {
    metricKit = root.appendingPathComponent("diagnostics", isDirectory: true)
    exceptions = root.appendingPathComponent("exceptions", isDirectory: true)
    self.root = root
  }

  private let root: URL

  /// Creates the root and marks it out of backup. Best effort: a failure
  /// leaves a directory that is backed up, which is untidy, not wrong.
  func prepare() {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var url = root
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
  }
}
