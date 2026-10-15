import Foundation

/// The screen the app is showing, as this process keeps it, for the crash
/// records that name one.
///
/// [set] runs on the Pigeon background queue. The `NSException` handler reads
/// [current] on the throwing thread, in a process that is about to abort, so
/// the read is one lock and one copy of a string, never I/O. The run log is
/// written after the lock is released, so no lock is held across a file write.
final class CrashScreen {
  /// The attribute a crash record carries the screen in.
  static let attribute = "otel_zone.crashed.screen"
  /// The longest screen kept, in UTF-8 bytes.
  static let maxBytes = 64
  /// The process's screen. The plugin attaches its run log to it once.
  static let shared = CrashScreen()

  private let lock = NSLock()
  private var value: String?
  private var log: RunScreenLog?

  /// Internal so a test can make its own. The app uses [shared].
  init() {}

  /// The screen this process shows, or `nil` when it has named none.
  var current: String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  /// Connects the run log that a change of screen is written to.
  func attach(_ log: RunScreenLog) {
    lock.lock()
    defer { lock.unlock() }
    self.log = log
  }

  /// Keeps [screen], once cleaned, and records a change of it in the run log.
  /// An unchanged screen is not written again.
  func set(_ screen: String?) {
    let cleaned = Self.clean(screen)
    lock.lock()
    let changed = cleaned != value
    value = cleaned
    let target = log
    lock.unlock()
    if changed { target?.record(cleaned) }
  }

  /// [value] as a screen: a string, trimmed, not empty, at most [maxBytes] in
  /// UTF-8 and with no control character. Anything else is `nil`, and a screen
  /// is never cut to fit, because a cut route names the wrong screen.
  static func clean(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= maxBytes else { return nil }
    let hasControl = trimmed.unicodeScalars.contains { scalar in
      scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }
    return hasControl ? nil : trimmed
  }
}
