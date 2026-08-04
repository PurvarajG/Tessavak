// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaaniCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VaaniCore", targets: ["VaaniCore"]),
        .library(name: "VaaniPacks", targets: ["VaaniPacks"]),
        .library(name: "VaaniAdapters", targets: ["VaaniAdapters"]),
        .library(name: "VaaniWhisper", targets: ["VaaniWhisper"]),
        .executable(name: "vaani-bench", targets: ["VaaniBench"]),
        .executable(name: "vaani-live", targets: ["VaaniLive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(
            url: "https://github.com/exPHAT/SwiftWhisper",
            revision: "c340197966ebd264f3135d3955874b40f8ed58bc"
        ),
    ],
    targets: [
        .target(name: "VaaniCore"),
        .target(
            name: "VaaniPacks",
            dependencies: ["VaaniCore"],
            resources: [.process("Resources")]
        ),
        .target(name: "VaaniAdapters", dependencies: ["VaaniCore"]),
        .target(
            name: "VaaniWhisper",
            dependencies: [
                "VaaniCore",
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
            ]
        ),
        .executableTarget(
            name: "VaaniBench",
            dependencies: [
                "VaaniCore",
                "VaaniPacks",
                "VaaniAdapters",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // vaani-live is single-model: VaaniWhisper serves every route. Real
        // dual-recogniser routing is Phase 3 work.
        .executableTarget(
            name: "VaaniLive",
            dependencies: [
                "VaaniCore",
                "VaaniPacks",
                "VaaniWhisper",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "VaaniCoreTests", dependencies: ["VaaniCore"]),
        .testTarget(name: "VaaniPacksTests", dependencies: ["VaaniPacks"]),
        .testTarget(
            name: "VaaniAdaptersTests",
            dependencies: ["VaaniAdapters", "VaaniCore", "VaaniPacks"]
        ),
        .testTarget(
            name: "VaaniBenchTests",
            dependencies: ["VaaniBench", "VaaniCore", "VaaniPacks", "VaaniAdapters"]
        ),
        .testTarget(name: "VaaniWhisperTests", dependencies: ["VaaniWhisper", "VaaniCore"]),
        .testTarget(
            name: "VaaniLiveTests",
            dependencies: ["VaaniLive", "VaaniCore"]
        ),
    ]
)
