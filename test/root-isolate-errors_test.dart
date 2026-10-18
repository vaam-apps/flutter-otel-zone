// `listenForRootIsolateErrors`, off the browser: on the web it is a no-op that
// returns false and touches nothing, and on the VM it listens and returns true.
// The browser half, that `runGuarded` runs its body on the web, is
// `run-guarded-web_test.dart`, which plain `flutter test` skips.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/src/root-isolate-errors.dart';

void main() {
  test('on the web it tries nothing, warns nothing and returns false', () {
    final List<String> warnings = <String>[];
    var reported = false;

    final bool listening = listenForRootIsolateErrors(
      onError: (Object error, StackTrace stackTrace) => reported = true,
      onWarning: warnings.add,
      isWeb: true,
    );

    expect(listening, isFalse);
    expect(warnings, isEmpty);
    expect(reported, isFalse);
  });

  test('off the web it listens, warns nothing and returns true', () {
    final List<String> warnings = <String>[];

    final bool listening = listenForRootIsolateErrors(
      onError: (Object error, StackTrace stackTrace) {},
      onWarning: warnings.add,
      isWeb: false,
    );

    expect(listening, isTrue);
    expect(warnings, isEmpty);
  });
}
