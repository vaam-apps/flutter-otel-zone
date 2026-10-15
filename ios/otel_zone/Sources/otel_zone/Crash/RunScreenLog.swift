import Foundation

/// The screen each run of the app showed, kept so that a MetricKit crash can be
/// given the screen of the run it came from.
///
/// A MetricKit diagnostic names the crashed process's pid and a reporting
/// window, not a run. So each run keeps one small JSON file,
/// `run-<launch millis>-<pid>.json`, holding its pid, its launch time and its
/// last screen, atomically replaced on each change. A diagnostic takes a screen
/// only when exactly one other run matches its pid and window, because a pid is
/// reused and a guess is worse than none.
final class RunScreenLog {
  /// The newest this many run files are kept.
  static let maxFiles = 64
  /// A run file whose launch is older than this is removed.
  static let maxAge: TimeInterval = 7 * 24 * 60 * 60
  /// A payload's window can begin a day before the payload is delivered, so a
  /// run launched that long before the window still belongs to it.
  static let windowLead: TimeInterval = 24 * 60 * 60

  private let directory: URL
  private let pid: Int32
  private let launchedAt: Date
  private let now: () -> Date
  private let file: URL
  private let lock = NSLock()

  /// [pid] and [launchedAt] name this run's file. [now] is the clock the sweep
  /// measures age by; a test moves it.
  init(
    directory: URL,
    pid: Int32 = ProcessInfo.processInfo.processIdentifier,
    launchedAt: Date = Date(),
    now: @escaping () -> Date = Date.init
  ) {
    self.directory = directory
    self.pid = pid
    self.launchedAt = launchedAt
    self.now = now
    let millis = Int64(launchedAt.timeIntervalSince1970 * 1000)
    file = directory.appendingPathComponent(
      String(format: "run-%016lld-%d.json", millis, pid))
  }

  /// Writes this run's screen, `nil` clearing it. Never throws: a run whose
  /// screen cannot be written simply does not name one, as before this existed.
  func record(_ screen: String?) {
    lock.lock()
    defer { lock.unlock() }
    var object: [String: Any] = [
      "pid": Int(pid),
      "launchedAtMicros": Int64(launchedAt.timeIntervalSince1970 * 1_000_000),
    ]
    if let screen = screen {
      object["screen"] = screen
    }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: object)
      try CrashFileStore.atomicWrite(data, to: file)
    } catch {
      // Nothing to report to: the run is then one that named no screen.
    }
  }

  /// Removes runs launched more than [maxAge] ago, then all but the newest
  /// [maxFiles]. Called once, at install. Ages come from the launch time in each
  /// file's name, never from its attributes.
  func sweep() {
    lock.lock()
    defer { lock.unlock() }
    let cutoff = now().addingTimeInterval(-Self.maxAge)
    var kept: [String] = []
    for name in runNames() {
      guard let run = Self.launch(ofName: name) else { continue }
      let launched = Date(timeIntervalSince1970: TimeInterval(run.millis) / 1000)
      if launched < cutoff {
        remove(name)
      } else {
        kept.append(name)
      }
    }
    // Names lead with the launch time, zero-padded, so name order is age order.
    let excess = max(0, kept.count - Self.maxFiles)
    for name in kept.prefix(excess) {
      remove(name)
    }
  }

  /// The screen of the one other run with [pid] that was launched in the window
  /// a crash diagnostic covers, or `nil` when no run or more than one matches,
  /// or the matching run's file is unreadable or names no screen.
  func screen(pid: Int, windowStart: Date, windowEnd: Date) -> String? {
    lock.lock()
    defer { lock.unlock() }
    let low = windowStart.addingTimeInterval(-Self.windowLead)
    let high = windowEnd.addingTimeInterval(NativeCrashRepository.mergeSlack)
    let own = file.lastPathComponent
    let matches = runNames().filter { name in
      guard name != own, let run = Self.launch(ofName: name), Int(run.pid) == pid else {
        return false
      }
      let launched = Date(timeIntervalSince1970: TimeInterval(run.millis) / 1000)
      return launched >= low && launched <= high
    }
    guard matches.count == 1, let name = matches.first else { return nil }
    return readScreen(name)
  }

  // MARK: - Private

  /// The run file names in this directory that this log could have written,
  /// oldest first.
  private func runNames() -> [String] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { Self.launch(ofName: $0) != nil }.sorted()
  }

  private func remove(_ name: String) {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
  }

  /// The screen a run file names, or `nil` when it cannot be read or names none.
  private func readScreen(_ name: String) -> String? {
    let url = directory.appendingPathComponent(name)
    guard
      let data = try? Data(contentsOf: url),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return CrashScreen.clean(json["screen"])
  }

  /// The launch time and pid a run file's name carries, or `nil` for a name
  /// this log does not write.
  static func launch(ofName name: String) -> (millis: Int64, pid: Int32)? {
    guard name.hasPrefix("run-"), name.hasSuffix(".json") else { return nil }
    let body = name.dropFirst(4).dropLast(5)
    let parts = body.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, let millis = Int64(parts[0]), let pid = Int32(parts[1]) else {
      return nil
    }
    return (millis, pid)
  }
}
