# Changelog

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
