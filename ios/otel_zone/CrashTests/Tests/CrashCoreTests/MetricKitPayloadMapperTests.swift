import XCTest

@testable import CrashCore

final class MetricKitPayloadMapperTests: XCTestCase {
  private let received = Date(timeIntervalSince1970: 1_790_600_000)

  private func map(_ name: String) -> [MappedDiagnostic] {
    MetricKitPayloadMapper.map(
      data: fixture(name), fileId: "mx-0000001790600000000-0000", receivedAt: received)
  }

  func testSignalCrashCarriesSignalExceptionTerminationReasonAndCrashingThread() throws {
    let mapped = try XCTUnwrap(map("crash-sigsegv").first)
    let record = mapped.record

    XCTAssertEqual(record.id, "mx-0000001790600000000-0000-c0")
    XCTAssertEqual(record.kind, "signal")
    XCTAssertEqual(record.type, "SIGSEGV")
    XCTAssertEqual(record.message, "Namespace SIGNAL, Code 0xb")
    XCTAssertEqual(record.attributes?["crash.signal"], "11")
    XCTAssertEqual(record.attributes?["crash.signal_name"], "SIGSEGV")
    XCTAssertEqual(record.attributes?["crash.exception_type"], "1")
    XCTAssertEqual(record.attributes?["crash.exception_type_name"], "EXC_BAD_ACCESS")
    XCTAssertEqual(record.attributes?["crash.exception_code"], "1")
    XCTAssertEqual(record.attributes?["crash.termination_reason"], "Namespace SIGNAL, Code 0xb")
    XCTAssertEqual(record.attributes?["crash.vm_region_info"], "0 is not in any region.")
    XCTAssertEqual(record.attributes?["otel_zone.crashed.service.version"], "1.4.0")
    XCTAssertEqual(record.attributes?["otel_zone.crashed.app.build_id"], "42")
    XCTAssertEqual(record.attributes?["metrickit.device_type"], "iPhone15,2")
    // The timestamp is the end of the payload's window: a crash has none.
    XCTAssertEqual(record.timestampMicros, 1_790_591_400_000_000)
  }

  func testTheCrashedBuildIsOnEveryDiagnosticUnderTheSharedNames() throws {
    for name in ["crash-sigsegv", "crash-abort", "crash-nsexception-ios17", "hang"] {
      let record = try XCTUnwrap(map(name).first).record
      XCTAssertEqual(record.attributes?["otel_zone.crashed.service.version"], "1.4.0", name)
      XCTAssertEqual(record.attributes?["otel_zone.crashed.app.build_id"], "42", name)
    }
  }

  func testTheMetricKitSpecificCopiesOfTheBuildAreGone() throws {
    let attributes = try XCTUnwrap(map("crash-sigsegv").first).record.attributes ?? [:]

    XCTAssertNil(attributes["metrickit.app_version"])
    XCTAssertNil(attributes["metrickit.app_build_version"])
    // Nor did the unknown-key sweep pick them up under another name.
    XCTAssertNil(attributes["metrickit.meta.appVersion"])
    XCTAssertNil(attributes["metrickit.meta.appBuildVersion"])
  }

  func testADiagnosticWithNoBuildFieldsOrBlankOnesHasNoBuildAttributes() throws {
    func mapped(editing edit: (inout [String: Any]) -> Void) throws -> [String: String] {
      var root = try XCTUnwrap(
        JSONSerialization.jsonObject(with: fixture("crash-sigsegv")) as? [String: Any])
      var crashes = try XCTUnwrap(root["crashDiagnostics"] as? [[String: Any]])
      var meta = try XCTUnwrap(crashes[0]["diagnosticMetaData"] as? [String: Any])
      edit(&meta)
      crashes[0]["diagnosticMetaData"] = meta
      root["crashDiagnostics"] = crashes
      let data = try JSONSerialization.data(withJSONObject: root)
      return try XCTUnwrap(
        MetricKitPayloadMapper.map(
          data: data, fileId: "mx-0000001790600000000-0000", receivedAt: received
        )
        .first
      ).record.attributes ?? [:]
    }

    let absent = try mapped { meta in
      meta.removeValue(forKey: "appVersion")
      meta.removeValue(forKey: "appBuildVersion")
    }
    let blank = try mapped { meta in
      meta["appVersion"] = "  "
      meta["appBuildVersion"] = ""
    }
    let oneHalf = try mapped { meta in meta.removeValue(forKey: "appBuildVersion") }

    for attributes in [absent, blank] {
      XCTAssertNil(attributes["otel_zone.crashed.service.version"])
      XCTAssertNil(attributes["otel_zone.crashed.app.build_id"])
    }
    XCTAssertEqual(oneHalf["otel_zone.crashed.service.version"], "1.4.0")
    XCTAssertNil(oneHalf["otel_zone.crashed.app.build_id"])
  }

  func testCrashingThreadFramesAreInnermostFirstWithBinaryUUIDAndOffset() throws {
    let record = try XCTUnwrap(map("crash-sigsegv").first).record
    let lines = try XCTUnwrap(record.stacktrace).split(separator: "\n").map(String.init)

    XCTAssertEqual(lines.count, 3)
    XCTAssertEqual(
      lines[0],
      "#0 Runner 0x\(String(4_300_000_256, radix: 16)) (70B89F27-1634-3580-A695-57CDB41D7743) +165560"
    )
    XCTAssertEqual(
      lines[2],
      "#2 libdyld.dylib 0x\(String(7_170_808_612, radix: 16)) (77A62F2E-8212-30F3-84C1-E8497440ACF8) +6948"
    )
  }

  func testOtherThreadsAreExportedApartFromTheCrashingOne() throws {
    let record = try XCTUnwrap(map("crash-sigsegv").first).record
    let threads = try XCTUnwrap(record.threads)

    XCTAssertEqual(threads.count, 1)
    XCTAssertTrue(threads[0].hasPrefix("Thread 0:"))
    XCTAssertTrue(threads[0].contains("libsystem_kernel.dylib"))
    XCTAssertFalse(try XCTUnwrap(record.stacktrace).contains("libsystem_kernel.dylib"))
  }

  func testObjectiveCExceptionReasonMakesAnNSExceptionReport() throws {
    let mapped = try XCTUnwrap(map("crash-nsexception-ios17").first)

    XCTAssertEqual(mapped.record.kind, "nsexception")
    XCTAssertEqual(mapped.record.type, "NSRangeException")
    XCTAssertEqual(
      mapped.record.message, "*** -[__NSArrayM objectAtIndex:]: index 3 beyond bounds [0 .. 1]")
    XCTAssertEqual(mapped.record.attributes?["exception.class"], "NSException")
    XCTAssertTrue(mapped.couldBeUncaughtException)
  }

  func testAbortWithoutAReasonIsASignalReportThatCouldBeAnException() throws {
    let mapped = try XCTUnwrap(map("crash-abort").first)

    XCTAssertEqual(mapped.record.kind, "signal")
    XCTAssertEqual(mapped.record.type, "SIGABRT")
    XCTAssertTrue(mapped.couldBeUncaughtException)
  }

  func testASegfaultCouldNotBeAnUncaughtException() throws {
    XCTAssertFalse(try XCTUnwrap(map("crash-sigsegv").first).couldBeUncaughtException)
  }

  func testHangDiagnosticIsAHangReportFollowingTheHeaviestPath() throws {
    let mapped = try XCTUnwrap(map("hang").first)
    let record = mapped.record

    XCTAssertEqual(record.id, "mx-0000001790600000000-0000-h0")
    XCTAssertEqual(record.kind, "hang")
    XCTAssertEqual(record.type, "hang")
    XCTAssertEqual(record.message, "Main thread unresponsive for 4 sec 200 ms")
    XCTAssertEqual(record.attributes?["hang.duration"], "4 sec 200 ms")
    XCTAssertFalse(mapped.isCrash)
    let lines = try XCTUnwrap(record.stacktrace).split(separator: "\n").map(String.init)
    // The 8-sample branch, not the 2-sample one, innermost first.
    XCTAssertEqual(lines.count, 3)
    XCTAssertTrue(lines[0].contains("libsystem_kernel.dylib"))
    XCTAssertTrue(lines[1].contains("+900"))
    XCTAssertFalse(lines.joined().contains("+500"))
  }

  func testUnknownAndMistypedFieldsCostAFieldNotTheReport() throws {
    let mapped = map("unknown-fields")

    // `null` and `{}`-shaped neighbours do not produce reports of their own
    // beyond the entries that are objects; the index still counts them.
    XCTAssertEqual(
      mapped.map(\.record.id),
      [
        "mx-0000001790600000000-0000-c1", "mx-0000001790600000000-0000-c2",
      ])
    let record = mapped[0].record
    XCTAssertEqual(record.kind, "signal")
    XCTAssertEqual(record.attributes?["crash.exception_type"], "1")
    XCTAssertNil(record.attributes?["crash.signal"])
    XCTAssertEqual(record.attributes?["metrickit.meta.newScalar"], "7")
    XCTAssertEqual(record.attributes?["metrickit.meta.newFlag"], "false")
    XCTAssertNil(record.attributes?["metrickit.meta.newObject"])
    XCTAssertNil(record.attributes?["metrickit.meta.newList"])
    // A frame with a non-numeric address is still a frame, a scalar name is
    // read as text, and a malformed sibling is skipped.
    XCTAssertEqual(record.stacktrace, "#0 12")
    // No window was stated, so the report is filed at receipt.
    XCTAssertEqual(record.timestampMicros, 1_790_600_000_000_000)
    XCTAssertEqual(mapped[1].record.type, "crash")
  }

  func testMultipleDiagnosticsKeepTheirOwnIndexes() {
    let mapped = map("multiple-diagnostics")

    XCTAssertEqual(
      mapped.map(\.record.id),
      [
        "mx-0000001790600000000-0000-c0", "mx-0000001790600000000-0000-c1",
        "mx-0000001790600000000-0000-h0",
      ])
    XCTAssertEqual(mapped.map(\.record.type), ["SIGSEGV", "SIGILL", "hang"])
  }

  func testGarbageMapsToNothing() {
    for text in [
      "", "not json", "[]", "42", "{\"crashDiagnostics\": 5}", "{\"crashDiagnostics\": [1, \"a\"]}",
    ] {
      XCTAssertEqual(
        MetricKitPayloadMapper.map(data: Data(text.utf8), fileId: "mx-1-0", receivedAt: received)
          .count, 0,
        text)
    }
  }

  func testContentDistinguishesUnreadableFromEmptyFromLive() {
    XCTAssertEqual(MetricKitPayloadMapper.content(of: Data("nope".utf8)), .unreadable)
    XCTAssertEqual(
      MetricKitPayloadMapper.content(of: Data("{\"crashDiagnostics\": [null]}".utf8)), .empty)
    XCTAssertEqual(MetricKitPayloadMapper.content(of: fixture("hang")), .live)
  }

  func testTimestampFormatsAreReadOrIgnored() throws {
    func stamp(_ end: String) throws -> Int64 {
      let json = "{\"timeStampEnd\": \"\(end)\", \"crashDiagnostics\": [{}]}"
      return try XCTUnwrap(
        MetricKitPayloadMapper.map(data: Data(json.utf8), fileId: "mx-1-0", receivedAt: received)
          .first
      ).record.timestampMicros
    }
    XCTAssertEqual(try stamp("2026-09-28 10:30:00"), 1_790_591_400_000_000)
    XCTAssertEqual(try stamp("2026-09-28 10:30:00 +0000"), 1_790_591_400_000_000)
    XCTAssertEqual(try stamp("2026-09-28T10:30:00Z"), 1_790_591_400_000_000)
    XCTAssertEqual(try stamp("2026-09-28T10:30:00.000Z"), 1_790_591_400_000_000)
    XCTAssertEqual(try stamp("yesterday"), 1_790_600_000_000_000)
  }

  func testADeepStackIsWalkedWithoutRecursionAndWithinTheCap() throws {
    // Each frame is an object inside an array, and JSONSerialization refuses
    // nesting past 512, so 240 frames is about as deep as a payload can get
    // and still parse. The walk is a loop, so depth is not a stack-overflow
    // risk; the cap is the second line of defence, for a parser without that
    // limit.
    var frame: [String: Any] = ["binaryName": "leaf"]
    for _ in 0..<240 { frame = ["binaryName": "f", "subFrames": [frame]] }
    let payload: [String: Any] = [
      "crashDiagnostics": [
        [
          "callStackTree": [
            "callStacks": [["threadAttributed": true, "callStackRootFrames": [frame]]]
          ]
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let stack = try XCTUnwrap(
      MetricKitPayloadMapper.map(data: data, fileId: "mx-1-0", receivedAt: received).first
    ).record.stacktrace

    XCTAssertEqual(stack?.split(separator: "\n").count, 241)
  }
}
