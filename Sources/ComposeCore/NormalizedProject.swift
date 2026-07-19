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
    public var environment: [String: String] = [:]
    public var profiles: [String] = []
    public var services: [String: ComposeService]
    public var networks: [String: ComposeNetwork] = [:]
    public var volumes: [String: ComposeVolume] = [:]
    public var configs: [String: ComposeValue]?
    public var secrets: [String: ComposeValue]?
    public var models: [String: ComposeValue]?
    public var extensions: [String: ComposeValue]?

    public init(name: String, services: [String: ComposeService]) {
        self.name = name
        self.services = services
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
            ?? FileManager.default.currentDirectoryPath
        composeFiles = try container.decodeIfPresent([String].self, forKey: .composeFiles) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        profiles = try container.decodeIfPresent([String].self, forKey: .profiles) ?? []
        services = try container.decode([String: ComposeService].self, forKey: .services)
        networks = try container.decodeIfPresent([String: ComposeNetwork].self, forKey: .networks) ?? [:]
        volumes = try container.decodeIfPresent([String: ComposeVolume].self, forKey: .volumes) ?? [:]
        configs = try container.decodeIfPresent([String: ComposeValue].self, forKey: .configs)
        secrets = try container.decodeIfPresent([String: ComposeValue].self, forKey: .secrets)
        models = try container.decodeIfPresent([String: ComposeValue].self, forKey: .models)
        extensions = try container.decodeIfPresent([String: ComposeValue].self, forKey: .extensions)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(composeFiles, forKey: .composeFiles)
        try container.encode(services, forKey: .services)
        try container.encode(networks, forKey: .networks)
        try container.encode(volumes, forKey: .volumes)
        try container.encodeIfPresent(configs, forKey: .configs)
        try container.encodeIfPresent(secrets, forKey: .secrets)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(extensions, forKey: .extensions)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case workingDirectory
        case composeFiles
        case environment
        case profiles
        case services
        case networks
        case volumes
        case configs
        case secrets
        case models
        case extensions
    }
}

public struct ComposeVariable: Codable, Equatable, Sendable {
    public var name: String
    public var required: Bool
    public var defaultValue: String
    public var alternateValue: String

    public init(name: String, required: Bool = false, defaultValue: String = "", alternateValue: String = "") {
        self.name = name
        self.required = required
        self.defaultValue = defaultValue
        self.alternateValue = alternateValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        alternateValue = try container.decodeIfPresent(String.self, forKey: .alternateValue) ?? ""
    }
}

public struct ComposeEnvFile: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    public var path: String
    public var required: Bool
    public var format: String?

    public init(path: String, required: Bool = true, format: String? = nil) {
        self.path = path
        self.required = required
        self.format = format?.isEmpty == false ? format : nil
    }

    public init(stringLiteral value: String) {
        self.init(path: value)
    }

    public init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let path = try? singleValue.decode(String.self) {
            self.init(path: path)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        let format = try container.decodeIfPresent(String.self, forKey: .format)
        self.init(path: path, required: required, format: format)
    }

    public func encode(to encoder: Encoder) throws {
        if required, format == nil {
            var container = encoder.singleValueContainer()
            try container.encode(path)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        if !required {
            try container.encode(required, forKey: .required)
        }
        try container.encodeIfPresent(format, forKey: .format)
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case required
        case format
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
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

/// Compose block I/O controls normalized for the apple/container `--blkio`
/// runtime flag proposed in apple/container#1595.
public struct ComposeBlkioConfig: Codable, Equatable {
    public var weight: Int?
    public var weightDevice: [ComposeBlkioWeightDevice]?
    public var deviceReadBps: [ComposeBlkioThrottleDevice]?
    public var deviceReadIOps: [ComposeBlkioThrottleDevice]?
    public var deviceWriteBps: [ComposeBlkioThrottleDevice]?
    public var deviceWriteIOps: [ComposeBlkioThrottleDevice]?

    public init(
        weight: Int? = nil,
        weightDevice: [ComposeBlkioWeightDevice]? = nil,
        deviceReadBps: [ComposeBlkioThrottleDevice]? = nil,
        deviceReadIOps: [ComposeBlkioThrottleDevice]? = nil,
        deviceWriteBps: [ComposeBlkioThrottleDevice]? = nil,
        deviceWriteIOps: [ComposeBlkioThrottleDevice]? = nil,
    ) {
        self.weight = weight
        self.weightDevice = weightDevice
        self.deviceReadBps = deviceReadBps
        self.deviceReadIOps = deviceReadIOps
        self.deviceWriteBps = deviceWriteBps
        self.deviceWriteIOps = deviceWriteIOps
    }
}

public struct ComposeBlkioWeightDevice: Codable, Equatable {
    public var path: String
    public var weight: Int

    public init(path: String, weight: Int) {
        self.path = path
        self.weight = weight
    }
}

public struct ComposeBlkioThrottleDevice: Codable, Equatable {
    public var path: String
    public var rate: String

    public init(path: String, rate: String) {
        self.path = path
        self.rate = rate
    }
}

/// Canonical service definition used by the Swift orchestrator.
public struct ComposeService: Codable, Equatable {
    public var name: String
    public var image: String?
    public var profiles: [String]?
    public var pullPolicy: String?
    public var platform: String?
    public var annotations: [String: String]?
    public var attach: Bool?
    public var blkioConfig: ComposeBlkioConfig?
    public var macAddress: String?
    public var runtime: String?
    public var cgroup: String?
    public var cgroupParent: String?
    public var cpuCount: Int?
    public var cpuPercent: Double?
    public var cpuPeriod: Int?
    public var cpuQuota: Int?
    public var cpuRealtimePeriod: Int?
    public var cpuRealtimeRuntime: Int?
    public var cpuset: String?
    public var cpuShares: Int?
    public var develop: ComposeDevelop?
    public var deploy: ComposeValue?
    public var deployGPURequests: [ComposeValue]?
    public var unsupportedDeployFields: [String]?
    public var deployMode: String?
    public var deployLabels: [String: String]?
    public var deployRestartPolicy: ComposeDeployRestartPolicy?
    public var build: ComposeBuild?
    public var command: [String]?
    public var entrypoint: [String]?
    public var provider: ComposeProvider?
    public var credentialSpec: ComposeValue?
    public var deviceCgroupRules: [String]?
    public var devices: [ComposeValue]?
    public var environment: [String: String?]?
    public var envFiles: [ComposeEnvFile]?
    public var expose: [String]?
    public var gpus: [ComposeValue]?
    public var ports: [String]?
    public var volumes: [ComposeMount]?
    public var volumeDriver: String?
    public var volumesFrom: [String]?
    public var networks: [String]?
    public var networkAliases: [String: [String]]?
    public var networkOptions: [String: ComposeNetworkOptions]?
    public var networkMode: String?
    public var dependsOn: [String: ComposeDependency]?
    public var links: [String]?
    public var externalLinks: [String]?
    public var labels: [String: String]?
    public var labelFiles: [String]?
    public var containerName: String?
    public var hostname: String?
    public var domainName: String?
    public var workingDir: String?
    public var user: String?
    public var groupAdd: [String]?
    public var tty: Bool?
    public var stdinOpen: Bool?
    public var readOnly: Bool?
    public var privileged: Bool?
    public var restart: String?
    public var initEnabled: Bool?
    public var scale: Int?
    public var logging: ComposeValue?
    public var logDriver: String?
    public var logOptions: [String: String]?
    public var storageOptions: [String: String]?
    public var useAPISocket: Bool?
    public var ipc: String?
    public var isolation: String?
    public var tmpfs: [String]?
    public var dns: [String]?
    public var dnsSearch: [String]?
    public var dnsOptions: [String]?
    public var extraHosts: [String]?
    public var capAdd: [String]?
    public var capDrop: [String]?
    public var securityOpt: [String]?
    public var memLimit: String?
    public var memReservation: String?
    public var memSwapLimit: String?
    public var memSwappiness: String?
    public var models: [String: ComposeServiceModelBinding]?
    public var oomKillDisable: Bool?
    public var oomScoreAdj: Int?
    public var pidsLimit: Int?
    public var cpus: String?
    public var shmSize: String?
    public var ulimits: [String]?
    public var pid: String?
    public var sysctls: [String: String]?
    public var stopSignal: String?
    public var stopGracePeriodSeconds: Int?
    public var preStart: [ComposeServiceHook]?
    public var postStart: [ComposeServiceHook]?
    public var preStop: [ComposeServiceHook]?
    public var usernsMode: String?
    public var uts: String?
    public var healthcheck: ComposeValue?
    public var configs: [ComposeValue]?
    public var secrets: [ComposeValue]?
    public var extensions: [String: ComposeValue]?

    public init(name: String, image: String? = nil) {
        self.name = name
        self.image = image
    }

    enum CodingKeys: String, CodingKey {
        case name
        case image
        case profiles
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
        case deploy
        case deployGPURequests
        case unsupportedDeployFields
        case deployMode
        case deployLabels
        case deployRestartPolicy
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
        case preStart
        case postStart
        case preStop
        case usernsMode = "userns_mode"
        case uts
        case healthcheck
        case configs
        case secrets
        case extensions
    }
}

/// Compose Deploy Specification restart policy values used by local service
/// orchestration when apple/container exposes matching restart primitives.
public struct ComposeDeployRestartPolicy: Codable, Equatable {
    public var condition: String?
    public var delayNanoseconds: Int64?
    public var maxAttempts: UInt64?
    public var windowNanoseconds: Int64?

    public init(
        condition: String? = nil,
        delayNanoseconds: Int64? = nil,
        maxAttempts: UInt64? = nil,
        windowNanoseconds: Int64? = nil,
    ) {
        self.condition = condition
        self.delayNanoseconds = delayNanoseconds
        self.maxAttempts = maxAttempts
        self.windowNanoseconds = windowNanoseconds
    }
}

/// Compose Develop Specification data used by `compose watch`.
public struct ComposeDevelop: Codable, Equatable {
    public var watch: [ComposeDevelopWatch]?

    public init(watch: [ComposeDevelopWatch]? = nil) {
        self.watch = watch
    }
}

/// One Compose `develop.watch` trigger.
public struct ComposeDevelopWatch: Codable, Equatable {
    public var path: String
    public var action: String
    public var target: String?
    public var ignore: [String]?
    public var include: [String]?
    public var initialSync: Bool?
    public var exec: ComposeDevelopWatchExec?

    public init(
        path: String,
        action: String,
        target: String? = nil,
        ignore: [String]? = nil,
        include: [String]? = nil,
        initialSync: Bool? = nil,
        exec: ComposeDevelopWatchExec? = nil,
    ) {
        self.path = path
        self.action = action
        self.target = target
        self.ignore = ignore
        self.include = include
        self.initialSync = initialSync
        self.exec = exec
    }
}

/// Optional command metadata for `develop.watch` `sync+exec` triggers.
public struct ComposeDevelopWatchExec: Codable, Equatable {
    public var command: [String]?
    public var user: String?
    public var privileged: Bool?
    public var workingDir: String?
    public var environment: [String: String?]?

    public init(
        command: [String]? = nil,
        user: String? = nil,
        privileged: Bool? = nil,
        workingDir: String? = nil,
        environment: [String: String?]? = nil,
    ) {
        self.command = command
        self.user = user
        self.privileged = privileged
        self.workingDir = workingDir
        self.environment = environment
    }
}

/// Provider-service metadata used to delegate non-container lifecycle work.
public struct ComposeProvider: Codable, Equatable, Sendable {
    public var type: String
    public var options: [String: [String]]?

    public init(type: String, options: [String: [String]]? = nil) {
        self.type = type
        self.options = options
    }
}

/// Service binding metadata for one top-level Compose model.
public struct ComposeServiceModelBinding: Codable, Equatable, Sendable {
    public var endpointVariable: String?
    public var modelVariable: String?

    public init(endpointVariable: String? = nil, modelVariable: String? = nil) {
        self.endpointVariable = endpointVariable
        self.modelVariable = modelVariable
    }
}

/// One Compose service lifecycle hook.
public struct ComposeServiceHook: Codable, Equatable, Sendable {
    public var command: [String]?
    public var image: String?
    public var user: String?
    public var privileged: Bool?
    public var workingDir: String?
    public var environment: [String: String?]?
    public var perReplica: Bool?

    public init(
        command: [String]? = nil,
        image: String? = nil,
        user: String? = nil,
        privileged: Bool? = nil,
        workingDir: String? = nil,
        environment: [String: String?]? = nil,
        perReplica: Bool? = nil,
    ) {
        self.command = command
        self.image = image
        self.user = user
        self.privileged = privileged
        self.workingDir = workingDir
        self.environment = environment
        self.perReplica = perReplica
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
            macAddress: String? = nil,
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
        priority: Int? = nil,
    ) {
        self.driverOpts = driverOpts
        self.gatewayPriority = gatewayPriority
        self.interfaceName = interfaceName
        ipv4Address = addressing.ipv4Address
        ipv6Address = addressing.ipv6Address
        linkLocalIPs = addressing.linkLocalIPs
        macAddress = addressing.macAddress
        self.priority = priority
    }
}

/// Network definition normalized from the Compose project.
public struct ComposeNetwork: Codable, Equatable {
    /// IPAM addressing supported by apple/container network creation.
    public struct Subnets: Equatable {
        public var ipv4Subnet: String?
        public var ipv4Gateway: String?
        public var ipv4AllocationRange: String?
        public var ipv4ReservedAddresses: [String]?
        public var ipv6Subnet: String?

        public init(
            ipv4Subnet: String? = nil,
            ipv4Gateway: String? = nil,
            ipv4AllocationRange: String? = nil,
            ipv4ReservedAddresses: [String]? = nil,
            ipv6Subnet: String? = nil,
        ) {
            self.ipv4Subnet = ipv4Subnet
            self.ipv4Gateway = ipv4Gateway
            self.ipv4AllocationRange = ipv4AllocationRange
            self.ipv4ReservedAddresses = ipv4ReservedAddresses
            self.ipv6Subnet = ipv6Subnet
        }
    }

    /// Optional network attributes grouped to keep construction call sites readable.
    public struct Options: Equatable {
        public var external: Bool?
        public var driver: String?
        public var driverOpts: [String: String]?
        public var isInternal: Bool?
        public var labels: [String: String]?
        public var subnets: Subnets
        public var unsupportedFields: [String]?

        public init(
            external: Bool? = nil,
            driver: String? = nil,
            driverOpts: [String: String]? = nil,
            isInternal: Bool? = nil,
            labels: [String: String]? = nil,
            subnets: Subnets = Subnets(),
            unsupportedFields: [String]? = nil,
        ) {
            self.external = external
            self.driver = driver
            self.driverOpts = driverOpts
            self.isInternal = isInternal
            self.labels = labels
            self.subnets = subnets
            self.unsupportedFields = unsupportedFields
        }
    }

    public var name: String
    public var external: Bool?
    public var driver: String?
    public var driverOpts: [String: String]?
    public var isInternal: Bool?
    public var labels: [String: String]?
    public var ipv4Subnet: String?
    public var ipv4Gateway: String?
    public var ipv4AllocationRange: String?
    public var ipv4ReservedAddresses: [String]?
    public var ipv6Subnet: String?
    public var unsupportedFields: [String]?

    public init(
        name: String,
        options: Options = Options(),
    ) {
        self.name = name
        external = options.external
        driver = options.driver
        driverOpts = options.driverOpts
        isInternal = options.isInternal
        labels = options.labels
        ipv4Subnet = options.subnets.ipv4Subnet
        ipv4Gateway = options.subnets.ipv4Gateway
        ipv4AllocationRange = options.subnets.ipv4AllocationRange
        ipv4ReservedAddresses = options.subnets.ipv4ReservedAddresses
        ipv6Subnet = options.subnets.ipv6Subnet
        unsupportedFields = options.unsupportedFields
    }

    enum CodingKeys: String, CodingKey {
        case name
        case external
        case driver
        case driverOpts
        case isInternal = "internal"
        case labels
        case ipv4Subnet
        case ipv4Gateway
        case ipv4AllocationRange
        case ipv4ReservedAddresses
        case ipv6Subnet
        case unsupportedFields
    }
}

/// Volume definition normalized from the Compose project.
public struct ComposeVolume: Codable, Equatable {
    public var name: String
    public var external: Bool?
    public var driver: String?
    public var driverOpts: [String: String]?
    public var labels: [String: String]?

    public init(
        name: String,
        external: Bool? = nil,
        driver: String? = nil,
        driverOpts: [String: String]? = nil,
        labels: [String: String]? = nil,
    ) {
        self.name = name
        self.external = external
        self.driver = driver
        self.driverOpts = driverOpts
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
