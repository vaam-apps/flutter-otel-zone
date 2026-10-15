import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;

import 'native-crash.g.dart';

/// The longest screen, in UTF-8 bytes, that [normalizeCrashScreen] keeps.
///
/// A route pattern is short. The limit is the Android process state summary's:
/// the OS keeps 128 bytes per process, and the screen is the first field to be
/// dropped when they do not fit.
const int maxCrashScreenBytes = 64;

/// The screen [value] names once it is cleaned, or `null` when it names none.
///
/// The value is trimmed. It is `null` when it is absent, when it is empty
/// after trimming, when it is longer than [maxCrashScreenBytes] in UTF-8, or
/// when any character is a control character (U+0000 to U+001F, U+007F to
/// U+009F). A value is never cut to fit: a cut route is a wrong route.
String? normalizeCrashScreen(String? value) {
  if (value == null) return null;
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (utf8.encode(trimmed).length > maxCrashScreenBytes) return null;
  for (final int rune in trimmed.runes) {
    if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) return null;
  }
  return trimmed;
}

/// Where the screen goes: the platform, or a fake in a test.
///
/// Implementations should not throw synchronously; a failure is reported
/// through the returned future, and [CrashScreenForwarder] handles it.
abstract interface class CrashScreenSink {
  /// Sends [screen] to the platform, where `null` clears it.
  Future<void> setCrashScreen(String? screen);
}

/// The [CrashScreenSink] that sends the screen over the plugin's Pigeon
/// channel.
class PigeonCrashScreenSink implements CrashScreenSink {
  /// Wraps [api], or the plugin's default channel when it is omitted.
  PigeonCrashScreenSink([CrashContextApi? api])
    : _api = api ?? CrashContextApi();

  final CrashContextApi _api;

  @override
  Future<void> setCrashScreen(String? screen) => _api.setCrashScreen(screen);
}

/// A [CrashScreenSink] for tests: it keeps every screen it is asked to send,
/// in order, and completes at once.
class RecordingCrashScreenSink implements CrashScreenSink {
  /// Every screen [setCrashScreen] was called with, `null` included.
  final List<String?> screens = <String?>[];

  @override
  Future<void> setCrashScreen(String? screen) async {
    screens.add(screen);
  }
}

/// Carries the latest screen to the platform without ever having more than
/// one message in flight.
///
/// A change made while a message is in flight is not sent alongside it: the
/// latest value is sent once the flight lands, and the values in between are
/// never sent. Nothing waits on a timer.
///
/// Supported only with a [sink], on Android and iOS, and not on the web. Elsewhere
/// [set] does nothing.
final class CrashScreenForwarder {
  /// Forwards to [sink], warning through [onWarning].
  ///
  /// [isWeb] and [platform] exist so the no-op on the other platforms can be
  /// tested off them; they default to the real platform flag and to
  /// `defaultTargetPlatform`.
  CrashScreenForwarder(
    CrashScreenSink? sink, {
    required void Function(String message) onWarning,
    bool? isWeb,
    TargetPlatform? platform,
  }) : _sink = sink,
       _onWarning = onWarning,
       _supported =
           sink != null &&
           !(isWeb ?? kIsWeb) &&
           _nativePlatforms.contains(platform ?? defaultTargetPlatform);

  /// The platforms the plugin registers the Pigeon channel on.
  static const Set<TargetPlatform> _nativePlatforms = <TargetPlatform>{
    TargetPlatform.android,
    TargetPlatform.iOS,
  };

  final CrashScreenSink? _sink;
  final void Function(String message) _onWarning;
  final bool _supported;

  /// The screen the app wants the platform to hold.
  String? _wanted;

  /// The screen the platform last accepted, or failed to accept.
  String? _sent;

  bool _inFlight = false;

  /// Set when the channel is gone for this process: nothing more is sent.
  bool _stopped = false;

  bool _warned = false;

  /// Asks for [screen] to be held by the platform.
  void set(String? screen) {
    _wanted = screen;
    _pump();
  }

  void _pump() {
    final CrashScreenSink? sink = _sink;
    if (sink == null ||
        !_supported ||
        _stopped ||
        _inFlight ||
        _wanted == _sent) {
      return;
    }
    final String? next = _wanted;
    _inFlight = true;
    unawaited(_settle(_send(sink, next), next));
  }

  /// [screen] handed to [sink]. A synchronous throw becomes a failed future,
  /// so there is one way a failure arrives.
  static Future<void> _send(CrashScreenSink sink, String? screen) {
    try {
      return sink.setCrashScreen(screen);
    } on Object catch (error) {
      return Future<void>.error(error);
    }
  }

  Future<void> _settle(Future<void> sent, String? next) async {
    try {
      await sent;
    } on Object catch (error) {
      try {
        _failed(error);
      } on Object {
        // A warning that fails costs only itself: the flight still settles.
      }
    } finally {
      _sent = next;
      _inFlight = false;
      _pump();
    }
  }

  void _failed(Object error) {
    // No channel means no plugin on this platform or in this process, and
    // that does not change while the app runs: stop, quietly.
    if (error is MissingPluginException ||
        (error is PlatformException && error.code == 'channel-error')) {
      _stopped = true;
      return;
    }
    // The type only, never the message or the screen: a message can carry
    // whatever the platform put in it.
    if (_warned) return;
    _warned = true;
    _onWarning(
      'The crash screen did not reach the platform '
      '(${error.runtimeType}); later failures are not reported.',
    );
  }
}
