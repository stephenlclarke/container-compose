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

/// Options for `compose publish`.
public struct ComposePublishOptions: Equatable, Sendable {
    public var repository: String
    public var app: Bool
    public var ociVersion: String?
    public var resolveImageDigests: Bool
    public var withEnv: Bool
    public var assumeYes: Bool
    public var dryRun: Bool

    public init(
        repository: String,
        app: Bool = false,
        ociVersion: String? = nil,
        resolveImageDigests: Bool = false,
        withEnv: Bool = false,
        assumeYes: Bool = false,
        dryRun: Bool = false,
    ) {
        self.repository = repository
        self.app = app
        self.ociVersion = ociVersion
        self.resolveImageDigests = resolveImageDigests
        self.withEnv = withEnv
        self.assumeYes = assumeYes
        self.dryRun = dryRun
    }
}

/// Result emitted by the compose-go normalizer after planning or publishing.
public struct ComposePublishResult: Codable, Equatable, Sendable {
    public var repository: String
    public var ociVersion: String
    public var dryRun: Bool
    public var descriptor: ComposePublishDescriptor?
    public var layers: [ComposePublishLayer]

    public init(
        repository: String,
        ociVersion: String,
        dryRun: Bool = false,
        descriptor: ComposePublishDescriptor? = nil,
        layers: [ComposePublishLayer] = [],
    ) {
        self.repository = repository
        self.ociVersion = ociVersion
        self.dryRun = dryRun
        self.descriptor = descriptor
        self.layers = layers
    }
}

public struct ComposePublishDescriptor: Codable, Equatable, Sendable {
    public var mediaType: String
    public var digest: String
    public var size: Int64
    public var artifactType: String?

    public init(mediaType: String, digest: String, size: Int64, artifactType: String? = nil) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.artifactType = artifactType
    }
}

public struct ComposePublishLayer: Codable, Equatable, Sendable {
    public var kind: String
    public var path: String
    public var mediaType: String
    public var digest: String
    public var size: Int64

    public init(kind: String, path: String, mediaType: String, digest: String, size: Int64) {
        self.kind = kind
        self.path = path
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
    }
}
