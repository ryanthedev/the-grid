// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GridNotify",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "GridNotify",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/GridNotify"
        ),
        .testTarget(
            name: "GridNotifyTests",
            dependencies: ["GridNotify"],
            path: "Tests/GridNotifyTests"
        )
    ]
)
