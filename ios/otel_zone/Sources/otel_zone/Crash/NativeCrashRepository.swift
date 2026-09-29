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
/// or a dev build, and can lag on iOS 14 — that side is returned alone.
///
/// ## The late diagnostic
///
/// The exception report is written at crash time, so it is always the first
/// to exist, and it is usually exported and acknowledged alone before MetricKit
/// delivers the diagnostic of the same crash. Acknowledging a report that was
/// *not* merged therefore records it (id, name, timestamp) in an
/// [AcknowledgedExceptionLedger]. A crash diagnostic that no live exception
/// report claimed is then matched against the ledger by the same rule, and on
/// a match it is **still returned**, tagged `otel_zone.duplicate_of` (the
/// exception report's id) and `otel_zone.late_metrickit` (`true`).
///
/// Tagged rather than dropped because the diagnostic's frames are the ones with
/// binary UUIDs and offsets — the symbolicatable ones — and a backend can
/// collapse a tagged record, where a dropped one is simply gone. Acknowledging
/// the tagged report forgets the ledger entry it explained.
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
  private let ledger: AcknowledgedExceptionLedger
  private let lock = NSLock()

  init(
    metricKit: CrashFileStore, exceptions: CrashFileStore, ledger: AcknowledgedExceptionLedger
  ) {
    self.metricKit = metricKit
    self.exceptions = exceptions
    self.ledger = ledger
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

    let merged = Self.merge(
      diagnostics: diagnostics, exceptions: reports,
      acknowledged: ledger.entries().map(\.asReport))
    return merged.sorted { ($0.timestampMicros, $0.id) < ($1.timestampMicros, $1.id) }
  }

  /// Deletes what [ids] name. Unknown, malformed and unsafe ids are ignored.
  func acknowledge(_ ids: [String]) {
    lock.lock()
    defer { lock.unlock() }
    for id in ids {
      // The ids come from across the channel, so each is checked before it
      // is turned into a path.
      let parts = id.split(separator: Self.mergedSeparator, omittingEmptySubsequences: false)
        .map(String.init)
      // A merged id names two files that are one crash; only a report that
      // went out on its own can be followed by a late diagnostic.
      let standalone = parts.count == 1
      for part in parts {
        guard CrashFileStore.isSafeId(part) else { continue }
        if part.hasPrefix(Self.exceptionPrefix + "-") {
          if standalone { remember(exceptionId: part) }
          exceptions.delete(id: part)
        } else if part.hasPrefix(Self.metricKitPrefix + "-") {
          if standalone { forgetLedgerEntry(explainedBy: part) }
          retire(reportId: part)
        }
      }
    }
  }

  /// Records an exception report that is about to be deleted unmerged.
  private func remember(exceptionId id: String) {
    guard let data = exceptions.read(id: id),
      let report = NSExceptionReport.decode(id: id, data: data)
    else { return }
    ledger.record(id: id, name: report.name, timestampMicros: report.timestampMicros)
  }

  /// Forgets the ledger entry a delivered late diagnostic was tagged with.
  private func forgetLedgerEntry(explainedBy reportId: String) {
    guard let (fileId, _, _) = Self.parse(reportId: reportId),
      let data = metricKit.read(id: fileId)
    else { return }
    let diagnostics = MetricKitPayloadMapper.map(
      data: data, fileId: fileId, receivedAt: CrashFileStore.timestamp(ofId: fileId) ?? Date())
    guard let index = diagnostics.firstIndex(where: { $0.record.id == reportId }) else { return }
    let entries = ledger.entries().map(\.asReport)
    let claimed = Self.match(entries, to: diagnostics, consumed: [])
    if let entry = claimed.first(where: { $0.diagnostic == index }) {
      ledger.remove(id: entry.report.id)
    }
  }

  // MARK: - Merge

  /// The merge rule, on already-read inputs so a test can drive it directly.
  static func merge(
    diagnostics: [MappedDiagnostic], exceptions: [NSExceptionReport],
    acknowledged: [NSExceptionReport] = []
  ) -> [CrashRecord] {
    var consumed = Set<Int>()
    var output: [CrashRecord] = []

    let merged = match(exceptions, to: diagnostics, consumed: consumed)
    for report in exceptions {
      if let pair = merged.first(where: { $0.report.id == report.id }) {
        consumed.insert(pair.diagnostic)
        output.append(combine(diagnostics[pair.diagnostic], report))
      } else {
        output.append(report.record)
      }
    }

    // Diagnostics no live report claimed may still be the late arrival of a
    // crash that was delivered on its own. Matched second, so a live report
    // always wins a diagnostic over a remembered one.
    var duplicateOf: [Int: String] = [:]
    for pair in match(acknowledged, to: diagnostics, consumed: consumed) {
      consumed.insert(pair.diagnostic)
      duplicateOf[pair.diagnostic] = pair.report.id
    }
    for (index, diagnostic) in diagnostics.enumerated() {
      if merged.contains(where: { $0.diagnostic == index }) { continue }
      var record = diagnostic.record
      if let original = duplicateOf[index] {
        var attributes = record.attributes ?? [:]
        attributes[duplicateOfAttribute] = original
        attributes[lateMetricKitAttribute] = "true"
        record.attributes = attributes
      }
      output.append(record)
    }
    return output
  }

  /// Attributes on a MetricKit report whose crash was already delivered from
  /// its `NSException` report, so a backend can collapse the two.
  static let duplicateOfAttribute = "otel_zone.duplicate_of"
  static let lateMetricKitAttribute = "otel_zone.late_metrickit"

  /// One-to-one pairs of a report with the crash diagnostic that describes it,
  /// oldest report first, skipping diagnostics already in [consumed].
  static func match(
    _ reports: [NSExceptionReport], to diagnostics: [MappedDiagnostic], consumed: Set<Int>
  ) -> [(report: NSExceptionReport, diagnostic: Int)] {
    var taken = consumed
    var pairs: [(report: NSExceptionReport, diagnostic: Int)] = []
    for report in reports.sorted(by: { ($0.timestampMicros, $0.id) < ($1.timestampMicros, $1.id) })
    {
      let at = Date(timeIntervalSince1970: TimeInterval(report.timestampMicros) / 1_000_000)
      let candidates = diagnostics.enumerated().filter { index, diagnostic in
        !taken.contains(index) && diagnostic.isCrash
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
        taken.insert(best.offset)
        pairs.append((report, best.offset))
      }
    }
    return pairs
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

extension AcknowledgedExceptionLedger.Entry {
  /// A ledger entry as the report the match rule takes. It has no reason or
  /// stack — the ledger keeps a name and a time — so only the time and the
  /// name can count towards a match.
  fileprivate var asReport: NSExceptionReport {
    NSExceptionReport(
      id: id, name: name, reason: nil, symbols: [], timestampMicros: timestampMicros)
  }
}
