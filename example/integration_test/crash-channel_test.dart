// Runs in the app on a device: `flutter test integration_test -d <device>`.
//
// It proves the half of the harness a process cannot outlive: that the channel
// is there and validates its input. It never sends a *valid* kind — that kills
// the test process, which is what `tool/android-crash-harness.dart` drives from
// the host.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:otel_zone_example/crash-harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the crash channel is registered and refuses an unknown kind', (
    WidgetTester tester,
  ) async {
    await expectLater(
      CrashHarness.trigger('not-a-kind'),
      throwsA(
        isA<PlatformException>().having(
          (PlatformException e) => e.code,
          'code',
          'unknown-kind',
        ),
      ),
    );
  });
}
