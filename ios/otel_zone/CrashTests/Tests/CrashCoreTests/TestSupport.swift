import Foundation
import XCTest

@testable import CrashCore

/// A fixture payload, as MetricKit's `jsonRepresentation()` would have
/// produced it.
func fixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
  guard
    let url = Bundle.module.url(
      forResource: name, withExtension: "json", subdirectory: "Fixtures"),
    let data = try? Data(contentsOf: url)
  else {
    XCTFail("missing fixture \(name)", file: file, line: line)
    return Data()
  }
  return data
}

func makeTempDirectory() -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("otel-zone-\(UUID().uuidString)", isDirectory: true)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A clock a test moves by hand. Store ids embed the time, so a fixed clock
/// with the store's own sequence number is what makes ids predictable.
final class TestClock {
  var now: Date
  init(_ now: Date = Date(timeIntervalSince1970: 1_790_600_000)) { self.now = now }
  func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Both stores in a throwaway directory.
struct Harness {
  let root: URL
  let clock: TestClock
  let metricKit: CrashFileStore
  let exceptions: CrashFileStore
  let repository: NativeCrashRepository

  init(maxFiles: Int = 16, clock: TestClock = TestClock()) {
    root = makeTempDirectory()
    self.clock = clock
    metricKit = CrashFileStore(
      directory: root.appendingPathComponent("diagnostics"), prefix: "mx",
      maxFiles: maxFiles, staleTempInterval: 60, now: { clock.now })
    exceptions = CrashFileStore(
      directory: root.appendingPathComponent("exceptions"), prefix: "ns",
      maxFiles: maxFiles, staleTempInterval: 60, now: { clock.now })
    try! metricKit.prepareDirectory()
    try! exceptions.prepareDirectory()
    repository = NativeCrashRepository(metricKit: metricKit, exceptions: exceptions)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }

  /// Writes an `NSException` report the way the handler does, at [unixSeconds].
  @discardableResult
  func writeException(
    name: String = "NSRangeException", reason: String? = "x",
    symbols: [String] = ["0 App 0x1 main"],
    at unixSeconds: TimeInterval
  ) -> String {
    let exception = NSException(name: NSExceptionName(name), reason: reason, userInfo: nil)
    let data = try! NSExceptionSource.encode(
      exception, now: Date(timeIntervalSince1970: unixSeconds))
    // `encode` reads callStackSymbols, which is empty for an exception that
    // was never raised, so the symbols are patched in.
    var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    json["callStackSymbols"] = symbols
    return try! exceptions.write(try! JSONSerialization.data(withJSONObject: json))
  }
}
