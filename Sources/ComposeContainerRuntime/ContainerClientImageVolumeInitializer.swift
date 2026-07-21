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

import ComposeCore
import ComposeRuntimeSPI
import ContainerAPIClient
import ContainerizationOCI
import ContainerPersistence
import ContainerResource

/// Direct apple/container adapter for Compose image-to-volume initialization.
///
/// Compose policy supplies a selected image path and local volume name. This
/// adapter resolves the corresponding immutable image snapshot and ext4 volume
/// backing file using only the public Container client APIs.
public struct ContainerClientImageVolumeInitializer: ComposeRuntimeImageVolumeInitializing {
    public typealias ResolveImageFilesystem = @Sendable (String, String?) async throws -> String
    public typealias ResolveVolume = @Sendable (String) async throws -> ComposeVolumeSummary

    private let resolveImageFilesystem: ResolveImageFilesystem
    private let resolveVolume: ResolveVolume
    private let initializer: ContainerImageVolumeInitializer

    /// Creates a live initializer backed by the matched Apple runtime APIs.
    public init() {
        self.init(
            resolveImageFilesystem: Self.resolveImageFilesystem,
            resolveVolume: Self.resolveVolume,
        )
    }

    /// Creates an initializer from narrow resolution operations for tests and alternate runtimes.
    public init(
        resolveImageFilesystem: @escaping ResolveImageFilesystem,
        resolveVolume: @escaping ResolveVolume,
        initializer: ContainerImageVolumeInitializer = ContainerImageVolumeInitializer(),
    ) {
        self.resolveImageFilesystem = resolveImageFilesystem
        self.resolveVolume = resolveVolume
        self.initializer = initializer
    }

    /// Resolves the requested image snapshot and initializes the named volume when empty.
    public func initializeImageVolume(_ request: ComposeImageVolumeInitializationRequest) async throws {
        async let imageFilesystem = resolveImageFilesystem(request.image, request.platform)
        async let volume = resolveVolume(request.volumeName)
        _ = try await initializer.initializeIfEmpty(
            imageFilesystem: imageFilesystem,
            imageSubpath: request.imageSubpath,
            volume: volume,
        )
    }

    private static func resolveImageFilesystem(reference: String, platform: String?) async throws -> String {
        let configuration = try await ConfigurationLoader.load()
        let image = try await ClientImage.get(reference: reference, containerSystemConfig: configuration)
        let filesystem = try await image.getCreateSnapshot(platform: requestedPlatform(platform))
        return filesystem.source
    }

    private static func resolveVolume(name: String) async throws -> ComposeVolumeSummary {
        guard let configuration = try await ClientVolume.list().first(where: { $0.name == name }) else {
            throw ComposeError.invalidProject("runtime volume '\(name)' was not created before image initialization")
        }
        return ContainerResourceAPIClient.composeVolumeSummary(from: configuration)
    }

    private static func requestedPlatform(_ value: String?) throws -> ContainerizationOCI.Platform {
        if let value, !value.isEmpty {
            return try ContainerizationOCI.Platform(from: value)
        }
        return try DefaultPlatform.resolve(platform: nil, os: nil, arch: nil) ?? .current
    }
}
