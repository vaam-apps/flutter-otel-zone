import XCTest

@testable import CrashCore

/// What the handler that was installed before ours has been asked to do.
///
/// A global because an `NSUncaughtExceptionHandler` is a C function pointer
/// and cannot capture; the tests reset it in `setUp`.
private var previousHandlerCalls: [String] = []

final class NSExceptionSourceTests: XCTestCase {
  private var directory: URL!
  private var store: CrashFileStore!

  override func setUp() {
    previousHandlerCalls = []
    directory = makeTempDirectory().appendingPathComponent("exceptions")
    store = CrashFileStore(directory: directory, prefix: "ns")
    NSSetUncaughtExceptionHandler(nil)
  }

  override func tearDown() {
    NSExceptionSource.uninstallForTesting()
    try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
  }

  private func installBehindAPreviousHandler() {
    NSSetUncaughtExceptionHandler { exception in
      previousHandlerCalls.append(exception.name.rawValue)
    }
    NSExceptionSource.install(store: store)
  }

  /// Runs the installed handler the way the runtime would, without raising an
  /// exception: raising an uncaught one aborts the test process.
  private func fire(_ exception: NSException) throws {
    let handler = try XCTUnwrap(NSGetUncaughtExceptionHandler())
    handler(exception)
  }

  func testTheHandlerWritesOneReportWithNameReasonAndTimestamp() throws {
    NSExceptionSource.install(store: store)
    let before = Date().timeIntervalSince1970 * 1_000_000

    try fire(NSException(name: .rangeException, reason: "x", userInfo: nil))

    let report = try XCTUnwrap(
      store.ids().first.flatMap { id in
        store.read(id: id).flatMap { NSExceptionReport.decode(id: id, data: $0) }
      })
    XCTAssertEqual(store.ids().count, 1)
    XCTAssertEqual(report.name, "NSRangeException")
    XCTAssertEqual(report.reason, "x")
    XCTAssertGreaterThanOrEqual(Double(report.timestampMicros), before)
    XCTAssertEqual(report.record.kind, "nsexception")
    XCTAssertEqual(report.record.message, "x")
  }

  func testAPreviouslyInstalledHandlerStillRuns() throws {
    installBehindAPreviousHandler()

    try fire(NSException(name: .invalidArgumentException, reason: "y", userInfo: nil))

    XCTAssertEqual(previousHandlerCalls, ["NSInvalidArgumentException"])
    XCTAssertEqual(store.ids().count, 1)
  }

  func testInstallingTwiceDoesNotChainTheHandlerToItself() throws {
    installBehindAPreviousHandler()
    NSExceptionSource.install(store: store)

    try fire(NSException(name: .rangeException, reason: "x", userInfo: nil))

    XCTAssertEqual(previousHandlerCalls.count, 1)
    XCTAssertEqual(store.ids().count, 1)
  }

  func testAFailedWriteDoesNotStopThePreviousHandler() throws {
    installBehindAPreviousHandler()
    // Replace the directory with a file, so the write cannot succeed.
    try FileManager.default.removeItem(at: directory)
    try Data("in the way".utf8).write(to: directory)

    try fire(NSException(name: .rangeException, reason: "x", userInfo: nil))

    XCTAssertEqual(previousHandlerCalls, ["NSRangeException"])
  }

  func testNoPreviousHandlerIsFine() throws {
    NSExceptionSource.install(store: store)

    XCTAssertNoThrow(try fire(NSException(name: .rangeException, reason: nil, userInfo: nil)))
    XCTAssertEqual(store.ids().count, 1)
  }

  func testAVeryLongReasonAndStackStayBounded() throws {
    let long = String(repeating: "a", count: 100_000)

    let data = try NSExceptionSource.encode(
      NSException(name: .rangeException, reason: long, userInfo: nil))

    XCTAssertLessThan(data.count, NSExceptionSource.maxReasonLength + 1024)
  }

  func testAnExceptionReportFromTheHandlerIsReadBackByTheRepository() throws {
    NSExceptionSource.install(store: store)
    try fire(NSException(name: .rangeException, reason: "x", userInfo: nil))
    let repository = NativeCrashRepository(
      metricKit: CrashFileStore(directory: directory.appendingPathComponent("mx"), prefix: "mx"),
      exceptions: store)

    let reports = repository.pending()

    XCTAssertEqual(reports.map(\.kind), ["nsexception"])
    XCTAssertEqual(reports.first?.message, "x")
    XCTAssertEqual(reports.first?.type, "NSRangeException")
  }
}
