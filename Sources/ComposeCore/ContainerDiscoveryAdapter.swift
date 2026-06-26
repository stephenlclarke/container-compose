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
import ContainerResource
import ContainerizationError
import Foundation

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
            networks: [ComposeContainerNetworkAttachment] = []
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
        state: State = State()
    ) {
        self.id = id
        self.status = status
        self.labels = labels
        self.imageReference = image.reference
        self.imageDigest = image.digest
        self.platform = image.platform
        self.publishedPorts = resources.publishedPorts
        self.mounts = resources.mounts
        self.networks = resources.networks
        self.exitCode = state.exitCode
        self.exitedDate = state.exitedDate
        self.health = state.health
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
        publishedPorts: [ComposeContainerPublishedPort]
    ) {
        self.init(id: id, status: status, labels: labels, resources: Resources(publishedPorts: publishedPorts))
    }

    public init(
        id: String,
        status: String,
        labels: [String: String] = [:],
        networks: [ComposeContainerNetworkAttachment]
    ) {
        self.init(id: id, status: status, labels: labels, resources: Resources(networks: networks))
    }
}

/// Stable network-attachment data projected from apple/container snapshots.
public struct ComposeContainerNetworkAttachment: Sendable, Equatable, Codable {
    public var network: String
    public var ipv4Address: String

    public init(network: String, ipv4Address: String) {
        self.network = network
        self.ipv4Address = ipv4Address
    }
}

/// Stable published-port data projected from apple/container snapshots.
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
        count: UInt16 = 1
    ) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
        self.count = count
    }
}

/// Low-level apple/container discovery calls used by
/// `ContainerClientDiscoveryManager`.
public protocol ContainerDiscoveryAPIClienting: Sendable {
    /// Lists containers with fully resolved apple/container filters.
    func listContainers(filters: ContainerListFilters) async throws -> [ContainerSnapshot]

    /// Returns a container snapshot when `id` exists.
    func getContainer(id: String) async throws -> ContainerSnapshot?
}

/// Direct apple/container APIs used for Compose project discovery.
public protocol ContainerDiscoveryManaging: Sendable {
    /// Lists containers, including stopped containers when `all` is true.
    func listContainers(all: Bool) async throws -> [ComposeContainerSummary]

    /// Returns a container summary when `id` exists.
    func getContainer(id: String) async throws -> ComposeContainerSummary?
}

/// Thin apple/container client wrapper around discovery API calls.
public struct ContainerDiscoveryAPIClient: ContainerDiscoveryAPIClienting {
    public typealias List = @Sendable (ContainerListFilters) async throws -> [ContainerSnapshot]
    public typealias Get = @Sendable (String) async throws -> ContainerSnapshot

    private let listOperation: List
    private let getOperation: Get

    public init(
        list: @escaping List = { try await ContainerClient().list(filters: $0) },
        get: @escaping Get = { try await ContainerClient().get(id: $0) }
    ) {
        self.listOperation = list
        self.getOperation = get
    }

    /// Lists containers through `ContainerClient`.
    public func listContainers(filters: ContainerListFilters) async throws -> [ContainerSnapshot] {
        try await listOperation(filters)
    }

    /// Fetches one container through `ContainerClient`.
    public func getContainer(id: String) async throws -> ContainerSnapshot? {
        do {
            return try await getOperation(id)
        } catch let error as ContainerizationError where error.code == .notFound {
            return nil
        }
    }
}

/// `ContainerClient`-backed discovery manager for Compose project metadata.
public struct ContainerClientDiscoveryManager: ContainerDiscoveryManaging {
    private let client: ContainerDiscoveryAPIClienting

    public init(client: ContainerDiscoveryAPIClienting = ContainerDiscoveryAPIClient()) {
        self.client = client
    }

    /// Lists non-machine containers through `ContainerClient.list(filters:)`.
    public func listContainers(all: Bool) async throws -> [ComposeContainerSummary] {
        let filters = ContainerListFilters(status: all ? nil : .running).withoutMachines()
        let snapshots = try await client.listContainers(filters: filters)
        return snapshots.map(Self.summary(from:))
    }

    /// Fetches one container through `ContainerClient.get(id:)`.
    public func getContainer(id: String) async throws -> ComposeContainerSummary? {
        guard let snapshot = try await client.getContainer(id: id) else {
            return nil
        }
        return Self.summary(from: snapshot)
    }

    /// Projects an apple/container snapshot into the stable Compose model.
    private static func summary(from snapshot: ContainerSnapshot) -> ComposeContainerSummary {
        ComposeContainerSummary(
            id: snapshot.id,
            status: snapshot.status.rawValue,
            labels: snapshot.configuration.labels,
            image: ComposeContainerSummary.Image(
                reference: snapshot.configuration.image.reference,
                digest: snapshot.configuration.image.digest,
                platform: snapshot.platform.description
            ),
            resources: ComposeContainerSummary.Resources(
                publishedPorts: snapshot.configuration.publishedPorts.map {
                    ComposeContainerPublishedPort(
                        hostAddress: String(describing: $0.hostAddress),
                        hostPort: $0.hostPort,
                        containerPort: $0.containerPort,
                        protocolName: $0.proto.rawValue,
                        count: $0.count
                    )
                },
                mounts: snapshot.configuration.mounts.map(Self.mount(from:)),
                networks: snapshot.networks.map {
                    ComposeContainerNetworkAttachment(
                        network: $0.network,
                        ipv4Address: String(describing: $0.ipv4Address.address)
                    )
                }
            ),
            state: ComposeContainerSummary.State(
                exitCode: snapshot.exitCode,
                exitedDate: snapshot.exitedDate,
                health: snapshot.health?.rawValue
            )
        )
    }

    /// Projects an apple/container filesystem mount into a runtime-ready Compose mount.
    private static func mount(from filesystem: Filesystem) -> ComposeMount {
        let readOnly = filesystem.options.readonly ? true : nil
        switch filesystem.type {
        case .volume(let name, _, _, _):
            return ComposeMount(type: "external-volume", source: name, target: filesystem.destination, readOnly: readOnly)
        case .virtiofs:
            return ComposeMount(type: "bind", source: filesystem.source, target: filesystem.destination, readOnly: readOnly)
        case .tmpfs:
            return ComposeMount(type: "tmpfs", target: filesystem.destination, readOnly: readOnly)
        case .block:
            return ComposeMount(
                type: "block",
                source: filesystem.source,
                target: filesystem.destination,
                readOnly: readOnly,
                unsupportedFields: ["apple.container.block"]
            )
        }
    }
}
