// The Android crash harness reads the OS's exit history (`dumpsys activity
// exit-info`) to know when a record has been filed and when the previous
// install's history is gone. These are the pure readings of that dump, checked
// against dumps captured from the CI emulators.
import 'package:flutter_test/flutter_test.dart';

import '../tool/exit-info.dart';

/// The dump at the end of a passing native case (artifact `art51`, repeat run
/// 1, API 34): the crash is filed under pid 8036 as reason 5, then two force
/// stops, newest first, all for uid 10197.
const String _kept = '''
ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)
Last Timestamp of Persistence Into Persistent Storage: 2026-10-08 22:49:04.298
  package: com.example.otel_zone_example
    Historical Process Exit for uid=10197
        ApplicationExitInfo #0:
          timestamp=2026-10-08 22:49:31.375 pid=8297 realUid=10197 packageUid=10197 definingUid=10197 user=0
          process=com.example.otel_zone_example reason=10 (USER REQUESTED) subreason=21 (FORCE STOP) status=0
          importance=100 pss=0.00 rss=0.00 description=stop com.example.otel_zone_example due to from pid 8396 state=46 bytes trace=null
        ApplicationExitInfo #1:
          timestamp=2026-10-08 22:49:23.372 pid=8180 realUid=10197 packageUid=10197 definingUid=10197 user=0
          process=com.example.otel_zone_example reason=10 (USER REQUESTED) subreason=21 (FORCE STOP) status=0
          importance=100 pss=0.00 rss=0.00 description=stop com.example.otel_zone_example due to from pid 8283 state=46 bytes trace=null
        ApplicationExitInfo #2:
          timestamp=2026-10-08 22:49:14.248 pid=8036 realUid=10197 packageUid=10197 definingUid=10197 user=0
          process=com.example.otel_zone_example reason=5 (APP CRASH(NATIVE)) subreason=0 (UNKNOWN) status=11
          importance=100 pss=0.00 rss=0.00 description=crash state=46 bytes trace=null
''';

/// The dump at the end of the failing native case (artifact `art49`, job
/// 113560596835, API 34). The app crashed as pid 5059 and the OS filed it at
/// 22:04:09; this is what was left at 22:05:57. Only the force stops remain
/// under the new install's uid, and the persistence timestamp is the moment
/// the previous install's removal landed.
const String _lost = '''
ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)
Last Timestamp of Persistence Into Persistent Storage: 2026-10-08 22:04:11.860
  package: com.example.otel_zone_example
    Historical Process Exit for uid=10193
        ApplicationExitInfo #0:
          timestamp=2026-10-08 22:05:57.008 pid=7414 realUid=10193 packageUid=10193 definingUid=10193 user=0
          process=com.example.otel_zone_example reason=10 (USER REQUESTED) subreason=21 (FORCE STOP) status=0
          importance=100 pss=0.00 rss=0.00 description=stop com.example.otel_zone_example due to from pid 7506 state=46 bytes trace=null
        ApplicationExitInfo #1:
          timestamp=2026-10-08 22:05:49.166 pid=5246 realUid=10193 packageUid=10193 definingUid=10193 user=0
          process=com.example.otel_zone_example reason=10 (USER REQUESTED) subreason=21 (FORCE STOP) status=0
          importance=100 pss=221MB rss=304MB description=stop com.example.otel_zone_example due to from pid 7397 state=46 bytes trace=null
''';

/// The dump of the install that the failing run replaced (artifact `art49`,
/// the `jvm` case before it, uid 10192): a crash and two force stops, and a
/// timestamp of the epoch because nothing had been persisted since boot.
const String _previousInstall = '''
ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)
Last Timestamp of Persistence Into Persistent Storage: 1970-01-01 00:00:00.000
  package: com.example.otel_zone_example
    Historical Process Exit for uid=10192
        ApplicationExitInfo #0:
          timestamp=2026-10-08 22:03:54.743 pid=4719 realUid=10192 packageUid=10192 definingUid=10192 user=0
          process=com.example.otel_zone_example reason=10 (USER REQUESTED) subreason=21 (FORCE STOP) status=0
          importance=100 pss=0.00 rss=0.00 description=stop com.example.otel_zone_example due to from pid 4985 state=46 bytes trace=null
        ApplicationExitInfo #1:
          timestamp=2026-10-08 22:03:43.342 pid=4192 realUid=10192 packageUid=10192 definingUid=10192 user=0
          process=com.example.otel_zone_example reason=10 (USER REQUESTED) subreason=21 (FORCE STOP) status=0
          importance=100 pss=208MB rss=289MB description=stop com.example.otel_zone_example due to from pid 4697 state=46 bytes trace=null
        ApplicationExitInfo #2:
          timestamp=2026-10-08 22:03:27.665 pid=3212 realUid=10192 packageUid=10192 definingUid=10192 user=0
          process=com.example.otel_zone_example reason=4 (APP CRASH(EXCEPTION)) subreason=0 (UNKNOWN) status=0
          importance=100 pss=0.00 rss=0.00 description=crash state=46 bytes trace=null
''';

/// What `dumpsys activity exit-info <package>` prints once the OS has dropped
/// the package: the two header lines the dump always starts with, and nothing
/// else. The OS prints a package's section only while it holds one. No dump was
/// captured at that moment, so this is the captured header with the timestamp
/// that the failing run's removal wrote (the one in [_lost]).
const String _removed = '''
ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)
Last Timestamp of Persistence Into Persistent Storage: 2026-10-08 22:04:11.860
''';

/// The same header, an older persistence: the app had no history when it was
/// uninstalled, and the OS has not yet processed the removal.
const String _emptyBefore = '''
ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)
Last Timestamp of Persistence Into Persistent Storage: 2026-10-08 22:03:30.120
''';

void main() {
  group('holdsExitRecords', () {
    test('is true for a dump that lists records', () {
      expect(holdsExitRecords(_kept), isTrue);
      expect(holdsExitRecords(_previousInstall), isTrue);
    });

    test('is false for a dump of only the header', () {
      expect(holdsExitRecords(_removed), isFalse);
      expect(holdsExitRecords(''), isFalse);
    });
  });

  group('exitInfoPersistedAt', () {
    test('reads the timestamp as the OS prints it', () {
      expect(exitInfoPersistedAt(_kept), '2026-10-08 22:49:04.298');
      expect(exitInfoPersistedAt(_removed), '2026-10-08 22:04:11.860');
    });

    test('reads the epoch of a boot that has persisted nothing', () {
      expect(exitInfoPersistedAt(_previousInstall), '1970-01-01 00:00:00.000');
    });

    test('throws when the line is missing, rather than guess', () {
      expect(
        () => exitInfoPersistedAt(
          'ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)\n',
        ),
        throwsFormatException,
      );
      expect(() => exitInfoPersistedAt(''), throwsFormatException);
    });
  });

  group('holdsExitRecord', () {
    test('finds the native crash of pid 8036 as reason 5', () {
      expect(holdsExitRecord(_kept, 8036, 5), isTrue);
    });

    test('does not find pid 8036 under another reason', () {
      expect(holdsExitRecord(_kept, 8036, 10), isFalse);
      expect(holdsExitRecord(_kept, 8036, 4), isFalse);
    });

    test('never reads across two records', () {
      // pid 8180 is a force stop (reason 10); the reason-5 line that follows
      // it in the dump belongs to pid 8036.
      expect(holdsExitRecord(_kept, 8180, 5), isFalse);
      expect(holdsExitRecord(_kept, 8297, 5), isFalse);
      expect(holdsExitRecord(_kept, 8180, 10), isTrue);
    });

    test('matches the whole pid, not a prefix of it', () {
      expect(holdsExitRecord(_kept, 803, 5), isFalse);
      expect(holdsExitRecord(_kept, 80361, 5), isFalse);
    });

    test('does not mistake reason 5 for reason 15 or 50', () {
      final String other = _kept.replaceFirst('reason=5 (', 'reason=15 (');
      expect(holdsExitRecord(other, 8036, 5), isFalse);
      expect(holdsExitRecord(other, 8036, 15), isTrue);
    });

    test('has nothing to find in the dump that lost the record', () {
      expect(holdsExitRecord(_lost, 5059, 5), isFalse);
      expect(holdsExitRecord(_lost, 7414, 10), isTrue);
      expect(holdsExitRecord(_removed, 5059, 5), isFalse);
    });
  });

  group('removalSettled', () {
    test('is false while the previous install records are still listed', () {
      expect(
        removalSettled(before: _previousInstall, after: _previousInstall),
        isFalse,
      );
    });

    test('is false when the records are gone but nothing was persisted', () {
      // The records are not what proves the OS is done: the persistence that
      // follows the removal is, and it has not happened.
      final String gone =
          'ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)\n'
          'Last Timestamp of Persistence Into Persistent Storage: '
          '1970-01-01 00:00:00.000\n';
      expect(removalSettled(before: _previousInstall, after: gone), isFalse);
    });

    test(
      'is false while records are listed even if something was persisted',
      () {
        // A persistence of some other package's exit does not mean this
        // package's removal has been processed.
        final String persistedElsewhere = _previousInstall.replaceFirst(
          '1970-01-01 00:00:00.000',
          '2026-10-08 22:03:56.000',
        );
        expect(
          removalSettled(before: _previousInstall, after: persistedElsewhere),
          isFalse,
        );
      },
    );

    test('is true once the records are gone and the history was persisted', () {
      // The failing run's uninstall at 22:03:55.7, then the removal landing
      // and being persisted at 22:04:11.860.
      expect(removalSettled(before: _previousInstall, after: _removed), isTrue);
    });

    test('is true for a passing run, too', () {
      final String removedLater = _removed.replaceFirst(
        '2026-10-08 22:04:11.860',
        '2026-10-08 22:49:32.574',
      );
      expect(removalSettled(before: _kept, after: removedLater), isTrue);
    });

    test('waits on the persistence when the old install had no records', () {
      // Nothing to see disappear, so only the timestamp can say the removal
      // has been processed: unchanged is not settled, moved is.
      expect(
        removalSettled(before: _emptyBefore, after: _emptyBefore),
        isFalse,
      );
      expect(removalSettled(before: _emptyBefore, after: _removed), isTrue);
    });

    test('is not settled by the new install\'s own records', () {
      // The shape of the failing run: the removal landed after the new
      // install had crashed, so the history holds the new uid's records and a
      // moved timestamp. Waiting is what keeps the install from being here.
      expect(removalSettled(before: _previousInstall, after: _lost), isFalse);
    });

    test('throws on a dump with no persistence line, rather than guess', () {
      expect(
        () => removalSettled(before: _previousInstall, after: ''),
        throwsFormatException,
      );
    });
  });
}
