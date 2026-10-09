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
//   3. wait until the process is gone, and until the OS has filed its exit
//      record for it: the process being gone is not the OS knowing, and a
//      launch that beats the record reads nothing;
//   4. relaunch: exactly ONE FATAL record of `<kind>` must have reached the
//      receiver;
//   5. relaunch once more: nothing may have been recovered.
//
// "Freshly installed" includes the OS having forgotten the previous install:
// uninstalling returns before the activity manager has dropped that install's
// exit records, and dropping them later would take the new install's with them.
// `_Device.reinstall` waits for it, on the OS's own state, before it installs.
//
// A launch is judged once it has been quiet for `--settle` seconds, not when
// the first start-up line appears. Android relaunches an activity in the same
// process, by itself, whenever an asset path or the package's application info
// changes, which is routine just after an install or a boot; the second engine
// runs `start()` again. So the receiver's total is what is asserted, and the
// start-up line's "recovered N" is required to be exactly 1 only when the
// activity was not relaunched (the engine that recovered the crash can be torn
// down before it logs). `--relaunch-after <ms,...>` provokes that relaunch on
// purpose, one run per delay; the window in which it once duplicated a crash is
// tens of milliseconds wide, so it is meant to be swept.
//
// There are no retries unless `--retries` asks for them: a run that needs one
// is a defect, and `--repeat <n>` is how a flake is measured.
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

import 'exit-info.dart';
import 'log-window.dart';
import 'otlp-log-sink.dart';

const String _package = 'com.example.otel_zone_example';
const String _activity = '$_package/.MainActivity';
const String _extra = 'otel_crash';

/// The attributes a native crash record uses for the build that crashed.
const String _crashedVersion = 'otel_zone.crashed.service.version';
const String _crashedBuild = 'otel_zone.crashed.app.build_id';

/// The app's start-up summary, which `start()` logs once the drain has made
/// the crash durable and acknowledged it, and the spool has been replayed. It
/// does not mean the collector has the crash yet, which is why a launch is
/// judged on what the receiver got and not on this line arriving.
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
        var passes = 0;
        var runs = 0;
        for (var round = 1; round <= options.repeat; round++) {
          for (final int? relaunchAfter in options.relaunchDelays) {
            runs++;
            var passed = false;
            for (
              var attempt = 0;
              attempt <= options.retries && !passed;
              attempt++
            ) {
              if (attempt > 0) {
                stdout.writeln('  retrying $kind (attempt ${attempt + 1})');
              }
              final String tag =
                  '$kind-$runs${attempt > 0 ? '-retry$attempt' : ''}';
              passed = await _KindRun(
                kind,
                device,
                sink,
                apk,
                options,
                tag,
                relaunchAfter,
              ).run();
            }
            if (passed) {
              passes++;
            } else {
              failures++;
            }
          }
        }
        if (runs > 1) stdout.writeln('$kind: $passes/$runs runs passed\n');
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
    required this.repeat,
    required this.logDir,
    required this.relaunchDelays,
    required this.settle,
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
      retries: int.parse(values['retries'] ?? '0'),
      repeat: int.parse(values['repeat'] ?? '1'),
      logDir: values['log-dir'],
      relaunchDelays: <int?>[
        if (values['relaunch-after'] == null)
          null
        else
          for (final String ms in values['relaunch-after']!.split(','))
            int.parse(ms),
      ],
      settle: Duration(seconds: int.parse(values['settle'] ?? '3')),
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
  final int repeat;
  final String? logDir;

  /// How long after each recovery launch starts the OS is made to relaunch
  /// the activity, one run per delay; `null` for none.
  final List<int?> relaunchDelays;

  /// How long a launch must stay quiet before it is judged.
  final Duration settle;
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
  --retries <n>          re-run a failed kind this many times; default 0
  --repeat <n>           run each kind n times, every run must pass; default 1
  --settle <s>           how long a launch must stay quiet, with no new
                         start-up line and no new record, before it is judged;
                         default 3
  --relaunch-after <ms,ms,...>
                         make Android relaunch the activity, in the same
                         process, this long after each recovery launch starts;
                         one run per delay
  --log-dir <path>       keep each run's full logcat and exit-info dump here
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
  ///
  /// `adb uninstall` returns when the package manager is done, not the
  /// activity manager. The package manager then broadcasts the removal, and
  /// when the activity manager's receiver gets it, which on a loaded emulator
  /// can be seconds later, it destroys every exit record filed under the
  /// package *name*: the new install's too, if it has already crashed. Installed
  /// straight away, the next install can crash and have its record filed
  /// before that happens, and the harness then reads nothing for a crash that
  /// did happen (`received []`). So this dumps the exit history first, and
  /// after the uninstall waits until the OS says it has dropped it
  /// ([removalSettled]) before it installs, polling every half a second and
  /// throwing a [StateError] after two minutes, as it does when `adb` fails.
  /// The wait is on the OS's own state and is not a retry: the run itself is
  /// untouched and nothing it asserts is relaxed.
  ///
  /// [upgrade] needs none of this. Replacing an install broadcasts a removal
  /// marked as a replacement, which the activity manager ignores, so the
  /// history is kept: that is the point of an update.
  Future<void> reinstall(String apk) async {
    const Duration pause = Duration(milliseconds: 500);
    const Duration timeout = Duration(seconds: 120);
    final String before = await exitInfo();
    var uninstalled = false;
    try {
      await adbCommand(<String>['uninstall', _package]);
      uninstalled = true;
    } on Object {
      // Not installed yet: no removal is coming, so nothing to wait for.
    }
    if (uninstalled) {
      final Stopwatch clock = Stopwatch()..start();
      String after = await exitInfo();
      while (!removalSettled(before: before, after: after)) {
        if (clock.elapsed >= timeout) {
          throw StateError(
            'the OS still held the previous install\'s exit history '
            '${timeout.inSeconds}s after it was uninstalled\n$after',
          );
        }
        await Future<void>.delayed(pause);
        after = await exitInfo();
      }
      stdout.writeln(
        '  previous install left the exit history after '
        '${clock.elapsedMilliseconds} ms',
      );
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

  /// Tells the running app its `ApplicationInfo` changed, which makes Android
  /// destroy and recreate its activities in the same process: the relaunch the
  /// OS does by itself when a package is updated or its assets change.
  Future<void> updateAppInfo() async {
    try {
      await shell(<String>['am', 'update-appinfo', '0', _package]);
    } on Object {
      // Best effort.
    }
  }

  String? _since;

  /// Opens this launch's window on the device log: everything logged from now
  /// on, and nothing before.
  ///
  /// The log is cleared first, but only as housekeeping, and it is allowed to
  /// fail: on a freshly booted emulator `logcat -c` can refuse to clear a
  /// buffer for a few seconds ("failed to clear the 'main' log"), and it is
  /// retried for that. What guarantees that a read-back holds this launch's
  /// lines and no other's is [_since], the device's own clock at this moment,
  /// which every read passes to `logcat -T`. A clear that never succeeds
  /// therefore costs a longer buffer to search and nothing else.
  Future<void> markLog() async {
    await succeedsWithin(
      () => adbCommand(<String>['logcat', '-b', 'all', '-c']),
      onFailure: (Object error, int attempt) => stdout.writeln(
        '  logcat clear failed (attempt $attempt), '
        '${error.toString().trim().replaceAll('\n', ' ')}',
      ),
    );
    _since = logcatSince(await shell(<String>['date', '+%s.%N']));
  }

  /// `logcat`'s arguments for reading only what was logged since [markLog].
  List<String> get _sinceMark {
    final String? since = _since;
    if (since == null) throw StateError('the log was read before markLog()');
    return <String>['-T', since];
  }

  /// Starts the activity, first marking the log so that what is read back
  /// belongs to this launch.
  ///
  /// [relaunchAfter] makes the OS relaunch the activity that long after the
  /// start was requested.
  Future<void> start({Duration? relaunchAfter}) async {
    await markLog();
    if (relaunchAfter != null) {
      Timer(relaunchAfter, () => unawaited(updateAppInfo()));
    }
    await shell(<String>['am', 'start', '-W', '-n', _activity]);
  }

  /// Every start-up line the app has logged since the log was last marked,
  /// in order, each with the line it came from (which names the process).
  ///
  /// More than one when the activity was relaunched in the same process: each
  /// engine runs `start()` and logs its own.
  Future<List<_Summary>> summaries() async {
    final String log = await adbCommand(<String>[
      'logcat',
      '-d',
      ..._sinceMark,
      '-v',
      'threadtime',
      '-s',
      'flutter:I',
    ]);
    return <_Summary>[
      for (final String line in const LineSplitter().convert(log))
        for (final RegExpMatch match in _summary.allMatches(line))
          _Summary(
            int.parse(match.group(1) ?? '0'),
            line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '').trim(),
          ),
    ];
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

  /// How many times the main activity was created since the log was last
  /// marked. More than once means Android relaunched it, in the same process.
  Future<int> activityCreations() async {
    final String log = await adbCommand(<String>[
      'logcat',
      '-d',
      ..._sinceMark,
      '-b',
      'events',
      '-s',
      'wm_on_create_called',
    ]);
    return const LineSplitter()
        .convert(log)
        .where((String line) => line.contains('.MainActivity'))
        .length;
  }

  /// Waits until the OS has filed an exit record of [reason] for [pid].
  ///
  /// The process being gone (`pidof`) is not the OS knowing it: the record is
  /// written by the activity manager afterwards, and on a loaded device that
  /// can be many seconds later. A relaunch in between reads no record, reports
  /// nothing, and the crash turns up on a later launch instead.
  Future<bool> waitForExitRecord(
    int pid,
    int reason, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < timeout) {
      if (holdsExitRecord(await exitInfo(), pid, reason)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  /// Streams the whole device log (every buffer, with pid and time) into
  /// [path] until [_LogCapture.stop].
  Future<_LogCapture> captureLog(String path) async {
    final Process process = await Process.start(adb, <String>[
      '-s',
      serial,
      'logcat',
      '-v',
      'threadtime',
      '-b',
      'all',
    ]);
    unawaited(process.stderr.drain<void>());
    final IOSink sink = File(path).openWrite();
    return _LogCapture(process, sink, process.stdout.pipe(sink));
  }
}

/// A running `adb logcat` that is being written to a file.
class _LogCapture {
  _LogCapture(this._process, this._sink, this._done);

  final Process _process;
  final IOSink _sink;
  final Future<void> _done;

  Future<void> stop() async {
    _process.kill();
    try {
      await _done;
    } on Object {
      await _sink.close();
    }
  }
}

class _Summary {
  const _Summary(this.recovered, this.line);

  final int recovered;
  final String line;
}

/// What one launch did: every start-up line the app logged and every record
/// the receiver was sent, once the launch went quiet.
class _Launch {
  const _Launch(this.summaries, this.records, this.creations);

  final List<_Summary> summaries;
  final List<SinkRecord> records;

  /// How many times the main activity was created. Two or more is a relaunch
  /// in the same process, which the OS does on its own after an install or a
  /// boot and which a start-up line can be lost to: the engine that would have
  /// logged it is torn down first.
  final int creations;

  bool get relaunched => creations > 1;

  /// How many native crashes the app said it recovered, over every start-up
  /// line: a relaunched activity runs `start()` again, in the same process.
  int get recovered =>
      summaries.fold(0, (int n, _Summary s) => n + s.recovered);

  List<String> get kinds => <String>[
    for (final SinkRecord r in records)
      if (r.crashKind != null) r.crashKind!,
  ];
}

/// One kind, end to end.
class _KindRun {
  _KindRun(
    this.kind,
    this.device,
    this.sink,
    this.apk,
    this.options,
    this.tag,
    this.relaunchAfter,
  );

  final String kind;
  final String tag;
  final _Device device;
  final OtlpLogSink sink;
  final String apk;
  final _Options options;

  /// When the OS is made to relaunch the activity during the recovery launch,
  /// or `null` to leave it alone.
  final int? relaunchAfter;

  final List<String> _problems = <String>[];

  void _expect(bool condition, String message) {
    if (!condition) _problems.add(message);
  }

  /// The `ApplicationExitInfo` reason the OS files for each kind of death.
  int get _exitReason => switch (kind) {
    'jvm' => 4, // REASON_CRASH
    'native' => 5, // REASON_CRASH_NATIVE
    _ => 6, // REASON_ANR
  };

  Future<bool> run() async {
    stdout.writeln(
      '== $kind'
      '${relaunchAfter == null ? '' : ' (activity relaunched ${relaunchAfter}ms into the recovery launch)'}',
    );
    // The ANR path needs the OS to kill the app the moment it declares the
    // ANR. With the dialog enabled the process lives until someone taps
    // "Close app"; this setting makes the OS do that itself and is restored
    // below either way.
    final String? hideDialogs = kind == 'anr'
        ? await _hideErrorDialogs(device)
        : null;
    final String? logDir = options.logDir;
    _LogCapture? capture;
    if (logDir != null) {
      Directory(logDir).createSync(recursive: true);
      capture = await device.captureLog('$logDir/$tag.logcat.txt');
    }
    try {
      await device.reinstall(apk);

      final _Launch first = await _launch(expected: 0);
      _expect(
        first.summaries.isNotEmpty,
        'launch 1: no start-up line within the timeout',
      );
      _expect(
        first.recovered == 0,
        'launch 1: recovered ${first.recovered}, expected 0',
      );
      _expect(
        first.kinds.isEmpty,
        'launch 1: unexpected records ${first.kinds}',
      );
      stdout.writeln('  launch 1: ${_lines(first)}');

      final int? crashing = await device.pid();
      await _trigger();
      final bool died = await device.waitForDeath(options.deathTimeout);
      _expect(
        died,
        'the process did not die within ${options.deathTimeout.inSeconds}s',
      );
      stdout.writeln('  process died: $died');
      // Gone is not recorded: the OS files its exit record afterwards, and a
      // launch that beats it reads nothing.
      final bool recorded =
          crashing != null &&
          await device.waitForExitRecord(crashing, _exitReason);
      _expect(recorded, 'the OS filed no exit record for pid $crashing');
      stdout.writeln('  exit record filed: $recorded');

      final String? upgradeApk = options.upgradeApk;
      if (upgradeApk != null) {
        await device.upgrade(upgradeApk);
        stdout.writeln(
          '  upgraded ${options.crashedVersion}+${options.crashedBuild} to '
          '${options.upgradedVersion}+${options.upgradedBuild} in place',
        );
      }

      final int? relaunch = relaunchAfter;
      final _Launch second = await _launch(
        expected: 1,
        relaunchAfter: relaunch == null
            ? null
            : Duration(milliseconds: relaunch),
      );
      stdout.writeln(
        '  launch 2: ${_lines(second)}'
        '${second.relaunched ? '\n            (the activity was relaunched: created ${second.creations} times)' : ''}',
      );
      for (final SinkRecord record in second.records) {
        stdout.writeln('    received $record');
      }
      _expect(
        second.summaries.isNotEmpty || second.relaunched,
        'launch 2: no start-up line within the timeout',
      );
      // What reached the receiver is the assertion; the start-up line is a
      // second opinion. After a relaunch it can be missing — the engine that
      // recovered the crash was torn down before it logged — or say 0, from
      // the engine that found the report already spooled. Never more than one.
      if (second.relaunched) {
        _expect(
          second.recovered <= 1,
          'launch 2: recovered ${second.recovered} in total, expected at most 1',
        );
      } else {
        _expect(
          second.recovered == 1,
          'launch 2: recovered ${second.recovered}, expected 1',
        );
      }
      _expect(
        second.kinds.length == 1 && second.kinds.single == kind,
        'launch 2: expected exactly one "$kind" record, '
        'received ${second.kinds}',
      );
      if (crashing != null && !second.kinds.contains(kind)) {
        // Not an assertion of its own: the one above has already failed. It
        // says which of the two ways a record goes missing this was.
        _problems.add(await _whereTheRecordWent(crashing));
      }
      final Iterable<SinkRecord> crashes = second.records.where(
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

      await device.forceStop();
      final _Launch third = await _launch(expected: 0);
      stdout.writeln('  launch 3: ${_lines(third)}');
      _expect(
        third.summaries.isNotEmpty,
        'launch 3: no start-up line within the timeout',
      );
      _expect(
        third.recovered == 0,
        'launch 3: recovered ${third.recovered}, expected 0',
      );
      _expect(
        third.kinds.isEmpty,
        'launch 3: duplicate records ${third.kinds}',
      );
    } finally {
      await device.forceStop();
      if (kind == 'anr') await _restoreErrorDialogs(device, hideDialogs);
    }

    if (_problems.isEmpty) {
      stdout.writeln('  PASS $kind: drained exactly once, then zero\n');
      await _keepEvidence(logDir, capture);
      return true;
    }
    for (final String problem in _problems) {
      stdout.writeln('  FAIL $kind: $problem');
    }
    stdout.writeln('');
    await _keepEvidence(logDir, capture, print: true);
    return false;
  }

  /// Where the OS's record of [pid]'s death is now that launch 2 reported none:
  /// still in its history, so the app lost it, or gone from it, so the OS did.
  Future<String> _whereTheRecordWent(int pid) async {
    try {
      final String dump = await device.exitInfo();
      return holdsExitRecord(dump, pid, _exitReason)
          ? "launch 2: the OS still holds pid $pid's record (the app lost it)"
          : "launch 2: the OS removed pid $pid's record "
                '(last persisted ${exitInfoPersistedAt(dump)})';
    } on Object catch (error) {
      return "launch 2: could not read the OS's exit history to say where "
          "pid $pid's record went: $error";
    }
  }

  /// The start-up lines of [launch], with the process each came from.
  String _lines(_Launch launch) => launch.summaries.isEmpty
      ? 'no start-up line'
      : launch.summaries
            .map((_Summary s) => '"${s.line}"')
            .join('\n            ');

  /// Starts the app and waits until the launch has gone quiet: at least one
  /// start-up line, at least [expected] recovered records at the receiver, and
  /// then nothing new for [_Options.settle].
  ///
  /// It is not enough to take the first start-up line and read the receiver a
  /// moment later. The activity can be relaunched in the same process — Android
  /// does it by itself when an asset path or a package's application info
  /// changes, which is routine in the first seconds after an install or a boot
  /// — and the second engine then runs `start()` again. That is not a fault
  /// in itself; what is under test is what reached the receiver, in total.
  Future<_Launch> _launch({
    required int expected,
    Duration? relaunchAfter,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    sink.clear();
    await device.start(relaunchAfter: relaunchAfter);
    final Stopwatch clock = Stopwatch()..start();
    var fingerprint = '';
    var changedAt = clock.elapsed;
    _Launch latest = const _Launch(<_Summary>[], <SinkRecord>[], 0);
    while (clock.elapsed < timeout) {
      latest = _Launch(
        await device.summaries(),
        sink.records,
        await device.activityCreations(),
      );
      final String now =
          '${latest.summaries.length}/${latest.records.length}/'
          '${latest.creations}';
      if (now != fingerprint) {
        fingerprint = now;
        changedAt = clock.elapsed;
      }
      final bool complete =
          (latest.summaries.isNotEmpty || latest.relaunched) &&
          latest.kinds.length >= expected;
      if (complete && clock.elapsed - changedAt >= options.settle) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return latest;
  }

  /// Stops the log capture and keeps what the OS itself recorded about the
  /// deaths, so a failure can be read afterwards instead of re-run.
  ///
  /// A failed run also prints the lines that decide the outcome — process
  /// starts and deaths, the crash, the activity lifecycle, the app's own
  /// output — because a CI log is the one place a flake is seen.
  Future<void> _keepEvidence(
    String? logDir,
    _LogCapture? capture, {
    bool print = false,
  }) async {
    if (logDir == null || capture == null) return;
    await capture.stop();
    final String exits = await device.exitInfo();
    File('$logDir/$tag.exit-info.txt').writeAsStringSync(exits);
    if (!print) return;
    stdout.writeln('  --- exit-info after the run ---\n$exits');
    final RegExp interesting = RegExp(
      r'am_proc_start|am_proc_died|am_crash|am_kill|am_proc_bound|'
      r'wm_create_activity|wm_restart_activity|wm_finish_activity|'
      r'wm_task_(created|removed)|wm_destroy_activity|ActivityTaskManager: START|'
      r'Force finishing|Sending signal|Fatal signal|tombstoned|'
      r'OtelZone|flutter *:|Zygote *: Process|has died',
    );
    final List<String> lines = <String>[
      for (final String line in File(
        '$logDir/$tag.logcat.txt',
      ).readAsLinesSync())
        if (line.contains(_package) ||
            (interesting.hasMatch(line) &&
                !line.contains(' DEBUG '))) ...<String>[line],
    ];
    stdout.writeln('  --- log ($tag), ${lines.length} lines ---');
    for (final String line in lines.take(400)) {
      stdout.writeln('  $line');
    }
  }

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
    await device.markLog();
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
      ...device._sinceMark,
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
