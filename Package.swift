// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "wicher",
    platforms: [.macOS(.v26)],
    targets: [
        // Everything but the entry point, so tests can import it.
        .target(
            name: "WicherCore",
            path: "Sources/WicherCore"
        ),
        .executableTarget(
            name: "wicher",
            dependencies: ["WicherCore"],
            path: "Sources/wicher"
        ),
        .testTarget(
            name: "WicherCoreTests",
            dependencies: ["WicherCore"],
            path: "Tests/WicherCoreTests"
        ),
    ],
    // Swift 6 mode turns the strict-concurrency warnings into errors; the
    // @MainActor annotations come first (REVIEW-TASKS.md).
    swiftLanguageModes: [.v5]
)
