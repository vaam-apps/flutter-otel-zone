// What `riverpodObserver()` puts on the wire, with no `redact` at all.
//
// The argument is dropped by the observer, not by the scrubber, so this file
// configures none: a family argument must not leave the device whether or not
// the app supplied a redactor, which is the whole point of the default.
//
// Real sockets, through `OtelZone.start()`. In its own file because
// `OTel.initialize()` may only be called once per isolate.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_zone/otel_zone.dart';
import 'package:riverpod/experimental/mutation.dart';
import 'package:riverpod/riverpod.dart';

import 'support/local-collector.dart';

final _lookup = Provider.family<int, String>(
  (Ref ref, String query) => query.length,
);

void main() {
  late LocalCollector collector;
  late OtelZone zone;

  setUpAll(() async {
    collector = await LocalCollector.start();
    zone = OtelZone(
      OtelZoneConfig(
        serviceName: 'riverpod-observer-test',
        endpoint: collector.endpoint,
        useConsoleLogs: false,
        enableLogs: false,
      ),
      sink: RecordingTalkerObserver(),
    );
    await zone.start(serviceVersion: '1.2.3');
  });

  tearDownAll(() => collector.close());

  Future<String> wireAfter(void Function() emit) async {
    final int before = collector.requests.length;
    emit();
    await OTel.tracerProvider().forceFlush();
    await collector.waitForRequests(before + 1);
    return collector.requests.skip(before).map((r) => r.body).join('\n');
  }

  test('the SDK is up, so the assertions below can fail', () {
    expect(zone.isReady, isTrue);
  });

  test('records no family argument by default', () async {
    final ProviderContainer container = ProviderContainer(
      observers: <ProviderObserver>[?zone.riverpodObserver()],
    );
    addTearDown(container.dispose);

    final String wire = await wireAfter(
      () => container.read(_lookup('search-query-nobody-typed')),
    );

    // The span is there and says what it is...
    expect(wire, contains('provider.added:'));
    expect(wire, contains('riverpod.provider.family'));
    // ...and the argument is not.
    expect(wire, isNot(contains('search-query-nobody-typed')));
    expect(wire, isNot(contains('riverpod.provider.argument')));
  });

  test(
    'records it when asked to, and only for the observer that was',
    () async {
      final ProviderContainer optedIn = ProviderContainer(
        observers: <ProviderObserver>[
          ?zone.riverpodObserver(recordArguments: true),
        ],
      );
      final ProviderContainer optedOut = ProviderContainer(
        observers: <ProviderObserver>[?zone.riverpodObserver()],
      );
      addTearDown(optedIn.dispose);
      addTearDown(optedOut.dispose);

      final String wire = await wireAfter(() {
        optedIn.read(_lookup('typed-and-recorded'));
        optedOut.read(_lookup('typed-and-dropped'));
      });

      expect(wire, contains('typed-and-recorded'));
      expect(wire, isNot(contains('typed-and-dropped')));
    },
  );

  test('a value is still not recorded by default either', () async {
    final ProviderContainer container = ProviderContainer(
      observers: <ProviderObserver>[?zone.riverpodObserver()],
    );
    addTearDown(container.dispose);
    final Provider<String> secret = Provider<String>(
      (Ref ref) => 'state-secret',
    );

    final String wire = await wireAfter(() => container.read(secret));

    expect(wire, contains('provider.added:'));
    expect(wire, isNot(contains('state-secret')));
  });

  group('a keyed mutation', () {
    // `otel_riverpod` records `mutation.toString()` as `riverpod.mutation`,
    // and a keyed mutation renders its key there:
    // `Mutation<int>#d9771(+237690000001, label: addToCart)`.
    final Mutation<int> addToCart = Mutation<int>(label: 'addToCart');
    final Provider<int> cart = Provider<int>((Ref ref) => 1);

    Future<String> wireOfMutation(ProviderObserver? observer) async {
      final ProviderContainer container = ProviderContainer(
        observers: <ProviderObserver>[?observer],
      );
      addTearDown(container.dispose);
      return wireAfter(
        () => addToCart(
          'mutation-key-nobody-typed',
        ).run(container, (MutationTransaction tsx) async => tsx.get(cart)),
      );
    }

    test(
      'is recorded by the upstream observer, so the test below can fail',
      () async {
        final String wire = await wireOfMutation(
          zone.riverpodObserver(recordArguments: true),
        );

        expect(wire, contains('riverpod.mutation'));
        expect(wire, contains('mutation-key-nobody-typed'));
      },
    );

    test('leaves its key off the wire by default', () async {
      final String wire = await wireOfMutation(zone.riverpodObserver());

      expect(wire, contains('provider.added:'));
      expect(wire, isNot(contains('mutation-key-nobody-typed')));
      expect(wire, isNot(contains('riverpod.mutation')));
    });
  });
}
