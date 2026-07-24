// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaaniCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VaaniCore", targets: ["VaaniCore"]),
        .library(name: "VaaniPacks", targets: ["VaaniPacks"]),
        .library(name: "VaaniAdapters", targets: ["VaaniAdapters"]),
        .executable(name: "vaani-bench", targets: ["VaaniBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "VaaniCore"),
        .target(
            name: "VaaniPacks",
            dependencies: ["VaaniCore"],
            resources: [.process("Resources")]
        ),
        .target(name: "VaaniAdapters", dependencies: ["VaaniCore"]),
        .executableTarget(
            name: "VaaniBench",
            dependencies: [
                "VaaniCore",
                "VaaniPacks",
                "VaaniAdapters",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "VaaniCoreTests", dependencies: ["VaaniCore"]),
        .testTarget(name: "VaaniPacksTests", dependencies: ["VaaniPacks"]),
        .testTarget(name: "VaaniAdaptersTests", dependencies: ["VaaniAdapters"]),
        .testTarget(
            name: "VaaniBenchTests",
            dependencies: ["VaaniBench", "VaaniCore", "VaaniPacks", "VaaniAdapters"]
        ),
    ]
)
