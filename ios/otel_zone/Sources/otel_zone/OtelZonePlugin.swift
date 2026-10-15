import Flutter

/// Registers the native crash-capture channel and the two iOS sources behind
/// it.
///
/// Both sources are started here, in `register(with:)`, which runs when the
/// engine starts — before Dart, and so before anything the app can throw. Each
/// is started at most once per process: a second engine (add-to-app, or a
/// plugin re-registration) must not chain the exception handler to itself or
/// add a second MetricKit subscriber.
public class OtelZonePlugin: NSObject, FlutterPlugin {
  /// Held for the life of the process. MetricKit does not promise to keep its
  /// subscribers alive, and the objects are tiny.
  private static var capture: Capture?
  private static let captureLock = NSLock()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let repository = startCapture()
    NativeCrashApiSetup.setUp(
      binaryMessenger: registrar.messenger(),
      api: IosNativeCrashApi(repository: repository))
    CrashContextApiSetup.setUp(
      binaryMessenger: registrar.messenger(),
      api: IosCrashContextApi())
  }

  private final class Capture {
    let repository: NativeCrashRepository
    let metricKit: AnyObject?

    init(repository: NativeCrashRepository, metricKit: AnyObject?) {
      self.repository = repository
      self.metricKit = metricKit
    }
  }

  private static func startCapture() -> NativeCrashRepository {
    captureLock.lock()
    defer { captureLock.unlock() }
    if let capture { return capture.repository }

    // With no Application Support directory the stores point at a path that
    // cannot be written, so every write fails quietly and `pending()` is
    // empty: the behaviour of the package before this plugin captured
    // anything.
    let directories =
      CrashDirectories.standard()
      ?? CrashDirectories(root: URL(fileURLWithPath: "/dev/null/otel_zone", isDirectory: true))
    directories.prepare()

    let metricKitStore = CrashFileStore(
      directory: directories.metricKit, prefix: NativeCrashRepository.metricKitPrefix)
    let exceptionStore = CrashFileStore(
      directory: directories.exceptions, prefix: NativeCrashRepository.exceptionPrefix)
    // The screen each run showed, so a MetricKit crash can be given the screen
    // of the run it came from. Swept once here, and attached to CrashScreen
    // before the exception handler is installed, so both read the same screen.
    // This run's file is written now, with no screen, so that a run that dies
    // before Dart names one still leaves a file: a reused pid then matches two
    // runs and names none, instead of matching an older run's screen.
    let screens = RunScreenLog(directory: directories.screens)
    screens.sweep()
    screens.record(nil)
    CrashScreen.shared.attach(screens)
    let repository = NativeCrashRepository(
      metricKit: metricKitStore, exceptions: exceptionStore,
      ledger: AcknowledgedExceptionLedger(file: directories.ledger), screens: screens)

    NSExceptionSource.install(store: exceptionStore)

    var subscriber: AnyObject?
    if #available(iOS 14.0, *) {
      let source = MetricKitSource(repository: repository)
      source.start()
      subscriber = source
    }

    capture = Capture(repository: repository, metricKit: subscriber)
    return repository
  }
}
