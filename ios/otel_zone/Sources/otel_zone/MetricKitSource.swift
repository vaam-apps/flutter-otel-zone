import Foundation
import MetricKit

/// Receives MetricKit's diagnostics and writes them to disk on arrival.
///
/// MetricKit is iOS's own record of why the process died — the counterpart of
/// Android's `ApplicationExitInfo` — and reading it needs no in-process signal
/// handler, so there is no async-signal-safety risk and no clash with the
/// debugger or another crash reporter.
///
/// The payload is persisted before it is interpreted. `didReceive` can fire
/// before Dart is running, and MetricKit does not deliver a payload twice, so
/// a payload held only in memory would be lost with the process. Mapping
/// happens later, in `pending()`, from the same bytes.
///
/// MetricKit's diagnostics need iOS 14; the plugin's minimum is lower, and the
/// registration is guarded the same way.
@available(iOS 14.0, *)
final class MetricKitSource: NSObject, MXMetricManagerSubscriber {
  private let repository: NativeCrashRepository

  init(repository: NativeCrashRepository) {
    self.repository = repository
    super.init()
  }

  func start() {
    MXMetricManager.shared.add(self)
  }

  /// Diagnostics: crashes, hangs and the rest. Only crash and hang payloads
  /// are kept — the repository drops any payload with neither.
  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      repository.persist(payload: payload.jsonRepresentation())
    }
  }

  /// Daily metrics. Out of scope here: `MXAppExitMetric` counts are a
  /// possible follow-up, and the protocol method is optional.
  func didReceive(_ payloads: [MXMetricPayload]) {}
}
