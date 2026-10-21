# Building and testing

How the repository itself is checked. Everything here runs in CI
([`.github/workflows/ci.yml`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/.github/workflows/ci.yml))
on every pull request and push to `main`.

## Dart

```bash
flutter pub get
(cd example && flutter pub get)
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

CI pins Flutter to an exact build (`FLUTTER_VERSION` in `ci.yml`) — the same
pin the consuming app's CI carries — so a green run means the package
analyses under the Dart the app is actually built with.

`flutter test` is the whole Dart contract — the floor, the breadcrumbs, the
redaction, the spool, the crash drain and the start-up summary — and needs no
device. Several tests talk to a local OTLP collector started in-process
([`test/support/local-collector.dart`](https://github.com/vaam-apps/flutter-otel-zone/blob/main/test/support/local-collector.dart)),
and some are in files of their own because a successful `start()` has to be
the first one in its isolate.

## Web

```bash
flutter test --platform chrome test/run-guarded-web_test.dart
flutter test --platform chrome --wasm test/run-guarded-web_test.dart
```

Plain `flutter test` skips this file.

## Kotlin

```bash
cd example && flutter create --platforms=android . && cd android
./gradlew :otel_zone:testDebugUnitTest --console=plain
```

The example's Gradle wrapper is generated, not committed; CI regenerates it
the same way. These JVM tests are the only thing in the repository that
compiles the plugin's `.kt` files.

## Swift

```bash
cd ios/otel_zone/CrashTests && swift test
```

That covers the Foundation-only half (`Sources/otel_zone/Crash`: the MetricKit
mapper, the merge rule, the stores). CI's `ios` job then generates the
example's iOS runner, builds it for the simulator — which compiles the half
that links Flutter and MetricKit — and checks that the crash harness is in the
Debug build and absent from Release.

## Native crash capture

End to end, on an emulator or simulator: the
[crash harness](/development/crash-harness), run by
`.github/workflows/crash-harness.yml`.

## The Pigeon channel

```bash
dart run pigeon --input pigeons/native_crash.dart && dart format .
```

The generated Dart, Kotlin and Swift files are committed. See
[the Pigeon channel](/platforms/#the-pigeon-channel).

## Commits, pull requests and releases

The repository squash-merges, so a pull request's **title** becomes the one
commit on `main`, and it must be a conventional commit — `pr-title.yml`
checks it:

```text
type(optional scope)optional-!: subject
```

with `type` one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`,
`test`, `build`, `ci`, `chore`, `revert`. release-please reads those subjects
to propose the next release, write the
[changelog](https://github.com/vaam-apps/flutter-otel-zone/blob/main/CHANGELOG.md),
bump `pubspec.yaml` and tag `vX.Y.Z`.

## This site

The documentation is a VitePress site in `docs/`, a standalone pnpm project
using the vaam-apps Material 3 theme:

```bash
cd docs
pnpm install
pnpm dev      # or: pnpm build && pnpm preview
```

`.github/workflows/docs.yml` builds it on every pull request — a dead link
fails the build — and deploys it to GitHub Pages from `main`.
