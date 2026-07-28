// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Wallstats",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WallstatsCore", targets: ["WallstatsCore"]),
        .executable(name: "Wallstats", targets: ["Wallstats"]),
    ],
    targets: [
        .target(name: "WallstatsCore"),
        .executableTarget(
            name: "Wallstats",
            dependencies: ["WallstatsCore"]
        ),
        .testTarget(
            name: "WallstatsCoreTests",
            dependencies: ["WallstatsCore", "Wallstats"],
            resources: [.process("Fixtures")]
        ),
    ]
)
