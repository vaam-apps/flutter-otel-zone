# Changelog

## [0.5.0](https://github.com/vaam-apps/flutter-otel-zone/compare/v0.4.0...v0.5.0) (2026-09-30)


### Features

* cap the telemetry spool in bytes with spoolMaxBytes ([#47](https://github.com/vaam-apps/flutter-otel-zone/issues/47)) ([32dd931](https://github.com/vaam-apps/flutter-otel-zone/commit/32dd931f2656856397358ed2c057a625f4df178f))

## [0.4.0](https://github.com/vaam-apps/flutter-otel-zone/compare/v0.3.1...v0.4.0) (2026-09-29)


### ⚠ BREAKING CHANGES

* spans no longer carry `riverpod.provider.argument` unless `riverpodObserver(recordArguments: true)` is passed.

### Features

* spoolDirectory accepts a Future, so the README's path_provider example compiles ([#39](https://github.com/vaam-apps/flutter-otel-zone/issues/39)) ([cbb0662](https://github.com/vaam-apps/flutter-otel-zone/commit/cbb0662846a43405c853a7d98786d025019fbfc4)), closes [#38](https://github.com/vaam-apps/flutter-otel-zone/issues/38)


### Bug Fixes

* redact covers spans, and riverpodObserver() drops provider arguments by default ([#44](https://github.com/vaam-apps/flutter-otel-zone/issues/44)) ([97c7966](https://github.com/vaam-apps/flutter-otel-zone/commit/97c79664305f635949c54693ead17831451e5dc1))


### Continuous Integration

* scope the crash harness's log reads to a launch, not to a clear ([#43](https://github.com/vaam-apps/flutter-otel-zone/issues/43)) ([05c7d97](https://github.com/vaam-apps/flutter-otel-zone/commit/05c7d97a494526a67085f17c66d3544c2425824d))

## [0.3.1](https://github.com/vaam-apps/flutter-otel-zone/compare/v0.3.0...v0.3.1) (2026-09-29)


### Bug Fixes

* deliver a recovered native crash once when the activity is relaunched ([#37](https://github.com/vaam-apps/flutter-otel-zone/issues/37)) ([c316df7](https://github.com/vaam-apps/flutter-otel-zone/commit/c316df7909cd53c592511b58873c436c2dd904ee))
* skip the native-crash drain on desktop ([#34](https://github.com/vaam-apps/flutter-otel-zone/issues/34)) ([9b2c9f0](https://github.com/vaam-apps/flutter-otel-zone/commit/9b2c9f08b559e21bfba5501e6c38259394e14f08)), closes [#33](https://github.com/vaam-apps/flutter-otel-zone/issues/33)
* tag native crash records with the build that crashed ([#32](https://github.com/vaam-apps/flutter-otel-zone/issues/32)) ([91ea4ec](https://github.com/vaam-apps/flutter-otel-zone/commit/91ea4ec36aee29e639681fbdadb4e3e8269da6b2))

## [0.3.0](https://github.com/vaam-apps/flutter-otel-zone/compare/v0.2.0...v0.3.0) (2026-09-29)


### Features

* capture iOS crashes and hangs from MetricKit and uncaught NSExceptions ([#25](https://github.com/vaam-apps/flutter-otel-zone/issues/25)) ([5f03183](https://github.com/vaam-apps/flutter-otel-zone/commit/5f031836f634aa37338dbfba9a4b65791d3bb212))
* capture JVM crashes with a chained uncaught-exception handler ([#23](https://github.com/vaam-apps/flutter-otel-zone/issues/23)) ([1bf0060](https://github.com/vaam-apps/flutter-otel-zone/commit/1bf0060dc78f9080ef65fe6a800b6577d58b4f71))
* drain native crash reports into the spool on start ([#22](https://github.com/vaam-apps/flutter-otel-zone/issues/22)) ([0f9d35d](https://github.com/vaam-apps/flutter-otel-zone/commit/0f9d35dc6cfd9d862115059e6afd004d25ebfbcc))
* read ApplicationExitInfo past a watermark on the next launch ([#26](https://github.com/vaam-apps/flutter-otel-zone/issues/26)) ([928a941](https://github.com/vaam-apps/flutter-otel-zone/commit/928a941fb7d36908dd6cbffe48dfde3431eba42c))
* scrub every exported record with OtelZoneConfig.redact ([#19](https://github.com/vaam-apps/flutter-otel-zone/issues/19)) ([ba13ff7](https://github.com/vaam-apps/flutter-otel-zone/commit/ba13ff705f26b4dbd8f311f0100e38afd2ff7bc0))
* spool refused log batches to disk and replay them on start ([#21](https://github.com/vaam-apps/flutter-otel-zone/issues/21)) ([99f79b8](https://github.com/vaam-apps/flutter-otel-zone/commit/99f79b80d3a803d013620d13937fdd5b8dd0fc3f))


### Bug Fixes

* report each uncaught Dart error once and flush before background ([#18](https://github.com/vaam-apps/flutter-otel-zone/issues/18)) ([baa4bbf](https://github.com/vaam-apps/flutter-otel-zone/commit/baa4bbf7debdcf64bdcf7dc2d3daa096902b60ce))
* spool before sending, drain crashes off the start path, and carry OTLP headers everywhere ([#29](https://github.com/vaam-apps/flutter-otel-zone/issues/29)) ([14ef644](https://github.com/vaam-apps/flutter-otel-zone/commit/14ef6444a2b87f459f3c7d32a6478c71f3ecd516))


### Tests

* crash harness and emulator tests for native capture ([#30](https://github.com/vaam-apps/flutter-otel-zone/issues/30)) ([a9a08ba](https://github.com/vaam-apps/flutter-otel-zone/commit/a9a08ba6f16ba172eeb76520c70a2a7387be9b1d))


### Continuous Integration

* compile and test the plugin's Kotlin on every pull request ([#24](https://github.com/vaam-apps/flutter-otel-zone/issues/24)) ([0bd7183](https://github.com/vaam-apps/flutter-otel-zone/commit/0bd7183e8518c59ced33250ee8c6e8c9be2df705))

## [0.2.0](https://github.com/vaam-apps/flutter-otel-zone/compare/v0.1.0...v0.2.0) (2026-09-21)


### Features

* one Talker, one OpenTelemetry SDK, one guarded zone ([77b27b9](https://github.com/vaam-apps/flutter-otel-zone/commit/77b27b9c7f35a933ab3de2898e208093c2904f25))
