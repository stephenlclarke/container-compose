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
import ContainerizationExtras

/// Runtime volume metadata needed by Compose project commands.
public struct ComposeVolumeSummary: Codable, Equatable, Sendable {
    public var name: String
    public var driver: String
    public var source: String
    public var labels: [String: String]
    public var sizeInBytes: UInt64?

    public init(
        name: String,
        driver: String = "local",
        source: String = "",
        labels: [String: String] = [:],
        sizeInBytes: UInt64? = nil
    ) {
        self.name = name
        self.driver = driver
        self.source = source
        self.labels = labels
        self.sizeInBytes = sizeInBytes
    }

    /// Creates a Compose-facing summary from an Apple container volume.
    public init(configuration: VolumeConfiguration) {
        self.init(
            name: configuration.name,
            driver: configuration.driver,
            source: configuration.source,
            labels: configuration.labels,
            sizeInBytes: configuration.sizeInBytes
        )
    }
}

/// Fully resolved Compose network creation request.
public struct ComposeNetworkCreateRequest: Equatable, Sendable {
    public var name: String
    public var isInternal: Bool
    public var ipv4Subnet: String?
    public var ipv6Subnet: String?
    public var labels: [String: String]

    public init(
        name: String,
        isInternal: Bool = false,
        ipv4Subnet: String? = nil,
        ipv6Subnet: String? = nil,
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.isInternal = isInternal
        self.ipv4Subnet = ipv4Subnet
        self.ipv6Subnet = ipv6Subnet
        self.labels = labels
    }
}

/// Low-level Apple container resource calls used by
/// `ContainerClientResourceManager`.
public protocol ContainerResourceAPIClienting: Sendable {
    /// Creates a network from a fully resolved Apple container configuration.
    func createNetwork(configuration: NetworkConfiguration) async throws

    /// Deletes the runtime network named by `id`.
    func deleteNetwork(id: String) async throws

    /// Creates a local volume with the supplied runtime name and labels.
    func createVolume(name: String, labels: [String: String]) async throws

    /// Lists local volumes available through the Apple container API.
    func listVolumes() async throws -> [ComposeVolumeSummary]

    /// Deletes the runtime volume named by `name`.
    func deleteVolume(name: String) async throws
}

/// Direct Apple container APIs used for Compose-scoped network and volume
/// resources.
public protocol ContainerResourceManaging: Sendable {
    /// Creates a project network with resolved Apple runtime metadata.
    func createNetwork(_ request: ComposeNetworkCreateRequest) async throws

    /// Deletes the runtime network named by `id`.
    func deleteNetwork(id: String) async throws

    /// Creates a local volume with the supplied runtime name and labels.
    func createVolume(name: String, labels: [String: String]) async throws

    /// Lists local volumes available to Compose project commands.
    func listVolumes() async throws -> [ComposeVolumeSummary]

    /// Deletes the runtime volume named by `name`.
    func deleteVolume(name: String) async throws
}

/// Thin Apple `container` client wrapper around network and volume API calls.
public struct ContainerResourceAPIClient: ContainerResourceAPIClienting {
    public typealias CreateNetwork = @Sendable (NetworkConfiguration) async throws -> Void
    public typealias DeleteNetwork = @Sendable (String) async throws -> Void
    public typealias CreateVolume = @Sendable (String, [String: String]) async throws -> Void
    public typealias ListVolumes = @Sendable () async throws -> [ComposeVolumeSummary]
    public typealias DeleteVolume = @Sendable (String) async throws -> Void

    private let createNetworkOperation: CreateNetwork
    private let deleteNetworkOperation: DeleteNetwork
    private let createVolumeOperation: CreateVolume
    private let listVolumesOperation: ListVolumes
    private let deleteVolumeOperation: DeleteVolume

    public init(
        createNetwork: @escaping CreateNetwork = { _ = try await NetworkClient().create(configuration: $0) },
        deleteNetwork: @escaping DeleteNetwork = { try await NetworkClient().delete(id: $0) },
        createVolume: @escaping CreateVolume = { _ = try await ClientVolume.create(name: $0, labels: $1) },
        listVolumes: @escaping ListVolumes = { try await ClientVolume.list().map(ComposeVolumeSummary.init(configuration:)) },
        deleteVolume: @escaping DeleteVolume = { try await ClientVolume.delete(name: $0) }
    ) {
        self.createNetworkOperation = createNetwork
        self.deleteNetworkOperation = deleteNetwork
        self.createVolumeOperation = createVolume
        self.listVolumesOperation = listVolumes
        self.deleteVolumeOperation = deleteVolume
    }

    /// Creates a network through `NetworkClient`.
    public func createNetwork(configuration: NetworkConfiguration) async throws {
        try await createNetworkOperation(configuration)
    }

    /// Deletes a network through `NetworkClient`.
    public func deleteNetwork(id: String) async throws {
        try await deleteNetworkOperation(id)
    }

    /// Creates a volume through `ClientVolume`.
    public func createVolume(name: String, labels: [String: String]) async throws {
        try await createVolumeOperation(name, labels)
    }

    /// Lists volumes through `ClientVolume`.
    public func listVolumes() async throws -> [ComposeVolumeSummary] {
        try await listVolumesOperation()
    }

    /// Deletes a volume through `ClientVolume`.
    public func deleteVolume(name: String) async throws {
        try await deleteVolumeOperation(name)
    }
}

/// Apple `container` client-backed resource manager for Compose project
/// networks and volumes.
public struct ContainerClientResourceManager: ContainerResourceManaging {
    private let client: ContainerResourceAPIClienting

    public init(client: ContainerResourceAPIClienting = ContainerResourceAPIClient()) {
        self.client = client
    }

    /// Creates a Compose project network through `NetworkClient`.
    public func createNetwork(_ request: ComposeNetworkCreateRequest) async throws {
        let configuration = try NetworkConfiguration(
            name: request.name,
            mode: request.isInternal ? .hostOnly : .nat,
            ipv4Subnet: try request.ipv4Subnet.map { try CIDRv4($0) },
            ipv6Subnet: try request.ipv6Subnet.map { try CIDRv6($0) },
            labels: try ResourceLabels(request.labels),
            plugin: "container-network-vmnet",
            options: [:]
        )
        do {
            try await client.createNetwork(configuration: configuration)
        } catch let error as ContainerizationError where error.code == .exists {
            return
        }
    }

    /// Deletes a Compose project network through `NetworkClient`.
    public func deleteNetwork(id: String) async throws {
        try await client.deleteNetwork(id: id)
    }

    /// Creates a Compose project volume through `ClientVolume`.
    public func createVolume(name: String, labels: [String: String]) async throws {
        try await client.createVolume(name: name, labels: labels)
    }

    /// Lists local volumes through `ClientVolume`.
    public func listVolumes() async throws -> [ComposeVolumeSummary] {
        try await client.listVolumes()
    }

    /// Deletes a Compose project volume through `ClientVolume`.
    public func deleteVolume(name: String) async throws {
        try await client.deleteVolume(name: name)
    }
}
