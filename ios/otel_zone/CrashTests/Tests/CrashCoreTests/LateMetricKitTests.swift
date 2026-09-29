import XCTest

@testable import CrashCore

/// The orderings in which one crash's two records can reach `pending()`.
final class LateMetricKitTests: XCTestCase {
  // crash-abort.json covers 09:00-11:00 UTC on 2026-09-28.
  private let ten: TimeInterval = 1_790_589_600

  private var harness: Harness!

  override func setUp() { harness = Harness() }
  override func tearDown() { harness.cleanUp() }

  private func persist(_ name: String) {
    XCTAssertTrue(harness.repository.persist(payload: fixture(name)))
    harness.clock.advance(1)
  }

  private func isTagged(_ report: CrashRecord) -> Bool {
    report.attributes?[NativeCrashRepository.lateMetricKitAttribute] == "true"
  }

  // MARK: - The three orderings

  /// The handler writes at crash time, so MetricKit's diagnostic of the same
  /// crash cannot exist before it. What can happen is a diagnostic delivered
  /// and acknowledged first for an *earlier* crash, and a later exception
  /// that must not be mistaken for a duplicate of it.
  func testAMetricKitReportAcknowledgedFirstDoesNotClaimALaterException() {
    persist("crash-abort")
    let first = harness.repository.pending()
    XCTAssertEqual(first.count, 1)
    harness.repository.acknowledge(first.map(\.id))

    // A different crash, three hours after the window closed.
    harness.writeException(reason: "later", at: ten + 3 * 3600)
    let second = harness.repository.pending()

    XCTAssertEqual(second.map(\.message), ["later"])
    XCTAssertEqual(second.map(isTagged), [false])
    XCTAssertEqual(harness.ledger.entries(), [], "an MX-first report leaves nothing in the ledger")
  }

  func testBothTogetherMergeAndLeaveNothingInTheLedger() {
    persist("crash-abort")
    harness.writeException(at: ten)

    let reports = harness.repository.pending()
    XCTAssertEqual(reports.count, 1)
    XCTAssertFalse(isTagged(reports[0]))
    harness.repository.acknowledge(reports.map(\.id))

    XCTAssertEqual(harness.ledger.entries(), [])
    XCTAssertEqual(harness.repository.pending(), [])
  }

  func testAnExceptionAcknowledgedAloneTagsTheLateMetricKitReport() throws {
    let exceptionId = harness.writeException(name: "NSRangeException", reason: "x", at: ten)
    let alone = harness.repository.pending()
    XCTAssertEqual(alone.map(\.id), [exceptionId])
    harness.repository.acknowledge(alone.map(\.id))

    // Days of app time later, MetricKit delivers the same crash.
    harness.clock.advance(3600)
    persist("crash-abort")
    let late = try XCTUnwrap(harness.repository.pending().first)

    // Still returned: its frames carry the symbolicatable binary UUIDs.
    XCTAssertEqual(harness.repository.pending().count, 1)
    XCTAssertTrue(isTagged(late))
    XCTAssertEqual(late.attributes?[NativeCrashRepository.duplicateOfAttribute], exceptionId)
    XCTAssertEqual(late.attributes?["crash.source"], "metrickit")
    XCTAssertTrue(try XCTUnwrap(late.stacktrace).contains("77A62F2E-8212-30F3-84C1-E8497440ACF8"))
  }

  func testAcknowledgingTheTaggedReportForgetsTheLedgerEntry() {
    harness.writeException(at: ten)
    harness.repository.acknowledge(harness.repository.pending().map(\.id))
    persist("crash-abort")
    XCTAssertEqual(harness.ledger.entries().count, 1)

    harness.repository.acknowledge(harness.repository.pending().map(\.id))

    XCTAssertEqual(harness.ledger.entries(), [])
    XCTAssertEqual(harness.repository.pending(), [])
  }

  // MARK: - What must not be tagged

  func testALateReportOutsideTheWindowOrOfAnotherKindIsNotTagged() {
    harness.writeException(at: ten)
    harness.repository.acknowledge(harness.repository.pending().map(\.id))

    // SIGSEGV window 08:00-10:30 contains the time but could not be an
    // uncaught exception; the hang is not a crash at all.
    persist("crash-sigsegv")
    persist("hang")
    XCTAssertEqual(harness.repository.pending().map(isTagged), [false, false])
  }

  func testOneLedgerEntryTagsOneDiagnostic() {
    harness.writeException(at: ten)
    harness.repository.acknowledge(harness.repository.pending().map(\.id))
    persist("crash-abort")
    persist("crash-nsexception-ios17")

    XCTAssertEqual(harness.repository.pending().filter(isTagged).count, 1)
  }

  func testALiveExceptionClaimsTheDiagnosticBeforeTheLedgerDoes() {
    harness.writeException(reason: "old", at: ten)
    harness.repository.acknowledge(harness.repository.pending().map(\.id))
    harness.writeException(reason: "new", at: ten + 5)
    persist("crash-abort")

    let reports = harness.repository.pending()

    XCTAssertEqual(reports.count, 1)
    XCTAssertTrue(reports[0].id.contains("+"), "merged with the live report")
    XCTAssertFalse(isTagged(reports[0]))
  }

  // MARK: - The ledger itself

  func testLedgerEntriesExpireAfterTheTimeToLive() {
    harness.ledger.record(id: "ns-1-0", name: "A", timestampMicros: 1)
    XCTAssertEqual(harness.ledger.entries().count, 1)

    harness.clock.advance(AcknowledgedExceptionLedger.defaultTimeToLive - 1)
    XCTAssertEqual(harness.ledger.entries().count, 1)

    harness.clock.advance(2)
    XCTAssertEqual(harness.ledger.entries(), [])
  }

  func testAnExpiredEntryNoLongerTagsAndIsDroppedOnTheNextWrite() {
    harness.writeException(at: ten)
    harness.repository.acknowledge(harness.repository.pending().map(\.id))
    harness.clock.advance(AcknowledgedExceptionLedger.defaultTimeToLive + 60)
    persist("crash-abort")

    XCTAssertEqual(harness.repository.pending().map(isTagged), [false])
    harness.ledger.record(id: "ns-2-0", name: "B", timestampMicros: 2)
    XCTAssertEqual(harness.ledger.entries().map(\.id), ["ns-2-0"])
  }

  func testTheLedgerKeepsOnlyTheNewestEntries() {
    let ledger = AcknowledgedExceptionLedger(
      file: harness.ledgerFile, maxEntries: 3, now: { self.harness.clock.now })
    for index in 0..<5 {
      ledger.record(id: "ns-\(index)-0", name: "N\(index)", timestampMicros: Int64(index))
      harness.clock.advance(1)
    }

    XCTAssertEqual(ledger.entries().map(\.id), ["ns-2-0", "ns-3-0", "ns-4-0"])
  }

  func testRecordingTheSameIdTwiceKeepsOneEntry() {
    harness.ledger.record(id: "ns-1-0", name: "A", timestampMicros: 1)
    harness.ledger.record(id: "ns-1-0", name: "A", timestampMicros: 1)

    XCTAssertEqual(harness.ledger.entries().count, 1)
  }

  func testACorruptLedgerIsAnEmptyLedgerAndIsReplacedOnTheNextWrite() throws {
    try Data("{ not json".utf8).write(to: harness.ledgerFile)
    XCTAssertEqual(harness.ledger.entries(), [])

    // Nothing throws, nothing is tagged, and the reports still flow.
    persist("crash-abort")
    XCTAssertEqual(harness.repository.pending().map(isTagged), [false])

    let id = harness.writeException(at: ten - 7200)
    harness.repository.acknowledge([id])
    XCTAssertEqual(harness.ledger.entries().map(\.id), [id])
  }

  func testAMalformedEntryIsSkippedWithoutTakingItsNeighboursDown() throws {
    harness.ledger.record(id: "ns-1-0", name: "A", timestampMicros: 1)
    var list = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: harness.ledgerFile)) as? [Any])
    list.append(["id": "../escape", "name": "B", "timestampMicros": 2, "acknowledgedAtMillis": 3])
    list.append("junk")
    list.append(["id": "ns-3-0"])
    try JSONSerialization.data(withJSONObject: list).write(to: harness.ledgerFile)

    XCTAssertEqual(harness.ledger.entries().map(\.id), ["ns-1-0"])
  }

  func testAnUnwritableLedgerDegradesToTheOldBehaviourWithoutThrowing() throws {
    // A directory where the file should be: every write fails.
    try FileManager.default.createDirectory(
      at: harness.ledgerFile, withIntermediateDirectories: true)
    let id = harness.writeException(at: ten)

    harness.repository.acknowledge([id])
    persist("crash-abort")

    XCTAssertEqual(harness.exceptions.ids(), [], "the report is still acknowledged")
    XCTAssertEqual(harness.repository.pending().map(isTagged), [false])
    XCTAssertFalse(harness.ledger.record(id: "ns-1-0", name: "A", timestampMicros: 1))
  }

  func testAnUnknownExceptionIdIsNotRecorded() {
    harness.repository.acknowledge(["ns-9999999999999999-9999"])

    XCTAssertEqual(harness.ledger.entries(), [])
  }
}
