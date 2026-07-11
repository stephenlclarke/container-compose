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
        size: ComposeBridgeTransformerSize = .init()
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
        details: ComposeBridgeTransformerDetails = .init()
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
