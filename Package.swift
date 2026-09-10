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

import Foundation
import PackageDescription

let runtimeProfile = ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_BUILD_PROFILE"] ?? "enhanced"
let enhancedRuntime: Bool = {
    switch runtimeProfile {
    case "enhanced": true
    case "stock": false
    default: fatalError("CONTAINER_COMPOSE_BUILD_PROFILE must be stock or enhanced")
    }
}()

let runtimeSwiftSettings: [SwiftSetting] = enhancedRuntime
    ? [.define("CONTAINER_COMPOSE_ENHANCED_RUNTIME")]
    : []

let containerDependency: Package.Dependency = {
    if let path = ProcessInfo.processInfo.environment["CONTAINER_PACKAGE_PATH"],
       !path.isEmpty
    {
        return .package(name: "container", path: path)
    }
    return enhancedRuntime
        ? .package(
            url: "https://github.com/stephenlclarke/container.git",
            revision: "ccf99d73b75626ed49a0d638c640bd3b9851e2de",
        )
        : .package(url: "https://github.com/apple/container.git", exact: "1.4.1")
}()

let containerizationDependency: Package.Dependency = {
    if let path = ProcessInfo.processInfo.environment["CONTAINERIZATION_PACKAGE_PATH"],
       !path.isEmpty
    {
        return .package(name: "containerization", path: path)
    }
    return enhancedRuntime
        ? .package(
            url: "https://github.com/stephenlclarke/containerization.git",
            revision: "bd8130fea851f6ee264f00fc684e2543a7d2faa3",
        )
        : .package(url: "https://github.com/apple/containerization.git", exact: "0.45.0")
}()

let runtimeOnlyDependencies: [Package.Dependency] = enhancedRuntime
    ? [.package(
        url: "https://github.com/stephenlclarke/swift-nio-ssl.git",
        revision: "3e13ce5f6dd5b7e89fff9ab55ab7caed39fe7285",
    )]
    : []

let pluginRuntimeDependencies: [Target.Dependency] = enhancedRuntime
    ? ["ComposeContainerRuntime"]
    : ["ComposeEngineRuntime"]

let runtimeTargets: [Target] = enhancedRuntime
    ? [
        .target(
            name: "ComposeContainerRuntime",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ComposeCore",
                "ComposeRuntimeSPI",
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerCommands", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ComposeContainerRuntime",
            swiftSettings: runtimeSwiftSettings,
        ),
        .testTarget(
            name: "ComposeCoreTests",
            dependencies: [
                "ComposeCore",
                "ComposeContainerRuntime",
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
            ],
            path: "Tests/ComposeCoreTests",
            resources: [
                .process("Fixtures"),
            ],
        ),
        .testTarget(
            name: "ComposeContainerRuntimeTests",
            dependencies: [
                "ComposeContainerRuntime",
                "ComposeRuntimeSPI",
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ],
            path: "Tests/ComposeContainerRuntimeTests",
        ),
    ]
    : [
        .target(
            name: "ComposeEngineRuntime",
            dependencies: [
                "ComposeCore",
                "ComposeRuntimeSPI",
                .product(name: "ContainerEngineWire", package: "container-engine-api"),
                .product(name: "ContainerUnixHTTPClient", package: "container-engine-api"),
            ],
            path: "Sources/ComposeEngineRuntime",
        ),
        .testTarget(
            name: "ComposeEngineRuntimeTests",
            dependencies: [
                "ComposeEngineRuntime",
                "ComposeRuntimeSPI",
                .product(name: "ContainerEngineWire", package: "container-engine-api"),
                .product(name: "ContainerUnixHTTPServer", package: "container-engine-api"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/ComposeEngineRuntimeTests",
        ),
    ]

let package = Package(
    name: "container-compose",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "compose", targets: ["ComposePlugin"]),
        .library(name: "ComposeCore", targets: ["ComposeCore"]),
        enhancedRuntime
            ? .library(name: "ComposeContainerRuntime", targets: ["ComposeContainerRuntime"])
            : .library(name: "ComposeEngineRuntime", targets: ["ComposeEngineRuntime"]),
        .library(name: "ComposeRuntimeSPI", targets: ["ComposeRuntimeSPI"]),
    ],
    dependencies: [
        containerDependency,
        containerizationDependency,
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(
            url: "https://github.com/stephenlclarke/container-engine-api.git",
            revision: "276a7cfdba91fef60c232177a44c054e5de9ae8f",
        ),
    ] + runtimeOnlyDependencies,
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
            ] + pluginRuntimeDependencies,
            path: "Sources/ComposePlugin",
            swiftSettings: runtimeSwiftSettings,
        ),
        .target(
            name: "ComposeRuntimeSPI",
            path: "Sources/ComposeRuntimeSPI",
        ),
        .target(
            name: "ComposeCore",
            dependencies: [
                "ComposeRuntimeSPI",
            ],
            path: "Sources/ComposeCore",
        ),
        .testTarget(
            name: "ComposeRuntimeSPITests",
            dependencies: [
                "ComposeRuntimeSPI",
            ],
            path: "Tests/ComposeRuntimeSPITests",
        ),
        .testTarget(
            name: "ComposePluginTests",
            dependencies: [
                "ComposeCore",
                "ComposePlugin",
            ],
            path: "Tests/ComposePluginTests",
            swiftSettings: runtimeSwiftSettings,
        ),
        .testTarget(
            name: "ComposeRuntimeTests",
            dependencies: [
                "ComposeCore",
            ],
            path: "Tests/ComposeRuntimeTests",
            resources: [
                .copy("Fixtures"),
            ],
        ),
    ] + runtimeTargets,
)
