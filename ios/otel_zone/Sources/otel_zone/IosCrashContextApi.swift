import Foundation

/// The `CrashContextApi` the Dart side talks to: it hands the screen to
/// `CrashScreen.shared`.
///
/// Pigeon calls it on a serial background queue, so a change of screen is
/// written to the run log there, and never on the platform thread.
final class IosCrashContextApi: CrashContextApi {
  func setCrashScreen(screen: String?) throws {
    CrashScreen.shared.set(screen)
  }
}
