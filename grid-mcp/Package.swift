// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "GridMCP",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.0")
    ],
    targets: [
        .executableTarget(
            name: "GridMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/GridMCP",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
