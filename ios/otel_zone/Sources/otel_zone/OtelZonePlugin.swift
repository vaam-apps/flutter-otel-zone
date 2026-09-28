import Flutter

/// Registers the native crash-capture channel.
///
/// The channel's platform side is `NativeCrashStub` until the iOS capture
/// tickets land: it reports nothing and acknowledges nothing, which is exactly
/// the behaviour of the package before this plugin existed.
public class OtelZonePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    NativeCrashApiSetup.setUp(binaryMessenger: registrar.messenger(), api: NativeCrashStub())
  }
}

/// The no-op `NativeCrashApi` that the iOS capture tickets replace.
///
/// The MetricKit subscriber and the chained `NSSetUncaughtExceptionHandler`
/// both belong to those tickets, not this one.
final class NativeCrashStub: NativeCrashApi {
  func pending() async throws -> [NativeCrashReport] { [] }

  func acknowledge(ids: [String]) async throws {}
}
