// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexTokenBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexTokenCore", targets: ["CodexTokenCore"]),
        .executable(name: "CodexTokenBar", targets: ["CodexTokenBar"])
    ],
    targets: [
        .target(name: "CodexTokenCore"),
        .executableTarget(
            name: "CodexTokenBar",
            dependencies: ["CodexTokenCore"]
        ),
        .testTarget(
            name: "CodexTokenCoreTests",
            dependencies: ["CodexTokenCore"]
        )
    ]
)
