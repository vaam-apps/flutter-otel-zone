import Foundation

/// One crash or hang diagnostic, mapped, with what the merge needs to decide
/// whether an `NSException` report describes the same death.
struct MappedDiagnostic {
  var record: CrashRecord
  var isCrash: Bool
  /// The payload's reporting window. A crash diagnostic has no timestamp of
  /// its own — MetricKit only says the crash fell somewhere in the window.
  var windowStart: Date
  var windowEnd: Date
  /// `true` when this crash could be an uncaught `NSException`: an uncaught
  /// exception ends in `abort()`, so it is `SIGABRT` / `EXC_CRASH`, unless
  /// iOS 17's own exception reason says so outright.
  var couldBeUncaughtException: Bool
  var exceptionName: String?
  var exceptionMessage: String?
  /// The crashing thread's frames, kept apart from `record.stacktrace` so
  /// the merge can replace the stack with the throw site and still keep this.
  var crashedThread: String?
}

/// Maps the JSON of an `MXDiagnosticPayload` (`jsonRepresentation()`) to
/// [CrashRecord]s.
///
/// It takes JSON, not `MXDiagnosticPayload`, on purpose. The payload class
/// cannot be built outside MetricKit, and a simulator never produces one, so
/// the only thing a test can feed is the JSON — and the JSON is also what is
/// stored on disk, so this is the code path a real report takes.
///
/// Every read is defensive. The format is Apple's, it has changed between iOS
/// versions, and a field that is missing, has a new type, or is new altogether
/// must cost a field, never the report and never the process.
enum MetricKitPayloadMapper {
  static let maxFramesPerStack = 256
  static let maxThreads = 32
  static let maxUnknownAttributes = 32
  static let maxAttributeLength = 2048

  /// The stable id of the `index`-th crash diagnostic of the file `fileId`.
  static func crashId(fileId: String, index: Int) -> String { "\(fileId)-c\(index)" }
  /// The stable id of the `index`-th hang diagnostic of the file `fileId`.
  static func hangId(fileId: String, index: Int) -> String { "\(fileId)-h\(index)" }

  /// Every crash and hang diagnostic in [data], or an empty list when [data]
  /// is not a payload this build can read.
  ///
  /// [receivedAt] is when the payload reached the device. It stands in for a
  /// window the payload does not state, so a missing or reformatted
  /// `timeStampEnd` still orders the report.
  static func map(data: Data, fileId: String, receivedAt: Date) -> [MappedDiagnostic] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return []
    }
    let end = date(root["timeStampEnd"]) ?? receivedAt
    // A day is MetricKit's own batching period, so it is the widest window a
    // payload with no stated start can honestly claim.
    let start = date(root["timeStampBegin"]) ?? end.addingTimeInterval(-24 * 60 * 60)

    var mapped: [MappedDiagnostic] = []
    // `NSNull` placeholders (see `MetricKitPayloadRetirement`) and anything
    // else that is not an object are skipped, and the index still counts them
    // so an id never moves when a sibling is acknowledged.
    for (index, entry) in array(root["crashDiagnostics"]).enumerated() {
      guard let crash = entry as? [String: Any] else { continue }
      mapped.append(
        mapCrash(
          crash, id: crashId(fileId: fileId, index: index), start: start, end: end))
    }
    for (index, entry) in array(root["hangDiagnostics"]).enumerated() {
      guard let hang = entry as? [String: Any] else { continue }
      mapped.append(
        mapHang(hang, id: hangId(fileId: fileId, index: index), start: start, end: end))
    }
    return mapped
  }

  /// Whether [data] is a payload, and whether it still has anything to report.
  enum Content { case unreadable, empty, live }

  /// `unreadable` when [data] is not a JSON object this build can parse,
  /// `empty` when it parses but no crash or hang entry is left in it, `live`
  /// otherwise. The difference matters to the store: an empty payload is
  /// garbage to delete, an unreadable one may be a newer build's format.
  static func content(of data: Data) -> Content {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return .unreadable
    }
    let live = ["crashDiagnostics", "hangDiagnostics"].contains { key in
      array(root[key]).contains { $0 is [String: Any] }
    }
    return live ? .live : .empty
  }

  // MARK: - Crash

  private static func mapCrash(
    _ crash: [String: Any], id: String, start: Date, end: Date
  ) -> MappedDiagnostic {
    let meta = crash["diagnosticMetaData"] as? [String: Any] ?? [:]

    let signal = int(meta["signal"])
    let exceptionType = int(meta["exceptionType"])
    let terminationReason = string(meta["terminationReason"])
    let reason = objectiveCReason(meta)

    var attributes: [String: String] = ["crash.source": "metrickit"]
    if let signal {
      attributes["crash.signal"] = String(signal)
      if let name = signalNames[signal] { attributes["crash.signal_name"] = name }
    }
    if let exceptionType {
      attributes["crash.exception_type"] = String(exceptionType)
      if let name = exceptionTypeNames[exceptionType] {
        attributes["crash.exception_type_name"] = name
      }
    }
    if let code = string(meta["exceptionCode"]) { attributes["crash.exception_code"] = code }
    if let terminationReason { attributes["crash.termination_reason"] = terminationReason }
    if let region = string(meta["virtualMemoryRegionInfo"]) {
      attributes["crash.vm_region_info"] = region
    }
    if let className = reason?.className { attributes["exception.class"] = className }
    addCommonAttributes(meta, known: knownCrashKeys, to: &attributes)

    let stacks = callStacks(crash["callStackTree"])
    let crashed = stacks.first(where: \.attributed).map { render($0.frames) }
    let others = stacks.enumerated()
      .filter { !$0.element.attributed }
      .prefix(maxThreads)
      .map { "Thread \($0.offset):\n" + render($0.element.frames) }

    let isAbort = signal == 6 || (signal == nil && exceptionType == 10)
    let kind = reason != nil ? CrashKind.nsexception : CrashKind.signal
    let type: String?
    if let name = reason?.name {
      type = name
    } else if let signal, let name = signalNames[signal] {
      type = name
    } else if let exceptionType, let name = exceptionTypeNames[exceptionType] {
      type = name
    } else {
      type = nil
    }

    let record = CrashRecord(
      id: id,
      kind: kind,
      timestampMicros: micros(end),
      type: type ?? "crash",
      message: reason?.message ?? terminationReason,
      stacktrace: crashed,
      threads: others.isEmpty ? nil : Array(others),
      sessionId: nil,
      attributes: attributes)

    return MappedDiagnostic(
      record: record,
      isCrash: true,
      windowStart: start,
      windowEnd: end,
      couldBeUncaughtException: reason != nil || isAbort,
      exceptionName: reason?.name,
      exceptionMessage: reason?.message,
      crashedThread: crashed)
  }

  // MARK: - Hang

  private static func mapHang(
    _ hang: [String: Any], id: String, start: Date, end: Date
  ) -> MappedDiagnostic {
    let meta = hang["diagnosticMetaData"] as? [String: Any] ?? [:]
    var attributes: [String: String] = ["crash.source": "metrickit"]
    let duration = string(meta["hangDuration"])
    if let duration { attributes["hang.duration"] = duration }
    addCommonAttributes(meta, known: knownHangKeys, to: &attributes)

    let stacks = callStacks(hang["callStackTree"])
    // A hang is sampled, so the tree branches; the attributed thread is the
    // one that was blocked, and `render` follows its heaviest path.
    let blocked = stacks.first(where: \.attributed).map { render($0.frames) }
    let others = stacks.enumerated()
      .filter { !$0.element.attributed }
      .prefix(maxThreads)
      .map { "Thread \($0.offset):\n" + render($0.element.frames) }

    let record = CrashRecord(
      id: id,
      kind: CrashKind.hang,
      timestampMicros: micros(end),
      type: "hang",
      message: duration.map { "Main thread unresponsive for \($0)" } ?? "Main thread hang",
      stacktrace: blocked,
      threads: others.isEmpty ? nil : Array(others),
      sessionId: nil,
      attributes: attributes)

    return MappedDiagnostic(
      record: record,
      isCrash: false,
      windowStart: start,
      windowEnd: end,
      couldBeUncaughtException: false,
      exceptionName: nil,
      exceptionMessage: nil,
      crashedThread: blocked)
  }

  // MARK: - Metadata

  /// Keys the mapper reads by name; everything else becomes an attribute.
  private static let knownCrashKeys: Set<String> = [
    "signal", "exceptionType", "exceptionCode", "terminationReason",
    "virtualMemoryRegionInfo", "objectiveCexceptionReason", "objectiveCExceptionReason",
    "exceptionReason",
  ]
  private static let knownHangKeys: Set<String> = ["hangDuration"]

  /// The device and app context both diagnostic kinds carry, plus every
  /// scalar this build has never heard of.
  ///
  /// Unknown keys are kept rather than dropped: the format drifts across iOS
  /// versions, and a field Apple adds is more likely useful to whoever reads
  /// the report than harmful. They are capped, and only scalars are taken, so
  /// a new nested object cannot balloon a report.
  private static func addCommonAttributes(
    _ meta: [String: Any], known: Set<String>, to attributes: inout [String: String]
  ) {
    let named: [String: String] = [
      // The same two names the Android and NSException paths use, and only
      // those: the earlier `metrickit.app_*` copies carried the same value
      // under a second, platform-specific name, and two names for one fact is
      // how they drift apart.
      "appVersion": CrashedBuildAttribute.serviceVersion,
      "appBuildVersion": CrashedBuildAttribute.buildId,
      "osVersion": "metrickit.os_version",
      "deviceType": "metrickit.device_type",
      "platformArchitecture": "metrickit.platform_architecture",
      "regionFormat": "metrickit.region_format",
      "bundleIdentifier": "metrickit.bundle_id",
    ]
    for (key, name) in named {
      // A blank build is unknown, not an empty attribute.
      if let value = string(meta[key]),
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        attributes[name] = cap(value)
      }
    }
    var extras = 0
    for key in meta.keys.sorted() where !known.contains(key) && named[key] == nil {
      guard extras < maxUnknownAttributes, let value = string(meta[key]) else { continue }
      attributes["metrickit.meta.\(key)"] = cap(value)
      extras += 1
    }
    for (key, value) in attributes { attributes[key] = cap(value) }
  }

  /// iOS 17's `exceptionReason`. Read from the JSON rather than through
  /// `MXCrashDiagnostic.exceptionReason`, so there is no `#available` to get
  /// wrong here and an older payload simply has no such key.
  private static func objectiveCReason(_ meta: [String: Any]) -> ExceptionReason? {
    let raw =
      (meta["objectiveCexceptionReason"] ?? meta["objectiveCExceptionReason"]
      ?? meta["exceptionReason"]) as? [String: Any]
    guard let raw else { return nil }
    let name = string(raw["exceptionName"]) ?? string(raw["exceptionType"])
    let message = string(raw["composedMessage"]) ?? string(raw["message"])
    let className = string(raw["className"])
    if name == nil && message == nil && className == nil { return nil }
    return ExceptionReason(name: name, message: message, className: className)
  }

  private struct ExceptionReason {
    var name: String?
    var message: String?
    var className: String?
  }

  // MARK: - Call stacks

  private struct Stack {
    var attributed: Bool
    var frames: [Frame]
  }

  private struct Frame {
    var binaryName: String?
    var binaryUUID: String?
    var address: UInt64?
    var offset: UInt64?
  }

  private static func callStacks(_ tree: Any?) -> [Stack] {
    var holder = tree as? [String: Any]
    // Apple's documented example of `MXCallStackTree.jsonRepresentation()`
    // wraps the tree in a `callStackTree` key, and a diagnostic's own
    // `callStackTree` holds the tree directly. Both shapes are read, so
    // neither reading of the docs costs a stack.
    if let inner = holder?["callStackTree"] as? [String: Any] { holder = inner }
    return array(holder?["callStacks"]).compactMap { entry in
      guard let stack = entry as? [String: Any] else { return nil }
      return Stack(
        attributed: (stack["threadAttributed"] as? Bool) ?? false,
        frames: heaviestPath(array(stack["callStackRootFrames"])))
    }
  }

  /// Root-to-leaf frames along the heaviest branch.
  ///
  /// MetricKit stores a stack as a tree with the outermost frame (`start`) at
  /// the root and the innermost at the leaf. A crash has one path. A hang is
  /// sampled, so it branches, and the path with the most samples is where the
  /// thread actually spent the time. Iterative and depth-capped: this is
  /// external input, and a recursion depth of an attacker's choosing is not
  /// something a crash reporter should have.
  private static func heaviestPath(_ roots: [Any]) -> [Frame] {
    var path: [Frame] = []
    var level = roots
    while path.count < maxFramesPerStack {
      let objects = level.compactMap { $0 as? [String: Any] }
      guard
        let heaviest = objects.enumerated().max(by: { lhs, rhs in
          let (l, r) = (int(lhs.element["sampleCount"]) ?? 1, int(rhs.element["sampleCount"]) ?? 1)
          // Ties go to the earlier sibling.
          return l == r ? lhs.offset > rhs.offset : l < r
        })?.element
      else { break }
      path.append(
        Frame(
          binaryName: string(heaviest["binaryName"]),
          binaryUUID: string(heaviest["binaryUUID"]),
          address: uint64(heaviest["address"]),
          offset: uint64(heaviest["offsetIntoBinaryTextSegment"])))
      level = array(heaviest["subFrames"])
    }
    return path
  }

  /// Innermost frame first, the order every other stack trace uses.
  ///
  /// Each line carries the binary's UUID and the offset into its text
  /// segment, because that pair is what a symbolicator needs and MetricKit
  /// does not symbolicate. Symbolication itself is out of scope here.
  private static func render(_ frames: [Frame]) -> String {
    frames.reversed().enumerated().map { index, frame in
      var line = "#\(index) \(frame.binaryName ?? "?")"
      if let address = frame.address { line += " 0x" + String(address, radix: 16) }
      if let uuid = frame.binaryUUID { line += " (\(uuid))" }
      if let offset = frame.offset { line += " +\(offset)" }
      return line
    }.joined(separator: "\n")
  }

  // MARK: - Names

  static let signalNames: [Int: String] = [
    1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
    7: "SIGEMT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS",
    13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
  ]

  static let exceptionTypeNames: [Int: String] = [
    1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
    5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL",
    9: "EXC_RPC_ALERT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD",
    13: "EXC_CORPSE_NOTIFY",
  ]

  // MARK: - Loose JSON reads

  static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }

  private static func int(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber where !isBool(number): return number.intValue
    case let text as String: return Int(text)
    default: return nil
    }
  }

  private static func uint64(_ value: Any?) -> UInt64? {
    switch value {
    case let number as NSNumber where !isBool(number): return number.uint64Value
    case let text as String:
      if text.hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
      return UInt64(text)
    default: return nil
    }
  }

  /// A scalar as text, or `nil` for anything nested or absent.
  private static func string(_ value: Any?) -> String? {
    switch value {
    case let text as String: return text
    case let number as NSNumber:
      return isBool(number) ? (number.boolValue ? "true" : "false") : number.stringValue
    default: return nil
    }
  }

  private static func isBool(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func cap(_ value: String) -> String {
    value.count <= maxAttributeLength ? value : String(value.prefix(maxAttributeLength))
  }

  private static func micros(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1_000_000)
  }

  // MARK: - Dates

  /// The payload window's timestamps. Apple documents `timeStampBegin` and
  /// `timeStampEnd` as properties but not their JSON format, so several are
  /// tried and a string none of them reads becomes `nil`, not a wrong time.
  private static func date(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    if let date = isoFormatter.date(from: text) { return date }
    if let date = isoFractionalFormatter.date(from: text) { return date }
    for formatter in plainFormatters {
      if let date = formatter.date(from: text) { return date }
    }
    return nil
  }

  private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

  private static let isoFractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let plainFormatters: [DateFormatter] = [
    "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss",
  ].map { format in
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter
  }
}
