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

/// Runtime volume metadata needed by Compose project commands.
///
/// This value deliberately contains only Compose-visible fields. Runtime
/// adapters translate to and from their native volume representations at the
/// implementation boundary.
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
}

/// Fully resolved Compose network creation request.
public struct ComposeNetworkCreateRequest: Equatable, Sendable {
    /// IP addressing supplied for a runtime network create request.
    public struct Addressing: Equatable, Sendable {
        public var ipv4Subnet: String?
        public var ipv4Gateway: String?
        public var ipv4AllocationRange: String?
        public var ipv4ReservedAddresses: [String]
        public var ipv6Subnet: String?

        public init(
            ipv4Subnet: String? = nil,
            ipv4Gateway: String? = nil,
            ipv4AllocationRange: String? = nil,
            ipv4ReservedAddresses: [String] = [],
            ipv6Subnet: String? = nil,
        ) {
            self.ipv4Subnet = ipv4Subnet
            self.ipv4Gateway = ipv4Gateway
            self.ipv4AllocationRange = ipv4AllocationRange
            self.ipv4ReservedAddresses = ipv4ReservedAddresses
            self.ipv6Subnet = ipv6Subnet
        }
    }

    public var name: String
    public var isInternal: Bool
    public var ipv4Subnet: String?
    public var ipv4Gateway: String?
    public var ipv4AllocationRange: String?
    public var ipv4ReservedAddresses: [String]
    public var ipv6Subnet: String?
    public var driverOpts: [String: String]
    public var labels: [String: String]

    public init(
        name: String,
        isInternal: Bool = false,
        addressing: Addressing = Addressing(),
        driverOpts: [String: String] = [:],
        labels: [String: String] = [:],
    ) {
        self.name = name
        self.isInternal = isInternal
        ipv4Subnet = addressing.ipv4Subnet
        ipv4Gateway = addressing.ipv4Gateway
        ipv4AllocationRange = addressing.ipv4AllocationRange
        ipv4ReservedAddresses = addressing.ipv4ReservedAddresses
        ipv6Subnet = addressing.ipv6Subnet
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

    /// Returns the driver name that a runtime adapter should use by default.
    public var resolvedDriver: String {
        guard let driver, !driver.isEmpty else {
            return "local"
        }
        return driver
    }
}

/// Compose-scoped network and volume operations provided by a runtime backend.
///
/// Implementations may call typed runtime APIs, invoke a stable CLI surface,
/// or use a test double. The orchestrator depends on this contract rather than
/// on a particular runtime package.
public protocol ComposeRuntimeResourceManaging: Sendable {
    /// Creates a project network from a fully resolved Compose request.
    func createNetwork(_ request: ComposeNetworkCreateRequest) async throws

    /// Deletes the runtime network named by `id`.
    func deleteNetwork(id: String) async throws

    /// Creates a volume from a fully resolved Compose request.
    func createVolume(_ request: ComposeVolumeCreateRequest) async throws

    /// Lists local volumes available to Compose project commands.
    func listVolumes() async throws -> [ComposeVolumeSummary]

    /// Deletes the runtime volume named by `name`.
    func deleteVolume(name: String) async throws
}

public extension ComposeRuntimeResourceManaging {
    /// Creates a default local volume with labels.
    func createVolume(name: String, labels: [String: String]) async throws {
        try await createVolume(ComposeVolumeCreateRequest(name: name, labels: labels))
    }
}
