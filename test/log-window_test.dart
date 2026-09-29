// The crash harness scopes what it reads back from the device log to one
// launch. These are the two pure pieces of that, checked without a device.
import 'package:flutter_test/flutter_test.dart';

import '../tool/log-window.dart';

void main() {
  group('succeedsWithin', () {
    test('returns true at the first success and does not run again', () async {
      var runs = 0;
      final bool ok = await succeedsWithin(() async => runs++);
      expect(ok, isTrue);
      expect(runs, 1);
    });

    test('retries a failure and reports each one', () async {
      var runs = 0;
      final List<int> failedAttempts = <int>[];
      final bool ok = await succeedsWithin(
        () async {
          runs++;
          if (runs < 3) throw StateError('failed to clear the main log');
        },
        pause: Duration.zero,
        onFailure: (Object error, int attempt) => failedAttempts.add(attempt),
      );
      expect(ok, isTrue);
      expect(runs, 3);
      expect(failedAttempts, <int>[1, 2]);
    });

    test('gives up after the attempts it was given, and says so', () async {
      var runs = 0;
      final bool ok = await succeedsWithin(
        () async {
          runs++;
          throw StateError('never clears');
        },
        attempts: 4,
        pause: Duration.zero,
      );
      expect(ok, isFalse);
      expect(runs, 4);
    });

    test('waits between attempts', () async {
      final Stopwatch clock = Stopwatch()..start();
      await succeedsWithin(
        () async => throw StateError('no'),
        attempts: 3,
        pause: const Duration(milliseconds: 100),
      );
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(200));
    });
  });

  group('logcatSince', () {
    test('cuts the device clock to the milliseconds logcat reads', () {
      expect(logcatSince('1790702832.364939263\n'), '1790702832.364');
    });

    test('truncates and does not round', () {
      expect(logcatSince('1790702832.999999999'), '1790702832.999');
    });

    test('keeps leading zeros of the fraction', () {
      expect(logcatSince('1790702832.007000000'), '1790702832.007');
    });

    test('refuses anything that is not seconds.nanoseconds', () {
      for (final String bad in <String>[
        '',
        '1790702832',
        '1790702832.%N',
        '1790702832.364',
        '09-29 19:27:12.401',
        'date: bad',
      ]) {
        expect(() => logcatSince(bad), throwsFormatException, reason: bad);
      }
    });
  });
}
