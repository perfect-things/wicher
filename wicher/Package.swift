// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wicher",
    platforms: [.macOS(.v13)],
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
    ]
)
