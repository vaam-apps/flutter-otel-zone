import Foundation

/// A directory of small JSON files, one per record.
///
/// Files rather than a database because one writer is an uncaught-exception
/// handler in a process that is already dying: the write has to be a single
/// synchronous file write with no transaction to roll back, and it has to
/// survive being killed halfway, which is what the temp file and the rename
/// are for. The same store shape serves MetricKit payloads, which are written
/// from a callback that can fire before Dart is up.
final class CrashFileStore {
  static let fileSuffix = ".json"
  static let tempSuffix = ".tmp"

  /// Long enough that no in-flight write is ever this old.
  static let defaultStaleTempInterval: TimeInterval = 5 * 60

  let directory: URL
  private let prefix: String
  private let maxFiles: Int
  private let now: () -> Date
  private let staleTempInterval: TimeInterval
  private let lock = NSLock()
  private var sequence = 0

  /// - Parameter prefix: leads every id, so an id says which store it came
  ///   from and one store can never be asked to delete the other's files.
  init(
    directory: URL,
    prefix: String,
    maxFiles: Int = 16,
    staleTempInterval: TimeInterval = CrashFileStore.defaultStaleTempInterval,
    now: @escaping () -> Date = Date.init
  ) {
    self.directory = directory
    self.prefix = prefix
    self.maxFiles = maxFiles
    self.staleTempInterval = staleTempInterval
    self.now = now
  }

  /// Ids are the file's own name, so this is also the check that keeps an id
  /// that crossed the channel from being turned into a path outside the
  /// directory: a name is only accepted if this store could have written it.
  static func isSafeId(_ id: String) -> Bool {
    guard !id.isEmpty, id.utf8.count <= 128 else { return false }
    return id.utf8.allSatisfy { byte in
      (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
        || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
    }
  }

  /// Creates the directory. Separate from [write] so the crash handler can
  /// do it once at install time and never again on the way down.
  func prepareDirectory() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
  }

  /// Writes [data] as a new file and returns its id.
  ///
  /// Temp file then `rename(2)`, so a reader never sees half a file. The
  /// directory is not created and the cap is not enforced here — this is the
  /// call a dying process makes, and it does the least it can.
  @discardableResult
  func write(_ data: Data) throws -> String {
    let id = nextId()
    try put(data, id: id)
    return id
  }

  /// Replaces the file for [id], which must already be a safe id.
  func replace(id: String, with data: Data) throws {
    guard Self.isSafeId(id) else { throw CrashStoreError.unsafeId(id) }
    try put(data, id: id)
  }

  /// Every id, oldest first. The name leads with the timestamp, so lexical
  /// order is age order.
  func ids() -> [String] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return
      names
      .filter { $0.hasSuffix(Self.fileSuffix) }
      .map { String($0.dropLast(Self.fileSuffix.count)) }
      .filter(Self.isSafeId)
      .sorted()
  }

  /// The file's bytes, or `nil` when it is gone or unreadable.
  func read(id: String) -> Data? {
    guard Self.isSafeId(id) else { return nil }
    return try? Data(contentsOf: url(for: id))
  }

  /// Deletes the file for [id]. Unknown and unsafe ids are ignored.
  func delete(id: String) {
    guard Self.isSafeId(id) else { return }
    try? FileManager.default.removeItem(at: url(for: id))
  }

  /// Keeps the newest `maxFiles` files.
  func trim() {
    let all = ids()
    guard all.count > maxFiles else { return }
    all.prefix(all.count - maxFiles).forEach(delete(id:))
  }

  /// Deletes temp files that no live write can still own.
  ///
  /// A temp file only outlives its writer when the process died between the
  /// write and the rename, and nothing else looks for a `*.tmp`, so without
  /// this they accumulate for the life of the install. The age check is what
  /// keeps a sweep from destroying a crash in flight: the handler can fire on
  /// any thread while `pending()` runs, and a write in flight is milliseconds
  /// old.
  func sweepTemps() {
    let cutoff = now().addingTimeInterval(-staleTempInterval)
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasSuffix(Self.tempSuffix) {
      let path = directory.appendingPathComponent(name).path
      // An unknown age is not evidence of a dead write, so no date, no delete.
      guard
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[
          .modificationDate] as? Date,
        modified < cutoff
      else { continue }
      try? FileManager.default.removeItem(atPath: path)
    }
  }

  /// When the file for [id] was written, read back out of the id.
  static func timestamp(ofId id: String) -> Date? {
    let parts = id.split(separator: "-")
    guard parts.count >= 2, let millis = Int64(parts[1]) else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
  }

  // MARK: - Private

  private func url(for id: String) -> URL {
    directory.appendingPathComponent(id + Self.fileSuffix)
  }

  /// An id that sorts by age and cannot collide across launches.
  private func nextId() -> String {
    lock.lock()
    defer { lock.unlock() }
    while true {
      let millis = Int64(now().timeIntervalSince1970 * 1000)
      let id = String(format: "%@-%016lld-%04ld", prefix, millis, sequence)
      sequence += 1
      if !FileManager.default.fileExists(atPath: url(for: id).path) { return id }
    }
  }

  private func put(_ data: Data, id: String) throws {
    let target = url(for: id)
    let temp = directory.appendingPathComponent(id + Self.fileSuffix + Self.tempSuffix)
    try data.write(to: temp)
    // `rename` rather than `moveItem`: it replaces an existing target
    // atomically, which `replace(id:with:)` relies on.
    if rename(temp.path, target.path) != 0 {
      let code = errno
      try? FileManager.default.removeItem(at: temp)
      throw CrashStoreError.renameFailed(code)
    }
  }
}

enum CrashStoreError: Error, Equatable {
  case unsafeId(String)
  case renameFailed(Int32)
}
