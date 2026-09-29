// The iOS simulator counterpart of `android-crash-harness.dart`, for the one
// path a simulator can exercise: an uncaught NSException.
//
//     dart run tool/ios-crash-harness.dart --device <simulator udid or name>
//
// What a simulator cannot do is deliver MetricKit, so a `SIGABRT`/`SIGSEGV`
// death (MetricKit's job) and a hang cannot be seen here; the README's
// "manual device verification" runbook covers them. An NSException, though, is
// written to disk by the plugin's own chained handler at the moment it is
// thrown, which is what this drives:
//
//   1. launch the app; nothing may be recovered;
//   2. launch it again with `-otel_crash nsexception`; it raises one and dies;
//   3. launch: exactly ONE FATAL `nsexception` record must reach the receiver,
//      and the app's start-up line must say it recovered one;
//   4. launch once more: nothing may be recovered.
//
// A simulator shares the host's network, so the receiver needs no `adb
// reverse` equivalent: the app posts to 127.0.0.1 and lands here.
import 'dart:async';
import 'dart:io';

import 'otlp-log-sink.dart';

const String _bundle = 'com.example.otelZoneExample';
const String _appPath = 'example/build/ios/iphonesimulator/Runner.app';
final RegExp _recovered = RegExp(r'recovered (\d+) native crash');

Future<void> main(List<String> arguments) async {
  String? device;
  var port = 4421;
  var build = true;
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--device':
        device = arguments[++i];
      case '--port':
        port = int.parse(arguments[++i]);
      case '--no-build':
        build = false;
      default:
        stderr.writeln(
          'usage: dart run tool/ios-crash-harness.dart --device <udid|name> '
          '[--port n] [--no-build]',
        );
        exit(64);
    }
  }
  if (device == null) {
    stderr.writeln('--device is required: a booted simulator');
    exit(64);
  }

  if (build) {
    await _run('flutter', <String>[
      'build',
      'ios',
      '--simulator',
      '--debug',
      '--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:$port',
    ], workingDirectory: 'example');
  }

  final OtlpLogSink sink = await OtlpLogSink.bind(port);
  final _Run run = _Run(device, sink);
  final bool passed;
  try {
    passed = await run.execute();
  } finally {
    await sink.close();
  }
  stdout.writeln(passed ? '\nALL PASSED' : '\nFAILED');
  exit(passed ? 0 : 1);
}

class _Run {
  _Run(this.device, this.sink);

  final String device;
  final OtlpLogSink sink;
  final List<String> _problems = <String>[];

  void _expect(bool condition, String message) {
    if (!condition) _problems.add(message);
  }

  Future<bool> execute() async {
    stdout.writeln('== nsexception on simulator $device');
    try {
      await _simctl(<String>['uninstall', device, _bundle], allowFailure: true);
      await _simctl(<String>['install', device, _appPath]);

      sink.clear();
      final String? first = await _launchAndWaitForSummary();
      _expect(first != null, 'launch 1: no start-up record within the timeout');
      _expect(_crashes().isEmpty, 'launch 1: unexpected records ${_crashes()}');
      stdout.writeln('  launch 1: "${_line(first)}"');
      await _terminate();

      final int pid = await _launch(<String>['-otel_crash', 'nsexception']);
      final bool died = await _waitForExit(pid);
      _expect(died, 'the crash launch (pid $pid) did not die');
      stdout.writeln('  crash launch: pid $pid, died: $died');
      await _terminate();

      sink.clear();
      final String? second = await _launchAndWaitForSummary();
      await Future<void>.delayed(const Duration(seconds: 2));
      stdout.writeln('  launch 2: "${_line(second)}"');
      for (final SinkRecord record in sink.records.where(
        (SinkRecord r) => r.crashKind != null,
      )) {
        stdout.writeln('    received $record');
        stdout.writeln(
          '      stacktrace attribute present: '
          '${record.attributes.containsKey('exception.stacktrace')}',
        );
      }
      _expect(
        second != null,
        'launch 2: no start-up record within the timeout',
      );
      _expect(
        _recoveredCount(second) == 1,
        'launch 2: recovered ${_recoveredCount(second)}, expected 1',
      );
      _expect(
        _crashes().length == 1 && _crashes().single.crashKind == 'nsexception',
        'launch 2: expected exactly one nsexception record, got '
        '${_crashes().map((SinkRecord r) => r.crashKind).toList()}',
      );
      _expect(
        _crashes().every(
          (SinkRecord r) => r.isFatal && r.eventName == 'device.crash',
        ),
        'launch 2: the record was not a FATAL device.crash',
      );
      await _terminate();

      sink.clear();
      final String? third = await _launchAndWaitForSummary();
      await Future<void>.delayed(const Duration(seconds: 2));
      stdout.writeln('  launch 3: "${_line(third)}"');
      _expect(third != null, 'launch 3: no start-up record within the timeout');
      _expect(
        _recoveredCount(third) == 0,
        'launch 3: recovered ${_recoveredCount(third)}, expected 0',
      );
      _expect(_crashes().isEmpty, 'launch 3: duplicate records ${_crashes()}');
    } finally {
      await _terminate();
    }
    if (_problems.isEmpty) {
      stdout.writeln('  PASS nsexception: drained exactly once, then zero');
      return true;
    }
    for (final String problem in _problems) {
      stdout.writeln('  FAIL nsexception: $problem');
    }
    return false;
  }

  List<SinkRecord> _crashes() => <SinkRecord>[
    for (final SinkRecord r in sink.records)
      if (r.crashKind != null) r,
  ];

  String? _line(String? body) {
    if (body == null) return null;
    final int at = body.indexOf('records at');
    return at < 0 ? body : body.substring(at);
  }

  int? _recoveredCount(String? body) {
    if (body == null) return null;
    final RegExpMatch? match = _recovered.firstMatch(body);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  /// The body of the start-up summary record, which `start()` logs once the
  /// drain has finished, or `null` if none reaches the receiver in time.
  Future<String?> _launchAndWaitForSummary() async {
    await _launch(const <String>[]);
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 90)) {
      for (final SinkRecord record in sink.records) {
        final String? body = record.body;
        if (body != null && body.contains('records at ')) return body;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }

  Future<int> _launch(List<String> appArguments) async {
    final String out = await _simctl(<String>[
      'launch',
      device,
      _bundle,
      ...appArguments,
    ]);
    return int.parse(RegExp(r':\s*(\d+)').firstMatch(out)!.group(1)!);
  }

  Future<void> _terminate() =>
      _simctl(<String>['terminate', device, _bundle], allowFailure: true);

  /// Simulator processes are ordinary host processes, so `kill -0` sees them.
  Future<bool> _waitForExit(int pid) async {
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 60)) {
      if ((await Process.run('kill', <String>['-0', '$pid'])).exitCode != 0) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }
}

Future<String> _simctl(List<String> arguments, {bool allowFailure = false}) =>
    _run('xcrun', <String>['simctl', ...arguments], allowFailure: allowFailure);

Future<String> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  bool allowFailure = false,
}) async {
  final ProcessResult result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0 && !allowFailure) {
    throw StateError(
      '$executable ${arguments.join(' ')} exited ${result.exitCode}\n'
      '${result.stdout}${result.stderr}',
    );
  }
  return '${result.stdout}';
}
