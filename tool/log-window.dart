// The two pieces of the crash harness that decide which log lines belong to a
// launch, kept apart from the `adb` plumbing so they can be tested without a
// device. See `_Device.markLog` in `android-crash-harness.dart` for how they fit.

/// Runs [action] until it completes without throwing, at most [attempts] times
/// with [pause] between them, and says whether one did.
///
/// Every failure is handed to [onFailure] (with the 1-based attempt it ended)
/// so the caller can print it: a swallowed error nobody sees is how a flake
/// turns into a mystery.
Future<bool> succeedsWithin(
  Future<void> Function() action, {
  int attempts = 5,
  Duration pause = const Duration(seconds: 1),
  void Function(Object error, int attempt)? onFailure,
}) async {
  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      await action();
      return true;
    } on Object catch (error) {
      onFailure?.call(error, attempt);
      if (attempt < attempts) await Future<void>.delayed(pause);
    }
  }
  return false;
}

final RegExp _deviceClock = RegExp(r'^(\d+)\.(\d{9})$');

/// What `logcat -T` takes for a moment, from the device's `date +%s.%N`.
///
/// `1790702832.364939263` becomes `1790702832.364`: logcat reads
/// `<seconds>.<milliseconds>` since the epoch as a time, so this is the
/// device's own clock and no time zone comes into it. Throws a
/// [FormatException] on anything else, because a moment that is guessed at
/// would put another launch's lines in this one's window.
String logcatSince(String dateOutput) {
  final RegExpMatch? match = _deviceClock.firstMatch(dateOutput.trim());
  if (match == null) {
    throw FormatException(
      'expected the device clock as <seconds>.<nanoseconds> '
      '(`date +%s.%N`)',
      dateOutput,
    );
  }
  return '${match.group(1)}.${match.group(2)!.substring(0, 3)}';
}
