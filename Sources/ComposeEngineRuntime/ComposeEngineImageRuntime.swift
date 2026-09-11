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
import ContainerUnixHTTPClient
import Foundation

private struct EngineImagePlatformQuery: Encodable {
    let operatingSystem: String
    let architecture: String
    let variant: String?

    init(_ value: String) throws {
        let components = value.split(
            separator: "/",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard (2 ... 3).contains(components.count),
              components.allSatisfy({ !$0.isEmpty })
        else {
            throw ComposeError.commandFailed(
                command: "Engine image inspect --platform \(value)",
                status: 1,
                stderr: "invalid platform"
            )
        }
        operatingSystem = String(components[0])
        architecture = String(components[1])
        variant = components.count == 3 ? String(components[2]) : nil
    }

    func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ComposeError.commandFailed(
                command: "Engine image inspect",
                status: 1,
                stderr: "could not encode image platform"
            )
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case operatingSystem = "os"
        case architecture
        case variant
    }
}

extension EngineRuntimeProvider: ComposeRuntimeImageManaging {
    public func imageExists(_ reference: String) async throws -> Bool {
        do {
            let _: EngineImageInspect = try await request(.get, "/v1.53/images/\(escaped(reference))/json")
            return true
        } catch ContainerUnixHTTPClientError.server(status: 404, message: _) {
            return false
        }
    }

    public func imageDigest(_ reference: String) async throws -> String {
        let image: EngineImageInspect = try await request(.get, "/v1.53/images/\(escaped(reference))/json")
        return image.repoDigests.first ?? image.id
    }

    public func imageHealthCheck(_ reference: String, platform: String?) async throws -> ComposeImageHealthCheck? {
        try await inspectImage(reference, platform: platform).healthCheck
    }

    public func imageMetadata(_ reference: String) async throws -> ComposeImageMetadata {
        let image = try await inspectImage(reference)
        return Self.metadata(reference: reference, image: image)
    }

    public func imageMetadataIfAvailable(_ reference: String, platform: String?) async throws -> ComposeImageMetadata? {
        do {
            let image = try await inspectImage(reference, platform: platform)
            return Self.metadata(reference: reference, image: image)
        } catch ContainerUnixHTTPClientError.server(status: 404, message: _) {
            return nil
        }
    }

    public func imageDeclaredVolumeTargets(_ reference: String, platform: String?) async throws -> [String] {
        try await inspectImage(reference, platform: platform).config.volumes.keys.sorted()
    }

    private static func metadata(reference: String, image: EngineImageInspect) -> ComposeImageMetadata {
        ComposeImageMetadata(reference: reference) {
            $0.displayReference = image.repoTags.first ?? reference
            $0.user = image.config.user.nilIfEmpty
            $0.environment = image.config.environment
            $0.entrypoint = image.config.entrypoint
            $0.command = image.config.command
            $0.workingDir = image.config.workingDirectory.nilIfEmpty
            $0.labels = image.config.labels
            $0.exposedPorts = image.config.exposedPorts.keys.sorted()
            $0.stopSignal = image.config.stopSignal
            $0.healthCheck = image.healthCheck
            $0.declaredVolumeTargets = image.config.volumes.keys.sorted()
        }
    }

    public func bridgeTransformers() async throws -> [ComposeBridgeTransformer] {
        let images: [EngineImageSummary] = try await request(.get, "/v1.53/images/json")
        return images.flatMap { image in
            let references = image.repoTags.isEmpty ? [""] : image.repoTags
            return references.map { reference in
                ComposeBridgeTransformer(
                    id: image.id,
                    reference: reference,
                    details: .init(
                        createdAtUnix: image.created,
                        containers: image.containers,
                        labels: image.labels,
                        parentID: image.parentID,
                        repoDigests: image.repoDigests,
                        repoTags: image.repoTags,
                        size: .init(sharedSizeInBytes: image.sharedSize, sizeInBytes: Int64(image.size)),
                    ),
                )
            }
        }
    }

    public func pullImage(_ reference: String) async throws {
        try await request(
            .post,
            "/v1.53/images/create?fromImage=\(query(reference))",
            maximumBodyBytes: 64 * 1024 * 1024
        )
    }

    public func pushImage(_ reference: String, emit: @escaping @Sendable (String) -> Void) async throws {
        try await request(
            .post,
            "/v1.53/images/\(escaped(reference))/push",
            maximumBodyBytes: 64 * 1024 * 1024
        )
        emit(reference)
    }

    public func deleteImage(
        _ reference: String,
        force: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        try await request(.delete, "/v1.53/images/\(escaped(reference))?force=\(force ? 1 : 0)")
        emit(reference)
    }

    public func loadImageArchive(
        _ path: String,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        let archive = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        try await request(
            .post,
            "/v1.53/images/load",
            rawBody: archive,
            contentType: "application/x-tar",
            maximumBodyBytes: 64 * 1024 * 1024
        )
        emit(path)
    }

    func inspectImage(_ reference: String) async throws -> EngineImageInspect {
        try await request(.get, "/v1.53/images/\(escaped(reference))/json")
    }

    func inspectImage(
        _ reference: String,
        platform: String?
    ) async throws -> EngineImageInspect {
        guard let platform, !platform.isEmpty else {
            return try await inspectImage(reference)
        }
        let requestedPlatform = try EngineImagePlatformQuery(platform)
        let image: EngineImageInspect = try await request(
            .get,
            "/v1.53/images/\(escaped(reference))/json?platform=\(query(try requestedPlatform.encoded()))"
        )
        try Self.validateImagePlatform(
            image,
            requested: requestedPlatform,
            argument: platform
        )
        return image
    }

    private static func validateImagePlatform(
        _ image: EngineImageInspect,
        requested: EngineImagePlatformQuery,
        argument: String
    ) throws {
        let resolvedVariant = image.variant?.nilIfEmpty
        let variantMatches = requested.variant.map {
            Self.normalizedImageVariant($0, architecture: image.architecture)
                == Self.normalizedImageVariant(
                    resolvedVariant,
                    architecture: image.architecture
                )
        } ?? true
        guard requested.operatingSystem == image.operatingSystem,
              requested.architecture == image.architecture,
              variantMatches
        else {
            let resolvedPlatform = [
                image.operatingSystem,
                image.architecture,
                resolvedVariant,
            ].compactMap(\.self).joined(separator: "/")
            throw ComposeError.commandFailed(
                command: "Engine image inspect --platform \(argument)",
                status: 1,
                stderr: "resolved \(resolvedPlatform) instead"
            )
        }
    }

    private static func normalizedImageVariant(
        _ variant: String?,
        architecture: String
    ) -> String? {
        switch (architecture, variant) {
        case ("arm64", nil), ("arm64", "8"):
            "v8"
        case ("amd64", "v1"):
            nil
        default:
            variant
        }
    }
}
