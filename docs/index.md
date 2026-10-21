---
layout: home
title: otel_zone
titleTemplate: OpenTelemetry for Flutter, on a metered radio

hero:
  name: otel_zone
  text: One Talker, one OpenTelemetry SDK, one guarded zone.
  tagline: Every uncaught error in a Flutter app lands on the same sink — with a severity floor so a phone on a metered connection is not billed for telemetry nobody reads.
  image:
    src: /logo.svg
    alt: otel_zone
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: How it fits together
      link: /concepts/
    - theme: alt
      text: GitHub
      link: https://github.com/vaam-apps/flutter-otel-zone

features:
  - title: All four error channels
    details: runGuarded wires FlutterError.onError, PlatformDispatcher.onError, the zone's own handler and Isolate.addErrorListener to one reporting function. Anything less means a class of crash never reaches the logs.
    link: /concepts/guarded-zone
    linkText: The guarded zone
  - title: A severity floor, with breadcrumbs
    details: Only records at or above the floor are exported. An error or critical record brings the records that preceded it along as one breadcrumb record, so volume scales with faults, not with taps.
    link: /concepts/export-floor
    linkText: The export floor
  - title: Native crashes, recovered
    details: Android's ApplicationExitInfo and JVM handler, iOS's MetricKit and NSException handler, read on the next launch over one Pigeon channel and exported as FATAL records that name, when known, the build and screen that died.
    link: /guide/native-crashes
    linkText: Native crashes
  - title: Never in the functional path
    details: start() never throws, safely() swallows instrumentation that would, and the observers are only built when the SDK is up. A failed span costs a span, never a feature.
    link: /concepts/never-blocks
    linkText: Failure isolation
---

## Why it exists

`otel_zone` was extracted from the Vaam Store mobile app, where all of it was
measured against a real collector and a real prepaid network in Cameroon.
Every default in the package is the value that app ships, and the reasoning
for each lives in the doc comment next to it.

The number that shaped it: 7,715 records off one set of release builds, and
**96.5% of them chatter** — one record per provider initialisation, per
provider state change, per navigation. A cost that scales with how much
someone _uses the app_, paid on a prepaid metered connection. The
[export floor](/concepts/export-floor) is the answer, and the rest of the
package exists so the floor can be trusted.

## At a glance

```dart
final OtelZone observability = OtelZone(
  const OtelZoneConfig(
    serviceName: 'my-app',
    endpoint: 'http://localhost:4318',
  ),
);

Future<void> main() => observability.runGuarded(() async {
  WidgetsFlutterBinding.ensureInitialized();
  await observability.start(serviceVersion: '1.2.3');
  runApp(const MyApp());
});
```

That is the whole contract: build the `OtelZone` at the top level, open the
zone, start the SDK inside it, run the app. [Getting started](/guide/getting-started)
covers installing it and wiring the observers.

::: info Not on pub.dev
`otel_zone` is published as a Git dependency pinned to a commit
(`publish_to: 'none'` in its `pubspec.yaml`). It is MIT-licensed.
:::
