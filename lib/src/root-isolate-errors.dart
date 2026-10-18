import 'dart:isolate';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Reports the errors the root isolate raises outside any zone (a
/// platform-channel handler a plugin registered, say) to [onError], and
/// returns whether it is listening.
///
/// Not on the web, which has no isolates: `dart:isolate` compiles for a browser
/// but Dart's web runtime throws `UnsupportedError` from it (from
/// `ReceivePort.listen` and `sendPort` under DDC and dart2js, from the
/// `ReceivePort` constructor under wasm), and before 0.8.1 that throw kept
/// `OtelZone.runGuarded` from running its body. On the web this tries nothing
/// and returns `false`.
///
/// Never throws. Anywhere else a failure to listen is one line on [onWarning]
/// and `false`: an error hook is never the reason an app does not start.
/// [isWeb] exists so the web's no-op can be tested off it; it defaults to
/// `kIsWeb`.
bool listenForRootIsolateErrors({
  required void Function(Object error, StackTrace stackTrace) onError,
  required void Function(String message) onWarning,
  bool? isWeb,
}) {
  if (isWeb ?? kIsWeb) return false;
  ReceivePort? port;
  try {
    port = ReceivePort();
    // `[String error, String stackTrace]`, already stringified: an arbitrary
    // error object may not be sendable across an isolate boundary.
    port.listen((dynamic pair) {
      if (pair is! List || pair.length < 2) return;
      onError(
        pair.first?.toString() ?? 'Unknown isolate error',
        StackTrace.fromString(pair.last?.toString() ?? ''),
      );
    });
    Isolate.current.addErrorListener(port.sendPort);
    return true;
  } on Object catch (error) {
    port?.close();
    onWarning(
      'Errors raised outside any zone on the root isolate are not '
      'reported: Isolate.addErrorListener is unavailable '
      '(${error.runtimeType}).',
    );
    return false;
  }
}
