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
import ContainerAPIClient
import ContainerizationExtras
import ContainerizationOCI
import ContainerPersistence
import ContainerResource

/// Live apple/container image API bridge used by production orchestration.
public struct ContainerImageLiveAPIClient: ContainerImageAPIClienting {
    private static let isStateless = true

    public init() {
        _ = Self.isStateless
    }

    /// Returns whether the image can be resolved locally.
    public func imageExists(reference: String) async throws -> Bool {
        let config = try await ConfigurationLoader.load()
        let result = try await ClientImage.get(names: [reference], containerSystemConfig: config)
        return result.error.isEmpty
    }

    /// Resolves the remote registry manifest digest without importing image content.
    public func imageDigest(reference: String) async throws -> String {
        let config = try await ConfigurationLoader.load()
        let normalized = try ClientImage.normalizeReference(reference, containerSystemConfig: config)
        let parsed = try Reference.parse(normalized)
        parsed.normalize()
        guard let tag = parsed.tag ?? parsed.digest else {
            throw ComposeError.invalidProject("image reference '\(reference)' does not include a tag or digest")
        }
        let client = try RegistryClient(
            reference: parsed.description,
            tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration(),
        )
        return try await client.resolve(name: parsed.path, tag: tag).digest
    }

    /// Resolves Docker image healthcheck metadata from the image config for the requested platform.
    public func imageHealthCheck(reference: String, platform: String?) async throws -> ComposeImageHealthCheck? {
        let config = try await ConfigurationLoader.load()
        let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
        let resource = try await image.toImageResource(containerSystemConfig: config)
        let requestedPlatform = try Self.requestedPlatform(platform)
        let variant = Self.variant(in: resource, matching: requestedPlatform, allowFallback: platform == nil)
        return variant?.healthCheck.map(ComposeImageHealthCheck.init)
    }

    /// Resolves Docker image config metadata from the requested image.
    public func imageMetadata(reference: String) async throws -> ComposeImageMetadata {
        let config = try await ConfigurationLoader.load()
        let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
        let resource = try await image.toImageResource(containerSystemConfig: config)
        let variant = try Self.variant(in: resource, matching: Self.requestedPlatform(nil), allowFallback: true)
        let imageConfig = variant?.config.config
        return ComposeImageMetadata(reference: image.reference) {
            $0.displayReference = resource.displayReference
            $0.user = imageConfig?.user
            $0.environment = imageConfig?.env ?? []
            $0.entrypoint = imageConfig?.entrypoint
            $0.command = imageConfig?.cmd
            $0.workingDir = imageConfig?.workingDir
            $0.labels = imageConfig?.labels ?? [:]
            $0.exposedPorts = variant?.exposedPorts ?? []
            $0.stopSignal = imageConfig?.stopSignal
            $0.healthCheck = variant?.healthCheck.map(ComposeImageHealthCheck.init)
            $0.declaredVolumeTargets = imageConfig?.volumes?.keys.sorted() ?? []
        }
    }

    /// Resolves Docker image config `VOLUME` destinations for the requested platform.
    public func imageDeclaredVolumeTargets(reference: String, platform: String?) async throws -> [String] {
        let config = try await ConfigurationLoader.load()
        let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
        let resource = try await image.toImageResource(containerSystemConfig: config)
        let requestedPlatform = try Self.requestedPlatform(platform)
        let variant = Self.variant(in: resource, matching: requestedPlatform, allowFallback: platform == nil)
        return variant?.config.config?.volumes?.keys.sorted() ?? []
    }

    /// Lists local images labelled as Compose Bridge transformers.
    public func bridgeTransformers() async throws -> [ComposeBridgeTransformer] {
        let config = try await ConfigurationLoader.load()
        let platform = try Self.requestedPlatform(nil)
        let images = try await ClientImage.list()
        var transformers: [ComposeBridgeTransformer] = []
        for image in images {
            let resource = try await image.toImageResource(containerSystemConfig: config)
            let labelledVariants = resource.variants.filter {
                $0.imageConfigLabels["com.docker.compose.bridge"] == "transformation"
            }
            guard let variant = labelledVariants.first(where: { $0.platform == platform })
                ?? labelledVariants.first
            else {
                continue
            }
            let digest = resource.configuration.descriptor.digest
            let reference = resource.displayReference
            let repoTags = reference.contains("@") ? [] : [reference]
            transformers.append(
                ComposeBridgeTransformer(
                    id: digest,
                    reference: reference,
                    details: ComposeBridgeTransformerDetails(
                        createdAtUnix: Int64(resource.creationDate.timeIntervalSince1970),
                        labels: variant.imageConfigLabels,
                        repoDigests: [Self.repositoryDigest(reference: reference, digest: digest)],
                        repoTags: repoTags,
                        size: ComposeBridgeTransformerSize(sizeInBytes: variant.size),
                    ),
                ),
            )
        }
        return transformers.sorted { $0.reference < $1.reference }
    }

    /// Pulls and unpacks using the same default platform resolution as the apple/container CLI.
    public func pullImage(reference: String) async throws {
        let config = try await ConfigurationLoader.load()
        let platform = try Self.defaultPlatform()
        let image = try await ClientImage.pull(
            reference: reference,
            platform: platform,
            scheme: .auto,
            containerSystemConfig: config,
            progressUpdate: nil,
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

    /// Deletes the resolved local image and runs apple/container orphaned-blob cleanup.
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

    /// Loads an OCI or Docker archive through `ClientImage.load`, then unpacks each loaded image.
    public func loadImageArchive(path: String) async throws -> [String] {
        let platform = try Self.defaultPlatform()
        let result = try await ClientImage.load(from: path, force: false)
        if !result.rejectedMembers.isEmpty {
            throw ComposeError.invalidProject("image archive contains invalid members: \(result.rejectedMembers.joined(separator: ", "))")
        }
        var references: [String] = []
        for image in result.images {
            try await image.unpack(platform: platform)
            references.append(image.reference)
        }
        return references
    }

    /// Resolves `CONTAINER_DEFAULT_PLATFORM` for image operations.
    private static func defaultPlatform() throws -> ContainerizationOCI.Platform? {
        try DefaultPlatform.resolve(platform: nil, os: nil, arch: nil)
    }

    /// Resolves the platform used for image metadata lookups.
    private static func requestedPlatform(_ platform: String?) throws -> ContainerizationOCI.Platform {
        if let platform, !platform.isEmpty {
            return try ContainerizationOCI.Platform(from: platform)
        }
        return try defaultPlatform() ?? .current
    }

    /// Selects the requested platform variant, with optional default-platform fallback.
    private static func variant(
        in resource: ImageResource,
        matching platform: ContainerizationOCI.Platform,
        allowFallback: Bool,
    ) -> ImageResource.Variant? {
        resource.variants.first { $0.platform == platform } ?? (allowFallback ? resource.variants.first : nil)
    }

    /// Combines a familiar local image name with its OCI index digest.
    private static func repositoryDigest(reference: String, digest: String) -> String {
        let withoutDigest = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        let lastSlash = withoutDigest.lastIndex(of: "/")
        let lastColon = withoutDigest.lastIndex(of: ":")
        let repository: String = if let lastColon, lastSlash.map({ lastColon > $0 }) ?? true {
            String(withoutDigest[..<lastColon])
        } else {
            withoutDigest
        }
        return "\(repository)@\(digest)"
    }
}

private extension ComposeImageHealthCheck {
    /// Projects apple/container image metadata into Compose's runtime model.
    init(_ healthCheck: ImageResource.HealthCheck) {
        self.init(
            test: healthCheck.test,
            intervalInNanoseconds: healthCheck.intervalInNanoseconds,
            timeoutInNanoseconds: healthCheck.timeoutInNanoseconds,
            startPeriodInNanoseconds: healthCheck.startPeriodInNanoseconds,
            startIntervalInNanoseconds: healthCheck.startIntervalInNanoseconds,
            retries: healthCheck.retries,
        )
    }
}
