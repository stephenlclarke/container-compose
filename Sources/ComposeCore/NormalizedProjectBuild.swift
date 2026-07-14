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

/// Image-related build options while retaining the `ComposeBuild.Options.Image`
/// source-level API through a type alias.
public struct ComposeBuildImageOptions: Equatable {
    public var target: String?
    public var noCache: Bool?
    public var pull: Bool?
    public var platforms: [String]?
    public var tags: [String]?

    public init(
        target: String? = nil,
        noCache: Bool? = nil,
        pull: Bool? = nil,
        platforms: [String]? = nil,
        tags: [String]? = nil,
    ) {
        self.target = target
        self.noCache = noCache
        self.pull = pull
        self.platforms = platforms
        self.tags = tags
    }
}

/// Build frontend options while retaining the `ComposeBuild.Options.Frontend`
/// source-level API through a type alias.
public struct ComposeBuildFrontendOptions: Equatable {
    public var entitlements: [String]?
    public var extraHosts: [String]?
    public var isolation: String?
    public var network: String?
    public var privileged: Bool?
    public var shmSize: String?
    public var ulimits: [String]?

    public init(
        entitlements: [String]? = nil,
        extraHosts: [String]? = nil,
        isolation: String? = nil,
        network: String? = nil,
        privileged: Bool? = nil,
        shmSize: String? = nil,
        ulimits: [String]? = nil,
    ) {
        self.entitlements = entitlements
        self.extraHosts = extraHosts
        self.isolation = isolation
        self.network = network
        self.privileged = privileged
        self.shmSize = shmSize
        self.ulimits = ulimits
    }
}

/// Build provenance and software-bill-of-materials options while retaining the
/// `ComposeBuild.Options.Attestations` source-level API through a type alias.
public struct ComposeBuildAttestations: Equatable {
    public var provenance: String?
    public var sbom: String?

    public init(provenance: String? = nil, sbom: String? = nil) {
        self.provenance = provenance
        self.sbom = sbom
    }
}

/// Build configuration for a Compose service.
public struct ComposeBuild: Codable, Equatable {
    /// Build cache sources and destinations.
    public struct Cache: Equatable {
        public var from: [String]?
        public var to: [String]?

        public init(from: [String]? = nil, to: [String]? = nil) {
            self.from = from
            self.to = to
        }
    }

    /// Build labels and secrets that become build-time metadata.
    public struct Metadata: Equatable {
        public var labels: [String: String]?
        public var secrets: [ComposeBuildSecret]?
        public var ssh: [String]?

        public init(labels: [String: String]? = nil, secrets: [ComposeBuildSecret]? = nil, ssh: [String]? = nil) {
            self.labels = labels
            self.secrets = secrets
            self.ssh = ssh
        }
    }

    /// Optional build behavior that is not required for every service.
    public struct Options: Equatable {
        // Keep the established nested public API while implementing its
        // components as independently testable top-level value types.
        // swiftlint:disable nesting
        public typealias Image = ComposeBuildImageOptions
        public typealias Frontend = ComposeBuildFrontendOptions
        public typealias Attestations = ComposeBuildAttestations
        // swiftlint:enable nesting

        public var target: String?
        public var noCache: Bool?
        public var pull: Bool?
        public var platforms: [String]?
        public var tags: [String]?
        public var entitlements: [String]?
        public var extraHosts: [String]?
        public var isolation: String?
        public var network: String?
        public var privileged: Bool?
        public var shmSize: String?
        public var ulimits: [String]?
        public var provenance: String?
        public var sbom: String?
        public var unsupportedFields: [String]?

        public init(
            image: Image = Image(),
            frontend: Frontend = Frontend(),
            attestations: Attestations = Attestations(),
            unsupportedFields: [String]? = nil,
        ) {
            target = image.target
            noCache = image.noCache
            pull = image.pull
            platforms = image.platforms
            tags = image.tags
            entitlements = frontend.entitlements
            extraHosts = frontend.extraHosts
            isolation = frontend.isolation
            network = frontend.network
            privileged = frontend.privileged
            shmSize = frontend.shmSize
            ulimits = frontend.ulimits
            provenance = attestations.provenance
            sbom = attestations.sbom
            self.unsupportedFields = unsupportedFields
        }
    }

    /// Build context inputs used to locate Dockerfile and named BuildKit contexts.
    public struct Contexts: Equatable {
        public var context: String?
        public var dockerfile: String?
        public var dockerfileInline: String?
        public var additionalContexts: [String: String]?

        public init(
            context: String? = nil,
            dockerfile: String? = nil,
            dockerfileInline: String? = nil,
            additionalContexts: [String: String]? = nil,
        ) {
            self.context = context
            self.dockerfile = dockerfile
            self.dockerfileInline = dockerfileInline
            self.additionalContexts = additionalContexts
        }
    }

    public var context: String?
    public var dockerfile: String?
    public var dockerfileInline: String?
    public var additionalContexts: [String: String]?
    public var args: [String: String]?
    public var cacheFrom: [String]?
    public var cacheTo: [String]?
    public var entitlements: [String]?
    public var extraHosts: [String]?
    public var isolation: String?
    public var labels: [String: String]?
    public var network: String?
    public var privileged: Bool?
    public var secrets: [ComposeBuildSecret]?
    public var shmSize: String?
    public var ssh: [String]?
    public var target: String?
    public var noCache: Bool?
    public var pull: Bool?
    public var platforms: [String]?
    public var tags: [String]?
    public var ulimits: [String]?
    public var provenance: String?
    public var sbom: String?
    public var unsupportedFields: [String]?

    public init(
        context: String? = nil,
        dockerfile: String? = nil,
        dockerfileInline: String? = nil,
        args: [String: String]? = nil,
        cache: Cache = Cache(),
        metadata: Metadata = Metadata(),
        options: Options = Options(),
    ) {
        self.init(
            contexts: Contexts(
                context: context,
                dockerfile: dockerfile,
                dockerfileInline: dockerfileInline,
            ),
            args: args,
            cache: cache,
            metadata: metadata,
            options: options,
        )
    }

    public init(
        contexts: Contexts,
        args: [String: String]? = nil,
        cache: Cache = Cache(),
        metadata: Metadata = Metadata(),
        options: Options = Options(),
    ) {
        context = contexts.context
        dockerfile = contexts.dockerfile
        dockerfileInline = contexts.dockerfileInline
        additionalContexts = contexts.additionalContexts
        self.args = args
        cacheFrom = cache.from
        cacheTo = cache.to
        entitlements = options.entitlements
        extraHosts = options.extraHosts
        isolation = options.isolation
        labels = metadata.labels
        network = options.network
        privileged = options.privileged
        secrets = metadata.secrets
        shmSize = options.shmSize
        ssh = metadata.ssh
        target = options.target
        noCache = options.noCache
        pull = options.pull
        platforms = options.platforms
        tags = options.tags
        ulimits = options.ulimits
        provenance = options.provenance
        sbom = options.sbom
        unsupportedFields = options.unsupportedFields
    }
}

/// Build-time secret supported by apple/container `container build --secret`.
public struct ComposeBuildSecret: Codable, Equatable {
    public var id: String
    public var file: String?
    public var environment: String?

    public init(id: String, file: String? = nil, environment: String? = nil) {
        self.id = id
        self.file = file
        self.environment = environment
    }
}
