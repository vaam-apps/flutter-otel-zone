// swift-tools-version: 5.9
// Tests for the Flutter-free half of the iOS plugin: everything under
// `Sources/otel_zone/Crash`. The plugin's own package cannot run `swift test`,
// because its target links the Flutter framework, which a macOS toolchain does
// not have. So the Foundation-only sources are compiled here on their own,
// under the name `CrashCore`, and the plugin compiles the very same files
// into `otel_zone`. Run with `swift test` from this directory.

import PackageDescription

let package = Package(
    name: "CrashCoreTests",
    platforms: [
        .iOS("13.0"),
        .macOS("12.0"),
    ],
    targets: [
        .target(
            name: "CrashCore",
            // A symlink to `../Sources/otel_zone/Crash`: SwiftPM refuses a
            // target path outside the package root, and the files themselves
            // must stay where the podspec's glob finds them.
            path: "Sources/CrashCore"
        ),
        .testTarget(
            name: "CrashCoreTests",
            dependencies: ["CrashCore"],
            path: "Tests/CrashCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
