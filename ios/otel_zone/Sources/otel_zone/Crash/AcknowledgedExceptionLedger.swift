import Foundation

/// A short memory of the `NSException` reports that were already delivered
/// on their own.
///
/// The handler writes an exception report at crash time, which is always
/// before MetricKit delivers its diagnostic of the same crash, so the report
/// is usually exported and acknowledged first. Without a memory of that, the
/// MetricKit diagnostic arriving a launch or a day later would be exported as
/// a second record of a crash the backend already has. The ledger is that
/// memory: `NativeCrashRepository` matches a late diagnostic against it with
/// the same rule it uses to merge, and tags the diagnostic instead of
/// pretending it is new.
///
/// One small JSON file. Bounded both ways — at most [maxEntries] entries, each
/// forgotten after [timeToLive] (MetricKit delivers within about a day, so a
/// week is generous) — so it can never grow with the life of the install.
///
/// It is a courtesy, never a dependency: every failure degrades to the
/// behaviour before the ledger existed, a duplicate that is not tagged, and
/// nothing here throws.
final class AcknowledgedExceptionLedger {
  struct Entry: Equatable {
    var id: String
    var name: String
    var timestampMicros: Int64
    var acknowledgedAtMillis: Int64
  }

  static let defaultMaxEntries = 32
  static let defaultTimeToLive: TimeInterval = 7 * 24 * 60 * 60

  private let file: URL
  private let maxEntries: Int
  private let timeToLive: TimeInterval
  private let now: () -> Date

  init(
    file: URL,
    maxEntries: Int = AcknowledgedExceptionLedger.defaultMaxEntries,
    timeToLive: TimeInterval = AcknowledgedExceptionLedger.defaultTimeToLive,
    now: @escaping () -> Date = Date.init
  ) {
    self.file = file
    self.maxEntries = maxEntries
    self.timeToLive = timeToLive
    self.now = now
  }

  /// The entries that have not expired, oldest acknowledgement first.
  ///
  /// A missing file is an empty ledger, and so is one that does not parse: a
  /// corrupt ledger must cost the tagging and nothing else. An entry that is
  /// malformed is skipped on its own rather than taking its neighbours down.
  func entries() -> [Entry] {
    guard let data = try? Data(contentsOf: file),
      let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    else { return [] }
    let cutoff = Int64(now().timeIntervalSince1970 * 1000) - Int64(timeToLive * 1000)
    return list.compactMap { item -> Entry? in
      guard let object = item as? [String: Any],
        let id = object["id"] as? String, CrashFileStore.isSafeId(id),
        let name = object["name"] as? String,
        let timestamp = (object["timestampMicros"] as? NSNumber)?.int64Value,
        let acknowledgedAt = (object["acknowledgedAtMillis"] as? NSNumber)?.int64Value,
        acknowledgedAt >= cutoff
      else { return nil }
      return Entry(
        id: id, name: name, timestampMicros: timestamp, acknowledgedAtMillis: acknowledgedAt)
    }.sorted { ($0.acknowledgedAtMillis, $0.id) < ($1.acknowledgedAtMillis, $1.id) }
  }

  /// Remembers one delivered exception report. Returns `false` when the
  /// ledger could not be written, which the caller is free to ignore.
  @discardableResult
  func record(id: String, name: String, timestampMicros: Int64) -> Bool {
    var kept = entries().filter { $0.id != id }
    kept.append(
      Entry(
        id: id, name: name, timestampMicros: timestampMicros,
        acknowledgedAtMillis: Int64(now().timeIntervalSince1970 * 1000)))
    return write(Array(kept.suffix(maxEntries)))
  }

  /// Forgets one entry, once the late diagnostic it explained is delivered.
  @discardableResult
  func remove(id: String) -> Bool {
    let all = entries()
    let kept = all.filter { $0.id != id }
    guard kept.count != all.count else { return true }
    return write(kept)
  }

  private func write(_ entries: [Entry]) -> Bool {
    let list = entries.map { entry -> [String: Any] in
      [
        "id": entry.id, "name": entry.name, "timestampMicros": entry.timestampMicros,
        "acknowledgedAtMillis": entry.acknowledgedAtMillis,
      ]
    }
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try CrashFileStore.atomicWrite(try JSONSerialization.data(withJSONObject: list), to: file)
      return true
    } catch {
      return false
    }
  }
}
