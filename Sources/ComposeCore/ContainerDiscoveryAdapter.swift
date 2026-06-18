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

/// Stable container data used by Compose project discovery and projections.
public struct ComposeContainerSummary: Sendable, Equatable, Codable {
    public var id: String
    public var status: String
    public var labels: [String: String]
    public var imageReference: String
    public var imageDigest: String?
    public var platform: String

    public init(
        id: String,
        status: String,
        labels: [String: String] = [:],
        imageReference: String = "",
        imageDigest: String? = nil,
        platform: String = ""
    ) {
        self.id = id
        self.status = status
        self.labels = labels
        self.imageReference = imageReference
        self.imageDigest = imageDigest
        self.platform = platform
    }
}

/// Low-level Apple container discovery calls used by
/// `ContainerClientDiscoveryManager`.
public protocol ContainerDiscoveryAPIClienting: Sendable {
    /// Lists containers with fully resolved Apple container filters.
    func listContainers(filters: ContainerListFilters) async throws -> [ContainerSnapshot]

    /// Returns a container snapshot when `id` exists.
    func getContainer(id: String) async throws -> ContainerSnapshot?
}

/// Direct Apple container APIs used for Compose project discovery.
public protocol ContainerDiscoveryManaging: Sendable {
    /// Lists containers, including stopped containers when `all` is true.
    func listContainers(all: Bool) async throws -> [ComposeContainerSummary]

    /// Returns a container summary when `id` exists.
    func getContainer(id: String) async throws -> ComposeContainerSummary?
}

/// Thin Apple `container` client wrapper around discovery API calls.
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

    /// Projects Apple's container snapshot into the stable Compose model.
    private static func summary(from snapshot: ContainerSnapshot) -> ComposeContainerSummary {
        ComposeContainerSummary(
            id: snapshot.id,
            status: snapshot.status.rawValue,
            labels: snapshot.configuration.labels,
            imageReference: snapshot.configuration.image.reference,
            imageDigest: snapshot.configuration.image.digest,
            platform: snapshot.platform.description
        )
    }
}
