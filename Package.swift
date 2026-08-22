// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Kaze",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KazeDomain", targets: ["KazeDomain"]),
        .library(name: "KazeIPC", targets: ["KazeIPC"]),
        .library(name: "KazeHardware", targets: ["KazeHardware"]),
        .executable(name: "KazeApp", targets: ["KazeApp"]),
        .executable(name: "KazeHelper", targets: ["KazeHelper"]),
        .executable(name: "kaze", targets: ["KazeCLI"]),
        .executable(name: "kaze-recovery", targets: ["KazeRecovery"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.7.1"),
    ],
    targets: [
        .target(
            name: "KazeDomain",
            path: "Sources/KazeDomain"
        ),
        .target(
            name: "KazeIPC",
            dependencies: ["KazeDomain"],
            path: "Sources/KazeIPC",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "KazeHardware",
            dependencies: ["KazeDomain"],
            path: "Sources/KazeHardware",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "KazeHelper",
            dependencies: ["KazeDomain", "KazeIPC", "KazeHardware"],
            path: "Sources/KazeHelper"
        ),
        .executableTarget(
            name: "KazeApp",
            dependencies: ["KazeDomain", "KazeIPC"],
            path: "Sources/KazeApp",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(
            name: "KazeCLI",
            dependencies: [
                "KazeDomain",
                "KazeIPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/KazeCLI"
        ),
        .executableTarget(
            name: "KazeRecovery",
            dependencies: ["KazeDomain", "KazeHardware"],
            path: "Sources/KazeRecovery"
        ),
        .testTarget(
            name: "KazeDomainTests",
            dependencies: ["KazeDomain"],
            path: "Tests/KazeDomainTests"
        ),
        .testTarget(
            name: "KazeIPCTests",
            dependencies: ["KazeIPC"],
            path: "Tests/KazeIPCTests"
        ),
        .testTarget(
            name: "KazeHardwareTests",
            dependencies: ["KazeHardware"],
            path: "Tests/KazeHardwareTests"
        ),
    ]
)
