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
import ContainerizationError
import ContainerizationExtras
import ContainerResource

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
        sizeInBytes: UInt64? = nil,
    ) {
        self.name = name
        self.driver = driver
        self.source = source
        self.labels = labels
        self.sizeInBytes = sizeInBytes
    }

    /// Creates a Compose-facing summary from an apple/container volume.
    public init(configuration: VolumeConfiguration) {
        self.init(
            name: configuration.name,
            driver: configuration.driver,
            source: configuration.source,
            labels: configuration.labels,
            sizeInBytes: configuration.sizeInBytes,
        )
    }
}

/// Fully resolved Compose network creation request.
public struct ComposeNetworkCreateRequest: Equatable, Sendable {
    public var name: String
    public var isInternal: Bool
    public var ipv4Subnet: String?
    public var ipv4Gateway: String?
    public var ipv4AllocationRange: String?
    public var ipv6Subnet: String?
    public var driverOpts: [String: String]
    public var labels: [String: String]

    public init(
        name: String,
        isInternal: Bool = false,
        ipv4Subnet: String? = nil,
        ipv4Gateway: String? = nil,
        ipv4AllocationRange: String? = nil,
        ipv6Subnet: String? = nil,
        driverOpts: [String: String] = [:],
        labels: [String: String] = [:],
    ) {
        self.name = name
        self.isInternal = isInternal
        self.ipv4Subnet = ipv4Subnet
        self.ipv4Gateway = ipv4Gateway
        self.ipv4AllocationRange = ipv4AllocationRange
        self.ipv6Subnet = ipv6Subnet
        self.driverOpts = driverOpts
        self.labels = labels
    }
}

/// Fully resolved Compose volume creation request.
public struct ComposeVolumeCreateRequest: Equatable, Sendable {
    public var name: String
    public var driver: String?
    public var driverOpts: [String: String]
    public var labels: [String: String]

    public init(
        name: String,
        driver: String? = nil,
        driverOpts: [String: String] = [:],
        labels: [String: String] = [:],
    ) {
        self.name = name
        self.driver = driver
        self.driverOpts = driverOpts
        self.labels = labels
    }

    /// Returns the apple/container volume driver for direct API calls.
    public var resolvedDriver: String {
        guard let driver, !driver.isEmpty else {
            return "local"
        }
        return driver
    }
}

/// Low-level apple/container resource calls used by
/// `ContainerClientResourceManager`.
public protocol ContainerResourceAPIClienting: Sendable {
    /// Creates a network from a fully resolved apple/container configuration.
    func createNetwork(configuration: NetworkConfiguration) async throws

    /// Returns whether the runtime network named by `id` exists.
    func networkExists(id: String) async throws -> Bool

    /// Deletes the runtime network named by `id`.
    func deleteNetwork(id: String) async throws

    /// Creates a volume with resolved apple/container runtime metadata.
    func createVolume(_ request: ComposeVolumeCreateRequest) async throws

    /// Lists local volumes available through the apple/container API.
    func listVolumes() async throws -> [ComposeVolumeSummary]

    /// Deletes the runtime volume named by `name`.
    func deleteVolume(name: String) async throws
}

/// Direct apple/container APIs used for Compose-scoped network and volume
/// resources.
public protocol ContainerResourceManaging: Sendable {
    /// Creates a project network with resolved apple/container runtime metadata.
    func createNetwork(_ request: ComposeNetworkCreateRequest) async throws

    /// Deletes the runtime network named by `id`.
    func deleteNetwork(id: String) async throws

    /// Creates a volume with resolved apple/container runtime metadata.
    func createVolume(_ request: ComposeVolumeCreateRequest) async throws

    /// Lists local volumes available to Compose project commands.
    func listVolumes() async throws -> [ComposeVolumeSummary]

    /// Deletes the runtime volume named by `name`.
    func deleteVolume(name: String) async throws
}

public extension ContainerResourceAPIClienting {
    /// Creates a default local volume with labels.
    func createVolume(name: String, labels: [String: String]) async throws {
        try await createVolume(ComposeVolumeCreateRequest(name: name, labels: labels))
    }
}

public extension ContainerResourceManaging {
    /// Creates a default local volume with labels.
    func createVolume(name: String, labels: [String: String]) async throws {
        try await createVolume(ComposeVolumeCreateRequest(name: name, labels: labels))
    }
}

/// Thin apple/container client wrapper around network and volume API calls.
public struct ContainerResourceAPIClient: ContainerResourceAPIClienting {
    public typealias CreateNetwork = @Sendable (NetworkConfiguration) async throws -> Void
    public typealias NetworkExists = @Sendable (String) async throws -> Bool
    public typealias DeleteNetwork = @Sendable (String) async throws -> Void
    public typealias CreateVolume = @Sendable (ComposeVolumeCreateRequest) async throws -> Void
    public typealias ListVolumes = @Sendable () async throws -> [ComposeVolumeSummary]
    public typealias DeleteVolume = @Sendable (String) async throws -> Void

    private let createNetworkOperation: CreateNetwork
    private let networkExistsOperation: NetworkExists
    private let deleteNetworkOperation: DeleteNetwork
    private let createVolumeOperation: CreateVolume
    private let listVolumesOperation: ListVolumes
    private let deleteVolumeOperation: DeleteVolume

    public init(
        createNetwork: @escaping CreateNetwork = { _ = try await NetworkClient().create(configuration: $0) },
        networkExists: @escaping NetworkExists = { id in
            do {
                _ = try await NetworkClient().get(id: id)
                return true
            } catch let error as ContainerizationError where error.code == .notFound {
                return false
            }
        },
        deleteNetwork: @escaping DeleteNetwork = { try await NetworkClient().delete(id: $0) },
        createVolume: @escaping CreateVolume = {
            _ = try await ClientVolume.create(
                name: $0.name,
                driver: $0.resolvedDriver,
                driverOpts: $0.driverOpts,
                labels: $0.labels,
            )
        },
        listVolumes: @escaping ListVolumes = { try await ClientVolume.list().map(ComposeVolumeSummary.init(configuration:)) },
        deleteVolume: @escaping DeleteVolume = { try await ClientVolume.delete(name: $0) },
    ) {
        createNetworkOperation = createNetwork
        networkExistsOperation = networkExists
        deleteNetworkOperation = deleteNetwork
        createVolumeOperation = createVolume
        listVolumesOperation = listVolumes
        deleteVolumeOperation = deleteVolume
    }

    /// Creates a network through `NetworkClient`.
    public func createNetwork(configuration: NetworkConfiguration) async throws {
        try await createNetworkOperation(configuration)
    }

    /// Checks whether a network exists through `NetworkClient`.
    public func networkExists(id: String) async throws -> Bool {
        try await networkExistsOperation(id)
    }

    /// Deletes a network through `NetworkClient`.
    public func deleteNetwork(id: String) async throws {
        try await deleteNetworkOperation(id)
    }

    /// Creates a volume through `ClientVolume`.
    public func createVolume(_ request: ComposeVolumeCreateRequest) async throws {
        try await createVolumeOperation(request)
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

/// apple/container client-backed resource manager for Compose project
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
            ipv4Subnet: request.ipv4Subnet.map { try CIDRv4($0) },
            ipv4Gateway: request.ipv4Gateway.map { try IPv4Address($0) },
            ipv4AllocationRange: request.ipv4AllocationRange.map { try CIDRv4($0) },
            ipv6Subnet: request.ipv6Subnet.map { try CIDRv6($0) },
            labels: ResourceLabels(request.labels),
            plugin: "container-network-vmnet",
            options: request.driverOpts,
        )
        do {
            try await client.createNetwork(configuration: configuration)
        } catch let error as ContainerizationError where error.code == .exists {
            return
        }
    }

    /// Deletes a Compose project network through `NetworkClient`.
    public func deleteNetwork(id: String) async throws {
        guard try await client.networkExists(id: id) else {
            return
        }
        do {
            try await client.deleteNetwork(id: id)
        } catch let error as ContainerizationError where error.code == .notFound {
            return
        }
    }

    /// Creates a Compose project volume through `ClientVolume`.
    public func createVolume(_ request: ComposeVolumeCreateRequest) async throws {
        do {
            try await client.createVolume(request)
        } catch let error as VolumeError {
            if case .volumeAlreadyExists = error {
                return
            }
            throw error
        }
    }

    /// Lists local volumes through `ClientVolume`.
    public func listVolumes() async throws -> [ComposeVolumeSummary] {
        try await client.listVolumes()
    }

    /// Deletes a Compose project volume through `ClientVolume`.
    public func deleteVolume(name: String) async throws {
        let volumes = try await client.listVolumes()
        guard volumes.contains(where: { $0.name == name }) else {
            return
        }
        do {
            try await client.deleteVolume(name: name)
        } catch let error as VolumeError {
            if case .volumeNotFound = error {
                return
            }
            throw error
        }
    }
}
