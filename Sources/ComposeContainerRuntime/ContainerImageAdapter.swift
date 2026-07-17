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

/// Low-level apple/container image calls used by `ContainerClientImageManager`.
public protocol ContainerImageAPIClienting: Sendable {
    /// Returns whether `reference` exists in the local image store.
    func imageExists(reference: String) async throws -> Bool

    /// Resolves the remote manifest digest for `reference` without pulling it.
    func imageDigest(reference: String) async throws -> String

    /// Returns Docker image healthcheck metadata for `reference` and `platform`.
    func imageHealthCheck(reference: String, platform: String?) async throws -> ComposeImageHealthCheck?

    /// Returns image config metadata for `reference`.
    func imageMetadata(reference: String) async throws -> ComposeImageMetadata

    /// Lists local Compose Bridge transformer images.
    func bridgeTransformers() async throws -> [ComposeBridgeTransformer]

    /// Pulls and unpacks `reference`.
    func pullImage(reference: String) async throws

    /// Pushes `reference` and returns the runtime image reference that was pushed.
    func pushImage(reference: String) async throws -> String

    /// Deletes `reference`, returning the runtime image reference that was deleted.
    func deleteImage(reference: String, force: Bool) async throws -> String?

    /// Loads an OCI or Docker image archive and returns loaded image references.
    func loadImageArchive(path: String) async throws -> [String]
}

/// Thin apple/container client wrapper around image API calls.
public struct ContainerImageAPIClient: ContainerImageAPIClienting {
    public typealias Exists = @Sendable (String) async throws -> Bool
    public typealias Digest = @Sendable (String) async throws -> String
    public typealias HealthCheck = @Sendable (String, String?) async throws -> ComposeImageHealthCheck?
    public typealias Metadata = @Sendable (String) async throws -> ComposeImageMetadata
    public typealias Transformers = @Sendable () async throws -> [ComposeBridgeTransformer]
    public typealias Pull = @Sendable (String) async throws -> Void
    public typealias Push = @Sendable (String) async throws -> String
    public typealias Delete = @Sendable (String, Bool) async throws -> String?
    public typealias Load = @Sendable (String) async throws -> [String]

    private let existsOperation: Exists
    private let digestOperation: Digest
    private let healthCheckOperation: HealthCheck
    private let metadataOperation: Metadata
    private let transformersOperation: Transformers
    private let pullOperation: Pull
    private let pushOperation: Push
    private let deleteOperation: Delete
    private let loadOperation: Load

    /// Read-only image operations.
    public struct QueryOperations: Sendable {
        public var exists: Exists
        public var digest: Digest
        public var healthCheck: HealthCheck
        public var metadata: Metadata
        public var transformers: Transformers

        public init(
            exists: @escaping Exists,
            digest: @escaping Digest = { reference in
                throw ComposeError.unsupported("config image digest resolution for '\(reference)'")
            },
            healthCheck: @escaping HealthCheck = { _, _ in nil },
            metadata: @escaping Metadata = { reference in ComposeImageMetadata(reference: reference) },
            transformers: @escaping Transformers = { [] },
        ) {
            self.exists = exists
            self.digest = digest
            self.healthCheck = healthCheck
            self.metadata = metadata
            self.transformers = transformers
        }
    }

    /// Mutating image operations.
    public struct MutationOperations: Sendable {
        public var pull: Pull
        public var push: Push
        public var delete: Delete
        public var load: Load

        public init(
            pull: @escaping Pull,
            push: @escaping Push,
            delete: @escaping Delete,
            load: @escaping Load,
        ) {
            self.pull = pull
            self.push = push
            self.delete = delete
            self.load = load
        }
    }

    /// Creates a facade around another image API client.
    public init(client: ContainerImageAPIClienting) {
        self.init(
            queries: QueryOperations(
                exists: { try await client.imageExists(reference: $0) },
                digest: { try await client.imageDigest(reference: $0) },
                healthCheck: { try await client.imageHealthCheck(reference: $0, platform: $1) },
                metadata: { try await client.imageMetadata(reference: $0) },
                transformers: { try await client.bridgeTransformers() },
            ),
            mutations: MutationOperations(
                pull: { try await client.pullImage(reference: $0) },
                push: { try await client.pushImage(reference: $0) },
                delete: { try await client.deleteImage(reference: $0, force: $1) },
                load: { try await client.loadImageArchive(path: $0) },
            ),
        )
    }

    /// Creates a facade from explicit image operation closures.
    public init(queries: QueryOperations, mutations: MutationOperations) {
        existsOperation = queries.exists
        digestOperation = queries.digest
        healthCheckOperation = queries.healthCheck
        metadataOperation = queries.metadata
        transformersOperation = queries.transformers
        pullOperation = mutations.pull
        pushOperation = mutations.push
        deleteOperation = mutations.delete
        loadOperation = mutations.load
    }

    /// Creates a facade around the live apple/container image API bridge.
    public init() {
        self.init(client: ContainerImageLiveAPIClient())
    }

    /// Checks the local image store through `ClientImage.get(names:)`.
    public func imageExists(reference: String) async throws -> Bool {
        try await existsOperation(reference)
    }

    /// Resolves an image digest through the configured resolver.
    public func imageDigest(reference: String) async throws -> String {
        try await digestOperation(reference)
    }

    /// Reads Docker image healthcheck metadata through `ClientImage`.
    public func imageHealthCheck(reference: String, platform: String?) async throws -> ComposeImageHealthCheck? {
        try await healthCheckOperation(reference, platform)
    }

    /// Reads image config metadata through `ClientImage`.
    public func imageMetadata(reference: String) async throws -> ComposeImageMetadata {
        try await metadataOperation(reference)
    }

    /// Lists local Compose Bridge transformer images.
    public func bridgeTransformers() async throws -> [ComposeBridgeTransformer] {
        try await transformersOperation()
    }

    /// Pulls and unpacks an image through `ClientImage`.
    public func pullImage(reference: String) async throws {
        try await pullOperation(reference)
    }

    /// Pushes an image through `ClientImage`.
    public func pushImage(reference: String) async throws -> String {
        try await pushOperation(reference)
    }

    /// Deletes an image through `ClientImage`.
    public func deleteImage(reference: String, force: Bool) async throws -> String? {
        try await deleteOperation(reference, force)
    }

    /// Loads an OCI or Docker image archive through `ClientImage`.
    public func loadImageArchive(path: String) async throws -> [String] {
        try await loadOperation(path)
    }
}

/// `ClientImage`-backed manager for Compose image operations.
public struct ContainerClientImageManager: ComposeRuntimeImageManaging {
    private let client: ContainerImageAPIClienting

    public init(client: ContainerImageAPIClienting = ContainerImageAPIClient()) {
        self.client = client
    }

    /// Checks the local image store through the direct apple/container image API.
    public func imageExists(_ reference: String) async throws -> Bool {
        try await client.imageExists(reference: reference)
    }

    /// Resolves a remote image digest through the direct apple/container image API.
    public func imageDigest(_ reference: String) async throws -> String {
        try await client.imageDigest(reference: reference)
    }

    /// Reads Docker image healthcheck metadata through the direct apple/container image API.
    public func imageHealthCheck(_ reference: String, platform: String?) async throws -> ComposeImageHealthCheck? {
        try await client.imageHealthCheck(reference: reference, platform: platform)
    }

    /// Reads image config metadata through the direct apple/container image API.
    public func imageMetadata(_ reference: String) async throws -> ComposeImageMetadata {
        try await client.imageMetadata(reference: reference)
    }

    /// Lists local Compose Bridge transformer images through the direct apple/container image API.
    public func bridgeTransformers() async throws -> [ComposeBridgeTransformer] {
        try await client.bridgeTransformers()
    }

    /// Pulls an image through the direct apple/container image API.
    public func pullImage(_ reference: String) async throws {
        try await client.pullImage(reference: reference)
    }

    /// Pushes an image and emits the pushed reference.
    public func pushImage(_ reference: String, emit: @escaping @Sendable (String) -> Void) async throws {
        let pushed = try await client.pushImage(reference: reference)
        if !pushed.isEmpty {
            emit(pushed)
        }
    }

    /// Deletes an image and emits the deleted reference when one was found.
    public func deleteImage(_ reference: String, force: Bool, emit: @escaping @Sendable (String) -> Void) async throws {
        guard let deleted = try await client.deleteImage(reference: reference, force: force), !deleted.isEmpty else {
            return
        }
        emit(deleted)
    }

    /// Loads an image archive and emits loaded image references.
    public func loadImageArchive(_ path: String, emit: @escaping @Sendable (String) -> Void) async throws {
        let references = try await client.loadImageArchive(path: path)
        for reference in references where !reference.isEmpty {
            emit(reference)
        }
    }
}
