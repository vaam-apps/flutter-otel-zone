// Crashes the example app on a real Android device or emulator, relaunches it,
// and checks what the drain reported. Run from the repository root:
//
//     dart run tool/android-crash-harness.dart --device emulator-5554
//
// Flutter's `integration_test` cannot do this: the test runner lives inside the
// process that is about to die. So the driver is on the host, and it talks to
// the device with `adb` and to the app with an OTLP receiver of its own.
//
// For every kind (jvm, native, anr), from a freshly installed app:
//
//   1. launch, and wait for start() to finish (the app's own start-up line);
//      nothing may have been recovered;
//   2. `am start --es otel_crash <kind>` delivers the request to the running
//      activity, and the app kills itself on purpose;
//   3. wait until the process is gone;
//   4. relaunch: exactly ONE FATAL record of `<kind>` must have reached the
//      receiver, and the app's start-up line must say it recovered one;
//   5. relaunch once more: nothing may have been recovered.
//
// Each recovered record must also say which build died: the attributes
// `otel_zone.crashed.service.version` and `otel_zone.crashed.app.build_id`,
// which the app reads back from the process that crashed.
//
// `--upgrade-apk <apk>` adds the case that attribute exists for. After step 3
// the second build is installed *over* the first, without clearing its data,
// and step 4 then also requires the record's resource (the reporting launch)
// to name the new build while the crashed-build attributes still name the old
// one. Build the two like this, then pass the second to `--upgrade-apk`:
//
//     flutter build apk --debug --build-name 1.0.0 --build-number 1 \
//         --dart-define=APP_VERSION=1.0.0 --dart-define=APP_BUILD=1
//     cp build/app/outputs/flutter-apk/app-debug.apk /tmp/first.apk
//     flutter build apk --debug --build-name 1.0.1 --build-number 2 \
//         --dart-define=APP_VERSION=1.0.1 --dart-define=APP_BUILD=2
//

// "Reached the receiver" is the point. The assertion reads what was on the
// wire, not a marker the app prints about itself.
//
// `--release-refusal` checks the opposite, for a release build: the crash
// channel is not in the APK, and asking for a crash is refused.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'otlp-log-sink.dart';

const String _package = 'com.example.otel_zone_example';
const String _activity = '$_package/.MainActivity';
const String _extra = 'otel_crash';

/// The attributes a native crash record uses for the build that crashed.
const String _crashedVersion = 'otel_zone.crashed.service.version';
const String _crashedBuild = 'otel_zone.crashed.app.build_id';

/// The app's start-up summary, which `start()` logs after the drain has
/// exported and acknowledged, so its arrival means "the drain is over".
final RegExp _summary = RegExp(
  r'records at \w+ and above(?:, recovered (\d+) native crash)?',
);

Future<void> main(List<String> arguments) async {
  final _Options options = _Options.parse(arguments);
  final _Device device = await _Device.connect(options);
  final OtlpLogSink sink = await OtlpLogSink.bind(options.port);
  var failures = 0;
  try {
    await device.reverse(options.port);
    if (options.releaseRefusal) {
      failures += await _ReleaseRefusal(options, device).run() ? 0 : 1;
    } else {
      final String apk = await _debugApk(options);
      stdout.writeln(
        'device ${device.serial}, API ${await device.apiLevel()}, '
        'receiver on 127.0.0.1:${options.port}\n',
      );
      for (final String kind in options.kinds) {
        var passed = false;
        for (
          var attempt = 0;
          attempt <= options.retries && !passed;
          attempt++
        ) {
          if (attempt > 0) {
            stdout.writeln('  retrying $kind (attempt ${attempt + 1})');
          }
          passed = await _KindRun(kind, device, sink, apk, options).run();
        }
        if (!passed) failures++;
      }
    }
  } finally {
    await device.removeReverse(options.port);
    await sink.close();
  }
  stdout.writeln(failures == 0 ? '\nALL PASSED' : '\n$failures FAILED');
  exit(failures == 0 ? 0 : 1);
}

class _Options {
  _Options({
    required this.serial,
    required this.kinds,
    required this.port,
    required this.build,
    required this.retries,
    required this.deathTimeout,
    required this.releaseRefusal,
    required this.apk,
    required this.adb,
    required this.upgradeApk,
    required this.crashedVersion,
    required this.crashedBuild,
    required this.upgradedVersion,
    required this.upgradedBuild,
  });

  factory _Options.parse(List<String> arguments) {
    final Map<String, String> values = <String, String>{};
    final Set<String> flags = <String>{};
    for (var i = 0; i < arguments.length; i++) {
      final String argument = arguments[i];
      if (!argument.startsWith('--')) _usage('unexpected argument: $argument');
      final String name = argument.substring(2);
      const Set<String> booleans = <String>{
        'no-build',
        'release-refusal',
        'help',
      };
      if (booleans.contains(name)) {
        flags.add(name);
      } else if (i + 1 < arguments.length) {
        values[name] = arguments[++i];
      } else {
        _usage('--$name needs a value');
      }
    }
    if (flags.contains('help')) _usage(null);
    final String home =
        Platform.environment['ANDROID_HOME'] ??
        Platform.environment['ANDROID_SDK_ROOT'] ??
        '';
    return _Options(
      serial: values['device'],
      kinds: (values['kinds'] ?? 'jvm,native,anr').split(','),
      port: int.parse(values['port'] ?? '4421'),
      build: !flags.contains('no-build'),
      retries: int.parse(values['retries'] ?? '1'),
      deathTimeout: Duration(
        seconds: int.parse(values['death-timeout'] ?? '90'),
      ),
      releaseRefusal: flags.contains('release-refusal'),
      apk: values['apk'],
      adb: values['adb'] ?? (home.isEmpty ? 'adb' : '$home/platform-tools/adb'),
      upgradeApk: values['upgrade-apk'],
      crashedVersion: values['crashed-version'] ?? '1.0.0',
      crashedBuild: values['crashed-build'] ?? '1',
      upgradedVersion: values['upgraded-version'] ?? '1.0.1',
      upgradedBuild: values['upgraded-build'] ?? '2',
    );
  }

  final String? serial;
  final List<String> kinds;
  final int port;
  final bool build;
  final int retries;
  final Duration deathTimeout;
  final bool releaseRefusal;
  final String? apk;
  final String adb;

  /// When set, this build is installed over the crashed one before relaunch.
  final String? upgradeApk;

  /// The version and build the crashing APK was built as.
  final String crashedVersion;
  final String crashedBuild;

  /// The version and build of [upgradeApk].
  final String upgradedVersion;
  final String upgradedBuild;

  String get endpoint => 'http://127.0.0.1:$port';

  static Never _usage(String? error) {
    if (error != null) stderr.writeln('error: $error\n');
    stderr.writeln(
      '''
usage: dart run tool/android-crash-harness.dart [options]

  --device <serial>      adb serial (required when more than one is attached)
  --kinds <a,b,c>        crash kinds to run; default jvm,native,anr
  --port <n>             local receiver port; default 4421
  --apk <path>           debug APK to install; default: build one
  --no-build             use the existing APK instead of building
  --retries <n>          re-run a failed kind this many times; default 1
  --death-timeout <s>    how long to wait for the process to die; default 90
  --upgrade-apk <path>   install this build over the crashed one (data kept)
                         before relaunching, and check the record names the
                         crashed build while its resource names this one
  --crashed-version <v>  versionName the crashing APK was built as; 1.0.0
  --crashed-build <n>    versionCode of the crashing APK; 1
  --upgraded-version <v> versionName of --upgrade-apk; 1.0.1
  --upgraded-build <n>   versionCode of --upgrade-apk; 2
  --release-refusal      instead, prove a release build refuses to crash
  --adb <path>           adb executable; default \$ANDROID_HOME/platform-tools/adb''',
    );
    exit(error == null ? 0 : 64);
  }
}

Future<String> _debugApk(_Options options) async {
  final String path =
      options.apk ?? 'example/build/app/outputs/flutter-apk/app-debug.apk';
  if (options.build && options.apk == null) {
    await _run('flutter', <String>[
      'build',
      'apk',
      '--debug',
      '--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=${options.endpoint}',
    ], workingDirectory: 'example');
  }
  if (!File(path).existsSync()) {
    stderr.writeln('no APK at $path (run without --no-build)');
    exit(64);
  }
  return path;
}

Future<String> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final ProcessResult result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} exited ${result.exitCode}\n'
      '${result.stdout}${result.stderr}',
    );
  }
  return '${result.stdout}';
}

/// One attached device, and the handful of `adb` operations the harness needs.
class _Device {
  _Device(this.adb, this.serial);

  final String adb;
  final String serial;

  static Future<_Device> connect(_Options options) async {
    final String listing = await _run(options.adb, <String>['devices']);
    final List<String> serials = <String>[
      for (final String line in const LineSplitter().convert(listing).skip(1))
        if (line.endsWith('\tdevice')) line.split('\t').first,
    ];
    final String? serial =
        options.serial ?? (serials.length == 1 ? serials.single : null);
    if (serial == null) {
      stderr.writeln(
        serials.isEmpty
            ? 'no adb device attached'
            : 'several devices attached (${serials.join(', ')}); pass --device',
      );
      exit(64);
    }
    return _Device(options.adb, serial);
  }

  Future<String> shell(List<String> command) =>
      _run(adb, <String>['-s', serial, 'shell', ...command]);

  Future<String> adbCommand(List<String> arguments) =>
      _run(adb, <String>['-s', serial, ...arguments]);

  Future<int> apiLevel() async => int.parse(
    (await shell(<String>['getprop', 'ro.build.version.sdk'])).trim(),
  );

  Future<void> reverse(int port) =>
      adbCommand(<String>['reverse', 'tcp:$port', 'tcp:$port']);

  Future<void> removeReverse(int port) async {
    try {
      await adbCommand(<String>['reverse', '--remove', 'tcp:$port']);
    } on Object {
      // Best effort: the device may already be gone.
    }
  }

  /// A fresh install, so no earlier run's exit records or watermark survive.
  Future<void> reinstall(String apk) async {
    try {
      await adbCommand(<String>['uninstall', _package]);
    } on Object {
      // Not installed yet.
    }
    await adbCommand(<String>['install', '-r', '-t', apk]);
  }

  /// Installs [apk] over the installed app, keeping its data: what an update
  /// from a store does, and what `reinstall` deliberately does not.
  Future<void> upgrade(String apk) =>
      adbCommand(<String>['install', '-r', '-t', apk]);

  Future<int?> pid() async {
    final ProcessResult result = await Process.run(adb, <String>[
      '-s',
      serial,
      'shell',
      'pidof',
      _package,
    ]);
    final String out = '${result.stdout}'.trim();
    return out.isEmpty ? null : int.tryParse(out.split(' ').first);
  }

  Future<void> forceStop() => shell(<String>['am', 'force-stop', _package]);

  /// Starts the activity and returns the first start-up summary logged after
  /// this call, or `null` if it never came.
  Future<_Summary?> launch({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    await adbCommand(<String>['logcat', '-c']);
    await shell(<String>['am', 'start', '-W', '-n', _activity]);
    return waitForSummary(timeout);
  }

  Future<_Summary?> waitForSummary(Duration timeout) async {
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < timeout) {
      final String log = await adbCommand(<String>[
        'logcat',
        '-d',
        '-s',
        'flutter:I',
      ]);
      final RegExpMatch? match = _summary.firstMatch(log);
      if (match != null) {
        return _Summary(int.parse(match.group(1) ?? '0'), match.group(0)!);
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }

  Future<bool> waitForDeath(Duration timeout) async {
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < timeout) {
      if (await pid() == null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  Future<String> exitInfo() =>
      shell(<String>['dumpsys', 'activity', 'exit-info', _package]);
}

class _Summary {
  const _Summary(this.recovered, this.line);

  final int recovered;
  final String line;
}

/// One kind, end to end.
class _KindRun {
  _KindRun(this.kind, this.device, this.sink, this.apk, this.options);

  final String kind;
  final _Device device;
  final OtlpLogSink sink;
  final String apk;
  final _Options options;

  final List<String> _problems = <String>[];

  void _expect(bool condition, String message) {
    if (!condition) _problems.add(message);
  }

  Future<bool> run() async {
    stdout.writeln('== $kind');
    // The ANR path needs the OS to kill the app the moment it declares the
    // ANR. With the dialog enabled the process lives until someone taps
    // "Close app"; this setting makes the OS do that itself and is restored
    // below either way.
    final String? hideDialogs = kind == 'anr'
        ? await _hideErrorDialogs(device)
        : null;
    try {
      await device.reinstall(apk);
      sink.clear();

      final _Summary? first = await device.launch();
      _expect(first != null, 'launch 1: no start-up line within the timeout');
      _expect(
        first?.recovered == 0,
        'launch 1: recovered ${first?.recovered}, expected 0',
      );
      await _settle();
      _expect(_kinds().isEmpty, 'launch 1: unexpected records ${_kinds()}');
      stdout.writeln('  launch 1: "${first?.line}"');

      sink.clear();
      await _trigger();
      final bool died = await device.waitForDeath(options.deathTimeout);
      _expect(
        died,
        'the process did not die within ${options.deathTimeout.inSeconds}s',
      );
      stdout.writeln('  process died: $died');

      final String? upgradeApk = options.upgradeApk;
      if (upgradeApk != null) {
        await device.upgrade(upgradeApk);
        stdout.writeln(
          '  upgraded ${options.crashedVersion}+${options.crashedBuild} to '
          '${options.upgradedVersion}+${options.upgradedBuild} in place',
        );
      }

      final _Summary? second = await device.launch();
      await _settle();
      final List<SinkRecord> received = sink.records;
      stdout.writeln('  launch 2: "${second?.line}"');
      for (final SinkRecord record in received) {
        stdout.writeln('    received $record');
      }
      _expect(second != null, 'launch 2: no start-up line within the timeout');
      _expect(
        second?.recovered == 1,
        'launch 2: recovered ${second?.recovered}, expected 1',
      );
      _expect(
        _kinds().length == 1 && _kinds().single == kind,
        'launch 2: expected exactly one "$kind" record, received ${_kinds()}',
      );
      final Iterable<SinkRecord> crashes = received.where(
        (SinkRecord r) => r.crashKind != null,
      );
      _expect(
        crashes.every((SinkRecord r) => r.isFatal),
        'launch 2: a recovered crash was not FATAL',
      );
      // The build that crashed, from the crashed process; the resource, from
      // the launch that reported it. After an upgrade they differ.
      final String resourceVersion = upgradeApk == null
          ? options.crashedVersion
          : options.upgradedVersion;
      final String resourceBuild = upgradeApk == null
          ? options.crashedBuild
          : options.upgradedBuild;
      for (final SinkRecord r in crashes) {
        stdout.writeln(
          '    crashed build ${r.attributes[_crashedVersion]}+'
          '${r.attributes[_crashedBuild]}, resource '
          '${r.resource['service.version']}+${r.resource['app.build_id']}',
        );
        _expect(
          r.attributes[_crashedVersion] == options.crashedVersion,
          'launch 2: $_crashedVersion is ${r.attributes[_crashedVersion]}, '
          'expected ${options.crashedVersion}',
        );
        _expect(
          r.attributes[_crashedBuild] == options.crashedBuild,
          'launch 2: $_crashedBuild is ${r.attributes[_crashedBuild]}, '
          'expected ${options.crashedBuild}',
        );
        _expect(
          r.resource['service.version'] == resourceVersion,
          'launch 2: resource service.version is '
          '${r.resource['service.version']}, expected $resourceVersion',
        );
        _expect(
          r.resource['app.build_id'] == resourceBuild,
          'launch 2: resource app.build_id is ${r.resource['app.build_id']}, '
          'expected $resourceBuild',
        );
      }
      final String event = kind == 'anr' ? 'device.anr' : 'device.crash';
      _expect(
        crashes.every((SinkRecord r) => r.eventName == event),
        'launch 2: expected event.name "$event", got ${crashes.map((SinkRecord r) => r.eventName).toList()}',
      );

      sink.clear();
      await device.forceStop();
      final _Summary? third = await device.launch();
      await _settle();
      stdout.writeln('  launch 3: "${third?.line}"');
      _expect(third != null, 'launch 3: no start-up line within the timeout');
      _expect(
        third?.recovered == 0,
        'launch 3: recovered ${third?.recovered}, expected 0',
      );
      _expect(_kinds().isEmpty, 'launch 3: duplicate records ${_kinds()}');
    } finally {
      await device.forceStop();
      if (kind == 'anr') await _restoreErrorDialogs(device, hideDialogs);
    }

    if (_problems.isEmpty) {
      stdout.writeln('  PASS $kind: drained exactly once, then zero\n');
      return true;
    }
    for (final String problem in _problems) {
      stdout.writeln('  FAIL $kind: $problem');
    }
    stdout.writeln('');
    return false;
  }

  List<String> _kinds() => <String>[
    for (final SinkRecord r in sink.records)
      if (r.crashKind != null) r.crashKind!,
  ];

  /// The receiver is fed before the summary is logged; this only covers a
  /// record that is still in flight.
  Future<void> _settle() => Future<void>.delayed(const Duration(seconds: 2));

  Future<void> _trigger() async {
    await device.shell(<String>[
      'am',
      'start',
      '-n',
      _activity,
      '--es',
      _extra,
      kind,
    ]);
    if (kind == 'anr') {
      // Blocking the main thread is not enough on its own: the OS declares an
      // ANR only when something waits on the thread, and an idle app has
      // nobody waiting. A tap is the waiter; the ANR lands 5 s after it.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await device.shell(<String>['input', 'tap', '540', '1200']);
    }
  }
}

Future<String?> _hideErrorDialogs(_Device device) async {
  final String previous = (await device.shell(<String>[
    'settings',
    'get',
    'global',
    'hide_error_dialogs',
  ])).trim();
  await device.shell(<String>[
    'settings',
    'put',
    'global',
    'hide_error_dialogs',
    '1',
  ]);
  return previous;
}

Future<void> _restoreErrorDialogs(_Device device, String? previous) async {
  if (previous == null || previous == 'null' || previous.isEmpty) {
    await device.shell(<String>[
      'settings',
      'delete',
      'global',
      'hide_error_dialogs',
    ]);
  } else {
    await device.shell(<String>[
      'settings',
      'put',
      'global',
      'hide_error_dialogs',
      previous,
    ]);
  }
}

/// The release-build half: nothing to crash with, and a refusal when asked.
class _ReleaseRefusal {
  _ReleaseRefusal(this.options, this.device);

  final _Options options;
  final _Device device;

  static const String _debugApkPath =
      'example/build/app/outputs/flutter-apk/app-debug.apk';
  static const String _releaseApkPath =
      'example/build/app/outputs/flutter-apk/app-release.apk';

  /// Strings that exist only in the debug harness: its channel name and its
  /// exception message.
  static const List<String> _markers = <String>[
    'otel_zone_example/crash',
    'induced JVM crash',
  ];

  Future<bool> run() async {
    if (options.build) {
      for (final String mode in <String>['debug', 'release']) {
        await _run('flutter', <String>[
          'build',
          'apk',
          '--$mode',
          '--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=${options.endpoint}',
        ], workingDirectory: 'example');
      }
    }
    var ok = true;

    stdout.writeln('== static: harness strings in the built dex');
    for (final String marker in _markers) {
      final int inDebug = await _dexHits(_debugApkPath, marker);
      final int inRelease = await _dexHits(_releaseApkPath, marker);
      final bool good = inDebug > 0 && inRelease == 0;
      stdout.writeln(
        '  "$marker": debug APK ${inDebug > 0 ? 'has it' : 'MISSING'}, '
        'release APK ${inRelease == 0 ? 'absent' : 'PRESENT'} '
        '${good ? 'ok' : 'FAIL'}',
      );
      ok &= good;
    }

    stdout.writeln('\n== runtime: a release build refuses every kind');
    await device.reinstall(_releaseApkPath);
    await device.adbCommand(<String>['logcat', '-c']);
    await device.shell(<String>['am', 'start', '-W', '-n', _activity]);
    await Future<void>.delayed(const Duration(seconds: 8));
    final int? before = await device.pid();
    stdout.writeln('  release app running as pid $before');
    ok &= before != null;
    for (final String kind in options.kinds) {
      await device.shell(<String>[
        'am',
        'start',
        '-n',
        _activity,
        '--es',
        _extra,
        kind,
      ]);
      if (kind == 'anr') {
        // The tap a real ANR would need; harmless if nothing is blocked.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        await device.shell(<String>['input', 'tap', '540', '1200']);
      }
      await Future<void>.delayed(const Duration(seconds: 12));
      final int? after = await device.pid();
      final bool survived = after == before;
      stdout.writeln(
        '  asked for "$kind": pid $after, ${survived ? 'survived' : 'DIED'}',
      );
      ok &= survived;
    }
    final String log = await device.adbCommand(<String>[
      'logcat',
      '-d',
      '-s',
      'OtelZoneCrashHarness:W',
      'AndroidRuntime:E',
    ]);
    stdout.writeln(
      const LineSplitter()
          .convert(log)
          .where((String l) => l.trim().isNotEmpty)
          .map((String l) => '  $l')
          .join('\n'),
    );
    final bool refused = log.contains('refused: crash requests are debug-only');
    final bool noFatal = !log.contains('FATAL EXCEPTION');
    final String exits = await device.exitInfo();
    final bool noExit =
        !exits.contains('reason=4 (') &&
        !exits.contains('reason=6 (') &&
        !exits.contains('reason=5 (');
    stdout.writeln(
      '  refusal logged: $refused; no FATAL EXCEPTION: $noFatal; '
      'no crash/ANR exit record: $noExit',
    );
    ok &= refused && noFatal && noExit;

    // A control for the matcher above: a check that greps a dump for a format
    // it has never seen would pass vacuously. Force-stopping the app makes the
    // OS file a REASON_USER_REQUESTED record, so the dump must now contain a
    // `reason=<n> (` line at all; if it does not, the format has changed and
    // the "no crash/ANR exit record" verdict above means nothing.
    await device.forceStop();
    final String after = await device.exitInfo();
    final List<String> reasons = <String>[
      for (final RegExpMatch m in RegExp(
        r'reason=\d+ \([^)]*\)',
      ).allMatches(after))
        m.group(0)!,
    ];
    final bool parsed = reasons.isNotEmpty;
    stdout.writeln(
      '  exit-info control: after a force-stop the dump lists $reasons '
      '(${parsed ? 'format recognised' : 'FORMAT NOT RECOGNISED'})',
    );
    ok &= parsed;
    stdout.writeln(ok ? '  PASS release refuses the crash channel' : '  FAIL');
    return ok;
  }

  /// How many times [marker] occurs in the APK's dex files. Dex strings are
  /// plain (modified) UTF-8, so a byte search is enough.
  Future<int> _dexHits(String apk, String marker) async {
    final Process unzip = await Process.start('unzip', <String>[
      '-p',
      apk,
      'classes*.dex',
    ]);
    final List<int> bytes = <int>[
      for (final List<int> chunk in await unzip.stdout.toList()) ...chunk,
    ];
    unawaited(unzip.stderr.drain<void>());
    await unzip.exitCode;
    final List<int> needle = utf8.encode(marker);
    var hits = 0;
    outer:
    for (var i = 0; i + needle.length <= bytes.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (bytes[i + j] != needle[j]) continue outer;
      }
      hits++;
    }
    return hits;
  }
}
