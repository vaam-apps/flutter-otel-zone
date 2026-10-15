import XCTest

@testable import CrashCore

final class CrashScreenTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    directory = makeTempDirectory().appendingPathComponent("screens")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
  }

  func testSetKeepsTheCleanedScreen() {
    let screen = CrashScreen()

    screen.set("  /orders/:id\n")

    XCTAssertEqual(screen.current, "/orders/:id")
  }

  func testSetRecordsAChangeInTheRunLogAndSkipsAnUnchangedOne() {
    let screen = CrashScreen()
    screen.attach(
      RunScreenLog(
        directory: directory, pid: 7,
        launchedAt: Date(timeIntervalSince1970: 1_790_600_000)))

    screen.set("/a")
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

    // The run log is taken away: a repeated screen must not write it again.
    try? FileManager.default.removeItem(at: directory)
    screen.set("/a")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.path),
      "an unchanged screen is not written")

    screen.set("/b")
    let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(names?.count, 1)
    XCTAssertEqual(screen.current, "/b")
  }

  func testNilBlankOverlongAndControlCharacterScreensClearIt() {
    let screen = CrashScreen()
    let cleared: [String?] = [
      nil, "", "   ", String(repeating: "x", count: 65), "/a\u{7}b", "/a\u{9F}b",
    ]

    for value in cleared {
      screen.set("/a")
      screen.set(value)
      XCTAssertNil(screen.current, "\(String(describing: value))")
    }
  }

  func testAScreenOfExactlySixtyFourBytesIsKept() {
    let screen = CrashScreen()
    let sixtyFour = String(repeating: "é", count: 32)

    screen.set(sixtyFour)

    XCTAssertEqual(screen.current, sixtyFour)
  }
}
