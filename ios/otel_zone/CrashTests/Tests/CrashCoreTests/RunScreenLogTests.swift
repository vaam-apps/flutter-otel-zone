import XCTest

@testable import CrashCore

final class RunScreenLogTests: XCTestCase {
  private var directory: URL!

  /// crash-sigsegv.json's window: 08:00 to 10:30 UTC on 2026-09-28.
  private let windowStart = Date(timeIntervalSince1970: 1_790_582_400)
  private let windowEnd = Date(timeIntervalSince1970: 1_790_591_400)

  override func setUp() {
    directory = makeTempDirectory().appendingPathComponent("screens")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
  }

  /// The file name a run launched at [launched] with [pid] writes.
  private func runName(_ launched: Date, pid: Int32) -> String {
    String(format: "run-%016lld-%d.json", Int64(launched.timeIntervalSince1970 * 1000), pid)
  }

  /// A run that was launched at [launched] with [pid] and showed [screen] last.
  private func run(pid: Int32, launched: Date, screen: String?) {
    RunScreenLog(directory: directory, pid: pid, launchedAt: launched).record(screen)
  }

  /// A reader that is not any run in the directory: it is launched later than
  /// every window the tests use, so it never matches, and its own file is absent.
  private func reader(now: Date = Date(timeIntervalSince1970: 1_790_700_000)) -> RunScreenLog {
    RunScreenLog(directory: directory, pid: 1, launchedAt: now, now: { now })
  }

  private func match(_ log: RunScreenLog, pid: Int = 811) -> String? {
    log.screen(pid: pid, windowStart: windowStart, windowEnd: windowEnd)
  }

  private func clear() {
    try? FileManager.default.removeItem(at: directory)
  }

  func testTheLastScreenOfARunIsFoundByItsPid() {
    run(pid: 811, launched: windowStart.addingTimeInterval(600), screen: "/orders/:id")

    XCTAssertEqual(match(reader()), "/orders/:id")
    XCTAssertNil(match(reader(), pid: 812))
  }

  func testTheCurrentRunIsNeverMatched() {
    let log = RunScreenLog(
      directory: directory, pid: 811, launchedAt: windowStart.addingTimeInterval(600))
    log.record("/self")

    XCTAssertNil(match(log))
  }

  func testTwoRunsWithOnePidAreAmbiguousAndYieldNil() {
    run(pid: 811, launched: windowStart.addingTimeInterval(600), screen: "/a")
    run(pid: 811, launched: windowStart.addingTimeInterval(1200), screen: "/b")

    XCTAssertNil(match(reader()))
  }

  func testARunLaunchedAfterTheWindowOrADayBeforeItIsNotMatched() {
    run(pid: 811, launched: windowEnd.addingTimeInterval(120), screen: "/late")
    XCTAssertNil(match(reader()), "launched after the window and its slack")
    clear()

    run(pid: 811, launched: windowStart.addingTimeInterval(-25 * 3600), screen: "/early")
    XCTAssertNil(match(reader()), "launched more than a day before the window")
    clear()

    run(pid: 811, launched: windowStart.addingTimeInterval(-23 * 3600), screen: "/lead")
    XCTAssertEqual(match(reader()), "/lead", "launched within a day before the window")
    clear()

    run(pid: 811, launched: windowEnd.addingTimeInterval(30), screen: "/slack")
    XCTAssertEqual(match(reader()), "/slack", "launched within the slack after the window")
  }

  func testAClearedScreenYieldsNil() {
    run(pid: 811, launched: windowStart.addingTimeInterval(600), screen: nil)

    XCTAssertNil(match(reader()))
  }

  func testSweepKeepsTheNewest64AndDropsRunsOlderThanAWeek() throws {
    let now = Date(timeIntervalSince1970: 1_790_700_000)
    let old = now.addingTimeInterval(-8 * 24 * 60 * 60)
    run(pid: 1, launched: old, screen: "/old")
    for index in 0..<70 {
      run(pid: 2, launched: now.addingTimeInterval(TimeInterval(index)), screen: "/\(index)")
    }

    RunScreenLog(directory: directory, pid: 9, launchedAt: now, now: { now }).sweep()

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(names.count, 64)
    XCTAssertFalse(names.contains(runName(old, pid: 1)), "older than a week")
    XCTAssertFalse(names.contains(runName(now, pid: 2)), "the oldest of the 70 is dropped")
    XCTAssertTrue(names.contains(runName(now.addingTimeInterval(69), pid: 2)))
  }

  func testAnUnreadableRunFileYieldsNil() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = runName(windowStart.addingTimeInterval(600), pid: 811)
    try Data("not json".utf8).write(to: directory.appendingPathComponent(name))

    XCTAssertNil(match(reader()))
  }
}
