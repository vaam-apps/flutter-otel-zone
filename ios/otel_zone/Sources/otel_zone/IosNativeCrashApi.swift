import Foundation

/// The `NativeCrashApi` the Dart drain talks to: the reports already on disk.
///
/// Reading and deleting run off the platform thread because the channel calls
/// are awaited there, and `start()` must not pay for a directory read on the
/// frame the app is drawing.
final class IosNativeCrashApi: NativeCrashApi {
  private let repository: NativeCrashRepository
  private let queue = DispatchQueue(label: "otel_zone.crash-store", qos: .utility)

  init(repository: NativeCrashRepository) {
    self.repository = repository
  }

  func pending() async throws -> [NativeCrashReport] {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: self.repository.pending().map(NativeCrashReport.init))
      }
    }
  }

  func acknowledge(ids: [String]) async throws {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async {
        self.repository.acknowledge(ids)
        continuation.resume()
      }
    }
  }
}

extension NativeCrashReport {
  fileprivate init(_ record: CrashRecord) {
    self.init(
      id: record.id,
      kind: record.kind,
      timestampMicros: record.timestampMicros,
      type: record.type,
      message: record.message,
      stacktrace: record.stacktrace,
      threads: record.threads,
      sessionId: record.sessionId,
      attributes: record.attributes)
  }
}
