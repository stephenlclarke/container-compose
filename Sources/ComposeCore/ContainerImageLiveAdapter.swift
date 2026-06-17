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

import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI

/// Live Apple `container` image API bridge used by production orchestration.
public struct ContainerImageLiveAPIClient: ContainerImageAPIClienting {
    public init() {
        // Stateless adapter; public initializer supports dependency injection.
    }

    /// Returns whether the image can be resolved locally.
    public func imageExists(reference: String) async throws -> Bool {
        let config = try await ConfigurationLoader.load()
        let result = try await ClientImage.get(names: [reference], containerSystemConfig: config)
        return result.error.isEmpty
    }

    /// Pulls and unpacks using the same default platform resolution as Apple CLI.
    public func pullImage(reference: String) async throws {
        let config = try await ConfigurationLoader.load()
        let platform = try Self.defaultPlatform()
        let image = try await ClientImage.pull(
            reference: reference,
            platform: platform,
            scheme: .auto,
            containerSystemConfig: config,
            progressUpdate: nil
        )
        try await image.unpack(platform: platform)
    }

    /// Pushes the resolved local image reference.
    public func pushImage(reference: String) async throws -> String {
        let config = try await ConfigurationLoader.load()
        let platform = try Self.defaultPlatform()
        let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
        try await image.push(platform: platform, scheme: .auto, containerSystemConfig: config, progressUpdate: nil)
        return image.reference
    }

    /// Deletes the resolved local image and runs Apple's orphaned-blob cleanup.
    public func deleteImage(reference: String, force: Bool) async throws -> String? {
        let config = try await ConfigurationLoader.load()
        let result = try await ClientImage.get(names: [reference], containerSystemConfig: config)
        guard let image = result.images.first else {
            if force {
                return nil
            }
            throw ComposeError.invalidProject("image not found: \(reference)")
        }

        try await ClientImage.delete(reference: image.reference, garbageCollect: false)
        _ = try await ClientImage.cleanUpOrphanedBlobs()
        return image.reference
    }

    /// Resolves `CONTAINER_DEFAULT_PLATFORM` for image operations.
    private static func defaultPlatform() throws -> ContainerizationOCI.Platform? {
        try DefaultPlatform.resolve(platform: nil, os: nil, arch: nil)
    }
}
