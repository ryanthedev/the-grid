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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "GridServer",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/GridServer"
        ),
        .testTarget(
            name: "GridServerTests",
            dependencies: ["GridServer"],
            path: "Tests/GridServerTests"
        )
    ]
)
