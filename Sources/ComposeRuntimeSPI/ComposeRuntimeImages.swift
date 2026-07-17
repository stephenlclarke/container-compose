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

/// Docker image healthcheck metadata resolved from an image configuration.
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
        retries: Int? = nil,
    ) {
        self.test = test
        self.intervalInNanoseconds = intervalInNanoseconds
        self.timeoutInNanoseconds = timeoutInNanoseconds
        self.startPeriodInNanoseconds = startPeriodInNanoseconds
        self.startIntervalInNanoseconds = startIntervalInNanoseconds
        self.retries = retries
    }
}

/// Compact image metadata needed by Compose model projections.
public struct ComposeImageMetadata: Sendable, Equatable {
    /// Resolved local image reference.
    public var reference: String
    /// Human-facing display reference.
    public var displayReference: String
    /// Docker image config user.
    public var user: String?
    /// Docker image config environment entries.
    public var environment: [String]
    /// Docker image config entrypoint.
    public var entrypoint: [String]?
    /// Docker image config command.
    public var command: [String]?
    /// Docker image config working directory.
    public var workingDir: String?
    /// Docker image config labels.
    public var labels: [String: String]
    /// Docker image config exposed ports, keyed as "port/protocol".
    public var exposedPorts: [String]
    /// Docker image config stop signal.
    public var stopSignal: String?
    /// Docker image config healthcheck.
    public var healthCheck: ComposeImageHealthCheck?

    public init(reference: String) {
        self.reference = reference
        displayReference = reference
        user = nil
        environment = []
        entrypoint = nil
        command = nil
        workingDir = nil
        labels = [:]
        exposedPorts = []
        stopSignal = nil
        healthCheck = nil
    }

    public init(reference: String, _ configure: (inout ComposeImageMetadata) -> Void) {
        self.init(reference: reference)
        configure(&self)
    }
}

/// Size fields for a local Compose Bridge transformer image.
public struct ComposeBridgeTransformerSize: Sendable, Equatable {
    /// Shared image size, or `-1` when unavailable.
    public var sharedSizeInBytes: Int64
    /// Total image size in bytes when known.
    public var sizeInBytes: Int64

    public init(sharedSizeInBytes: Int64 = -1, sizeInBytes: Int64 = 0) {
        self.sharedSizeInBytes = sharedSizeInBytes
        self.sizeInBytes = sizeInBytes
    }
}

/// Detail fields for a local Compose Bridge transformer image.
public struct ComposeBridgeTransformerDetails: Sendable, Equatable {
    /// Image creation time as Unix seconds.
    public var createdAtUnix: Int64
    /// Number of containers using the image, or `-1` when unavailable.
    public var containers: Int64
    /// Image config labels.
    public var labels: [String: String]
    /// Parent image identifier when known.
    public var parentID: String
    /// Locally known repository digests.
    public var repoDigests: [String]
    /// Locally known repository tags.
    public var repoTags: [String]?
    /// Image size metadata.
    public var size: ComposeBridgeTransformerSize

    public init(
        createdAtUnix: Int64 = 0,
        containers: Int64 = -1,
        labels: [String: String] = [:],
        parentID: String = "",
        repoDigests: [String] = [],
        repoTags: [String]? = nil,
        size: ComposeBridgeTransformerSize = .init(),
    ) {
        self.createdAtUnix = createdAtUnix
        self.containers = containers
        self.labels = labels
        self.parentID = parentID
        self.repoDigests = repoDigests
        self.repoTags = repoTags
        self.size = size
    }
}

/// Local transformer image shown by `compose bridge transformations list`.
public struct ComposeBridgeTransformer: Sendable, Equatable {
    /// Image identifier or digest.
    public var id: String
    /// Human-facing image reference.
    public var reference: String
    /// Image creation time as Unix seconds.
    public var createdAtUnix: Int64
    /// Number of containers using the image, or `-1` when unavailable.
    public var containers: Int64
    /// Image config labels.
    public var labels: [String: String]
    /// Parent image identifier when known.
    public var parentID: String
    /// Locally known repository digests.
    public var repoDigests: [String]
    /// Locally known repository tags.
    public var repoTags: [String]
    /// Shared image size, or `-1` when unavailable.
    public var sharedSizeInBytes: Int64
    /// Total image size in bytes when known.
    public var sizeInBytes: Int64

    public init(
        id: String,
        reference: String,
        details: ComposeBridgeTransformerDetails = .init(),
    ) {
        self.id = id
        self.reference = reference
        createdAtUnix = details.createdAtUnix
        containers = details.containers
        labels = details.labels
        parentID = details.parentID
        repoDigests = details.repoDigests
        repoTags = details.repoTags ?? (reference.isEmpty ? [] : [reference])
        sharedSizeInBytes = details.size.sharedSizeInBytes
        sizeInBytes = details.size.sizeInBytes
    }
}

/// Image operations provided by a Compose runtime backend.
///
/// Implementations may call typed runtime APIs, invoke a stable CLI surface,
/// or use a remote image service. The orchestrator depends on this contract
/// rather than on a particular runtime package.
public protocol ComposeRuntimeImageManaging: Sendable {
    /// Returns whether `reference` exists in the local image store.
    func imageExists(_ reference: String) async throws -> Bool

    /// Resolves the remote manifest digest for `reference` without pulling it.
    func imageDigest(_ reference: String) async throws -> String

    /// Returns Docker image healthcheck metadata for `reference` and `platform`.
    func imageHealthCheck(_ reference: String, platform: String?) async throws -> ComposeImageHealthCheck?

    /// Returns image config metadata for `reference`.
    func imageMetadata(_ reference: String) async throws -> ComposeImageMetadata

    /// Lists local Compose Bridge transformer images.
    func bridgeTransformers() async throws -> [ComposeBridgeTransformer]

    /// Pulls `reference`.
    func pullImage(_ reference: String) async throws

    /// Pulls `reference` only when it is missing from the local image store.
    ///
    /// This remains a protocol requirement so a runtime provider can preserve
    /// its own atomic or instrumented missing-image behaviour. The default
    /// implementation below is suitable for providers that only expose
    /// separate existence and pull operations.
    func pullMissingImage(_ reference: String) async throws

    /// Pushes `reference` and emits the pushed runtime reference when available.
    func pushImage(_ reference: String, emit: @escaping @Sendable (String) -> Void) async throws

    /// Deletes `reference` and emits the deleted runtime reference when available.
    func deleteImage(_ reference: String, force: Bool, emit: @escaping @Sendable (String) -> Void) async throws

    /// Loads an image archive and emits loaded image references.
    func loadImageArchive(_ path: String, emit: @escaping @Sendable (String) -> Void) async throws
}

public extension ComposeRuntimeImageManaging {
    /// Pulls `reference` only when it is missing from the local image store.
    func pullMissingImage(_ reference: String) async throws {
        let exists = try await imageExists(reference)
        guard !exists else {
            return
        }
        try await pullImage(reference)
    }
}
