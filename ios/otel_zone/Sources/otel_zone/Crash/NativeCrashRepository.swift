import Foundation

/// Everything iOS left behind, as one list.
///
/// Two stores feed it — MetricKit payloads and `NSException` reports — and
/// the reason this type exists is that one crash can be in both. An uncaught
/// exception is written by [NSExceptionSource] as it happens and reported
/// again by MetricKit at some later launch, and `pending()` must return that
/// as one record, not two.
///
/// ## The merge rule
///
/// An `NSException` report and a MetricKit crash diagnostic describe the same
/// crash when both hold:
///
/// 1. **The time fits.** MetricKit gives a crash no timestamp of its own, only
///    its payload's reporting window, so the exception's timestamp has to fall
///    inside `[timeStampBegin - slack, timeStampEnd + slack]`.
/// 2. **The crash could have been that exception.** An uncaught exception ends
///    in `abort()`, so the diagnostic must be `SIGABRT` / `EXC_CRASH`, or carry
///    iOS 17's own Objective-C exception reason. A segfault in the same window
///    is a different crash.
///
/// The match is one-to-one. When several diagnostics qualify, one whose
/// exception name or message agrees wins, then the one nearest in time. The
/// merged record keeps the exception's exact timestamp, name and reason, and
/// its `callStackSymbols` as the stack, since that is where the exception was
/// *thrown* and the abort stack MetricKit holds is only the unwinding. The
/// MetricKit crashing thread, with its binary UUIDs and offsets, is kept as
/// the first entry of `threads`.
///
/// When only one side has arrived — MetricKit is not delivered on a simulator
/// or a dev build, and can lag on iOS 14 — that side is returned alone. A
/// later MetricKit delivery of a crash already returned this way is exported
/// again; a lost crash is worse than a duplicate, and this package cannot
/// know that a diagnostic is coming.
final class NativeCrashRepository {
  /// How far outside a payload's window an exception may fall and still be
  /// matched, for clocks that disagree by a little.
  static let mergeSlack: TimeInterval = 60

  static let metricKitPrefix = "mx"
  static let exceptionPrefix = "ns"
  /// Separates the two ids a merged record answers to.
  static let mergedSeparator: Character = "+"

  private let metricKit: CrashFileStore
  private let exceptions: CrashFileStore
  private let lock = NSLock()

  init(metricKit: CrashFileStore, exceptions: CrashFileStore) {
    self.metricKit = metricKit
    self.exceptions = exceptions
  }

  /// Persists a payload's JSON as delivered, before anything reads it.
  ///
  /// MetricKit can deliver before Dart is up, and it will not deliver twice,
  /// so the raw bytes go to disk first and are only interpreted later. Returns
  /// `false` when there was nothing worth keeping or the write failed; it
  /// never throws, because it runs on MetricKit's callback.
  @discardableResult
  func persist(payload data: Data) -> Bool {
    guard MetricKitPayloadMapper.content(of: data) == .live else { return false }
    lock.lock()
    defer { lock.unlock() }
    do {
      try metricKit.prepareDirectory()
      try metricKit.write(data)
      metricKit.trim()
      return true
    } catch {
      return false
    }
  }

  /// Every unacknowledged report, oldest first.
  func pending() -> [CrashRecord] {
    lock.lock()
    defer { lock.unlock() }
    metricKit.sweepTemps()
    exceptions.sweepTemps()
    metricKit.trim()
    exceptions.trim()

    var diagnostics: [MappedDiagnostic] = []
    for id in metricKit.ids() {
      guard let data = metricKit.read(id: id) else { continue }
      switch MetricKitPayloadMapper.content(of: data) {
      case .unreadable:
        // Left alone: it may be a newer build's format, and the cap will
        // age it out if it never becomes readable.
        continue
      case .empty:
        // Parses but holds nothing to report; removed so it stops counting
        // against the cap.
        metricKit.delete(id: id)
        continue
      case .live:
        break
      }
      let mapped = MetricKitPayloadMapper.map(
        data: data, fileId: id,
        receivedAt: CrashFileStore.timestamp(ofId: id) ?? Date())
      diagnostics.append(contentsOf: mapped)
    }
    let reports = exceptions.ids().compactMap { id in
      exceptions.read(id: id).flatMap { NSExceptionReport.decode(id: id, data: $0) }
    }.sorted { ($0.timestampMicros, $0.id) < ($1.timestampMicros, $1.id) }

    let merged = Self.merge(diagnostics: diagnostics, exceptions: reports)
    return merged.sorted { ($0.timestampMicros, $0.id) < ($1.timestampMicros, $1.id) }
  }

  /// Deletes what [ids] name. Unknown, malformed and unsafe ids are ignored.
  func acknowledge(_ ids: [String]) {
    lock.lock()
    defer { lock.unlock() }
    for id in ids {
      // The ids come from across the channel, so each is checked before it
      // is turned into a path.
      for part in id.split(separator: Self.mergedSeparator, omittingEmptySubsequences: false) {
        let part = String(part)
        guard CrashFileStore.isSafeId(part) else { continue }
        if part.hasPrefix(Self.exceptionPrefix + "-") {
          exceptions.delete(id: part)
        } else if part.hasPrefix(Self.metricKitPrefix + "-") {
          retire(reportId: part)
        }
      }
    }
  }

  // MARK: - Merge

  /// The merge rule, on already-read inputs so a test can drive it directly.
  static func merge(
    diagnostics: [MappedDiagnostic], exceptions: [NSExceptionReport]
  ) -> [CrashRecord] {
    var consumed = Set<Int>()
    var output: [CrashRecord] = []

    for report in exceptions {
      let at = Date(timeIntervalSince1970: TimeInterval(report.timestampMicros) / 1_000_000)
      let candidates = diagnostics.enumerated().filter { index, diagnostic in
        !consumed.contains(index) && diagnostic.isCrash
          && diagnostic.couldBeUncaughtException
          && at >= diagnostic.windowStart.addingTimeInterval(-mergeSlack)
          && at <= diagnostic.windowEnd.addingTimeInterval(mergeSlack)
      }
      let best = candidates.min { lhs, rhs in
        let (l, r) = (agrees(lhs.element, report), agrees(rhs.element, report))
        if l != r { return l }
        let (ld, rd) = (
          abs(lhs.element.record.timestampMicros - report.timestampMicros),
          abs(rhs.element.record.timestampMicros - report.timestampMicros)
        )
        return ld == rd ? lhs.offset < rhs.offset : ld < rd
      }
      if let best {
        consumed.insert(best.offset)
        output.append(combine(best.element, report))
      } else {
        output.append(report.record)
      }
    }
    for (index, diagnostic) in diagnostics.enumerated() where !consumed.contains(index) {
      output.append(diagnostic.record)
    }
    return output
  }

  private static func agrees(_ diagnostic: MappedDiagnostic, _ report: NSExceptionReport)
    -> Bool
  {
    if let name = diagnostic.exceptionName, name == report.name { return true }
    if let message = diagnostic.exceptionMessage, let reason = report.reason,
      !message.isEmpty, message == reason
    {
      return true
    }
    return false
  }

  private static func combine(_ diagnostic: MappedDiagnostic, _ report: NSExceptionReport)
    -> CrashRecord
  {
    var record = diagnostic.record
    record.id = diagnostic.record.id + String(mergedSeparator) + report.id
    record.kind = CrashKind.nsexception
    record.timestampMicros = report.timestampMicros
    record.type = report.name
    record.message = report.reason ?? diagnostic.exceptionMessage ?? record.message
    if !report.symbols.isEmpty { record.stacktrace = report.symbols.joined(separator: "\n") }
    // The abort stack is not the throw site, but it is what carries the binary
    // UUIDs and offsets a symbolicator wants, so it is kept, first.
    var threads: [String] = []
    if let crashed = diagnostic.crashedThread {
      threads.append("Crashed thread (MetricKit):\n" + crashed)
    }
    threads.append(contentsOf: record.threads ?? [])
    record.threads = threads.isEmpty ? nil : threads
    var attributes = record.attributes ?? [:]
    attributes["crash.source"] = "metrickit+nsexception"
    record.attributes = attributes
    return record
  }

  // MARK: - Acknowledge

  /// Marks one crash or hang diagnostic of a stored payload as delivered.
  ///
  /// A payload holds several diagnostics and the file is deleted when the
  /// last one goes. Deleting a diagnostic's entry would shift its siblings'
  /// indexes, and the index is part of the id, so an entry is replaced with
  /// `null` instead and the ids of the rest stay put.
  private func retire(reportId: String) {
    guard let (fileId, key, index) = Self.parse(reportId: reportId),
      let data = metricKit.read(id: fileId),
      var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      var entries = root[key] as? [Any], index < entries.count
    else { return }

    entries[index] = NSNull()
    root[key] = entries
    let live = ["crashDiagnostics", "hangDiagnostics"].contains { key in
      (root[key] as? [Any] ?? []).contains { $0 is [String: Any] }
    }
    if !live {
      metricKit.delete(id: fileId)
      return
    }
    guard let rewritten = try? JSONSerialization.data(withJSONObject: root) else { return }
    try? metricKit.replace(id: fileId, with: rewritten)
  }

  /// `mx-<millis>-<seq>-c<index>` into its file id, array key and index.
  static func parse(reportId: String) -> (fileId: String, key: String, index: Int)? {
    let parts = reportId.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == metricKitPrefix[...], let last = parts.last,
      let marker = last.first, let index = Int(last.dropFirst()), index >= 0
    else { return nil }
    let key: String
    switch marker {
    case "c": key = "crashDiagnostics"
    case "h": key = "hangDiagnostics"
    default: return nil
    }
    return (parts[0..<3].joined(separator: "-"), key, index)
  }
}
