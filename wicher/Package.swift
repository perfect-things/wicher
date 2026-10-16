// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wicher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "wicher",
            path: "Sources/wicher"
        )
    ]
)
