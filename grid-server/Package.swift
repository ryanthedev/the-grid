// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "theGrid",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "grid-server",
            targets: ["GridServer"]
        ),
        .executable(
            name: "grid-viewer",
            targets: ["GridViewer"]
        ),
        .executable(
            name: "grid-cli",
            targets: ["GridCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", from: "2.3.0")
    ],
    targets: [
        .systemLibrary(
            name: "mss",
            path: "include/mss",
            pkgConfig: "mss"
        ),
        .executableTarget(
            name: "GridServer",
            dependencies: [
                "mss",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core")
            ],
            path: "Sources/GridServer",
            linkerSettings: [
                .unsafeFlags(["-L", "lib"]),
                .linkedLibrary("mss"),
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks"]),
                .linkedFramework("SkyLight")
            ]
        ),
        .executableTarget(
            name: "GridViewer",
            dependencies: [],
            path: "Sources/GridViewer"
        ),
        .executableTarget(
            name: "GridCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/GridCLI"
        ),
        .testTarget(
            name: "GridServerTests",
            dependencies: ["GridServer"],
            path: "Tests/GridServerTests"
        )
    ]
)
