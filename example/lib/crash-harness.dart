// Induces a native death on purpose, so crash capture can be exercised.
//
// Debug builds only. The native half of the channel is compiled into the debug
// build alone (`android/app/src/debug/.../CrashHarness.kt` and the `#if DEBUG`
// block in `ios/Runner/AppDelegate.swift`); in a release build there is no
// handler, and [CrashHarness.trigger] answers `false` instead of throwing.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The kinds of death each platform can be asked for.
abstract final class CrashKinds {
  /// An uncaught exception on the Android main thread.
  static const String jvm = 'jvm';

  /// A SIGSEGV raised against the Android process.
  static const String native = 'native';

  /// The Android main thread held until the OS declares an ANR.
  static const String anr = 'anr';

  /// An uncaught `NSException` on iOS.
  static const String nsexception = 'nsexception';

  /// A `SIGABRT` raised against the iOS process.
  static const String signal = 'signal';

  /// What the running platform accepts.
  static List<String> get supported {
    if (kIsWeb) return const <String>[];
    if (Platform.isAndroid) return const <String>[jvm, native, anr];
    if (Platform.isIOS) return const <String>[nsexception, signal];
    return const <String>[];
  }
}

/// Asks the native side to die.
abstract final class CrashHarness {
  static const MethodChannel _channel = MethodChannel(
    'otel_zone_example/crash',
  );

  /// Requests a crash of [kind].
  ///
  /// Returns `true` when the platform accepted the request — the process then
  /// dies shortly after, so a caller never sees anything else happen — and
  /// `false` when this build has no harness, which is the case in every release
  /// and profile build. An unknown [kind] throws a [PlatformException].
  static Future<bool> trigger(String kind) async {
    // Refused before the channel is touched: nothing here is meant to run
    // outside a debug build, whatever the native side does.
    if (!kDebugMode) return false;
    try {
      await _channel.invokeMethod<void>('crash', kind);
      return true;
    } on MissingPluginException {
      return false;
    }
  }
}

/// One button per kind the platform accepts. Shown in debug builds only.
///
/// The host scripts do not need it — they trigger the same crashes from
/// outside — but a person verifying on a real device does: Xcode's "Simulate
/// MetricKit Payloads" covers MetricKit, and this is the only way to make a
/// real `NSException` happen on a phone with no tooling attached.
class CrashHarnessPanel extends StatelessWidget {
  /// Creates the panel.
  const CrashHarnessPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final List<String> kinds = CrashKinds.supported;
    if (!kDebugMode || kinds.isEmpty) return const SizedBox.shrink();
    return Column(
      children: <Widget>[
        const Text('Crash harness (debug builds only)'),
        Wrap(
          spacing: 8,
          children: <Widget>[
            for (final String kind in kinds)
              OutlinedButton(
                onPressed: () => CrashHarness.trigger(kind),
                child: Text('Crash: $kind'),
              ),
          ],
        ),
      ],
    );
  }
}
