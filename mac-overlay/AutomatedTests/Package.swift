// swift-tools-version:5.9
import PackageDescription

/// Standalone, deletable test package for FounderOfficeCopilot's non-UI logic.
///
/// This does NOT duplicate app code: `Sources/FounderOfficeCopilotCore/*.swift` are
/// symlinks into the real `../FounderOfficeCopilot/` source files, so these tests exercise
/// the exact same code the app ships, not a reimplementation. Only the SwiftUI views and
/// the `@main` app entry point are excluded (those need a running app + manual testing -
/// see the checklist at the end of the test run).
///
/// Run with: `swift test` from this directory. Delete this whole folder any time - it has
/// no effect on the Xcode project or app build.
let package = Package(
    name: "FounderOfficeCopilotCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "FounderOfficeCopilotCore",
            path: "Sources/FounderOfficeCopilotCore"
        ),
        .testTarget(
            name: "FounderOfficeCopilotCoreTests",
            dependencies: ["FounderOfficeCopilotCore"],
            path: "Tests/FounderOfficeCopilotCoreTests"
        )
    ]
)
