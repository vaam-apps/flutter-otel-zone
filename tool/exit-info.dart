// What the crash harness reads out of the OS's exit history, kept apart from
// the `adb` plumbing so it can be tested without a device. The history is what
// `dumpsys activity exit-info <package>` prints; see `_Device.reinstall` and
// `_Device.waitForExitRecord` in `android-crash-harness.dart` for how it is
// used, and `holdsExitRecord` for the one reading that decides a verdict.

final RegExp _anyRecord = RegExp(r'reason=\d+ \(');

final RegExp _persistedAt = RegExp(
  r'Last Timestamp of Persistence Into Persistent Storage: (.+)',
);

/// Whether [dump] lists at least one exit record, of any process and reason.
///
/// A dump lists a record as `reason=<n> (<NAME>)`; a package the OS holds
/// nothing for is the two header lines alone.
bool holdsExitRecords(String dump) => _anyRecord.hasMatch(dump);

/// When the OS last wrote its exit history to storage, as the dump prints it:
/// `2026-10-08 22:04:11.860`, or `1970-01-01 00:00:00.000` on a boot that has
/// not written it yet.
///
/// The OS writes the history out at once when a package is removed, and
/// otherwise only every half hour, so a removal moves this. The string is
/// compared, never parsed: it is only ever asked whether it changed. Throws a
/// [FormatException] when the line is missing, because a dump in a format this
/// does not know cannot say that anything settled, and a harness that guessed
/// would stop waiting.
String exitInfoPersistedAt(String dump) {
  final RegExpMatch? match = _persistedAt.firstMatch(dump);
  if (match == null) {
    throw FormatException(
      'no "Last Timestamp of Persistence Into Persistent Storage" line in the '
      'exit-info dump',
      dump,
    );
  }
  return match.group(1)!.trim();
}

/// Whether [dump] holds the record of [pid] having died for [reason], one of
/// `ApplicationExitInfo`'s `REASON_*` constants (4 a Java crash, 5 a native
/// crash, 6 an ANR, 10 a user request such as a force stop).
///
/// The match stays inside one record: it starts at `pid=<pid>` and may run on
/// to a `reason=<n> (` of the same record, never past the next
/// `ApplicationExitInfo`. So a pid that died for another reason is not found
/// because the next process in the dump died for this one, and `803` is not
/// found in `pid=8036`.
bool holdsExitRecord(String dump, int pid, int reason) => RegExp(
  'pid=$pid\\b(?:(?!ApplicationExitInfo)[\\s\\S])*?reason=$reason \\(',
).hasMatch(dump);

/// Whether the OS has finished taking the app's previous install out of its
/// exit history, given the dump [before] the app was uninstalled and the dump
/// [after], taken since.
///
/// The OS does it after the uninstall has returned, not during it: the package
/// manager broadcasts the removal and the activity manager's receiver then
/// destroys every exit record filed under the package name, whatever uid it
/// was filed for, and writes the history out. A crash of the *next* install
/// that is filed before that broadcast is handled is destroyed with the old
/// one's records, and the harness then reads no record for a crash that
/// happened.
///
/// It is settled when no record is listed and the history was written since
/// [before]. Both are needed. The records going away alone can be read before
/// the write, and the write alone can be the half-hourly one, or another
/// package's, with this package's records still listed. The write also covers
/// an old install that had no records at all, which leaves nothing to watch
/// disappear but still moves the timestamp. Throws a [FormatException] when
/// [after] has no timestamp (see [exitInfoPersistedAt]).
bool removalSettled({required String before, required String after}) =>
    !holdsExitRecords(after) &&
    exitInfoPersistedAt(after) != exitInfoPersistedAt(before);
