import Foundation

/// Keeps the one thing MetricKit lacks before iOS 17: the reason an
/// Objective-C exception was raised.
///
/// A chained `NSSetUncaughtExceptionHandler`, not a signal handler. It runs
/// on the throwing thread while the exception is still an ordinary Objective-C
/// object, so there is no async-signal-safety rule to break, and it cannot
/// fight the debugger or another reporter for `SIGABRT`. POSIX signals stay
/// MetricKit's job.
///
/// Everything the handler needs is fixed at install time, because it runs in
/// a process that is about to abort. It does one small synchronous file write
/// and returns.
enum NSExceptionSource {
  /// What the handler keeps. Bounded, so one exception with a very deep stack
  /// is still one small file.
  static let maxSymbols = 128
  static let maxReasonLength = 8 * 1024

  /// State the `@convention(c)` handler reads. A C function pointer cannot
  /// capture anything, so it lives here, and it is written once, before the
  /// handler is installed and never after.
  private static var store: CrashFileStore?
  private static var previous: NSUncaughtExceptionHandler?
  private static var installed = false
  private static let installLock = NSLock()

  /// Installs the handler in front of whatever is installed now.
  ///
  /// Idempotent: `register(with:)` runs once per Flutter engine, and a second
  /// install would chain the handler to itself and write every report twice.
  /// Never throws — a store that cannot be prepared means no reports, and the
  /// app carries on exactly as it would without this package.
  static func install(store: CrashFileStore) {
    installLock.lock()
    defer { installLock.unlock() }
    guard !installed else { return }

    // The directory is made now so the handler never has to. A failure here
    // is not fatal: the handler's own write will fail the same way, quietly.
    try? store.prepareDirectory()
    store.sweepTemps()

    self.store = store
    self.previous = NSGetUncaughtExceptionHandler()
    installed = true
    NSSetUncaughtExceptionHandler { exception in
      NSExceptionSource.handle(exception)
    }
  }

  /// Removes the handler and forgets the store. For tests.
  ///
  /// It clears the process's handler rather than restoring `previous`: Swift
  /// will only form a C function pointer from a literal closure, not from a
  /// stored one. A test that wants a previous handler installs its own literal
  /// before calling `install`, so it has nothing to restore.
  static func uninstallForTesting() {
    installLock.lock()
    defer { installLock.unlock() }
    guard installed else { return }
    NSSetUncaughtExceptionHandler(nil)
    store = nil
    previous = nil
    installed = false
  }

  /// The handler body. `internal` so a test can call the installed handler
  /// without raising a real exception, which would abort the test process.
  static func handle(_ exception: NSException) {
    // The write is best effort and the chain is not. Whatever went wrong, the
    // previous handler still runs, and the process still dies the way it
    // would have — a changed crash UX is worse than a lost report.
    if let store {
      do {
        try store.write(encode(exception))
      } catch {
        // Nowhere to report a failure to: the process is aborting.
      }
    }
    previous?(exception)
  }

  static func encode(_ exception: NSException, now: Date = Date()) throws -> Data {
    let symbols = exception.callStackSymbols.prefix(maxSymbols)
    let object: [String: Any] = [
      "name": exception.name.rawValue,
      "reason": String((exception.reason ?? "").prefix(maxReasonLength)),
      "callStackSymbols": Array(symbols),
      "timestampMicros": Int64(now.timeIntervalSince1970 * 1_000_000),
    ]
    return try JSONSerialization.data(withJSONObject: object)
  }
}

/// One uncaught `NSException`, as [NSExceptionSource] wrote it.
struct NSExceptionReport: Equatable {
  var id: String
  var name: String
  var reason: String?
  var symbols: [String]
  var timestampMicros: Int64

  /// The report in [data], or `nil` when this build cannot read it.
  static func decode(id: String, data: Data) -> NSExceptionReport? {
    guard
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let name = json["name"] as? String,
      let timestamp = (json["timestampMicros"] as? NSNumber)?.int64Value
    else { return nil }
    return NSExceptionReport(
      id: id,
      name: name,
      reason: json["reason"] as? String,
      symbols: (json["callStackSymbols"] as? [Any])?.compactMap { $0 as? String } ?? [],
      timestampMicros: timestamp)
  }

  var record: CrashRecord {
    CrashRecord(
      id: id,
      kind: CrashKind.nsexception,
      timestampMicros: timestampMicros,
      type: name,
      message: reason,
      stacktrace: symbols.isEmpty ? nil : symbols.joined(separator: "\n"),
      threads: nil,
      sessionId: nil,
      attributes: ["crash.source": "nsexception"])
  }
}
