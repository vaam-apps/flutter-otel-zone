import XCTest

@testable import CrashCore

final class NativeCrashRepositoryTests: XCTestCase {
  // crash-abort.json and crash-nsexception-ios17.json both cover
  // 09:00-11:00 UTC on 2026-09-28; crash-sigsegv.json covers 08:00-10:30.
  private let ten: TimeInterval = 1_790_589_600

  private var harness: Harness!

  override func setUp() { harness = Harness() }
  override func tearDown() { harness.cleanUp() }

  private func persist(_ name: String) {
    XCTAssertTrue(harness.repository.persist(payload: fixture(name)))
    harness.clock.advance(1)
  }

  // MARK: - MetricKit only

  func testAPersistedPayloadIsReturnedOnceAndGoneAfterAcknowledge() throws {
    persist("crash-sigsegv")

    let first = harness.repository.pending()
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(first[0].type, "SIGSEGV")
    // Not acknowledged, so still there: an unreachable collector re-reads it.
    XCTAssertEqual(harness.repository.pending().map(\.id), first.map(\.id))

    harness.repository.acknowledge(first.map(\.id))

    XCTAssertEqual(harness.repository.pending(), [])
    XCTAssertEqual(harness.metricKit.ids(), [])
  }

  func testAPayloadWithNothingToReportIsNotKept() {
    XCTAssertFalse(harness.repository.persist(payload: Data("{\"crashDiagnostics\": []}".utf8)))
    XCTAssertFalse(harness.repository.persist(payload: Data("not json".utf8)))
    XCTAssertEqual(harness.metricKit.ids(), [])
  }

  func testAnAcknowledgedDiagnosticDoesNotMoveItsSiblingsIds() {
    persist("multiple-diagnostics")
    let ids = harness.repository.pending().map(\.id)
    XCTAssertEqual(ids.count, 3)

    harness.repository.acknowledge([ids[0]])
    XCTAssertEqual(harness.repository.pending().map(\.id), Array(ids[1...]))

    harness.repository.acknowledge([ids[2]])
    XCTAssertEqual(harness.repository.pending().map(\.id), [ids[1]])

    harness.repository.acknowledge([ids[1]])
    XCTAssertEqual(harness.repository.pending(), [])
    XCTAssertEqual(harness.metricKit.ids(), [], "the file goes with its last diagnostic")
  }

  func testCrashAndHangAreBothReturnedOldestFirst() {
    persist("hang")
    persist("crash-sigsegv")

    // hang's window ends 07:00, sigsegv's 10:30.
    XCTAssertEqual(harness.repository.pending().map(\.kind), ["hang", "signal"])
  }

  // MARK: - Merge

  func testAMergedRecordCarriesTheBuildTheExceptionReportRecorded() throws {
    persist("crash-abort")
    // The fixture's MetricKit crash says 1.4.0 (42); the crashing process
    // said 1.3.9 (41). The process wrote its own, so its word stands.
    harness.writeException(
      reason: "x", build: AppBuild(version: "1.3.9", build: "41"), at: ten)

    let report = try XCTUnwrap(harness.repository.pending().first)

    XCTAssertEqual(report.kind, "nsexception")
    XCTAssertEqual(report.attributes?["otel_zone.crashed.service.version"], "1.3.9")
    XCTAssertEqual(report.attributes?["otel_zone.crashed.app.build_id"], "41")
  }

  func testAMergedRecordKeepsMetricKitsBuildWhenTheExceptionReportPredatesIt() throws {
    persist("crash-abort")
    harness.writeException(reason: "x", at: ten)

    let report = try XCTUnwrap(harness.repository.pending().first)

    XCTAssertEqual(report.attributes?["otel_zone.crashed.service.version"], "1.4.0")
    XCTAssertEqual(report.attributes?["otel_zone.crashed.app.build_id"], "42")
  }

  func testAnExceptionReportAloneCarriesItsBuildThroughTheRepository() throws {
    harness.writeException(
      reason: "x", build: AppBuild(version: "2.0.0", build: "7"), at: ten)

    let report = try XCTUnwrap(harness.repository.pending().first)

    XCTAssertEqual(report.attributes?["otel_zone.crashed.service.version"], "2.0.0")
    XCTAssertEqual(report.attributes?["otel_zone.crashed.app.build_id"], "7")
  }

  func testAnExceptionAndItsMetricKitCrashAreOneRecord() throws {
    persist("crash-abort")
    harness.writeException(
      reason: "x", symbols: ["0 App 0x100 -[Foo bar]", "1 App 0x200 main"], at: ten)

    let reports = harness.repository.pending()

    XCTAssertEqual(reports.count, 1)
    let report = try XCTUnwrap(reports.first)
    XCTAssertEqual(report.kind, "nsexception")
    XCTAssertEqual(report.type, "NSRangeException")
    XCTAssertEqual(report.message, "x")
    // The throw site, not the abort.
    XCTAssertEqual(report.stacktrace, "0 App 0x100 -[Foo bar]\n1 App 0x200 main")
    XCTAssertEqual(report.timestampMicros, Int64(ten) * 1_000_000)
    XCTAssertEqual(report.attributes?["crash.source"], "metrickit+nsexception")
    // MetricKit's own facts survive the merge.
    XCTAssertEqual(report.attributes?["crash.signal_name"], "SIGABRT")
    let crashed = try XCTUnwrap(report.threads?.first)
    XCTAssertTrue(crashed.hasPrefix("Crashed thread (MetricKit):"))
    XCTAssertTrue(crashed.contains("77A62F2E-8212-30F3-84C1-E8497440ACF8"))
  }

  func testAcknowledgingAMergedRecordDeletesBothSources() {
    persist("crash-abort")
    harness.writeException(at: ten)

    let ids = harness.repository.pending().map(\.id)
    XCTAssertEqual(ids.count, 1)
    XCTAssertTrue(ids[0].contains("+"))

    harness.repository.acknowledge(ids)

    XCTAssertEqual(harness.metricKit.ids(), [])
    XCTAssertEqual(harness.exceptions.ids(), [])
    XCTAssertEqual(harness.repository.pending(), [])
  }

  func testAnExceptionMergesIntoTheIOS17ReportThatAlreadyNamesIt() {
    persist("crash-nsexception-ios17")
    harness.writeException(name: "NSRangeException", reason: "index 3 beyond bounds", at: ten)

    let reports = harness.repository.pending()

    XCTAssertEqual(reports.count, 1)
    XCTAssertEqual(reports[0].message, "index 3 beyond bounds")
  }

  func testAnExceptionOutsideThePayloadWindowIsNotMerged() {
    persist("crash-abort")
    // 12:30, an hour and a half after the window closes.
    harness.writeException(at: ten + 2.5 * 3600)

    XCTAssertEqual(harness.repository.pending().count, 2)
  }

  func testAnExceptionJustInsideTheSlackIsStillMerged() {
    persist("crash-abort")
    // Window ends 11:00; 30s later is inside the 60s slack, 120s is not.
    harness.writeException(at: ten + 3600 + 30)
    XCTAssertEqual(harness.repository.pending().count, 1)

    harness.writeException(at: ten + 3600 + 120)
    XCTAssertEqual(harness.repository.pending().count, 2)
  }

  func testAnExceptionIsNotMergedIntoACrashThatCouldNotHaveBeenIt() {
    persist("crash-sigsegv")  // SIGSEGV, window 08:00-10:30
    harness.writeException(at: ten)

    XCTAssertEqual(harness.repository.pending().map(\.kind).sorted(), ["nsexception", "signal"])
  }

  func testTheMatchIsOneToOne() {
    persist("crash-abort")
    harness.writeException(reason: "first", at: ten)
    harness.writeException(reason: "second", at: ten + 10)

    let reports = harness.repository.pending()

    XCTAssertEqual(reports.count, 2, "two exceptions, one diagnostic: one merge, one alone")
    XCTAssertEqual(
      reports.filter { $0.attributes?["crash.source"] == "metrickit+nsexception" }.count, 1)
    XCTAssertEqual(reports.filter { $0.attributes?["crash.source"] == "nsexception" }.count, 1)
  }

  func testWhenSeveralDiagnosticsQualifyTheOneThatAgreesWins() throws {
    persist("crash-abort")  // no reason
    persist("crash-nsexception-ios17")  // NSRangeException
    harness.writeException(name: "NSRangeException", reason: "boom", at: ten)

    let merged = try XCTUnwrap(
      harness.repository.pending().first {
        $0.attributes?["crash.source"] == "metrickit+nsexception"
      })

    // The ios17 fixture is the second payload, so the abort-only one would
    // have won on age alone.
    XCTAssertTrue(merged.id.contains("mx-"), merged.id)
    XCTAssertTrue(merged.attributes?["exception.class"] == "NSException")
  }

  func testAnExceptionWithNoMetricKitReportIsReturnedAlone() throws {
    harness.writeException(reason: "alone", at: ten)

    let report = try XCTUnwrap(harness.repository.pending().first)

    XCTAssertEqual(report.kind, "nsexception")
    XCTAssertEqual(report.message, "alone")
    XCTAssertEqual(report.attributes?["crash.source"], "nsexception")
  }

  func testHangsAreNeverMerged() {
    persist("hang")  // window 06:00-07:00
    harness.writeException(at: 1_790_578_800 - 60)

    XCTAssertEqual(harness.repository.pending().count, 2)
  }

  // MARK: - Ids

  func testAnIdThatIsNotAReportNameCannotReachOutsideTheDirectory() throws {
    persist("crash-sigsegv")
    let outside = harness.root.appendingPathComponent("outside.json")
    try Data("{}".utf8).write(to: outside)

    harness.repository.acknowledge([
      "..", "../outside", "mx-1/../../outside", "ns-1/../../outside", "/etc/passwd",
      "mx-0000000000000000-0000-c0/../..", "+", "++", "ns-\0", "",
    ])

    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    XCTAssertEqual(harness.repository.pending().count, 1)
  }

  func testAnUnknownIdAndAMalformedMetricKitIdAreIgnored() {
    persist("crash-sigsegv")

    harness.repository.acknowledge([
      "mx-9999999999999999-9999-c0", "mx-x", "mx-1-2-3-4", "ns-9999999999999999-9999",
      "other-1-2", "mx-0000000000000000-0000-c99999",
    ])

    XCTAssertEqual(harness.repository.pending().count, 1)
  }

  func testSafeIdRule() {
    XCTAssertTrue(CrashFileStore.isSafeId("mx-0000001790600000000-0000"))
    XCTAssertTrue(CrashFileStore.isSafeId("a_B-9"))
    for id in ["", ".", "..", "a/b", "a b", "a.json", "é", String(repeating: "a", count: 129)] {
      XCTAssertFalse(CrashFileStore.isSafeId(id), id)
    }
  }

  // MARK: - Damaged files, cap, temp files

  func testAnUnparseableFileIsSkippedAndTheRestStillRead() throws {
    persist("crash-sigsegv")
    try Data("{ this is not json".utf8).write(
      to: harness.metricKit.directory.appendingPathComponent("mx-0000000000000001-0000.json"))
    try Data("[]".utf8).write(
      to: harness.exceptions.directory.appendingPathComponent("ns-0000000000000001-0000.json"))
    try Data("{\"name\": 5}".utf8).write(
      to: harness.exceptions.directory.appendingPathComponent("ns-0000000000000002-0000.json"))

    XCTAssertEqual(harness.repository.pending().map(\.type), ["SIGSEGV"])
    // Left where it is, in case a newer build can read it.
    XCTAssertEqual(harness.metricKit.ids().count, 2)
  }

  func testAParsableFileWithNothingLeftIsRemoved() throws {
    try Data("{\"crashDiagnostics\": [null]}".utf8).write(
      to: harness.metricKit.directory.appendingPathComponent("mx-0000000000000001-0000.json"))

    XCTAssertEqual(harness.repository.pending(), [])
    XCTAssertEqual(harness.metricKit.ids(), [])
  }

  func testTheCapKeepsTheNewestFilesInEachStore() {
    harness.cleanUp()
    harness = Harness(maxFiles: 3)
    for _ in 0..<5 { persist("crash-sigsegv") }
    for offset in 0..<5 {
      harness.writeException(at: ten + TimeInterval(offset))
      harness.clock.advance(1)
    }

    let reports = harness.repository.pending()

    XCTAssertEqual(harness.metricKit.ids().count, 3)
    XCTAssertEqual(harness.exceptions.ids().count, 3)
    // The three newest of each survive, so the oldest exceptions are gone.
    let exceptionTimes = reports.filter { $0.kind == "nsexception" }.map(\.timestampMicros)
    XCTAssertEqual(exceptionTimes.min(), Int64(ten + 2) * 1_000_000)
  }

  func testAStaleTempFileIsSweptAndAFreshOneIsKept() throws {
    let stale = harness.metricKit.directory.appendingPathComponent("mx-1-0.json.tmp")
    let fresh = harness.metricKit.directory.appendingPathComponent("mx-2-0.json.tmp")
    try Data("x".utf8).write(to: stale)
    try Data("x".utf8).write(to: fresh)
    // The harness clock is 2026; the files were written "now" in real time,
    // so pushing the clock forward two minutes ages both past the 60s window
    // — the fresh one is then re-touched to stay young.
    harness.clock.now = Date().addingTimeInterval(120)
    try FileManager.default.setAttributes(
      [.modificationDate: harness.clock.now], ofItemAtPath: fresh.path)

    _ = harness.repository.pending()

    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
  }

  func testTwoWritesInTheSameMillisecondDoNotCollide() throws {
    let a = try harness.metricKit.write(Data("{}".utf8))
    let b = try harness.metricKit.write(Data("{}".utf8))

    XCTAssertNotEqual(a, b)
    XCTAssertEqual(harness.metricKit.ids(), [a, b].sorted())
  }
}
