// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "container-compose",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "compose", targets: ["ComposePlugin"]),
        .library(name: "ComposeCore", targets: ["ComposeCore"]),
    ],
    dependencies: [
        .package(name: "container", path: "../container"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ComposePlugin",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerBuild", package: "container"),
                .product(name: "ContainerCommands", package: "container"),
                .product(name: "ContainerLog", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                "ComposeCore",
            ],
            path: "Sources/ComposePlugin"
        ),
        .target(
            name: "ComposeCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ComposeCore"
        ),
        .testTarget(
            name: "ComposeCoreTests",
            dependencies: [
                "ComposeCore",
            ],
            path: "Tests/ComposeCoreTests"
        ),
    ]
)
