// What a build's configured severity floor resolves to, and what it says
// when it cannot resolve the value it was given.
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:talker/talker.dart';

void main() {
  group('parseLogLevel', () {
    test('accepts every level Talker declares', () {
      for (final LogLevel level in LogLevel.values) {
        expect(parseLogLevel(level.name), level);
      }
    });

    test('is insensitive to case and surrounding whitespace', () {
      // The value normally arrives from a .env key or a --dart-define,
      // where both are easy to leave in.
      expect(parseLogLevel('  WARNING '), LogLevel.warning);
      expect(parseLogLevel('Error'), LogLevel.error);
    });

    test('returns null rather than guessing', () {
      expect(parseLogLevel('chatty'), isNull);
      expect(parseLogLevel(''), isNull);
    });
  });

  group('ExportFloor.parse', () {
    test('takes the level the build named', () {
      final ExportFloor floor = ExportFloor.parse('debug');
      expect(floor.level, LogLevel.debug);
      expect(floor.unrecognised, isNull);
    });

    test('falls back to the quiet end and remembers what was written', () {
      // Not a tautology: the *direction* of this fallback is the decision.
      // Defaulting loud bills a user on a metered connection for someone
      // else's typo, and the value is kept so the app can say so out loud
      // instead of silently changing what the build sends.
      final ExportFloor floor = ExportFloor.parse('loud');
      expect(floor.level, LogLevel.warning);
      expect(floor.unrecognised, 'loud');
      expect(ExportFloor.defaultLevel, LogLevel.warning);
    });

    test('an explicit fallback is honoured', () {
      expect(
        ExportFloor.parse('loud', fallback: LogLevel.error).level,
        LogLevel.error,
      );
    });
  });

  group('ExportFloor.carries', () {
    const ExportFloor floor = ExportFloor.of(LogLevel.warning);

    test('withholds everything below and keeps everything above', () {
      expect(floor.carries(LogLevel.verbose), isFalse);
      expect(floor.carries(LogLevel.debug), isFalse);
      expect(floor.carries(LogLevel.info), isFalse);
      expect(floor.carries(LogLevel.warning), isTrue);
      expect(floor.carries(LogLevel.error), isTrue);
      expect(floor.carries(LogLevel.critical), isTrue);
    });

    test(
      'a record with no level is treated as info, as the exporter would',
      () {
        expect(floor.carries(null), isFalse);
        expect(const ExportFloor.of(LogLevel.info).carries(null), isTrue);
      },
    );

    test('ranks by severity, not by the enum declaration order', () {
      // `LogLevel` is declared `error, critical, info, debug, verbose,
      // warning` — comparing `LogLevel.index` would rank `warning` (5)
      // below `verbose` (4) and export the whole stream. This is the test
      // that fails if anyone "simplifies" the comparison.
      expect(LogLevel.warning.index, greaterThan(LogLevel.verbose.index));
      expect(floor.carries(LogLevel.warning), isTrue);
      expect(floor.carries(LogLevel.verbose), isFalse);
    });
  });

  group('ExportFloor.withholdsBreadcrumbs', () {
    test('stops at debug, where the trail is already on the wire', () {
      expect(
        const ExportFloor.of(LogLevel.warning).withholdsBreadcrumbs,
        isTrue,
      );
      expect(const ExportFloor.of(LogLevel.info).withholdsBreadcrumbs, isTrue);
      expect(
        const ExportFloor.of(LogLevel.debug).withholdsBreadcrumbs,
        isFalse,
        reason: 'every record a trail is built from is already exported',
      );
      expect(
        const ExportFloor.of(LogLevel.verbose).withholdsBreadcrumbs,
        isFalse,
      );
    });
  });
}
