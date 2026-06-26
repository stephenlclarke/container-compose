// swift-tools-version: 6.2
//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

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
        .package(url: "https://github.com/stephenlclarke/containerization.git", branch: "integration/blkio-runtime"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ComposePlugin",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ComposeCore"
        ),
        .testTarget(
            name: "ComposeCoreTests",
            dependencies: [
                "ComposeCore",
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerizationExtras", package: "containerization"),
            ],
            path: "Tests/ComposeCoreTests",
            resources: [
                .process("Fixtures"),
            ]
        ),
        .testTarget(
            name: "ComposePluginTests",
            dependencies: [
                "ComposePlugin",
            ],
            path: "Tests/ComposePluginTests"
        ),
        .testTarget(
            name: "ComposeRuntimeTests",
            dependencies: [
                "ComposeCore",
            ],
            path: "Tests/ComposeRuntimeTests"
        ),
    ]
)
