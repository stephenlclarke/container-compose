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

import Foundation

/// Mount definition normalized from Compose volume and bind syntax.
public struct ComposeMount: Codable, Equatable, Sendable {
    /// Bind-specific behavior retained in a normalized mount.
    public struct BindOptions: Codable, Equatable, Sendable {
        public var createHostPath: Bool?
        public var propagation: String?

        public init(createHostPath: Bool? = nil, propagation: String? = nil) {
            self.createHostPath = createHostPath
            self.propagation = propagation
        }
    }

    /// The optional ownership metadata for a mounted source.
    public struct FileOwnership: Codable, Equatable, Sendable {
        public var uid: UInt32?
        public var gid: UInt32?

        public init(uid: UInt32? = nil, gid: UInt32? = nil) {
            self.uid = uid
            self.gid = gid
        }
    }

    /// Volume-specific behavior retained in a normalized mount.
    public struct VolumeOptions: Codable, Equatable, Sendable {
        public var subpath: String?
        public var fileOwnership: FileOwnership
        public var labels: [String: String]?

        public init(
            subpath: String? = nil,
            fileOwnership: FileOwnership = FileOwnership(),
            labels: [String: String]? = nil,
        ) {
            self.subpath = subpath
            self.fileOwnership = fileOwnership
            self.labels = labels
        }
    }

    /// Tmpfs options grouped for construction while preserving flat storage.
    public struct TmpfsOptions: Codable, Equatable, Sendable {
        public var size: String?
        public var mode: String?

        public init(size: String? = nil, mode: String? = nil) {
            self.size = size
            self.mode = mode
        }
    }

    /// Optional mount behavior grouped to keep call sites readable.
    public struct MountOptions: Codable, Equatable, Sendable {
        public var readOnly: Bool?
        public var bindCreateHostPath: Bool?
        public var bindPropagation: String?
        public var volumeSubpath: String?
        public var imageSubpath: String?
        public var fileOwnerUID: UInt32?
        public var fileOwnerGID: UInt32?
        public var volumeLabels: [String: String]?
        public var tmpfs: TmpfsOptions

        public init(
            readOnly: Bool? = nil,
            bind: BindOptions = BindOptions(),
            volume: VolumeOptions = VolumeOptions(),
            imageSubpath: String? = nil,
            tmpfs: TmpfsOptions = TmpfsOptions(),
        ) {
            self.readOnly = readOnly
            bindCreateHostPath = bind.createHostPath
            bindPropagation = bind.propagation
            volumeSubpath = volume.subpath
            self.imageSubpath = imageSubpath
            fileOwnerUID = volume.fileOwnership.uid
            fileOwnerGID = volume.fileOwnership.gid
            volumeLabels = volume.labels
            self.tmpfs = tmpfs
        }
    }

    public var type: String?
    public var source: String?
    public var target: String?
    public var readOnly: Bool?
    public var bindCreateHostPath: Bool?
    public var bindPropagation: String?
    public var volumeSubpath: String?
    public var imageSubpath: String?
    public var fileOwnerUID: UInt32?
    public var fileOwnerGID: UInt32?
    public var volumeLabels: [String: String]?
    public var tmpfsSize: String?
    public var tmpfsMode: String?
    public var raw: String?
    public var unsupportedFields: [String]?

    public init(
        type: String? = nil,
        source: String? = nil,
        target: String? = nil,
        options: MountOptions = MountOptions(),
        raw: String? = nil,
        unsupportedFields: [String]? = nil,
    ) {
        self.type = type
        self.source = source
        self.target = target
        readOnly = options.readOnly
        bindCreateHostPath = options.bindCreateHostPath
        bindPropagation = options.bindPropagation
        volumeSubpath = options.volumeSubpath
        imageSubpath = options.imageSubpath
        fileOwnerUID = options.fileOwnerUID
        fileOwnerGID = options.fileOwnerGID
        volumeLabels = options.volumeLabels
        tmpfsSize = options.tmpfs.size
        tmpfsMode = options.tmpfs.mode
        self.raw = raw
        self.unsupportedFields = unsupportedFields
    }

    /// Creates a mount with only its access-mode override.
    public init(
        type: String? = nil,
        source: String? = nil,
        target: String? = nil,
        readOnly: Bool?,
    ) {
        self.init(
            type: type,
            source: source,
            target: target,
            options: MountOptions(readOnly: readOnly),
        )
    }
}

/// Stable container data used by Compose project discovery and projections.
public struct ComposeContainerSummary: Sendable, Equatable, Codable {
    /// Image metadata discovered from the runtime snapshot.
    public struct Image: Sendable, Equatable, Codable {
        public var reference: String
        public var digest: String?
        public var platform: String

        public init(reference: String = "", digest: String? = nil, platform: String = "") {
            self.reference = reference
            self.digest = digest
            self.platform = platform
        }
    }

    /// Runtime resource attachments discovered from the container snapshot.
    public struct Resources: Sendable, Equatable, Codable {
        public var publishedPorts: [ComposeContainerPublishedPort]
        public var mounts: [ComposeMount]
        public var networks: [ComposeContainerNetworkAttachment]

        public init(
            publishedPorts: [ComposeContainerPublishedPort] = [],
            mounts: [ComposeMount] = [],
            networks: [ComposeContainerNetworkAttachment] = [],
        ) {
            self.publishedPorts = publishedPorts
            self.mounts = mounts
            self.networks = networks
        }
    }

    /// Runtime state discovered from the container snapshot.
    public struct State: Sendable, Equatable, Codable {
        public var exitCode: Int32?
        public var exitedDate: Date?
        public var health: String?

        public init(exitCode: Int32? = nil, exitedDate: Date? = nil, health: String? = nil) {
            self.exitCode = exitCode
            self.exitedDate = exitedDate
            self.health = health
        }
    }

    public var id: String
    public var status: String
    public var labels: [String: String]
    public var imageReference: String
    public var imageDigest: String?
    public var platform: String
    public var publishedPorts: [ComposeContainerPublishedPort]
    public var mounts: [ComposeMount]
    public var networks: [ComposeContainerNetworkAttachment]
    public var exitCode: Int32?
    public var exitedDate: Date?
    public var health: String?

    public init(
        id: String,
        status: String,
        labels: [String: String] = [:],
        image: Image = Image(),
        resources: Resources = Resources(),
        state: State = State(),
    ) {
        self.id = id
        self.status = status
        self.labels = labels
        imageReference = image.reference
        imageDigest = image.digest
        platform = image.platform
        publishedPorts = resources.publishedPorts
        mounts = resources.mounts
        networks = resources.networks
        exitCode = state.exitCode
        exitedDate = state.exitedDate
        health = state.health
    }

    public init(id: String, status: String, labels: [String: String] = [:], exitCode: Int32) {
        self.init(id: id, status: status, labels: labels, state: State(exitCode: exitCode))
    }

    public init(id: String, status: String, labels: [String: String] = [:], health: String) {
        self.init(id: id, status: status, labels: labels, state: State(health: health))
    }

    public init(id: String, status: String, labels: [String: String] = [:], mounts: [ComposeMount]) {
        self.init(id: id, status: status, labels: labels, resources: Resources(mounts: mounts))
    }

    public init(
        id: String,
        status: String,
        labels: [String: String] = [:],
        publishedPorts: [ComposeContainerPublishedPort],
    ) {
        self.init(id: id, status: status, labels: labels, resources: Resources(publishedPorts: publishedPorts))
    }

    public init(
        id: String,
        status: String,
        labels: [String: String] = [:],
        networks: [ComposeContainerNetworkAttachment],
    ) {
        self.init(id: id, status: status, labels: labels, resources: Resources(networks: networks))
    }
}

/// Stable network-attachment data projected from runtime snapshots.
public struct ComposeContainerNetworkAttachment: Sendable, Equatable, Codable {
    public var network: String
    public var ipv4Address: String

    public init(network: String, ipv4Address: String) {
        self.network = network
        self.ipv4Address = ipv4Address
    }
}

/// Stable published-port data projected from runtime snapshots.
public struct ComposeContainerPublishedPort: Sendable, Equatable, Codable {
    public var hostAddress: String
    public var hostPort: UInt16
    public var containerPort: UInt16
    public var protocolName: String
    public var count: UInt16

    public init(
        hostAddress: String,
        hostPort: UInt16,
        containerPort: UInt16,
        protocolName: String,
        count: UInt16 = 1,
    ) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
        self.count = count
    }
}

/// Container discovery operations provided by a Compose runtime backend.
public protocol ComposeRuntimeDiscoveryManaging: Sendable {
    /// Lists containers, including stopped containers when `all` is true.
    func listContainers(all: Bool) async throws -> [ComposeContainerSummary]

    /// Returns a container summary when `id` exists.
    func getContainer(id: String) async throws -> ComposeContainerSummary?
}
