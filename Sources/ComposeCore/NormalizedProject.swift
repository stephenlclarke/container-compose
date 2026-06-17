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
    public var models: [String: ComposeValue]? = nil
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

    /// Encodes the preserved JSON value without changing its original shape.
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
    public var annotations: [String: String]? = nil
    public var attach: Bool? = nil
    public var blkioConfig: Bool? = nil
    public var macAddress: String? = nil
    public var runtime: String? = nil
    public var cgroup: String? = nil
    public var cgroupParent: String? = nil
    public var cpuCount: Int? = nil
    public var cpuPercent: Double? = nil
    public var cpuPeriod: Int? = nil
    public var cpuQuota: Int? = nil
    public var cpuRealtimePeriod: Int? = nil
    public var cpuRealtimeRuntime: Int? = nil
    public var cpuset: String? = nil
    public var cpuShares: Int? = nil
    public var develop: Bool? = nil
    public var unsupportedDeployFields: [String]? = nil
    public var build: ComposeBuild? = nil
    public var command: [String]? = nil
    public var entrypoint: [String]? = nil
    public var provider: Bool? = nil
    public var credentialSpec: ComposeValue? = nil
    public var deviceCgroupRules: [String]? = nil
    public var devices: [ComposeValue]? = nil
    public var environment: [String: String?]? = nil
    public var envFiles: [String]? = nil
    public var expose: [String]? = nil
    public var gpus: [ComposeValue]? = nil
    public var ports: [String]? = nil
    public var volumes: [ComposeMount]? = nil
    public var volumeDriver: String? = nil
    public var volumesFrom: [String]? = nil
    public var networks: [String]? = nil
    public var networkAliases: [String: [String]]? = nil
    public var networkOptions: [String: ComposeNetworkOptions]? = nil
    public var networkMode: String? = nil
    public var dependsOn: [String: ComposeDependency]? = nil
    public var links: [String]? = nil
    public var externalLinks: [String]? = nil
    public var labels: [String: String]? = nil
    public var labelFiles: [String]? = nil
    public var containerName: String? = nil
    public var hostname: String? = nil
    public var domainName: String? = nil
    public var workingDir: String? = nil
    public var user: String? = nil
    public var groupAdd: [String]? = nil
    public var tty: Bool? = nil
    public var stdinOpen: Bool? = nil
    public var readOnly: Bool? = nil
    public var privileged: Bool? = nil
    public var restart: String? = nil
    public var initEnabled: Bool? = nil
    public var scale: Int? = nil
    public var logging: ComposeValue? = nil
    public var logDriver: String? = nil
    public var logOptions: [String: String]? = nil
    public var storageOptions: [String: String]? = nil
    public var useAPISocket: Bool? = nil
    public var ipc: String? = nil
    public var isolation: String? = nil
    public var tmpfs: [String]? = nil
    public var dns: [String]? = nil
    public var dnsSearch: [String]? = nil
    public var dnsOptions: [String]? = nil
    public var extraHosts: [String]? = nil
    public var capAdd: [String]? = nil
    public var capDrop: [String]? = nil
    public var securityOpt: [String]? = nil
    public var memLimit: String? = nil
    public var memReservation: String? = nil
    public var memSwapLimit: String? = nil
    public var memSwappiness: String? = nil
    public var models: Bool? = nil
    public var oomKillDisable: Bool? = nil
    public var oomScoreAdj: Int? = nil
    public var pidsLimit: Int? = nil
    public var cpus: String? = nil
    public var shmSize: String? = nil
    public var ulimits: [String]? = nil
    public var pid: String? = nil
    public var sysctls: [String: String]? = nil
    public var stopSignal: String? = nil
    public var stopGracePeriodSeconds: Int? = nil
    public var postStart: Bool? = nil
    public var preStop: Bool? = nil
    public var usernsMode: String? = nil
    public var uts: String? = nil
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
        case annotations
        case attach
        case blkioConfig
        case macAddress
        case runtime
        case cgroup
        case cgroupParent
        case cpuCount
        case cpuPercent
        case cpuPeriod
        case cpuQuota
        case cpuRealtimePeriod
        case cpuRealtimeRuntime
        case cpuset
        case cpuShares
        case develop
        case unsupportedDeployFields
        case build
        case command
        case entrypoint
        case provider
        case credentialSpec
        case deviceCgroupRules
        case devices
        case environment
        case envFiles
        case expose
        case gpus
        case ports
        case volumes
        case volumeDriver
        case volumesFrom
        case networks
        case networkAliases
        case networkOptions
        case networkMode
        case dependsOn
        case links
        case externalLinks
        case labels
        case labelFiles
        case containerName
        case hostname
        case domainName
        case workingDir
        case user
        case groupAdd
        case tty
        case stdinOpen
        case readOnly
        case privileged
        case restart
        case initEnabled = "init"
        case scale
        case logging
        case logDriver
        case logOptions
        case storageOptions
        case useAPISocket
        case ipc
        case isolation
        case tmpfs
        case dns
        case dnsSearch
        case dnsOptions
        case extraHosts
        case capAdd
        case capDrop
        case securityOpt
        case memLimit
        case memReservation
        case memSwapLimit
        case memSwappiness
        case models
        case oomKillDisable
        case oomScoreAdj
        case pidsLimit
        case cpus
        case shmSize
        case ulimits
        case pid
        case sysctls
        case stopSignal
        case stopGracePeriodSeconds
        case postStart
        case preStop
        case usernsMode
        case uts
        case healthcheck
        case configs
        case secrets
        case extensions
    }
}

/// Dependency metadata normalized from Compose `depends_on` entries.
public struct ComposeDependency: Codable, Equatable {
    public var condition: String
    public var restart: Bool
    public var required: Bool?

    public init(condition: String = "", restart: Bool = false, required: Bool? = nil) {
        self.condition = condition
        self.restart = restart
        self.required = required
    }

    public init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let condition = try? singleValue.decode(String.self) {
            self.init(condition: condition)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let condition = try container.decodeIfPresent(String.self, forKey: .condition) ?? ""
        let restart = try container.decodeIfPresent(Bool.self, forKey: .restart) ?? false
        let required = try container.decodeIfPresent(Bool.self, forKey: .required)
        self.init(condition: condition, restart: restart, required: required)
    }

    /// Encodes only non-default dependency metadata to keep `config` output compact.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !condition.isEmpty {
            try container.encode(condition, forKey: .condition)
        }
        if restart {
            try container.encode(restart, forKey: .restart)
        }
        try container.encodeIfPresent(required, forKey: .required)
    }

    enum CodingKeys: String, CodingKey {
        case condition
        case restart
        case required
    }
}

/// Per-service network attachment options normalized from Compose.
public struct ComposeNetworkOptions: Codable, Equatable {
    /// Address-like attachment options grouped to keep construction readable.
    public struct Addressing: Equatable {
        public var ipv4Address: String?
        public var ipv6Address: String?
        public var linkLocalIPs: [String]?
        public var macAddress: String?

        public init(
            ipv4Address: String? = nil,
            ipv6Address: String? = nil,
            linkLocalIPs: [String]? = nil,
            macAddress: String? = nil
        ) {
            self.ipv4Address = ipv4Address
            self.ipv6Address = ipv6Address
            self.linkLocalIPs = linkLocalIPs
            self.macAddress = macAddress
        }
    }

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
        addressing: Addressing = Addressing(),
        priority: Int? = nil
    ) {
        self.driverOpts = driverOpts
        self.gatewayPriority = gatewayPriority
        self.interfaceName = interfaceName
        self.ipv4Address = addressing.ipv4Address
        self.ipv6Address = addressing.ipv6Address
        self.linkLocalIPs = addressing.linkLocalIPs
        self.macAddress = addressing.macAddress
        self.priority = priority
    }
}

/// Build configuration for a Compose service.
public struct ComposeBuild: Codable, Equatable {
    public var context: String?
    public var dockerfile: String?
    public var args: [String: String]?
    public var labels: [String: String]?
    public var target: String?
    public var noCache: Bool?
    public var pull: Bool?
    public var tags: [String]?
    public var unsupportedFields: [String]?

    public init(
        context: String? = nil,
        dockerfile: String? = nil,
        args: [String: String]? = nil,
        labels: [String: String]? = nil,
        target: String? = nil,
        noCache: Bool? = nil,
        pull: Bool? = nil,
        tags: [String]? = nil,
        unsupportedFields: [String]? = nil
    ) {
        self.context = context
        self.dockerfile = dockerfile
        self.args = args
        self.labels = labels
        self.target = target
        self.noCache = noCache
        self.pull = pull
        self.tags = tags
        self.unsupportedFields = unsupportedFields
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
