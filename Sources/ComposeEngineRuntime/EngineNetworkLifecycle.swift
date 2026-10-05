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

import ComposeCore
import ComposeRuntimeSPI
import ContainerUnixHTTPClient
import Foundation

public extension EngineRuntimeProvider {
    func createNetwork(_ request: ComposeNetworkCreateRequest) async throws {
        let addressing = EngineIPAMConfig(
            subnet: request.ipv4Subnet,
            range: request.ipv4AllocationRange,
            gateway: request.ipv4Gateway,
            reserved: request.ipv4ReservedAddresses,
        )
        let payload = EngineNetworkCreateRequest(
            name: request.name,
            internalNetwork: request.isInternal,
            enableIPv4: request.enableIPv4,
            enableIPv6: request.enableIPv6,
            options: request.driverOpts,
            labels: request.labels,
            ipam: addressing.isEmpty ? nil : EngineIPAM(config: [addressing]),
        )
        do {
            let _: EngineNetworkCreateResponse = try await self.request(.post, "/v1.53/networks/create", body: payload)
        } catch let error as ContainerUnixHTTPClientError {
            guard case .server(status: 409, message: _) = error,
                  let existing = try await networkResource(reference: request.name),
                  existing.name == request.name,
                  existing.internalNetwork == request.isInternal,
                  request.labels.allSatisfy({ existing.labels[$0.key] == $0.value })
            else {
                throw error
            }
        }
    }

    func deleteNetwork(id: String) async throws {
        do {
            try await request(.delete, "/v1.53/networks/\(escaped(id))")
        } catch let error as ContainerUnixHTTPClientError {
            guard case .server(status: 404, message: _) = error,
                  case nil = try await networkResource(reference: id)
            else {
                throw error
            }
        }
    }

    /// Resolve exact identities from current inventory; never normalize an ambiguous lookup.
    internal func networkResource(reference: String) async throws -> EngineNetworkResource? {
        let networks: [EngineNetworkResource] = try await request(.get, "/v1.53/networks")
        let matches = networks.filter { $0.id == reference || $0.name == reference }
        guard matches.count <= 1 else {
            throw ComposeError.invalidProject("Engine network reference is ambiguous")
        }
        guard let network = matches.first else { return nil }
        guard !network.id.isEmpty, !network.name.isEmpty else {
            throw ComposeError.invalidProject("Engine network identity is malformed")
        }
        return network
    }
}

struct EngineNetworkResource: Decodable {
    let id: String
    let name: String
    let labels: [String: String]
    let internalNetwork: Bool

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", labels = "Labels", internalNetwork = "Internal"
    }
}

private struct EngineNetworkCreateRequest: Encodable {
    let name: String
    let internalNetwork: Bool
    let enableIPv4: Bool?
    let enableIPv6: Bool?
    let options: [String: String]
    let labels: [String: String]
    let ipam: EngineIPAM?
    enum CodingKeys: String, CodingKey {
        case name = "Name", internalNetwork = "Internal", enableIPv4 = "EnableIPv4", enableIPv6 = "EnableIPv6"
        case options = "Options", labels = "Labels", ipam = "IPAM"
    }
}

private struct EngineIPAM: Encodable {
    let config: [EngineIPAMConfig]
    enum CodingKeys: String, CodingKey { case config = "Config" }
}

private struct EngineIPAMConfig: Encodable {
    let subnet: String?
    let range: String?
    let gateway: String?
    let reserved: [String]
    var isEmpty: Bool {
        subnet == nil && range == nil && gateway == nil && reserved.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case subnet = "Subnet", range = "IPRange", gateway = "Gateway", reserved = "AuxiliaryAddresses"
    }
}

private struct EngineNetworkCreateResponse: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}
