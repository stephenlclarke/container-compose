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

/// Docker image healthcheck metadata resolved from an OCI image config.
public struct ComposeImageHealthCheck: Sendable, Equatable {
    /// Probe command encoded by Docker as `NONE`, `CMD`, or `CMD-SHELL`.
    public var test: [String]?
    /// Delay between health probes, in nanoseconds.
    public var intervalInNanoseconds: Int64?
    /// Maximum probe runtime, in nanoseconds.
    public var timeoutInNanoseconds: Int64?
    /// Grace period before failures count, in nanoseconds.
    public var startPeriodInNanoseconds: Int64?
    /// Delay between probes during the start period, in nanoseconds.
    public var startIntervalInNanoseconds: Int64?
    /// Number of consecutive failures before the container is unhealthy.
    public var retries: Int?

    public init(
        test: [String]? = nil,
        intervalInNanoseconds: Int64? = nil,
        timeoutInNanoseconds: Int64? = nil,
        startPeriodInNanoseconds: Int64? = nil,
        startIntervalInNanoseconds: Int64? = nil,
        retries: Int? = nil
    ) {
        self.test = test
        self.intervalInNanoseconds = intervalInNanoseconds
        self.timeoutInNanoseconds = timeoutInNanoseconds
        self.startPeriodInNanoseconds = startPeriodInNanoseconds
        self.startIntervalInNanoseconds = startIntervalInNanoseconds
        self.retries = retries
    }
}

/// Low-level apple/container image calls used by `ContainerClientImageManager`.
public protocol ContainerImageAPIClienting: Sendable {
    /// Returns whether `reference` exists in the local image store.
    func imageExists(reference: String) async throws -> Bool

    /// Returns Docker image healthcheck metadata for `reference` and `platform`.
    func imageHealthCheck(reference: String, platform: String?) async throws -> ComposeImageHealthCheck?

    /// Pulls and unpacks `reference`.
    func pullImage(reference: String) async throws

    /// Pushes `reference` and returns the runtime image reference that was pushed.
    func pushImage(reference: String) async throws -> String

    /// Deletes `reference`, returning the runtime image reference that was deleted.
    func deleteImage(reference: String, force: Bool) async throws -> String?
}

/// Direct apple/container image APIs used for Compose image workflows.
public protocol ContainerImageManaging: Sendable {
    /// Returns whether `reference` exists in the local image store.
    func imageExists(_ reference: String) async throws -> Bool

    /// Returns Docker image healthcheck metadata for `reference` and `platform`.
    func imageHealthCheck(_ reference: String, platform: String?) async throws -> ComposeImageHealthCheck?

    /// Pulls `reference`.
    func pullImage(_ reference: String) async throws

    /// Pulls `reference` only when it is missing from the local image store.
    func pullMissingImage(_ reference: String) async throws

    /// Pushes `reference` and emits the pushed runtime reference when available.
    func pushImage(_ reference: String, emit: @escaping @Sendable (String) -> Void) async throws

    /// Deletes `reference` and emits the deleted runtime reference when available.
    func deleteImage(_ reference: String, force: Bool, emit: @escaping @Sendable (String) -> Void) async throws
}

/// Thin apple/container client wrapper around image API calls.
public struct ContainerImageAPIClient: ContainerImageAPIClienting {
    public typealias Exists = @Sendable (String) async throws -> Bool
    public typealias HealthCheck = @Sendable (String, String?) async throws -> ComposeImageHealthCheck?
    public typealias Pull = @Sendable (String) async throws -> Void
    public typealias Push = @Sendable (String) async throws -> String
    public typealias Delete = @Sendable (String, Bool) async throws -> String?

    private let existsOperation: Exists
    private let healthCheckOperation: HealthCheck
    private let pullOperation: Pull
    private let pushOperation: Push
    private let deleteOperation: Delete

    /// Creates a facade around another image API client.
    public init(client: ContainerImageAPIClienting) {
        self.init(
            exists: { try await client.imageExists(reference: $0) },
            healthCheck: { try await client.imageHealthCheck(reference: $0, platform: $1) },
            pull: { try await client.pullImage(reference: $0) },
            push: { try await client.pushImage(reference: $0) },
            delete: { try await client.deleteImage(reference: $0, force: $1) }
        )
    }

    /// Creates a facade from explicit image operation closures.
    public init(
        exists: @escaping Exists,
        healthCheck: @escaping HealthCheck = { _, _ in nil },
        pull: @escaping Pull,
        push: @escaping Push,
        delete: @escaping Delete
    ) {
        self.existsOperation = exists
        self.healthCheckOperation = healthCheck
        self.pullOperation = pull
        self.pushOperation = push
        self.deleteOperation = delete
    }

    /// Creates a facade around the live apple/container image API bridge.
    public init() {
        self.init(client: ContainerImageLiveAPIClient())
    }

    /// Checks the local image store through `ClientImage.get(names:)`.
    public func imageExists(reference: String) async throws -> Bool {
        try await existsOperation(reference)
    }

    /// Reads Docker image healthcheck metadata through `ClientImage`.
    public func imageHealthCheck(reference: String, platform: String?) async throws -> ComposeImageHealthCheck? {
        try await healthCheckOperation(reference, platform)
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
}

/// `ClientImage`-backed manager for Compose image operations.
public struct ContainerClientImageManager: ContainerImageManaging {
    private let client: ContainerImageAPIClienting

    public init(client: ContainerImageAPIClienting = ContainerImageAPIClient()) {
        self.client = client
    }

    /// Checks the local image store through the direct apple/container image API.
    public func imageExists(_ reference: String) async throws -> Bool {
        try await client.imageExists(reference: reference)
    }

    /// Reads Docker image healthcheck metadata through the direct apple/container image API.
    public func imageHealthCheck(_ reference: String, platform: String?) async throws -> ComposeImageHealthCheck? {
        try await client.imageHealthCheck(reference: reference, platform: platform)
    }

    /// Pulls an image through the direct apple/container image API.
    public func pullImage(_ reference: String) async throws {
        try await client.pullImage(reference: reference)
    }

    /// Pulls an image only when `ClientImage.get` cannot resolve it locally.
    public func pullMissingImage(_ reference: String) async throws {
        let exists = try await client.imageExists(reference: reference)
        guard !exists else {
            return
        }
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
}
