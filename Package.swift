// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tessavak",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TessavakCore", targets: ["TessavakCore"]),
        .library(name: "TessavakPacks", targets: ["TessavakPacks"]),
        .library(name: "TessavakAdapters", targets: ["TessavakAdapters"]),
        .library(name: "TessavakWhisper", targets: ["TessavakWhisper"]),
        .executable(name: "tessavak-bench", targets: ["TessavakBench"]),
        .executable(name: "tessavak-live", targets: ["TessavakLive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(
            url: "https://github.com/exPHAT/SwiftWhisper",
            revision: "c340197966ebd264f3135d3955874b40f8ed58bc"
        ),
    ],
    targets: [
        .target(name: "TessavakCore"),
        .target(
            name: "TessavakPacks",
            dependencies: ["TessavakCore"],
            resources: [.process("Resources")]
        ),
        .target(name: "TessavakAdapters", dependencies: ["TessavakCore"]),
        .target(
            name: "TessavakWhisper",
            dependencies: [
                "TessavakCore",
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
            ]
        ),
        .executableTarget(
            name: "TessavakBench",
            dependencies: [
                "TessavakCore",
                "TessavakPacks",
                "TessavakAdapters",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // tessavak-live is single-model: TessavakWhisper serves every route. Real
        // dual-recogniser routing is Phase 3 work.
        .executableTarget(
            name: "TessavakLive",
            dependencies: [
                "TessavakCore",
                "TessavakPacks",
                "TessavakWhisper",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "TessavakCoreTests", dependencies: ["TessavakCore"]),
        .testTarget(name: "TessavakPacksTests", dependencies: ["TessavakPacks"]),
        .testTarget(
            name: "TessavakAdaptersTests",
            dependencies: ["TessavakAdapters", "TessavakCore", "TessavakPacks"]
        ),
        .testTarget(
            name: "TessavakBenchTests",
            dependencies: ["TessavakBench", "TessavakCore", "TessavakPacks", "TessavakAdapters"]
        ),
        .testTarget(name: "TessavakWhisperTests", dependencies: ["TessavakWhisper", "TessavakCore"]),
        .testTarget(
            name: "TessavakLiveTests",
            dependencies: ["TessavakLive", "TessavakCore"]
        ),
    ]
)
