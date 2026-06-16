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

/// Canonical Compose project data emitted by the Go normalizer.
public struct ComposeProject: Codable, Equatable {
    public var name: String
    public var workingDirectory: String = FileManager.default.currentDirectoryPath
    public var composeFiles: [String] = []
    public var services: [String: ComposeService]
    public var networks: [String: ComposeNetwork] = [:]
    public var volumes: [String: ComposeVolume] = [:]
    public var configs: [String: ComposeValue]? = nil
    public var secrets: [String: ComposeValue]? = nil
    public var extensions: [String: ComposeValue]? = nil

    public init(name: String, services: [String: ComposeService]) {
        self.name = name
        self.services = services
    }
}

/// JSON value used to preserve Compose fields that Swift does not orchestrate
/// yet but must round-trip through `config`.
public enum ComposeValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([ComposeValue])
    case object([String: ComposeValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ComposeValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ComposeValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// Canonical service definition used by the Swift orchestrator.
public struct ComposeService: Codable, Equatable {
    public var name: String
    public var image: String? = nil
    public var pullPolicy: String? = nil
    public var platform: String? = nil
    public var macAddress: String? = nil
    public var build: ComposeBuild? = nil
    public var command: [String]? = nil
    public var entrypoint: [String]? = nil
    public var environment: [String: String?]? = nil
    public var envFiles: [String]? = nil
    public var ports: [String]? = nil
    public var volumes: [ComposeMount]? = nil
    public var networks: [String]? = nil
    public var networkAliases: [String: [String]]? = nil
    public var networkOptions: [String: ComposeNetworkOptions]? = nil
    public var networkMode: String? = nil
    public var dependsOn: [String: String]? = nil
    public var labels: [String: String]? = nil
    public var containerName: String? = nil
    public var hostname: String? = nil
    public var workingDir: String? = nil
    public var user: String? = nil
    public var tty: Bool? = nil
    public var stdinOpen: Bool? = nil
    public var readOnly: Bool? = nil
    public var privileged: Bool? = nil
    public var restart: String? = nil
    public var initEnabled: Bool? = nil
    public var tmpfs: [String]? = nil
    public var dns: [String]? = nil
    public var dnsSearch: [String]? = nil
    public var extraHosts: [String]? = nil
    public var capAdd: [String]? = nil
    public var capDrop: [String]? = nil
    public var memLimit: String? = nil
    public var cpus: String? = nil
    public var healthcheck: ComposeValue? = nil
    public var configs: [ComposeValue]? = nil
    public var secrets: [ComposeValue]? = nil
    public var extensions: [String: ComposeValue]? = nil

    public init(name: String, image: String? = nil) {
        self.name = name
        self.image = image
    }

    enum CodingKeys: String, CodingKey {
        case name
        case image
        case pullPolicy
        case platform
        case macAddress
        case build
        case command
        case entrypoint
        case environment
        case envFiles
        case ports
        case volumes
        case networks
        case networkAliases
        case networkOptions
        case networkMode
        case dependsOn
        case labels
        case containerName
        case hostname
        case workingDir
        case user
        case tty
        case stdinOpen
        case readOnly
        case privileged
        case restart
        case initEnabled = "init"
        case tmpfs
        case dns
        case dnsSearch
        case extraHosts
        case capAdd
        case capDrop
        case memLimit
        case cpus
        case healthcheck
        case configs
        case secrets
        case extensions
    }
}

/// Per-service network attachment options normalized from Compose.
public struct ComposeNetworkOptions: Codable, Equatable {
    public var driverOpts: [String: String]?
    public var gatewayPriority: Int?
    public var interfaceName: String?
    public var ipv4Address: String?
    public var ipv6Address: String?
    public var linkLocalIPs: [String]?
    public var macAddress: String?
    public var priority: Int?

    public init(
        driverOpts: [String: String]? = nil,
        gatewayPriority: Int? = nil,
        interfaceName: String? = nil,
        ipv4Address: String? = nil,
        ipv6Address: String? = nil,
        linkLocalIPs: [String]? = nil,
        macAddress: String? = nil,
        priority: Int? = nil
    ) {
        self.driverOpts = driverOpts
        self.gatewayPriority = gatewayPriority
        self.interfaceName = interfaceName
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.linkLocalIPs = linkLocalIPs
        self.macAddress = macAddress
        self.priority = priority
    }
}

/// Build configuration for a Compose service.
public struct ComposeBuild: Codable, Equatable {
    public var context: String?
    public var dockerfile: String?
    public var args: [String: String]?
    public var target: String?

    public init(context: String? = nil, dockerfile: String? = nil, args: [String: String]? = nil, target: String? = nil) {
        self.context = context
        self.dockerfile = dockerfile
        self.args = args
        self.target = target
    }
}

/// Mount definition normalized from Compose volume and bind syntax.
public struct ComposeMount: Codable, Equatable {
    public var type: String?
    public var source: String?
    public var target: String?
    public var readOnly: Bool?
    public var raw: String?

    public init(type: String? = nil, source: String? = nil, target: String? = nil, readOnly: Bool? = nil, raw: String? = nil) {
        self.type = type
        self.source = source
        self.target = target
        self.readOnly = readOnly
        self.raw = raw
    }
}

/// Network definition normalized from the Compose project.
public struct ComposeNetwork: Codable, Equatable {
    public var name: String
    public var external: Bool?
    public var driver: String?
    public var labels: [String: String]?

    public init(name: String, external: Bool? = nil, driver: String? = nil, labels: [String: String]? = nil) {
        self.name = name
        self.external = external
        self.driver = driver
        self.labels = labels
    }
}

/// Volume definition normalized from the Compose project.
public struct ComposeVolume: Codable, Equatable {
    public var name: String
    public var external: Bool?
    public var driver: String?
    public var labels: [String: String]?

    public init(name: String, external: Bool? = nil, driver: String? = nil, labels: [String: String]? = nil) {
        self.name = name
        self.external = external
        self.driver = driver
        self.labels = labels
    }
}

public extension ComposeService {
    /// Image used directly by runtime commands when the service does not need
    /// to be built first.
    var effectiveImage: String? {
        if let image, !image.isEmpty {
            return image
        }
        if build != nil {
            return nil
        }
        return nil
    }
}
