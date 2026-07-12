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
    public var configs: [String: ComposeValue]? = nil
    public var secrets: [String: ComposeValue]? = nil
    public var models: [String: ComposeValue]? = nil
    public var extensions: [String: ComposeValue]? = nil

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

/// Compose block I/O controls normalized for the apple/container `--blkio`
/// runtime flag proposed in apple/container#1595.
public struct ComposeBlkioConfig: Codable, Equatable {
    public var weight: Int? = nil
    public var weightDevice: [ComposeBlkioWeightDevice]? = nil
    public var deviceReadBps: [ComposeBlkioThrottleDevice]? = nil
    public var deviceReadIOps: [ComposeBlkioThrottleDevice]? = nil
    public var deviceWriteBps: [ComposeBlkioThrottleDevice]? = nil
    public var deviceWriteIOps: [ComposeBlkioThrottleDevice]? = nil

    public init(
        weight: Int? = nil,
        weightDevice: [ComposeBlkioWeightDevice]? = nil,
        deviceReadBps: [ComposeBlkioThrottleDevice]? = nil,
        deviceReadIOps: [ComposeBlkioThrottleDevice]? = nil,
        deviceWriteBps: [ComposeBlkioThrottleDevice]? = nil,
        deviceWriteIOps: [ComposeBlkioThrottleDevice]? = nil
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
    public var image: String? = nil
    public var profiles: [String]? = nil
    public var pullPolicy: String? = nil
    public var platform: String? = nil
    public var annotations: [String: String]? = nil
    public var attach: Bool? = nil
    public var blkioConfig: ComposeBlkioConfig? = nil
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
    public var develop: ComposeDevelop? = nil
    public var deploy: ComposeValue? = nil
    public var unsupportedDeployFields: [String]? = nil
    public var deployMode: String? = nil
    public var deployLabels: [String: String]? = nil
    public var deployUpdateDelayNanoseconds: Int64? = nil
    public var deployRestartPolicy: ComposeDeployRestartPolicy? = nil
    public var build: ComposeBuild? = nil
    public var command: [String]? = nil
    public var entrypoint: [String]? = nil
    public var provider: ComposeProvider? = nil
    public var credentialSpec: ComposeValue? = nil
    public var deviceCgroupRules: [String]? = nil
    public var devices: [ComposeValue]? = nil
    public var environment: [String: String?]? = nil
    public var envFiles: [ComposeEnvFile]? = nil
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
    public var models: [String: ComposeServiceModelBinding]? = nil
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
    public var postStart: [ComposeServiceHook]? = nil
    public var preStop: [ComposeServiceHook]? = nil
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
        case unsupportedDeployFields
        case deployMode
        case deployLabels
        case deployUpdateDelayNanoseconds
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

/// Compose Deploy Specification restart policy values used by local service
/// orchestration when apple/container exposes matching restart primitives.
public struct ComposeDeployRestartPolicy: Codable, Equatable {
    public var condition: String? = nil
    public var delayNanoseconds: Int64? = nil
    public var maxAttempts: UInt64? = nil
    public var windowNanoseconds: Int64? = nil

    public init(
        condition: String? = nil,
        delayNanoseconds: Int64? = nil,
        maxAttempts: UInt64? = nil,
        windowNanoseconds: Int64? = nil
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
        exec: ComposeDevelopWatchExec? = nil
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
        environment: [String: String?]? = nil
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
public struct ComposeServiceHook: Codable, Equatable {
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
        environment: [String: String?]? = nil
    ) {
        self.command = command
        self.user = user
        self.privileged = privileged
        self.workingDir = workingDir
        self.environment = environment
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
    /// Build cache sources and destinations.
    public struct Cache: Equatable {
        public var from: [String]?
        public var to: [String]?

        public init(from: [String]? = nil, to: [String]? = nil) {
            self.from = from
            self.to = to
        }
    }

    /// Build labels and secrets that become build-time metadata.
    public struct Metadata: Equatable {
        public var labels: [String: String]?
        public var secrets: [ComposeBuildSecret]?
        public var ssh: [String]?

        public init(labels: [String: String]? = nil, secrets: [ComposeBuildSecret]? = nil, ssh: [String]? = nil) {
            self.labels = labels
            self.secrets = secrets
            self.ssh = ssh
        }
    }

    /// Optional build behavior that is not required for every service.
    public struct Options: Equatable {
        public struct Image: Equatable {
            public var target: String?
            public var noCache: Bool?
            public var pull: Bool?
            public var platforms: [String]?
            public var tags: [String]?

            public init(
                target: String? = nil,
                noCache: Bool? = nil,
                pull: Bool? = nil,
                platforms: [String]? = nil,
                tags: [String]? = nil
            ) {
                self.target = target
                self.noCache = noCache
                self.pull = pull
                self.platforms = platforms
                self.tags = tags
            }
        }

        public struct Frontend: Equatable {
            public var entitlements: [String]?
            public var extraHosts: [String]?
            public var isolation: String?
            public var network: String?
            public var privileged: Bool?
            public var shmSize: String?
            public var ulimits: [String]?

            public init(
                entitlements: [String]? = nil,
                extraHosts: [String]? = nil,
                isolation: String? = nil,
                network: String? = nil,
                privileged: Bool? = nil,
                shmSize: String? = nil,
                ulimits: [String]? = nil
            ) {
                self.entitlements = entitlements
                self.extraHosts = extraHosts
                self.isolation = isolation
                self.network = network
                self.privileged = privileged
                self.shmSize = shmSize
                self.ulimits = ulimits
            }
        }

        public struct Attestations: Equatable {
            public var provenance: String?
            public var sbom: String?

            public init(provenance: String? = nil, sbom: String? = nil) {
                self.provenance = provenance
                self.sbom = sbom
            }
        }

        public var target: String?
        public var noCache: Bool?
        public var pull: Bool?
        public var platforms: [String]?
        public var tags: [String]?
        public var entitlements: [String]?
        public var extraHosts: [String]?
        public var isolation: String?
        public var network: String?
        public var privileged: Bool?
        public var shmSize: String?
        public var ulimits: [String]?
        public var provenance: String?
        public var sbom: String?
        public var unsupportedFields: [String]?

        public init(
            image: Image = Image(),
            frontend: Frontend = Frontend(),
            attestations: Attestations = Attestations(),
            unsupportedFields: [String]? = nil
        ) {
            self.target = image.target
            self.noCache = image.noCache
            self.pull = image.pull
            self.platforms = image.platforms
            self.tags = image.tags
            self.entitlements = frontend.entitlements
            self.extraHosts = frontend.extraHosts
            self.isolation = frontend.isolation
            self.network = frontend.network
            self.privileged = frontend.privileged
            self.shmSize = frontend.shmSize
            self.ulimits = frontend.ulimits
            self.provenance = attestations.provenance
            self.sbom = attestations.sbom
            self.unsupportedFields = unsupportedFields
        }
    }

    /// Build context inputs used to locate Dockerfile and named BuildKit contexts.
    public struct Contexts: Equatable {
        public var context: String?
        public var dockerfile: String?
        public var dockerfileInline: String?
        public var additionalContexts: [String: String]?

        public init(
            context: String? = nil,
            dockerfile: String? = nil,
            dockerfileInline: String? = nil,
            additionalContexts: [String: String]? = nil
        ) {
            self.context = context
            self.dockerfile = dockerfile
            self.dockerfileInline = dockerfileInline
            self.additionalContexts = additionalContexts
        }
    }

    public var context: String?
    public var dockerfile: String?
    public var dockerfileInline: String?
    public var additionalContexts: [String: String]?
    public var args: [String: String]?
    public var cacheFrom: [String]?
    public var cacheTo: [String]?
    public var entitlements: [String]?
    public var extraHosts: [String]?
    public var isolation: String?
    public var labels: [String: String]?
    public var network: String?
    public var privileged: Bool?
    public var secrets: [ComposeBuildSecret]?
    public var shmSize: String?
    public var ssh: [String]?
    public var target: String?
    public var noCache: Bool?
    public var pull: Bool?
    public var platforms: [String]?
    public var tags: [String]?
    public var ulimits: [String]?
    public var provenance: String?
    public var sbom: String?
    public var unsupportedFields: [String]?

    public init(
        context: String? = nil,
        dockerfile: String? = nil,
        dockerfileInline: String? = nil,
        args: [String: String]? = nil,
        cache: Cache = Cache(),
        metadata: Metadata = Metadata(),
        options: Options = Options()
    ) {
        self.init(
            contexts: Contexts(
                context: context,
                dockerfile: dockerfile,
                dockerfileInline: dockerfileInline),
            args: args,
            cache: cache,
            metadata: metadata,
            options: options
        )
    }

    public init(
        contexts: Contexts,
        args: [String: String]? = nil,
        cache: Cache = Cache(),
        metadata: Metadata = Metadata(),
        options: Options = Options()
    ) {
        self.context = contexts.context
        self.dockerfile = contexts.dockerfile
        self.dockerfileInline = contexts.dockerfileInline
        self.additionalContexts = contexts.additionalContexts
        self.args = args
        self.cacheFrom = cache.from
        self.cacheTo = cache.to
        self.entitlements = options.entitlements
        self.extraHosts = options.extraHosts
        self.isolation = options.isolation
        self.labels = metadata.labels
        self.network = options.network
        self.privileged = options.privileged
        self.secrets = metadata.secrets
        self.shmSize = options.shmSize
        self.ssh = metadata.ssh
        self.target = options.target
        self.noCache = options.noCache
        self.pull = options.pull
        self.platforms = options.platforms
        self.tags = options.tags
        self.ulimits = options.ulimits
        self.provenance = options.provenance
        self.sbom = options.sbom
        self.unsupportedFields = options.unsupportedFields
    }
}

/// Build-time secret supported by apple/container `container build --secret`.
public struct ComposeBuildSecret: Codable, Equatable {
    public var id: String
    public var file: String?
    public var environment: String?

    public init(id: String, file: String? = nil, environment: String? = nil) {
        self.id = id
        self.file = file
        self.environment = environment
    }
}

/// Mount definition normalized from Compose volume and bind syntax.
public struct ComposeMount: Codable, Equatable, Sendable {
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
        public var volumeLabels: [String: String]?
        public var tmpfs: TmpfsOptions

        public init(
            readOnly: Bool? = nil,
            bindCreateHostPath: Bool? = nil,
            bindPropagation: String? = nil,
            volumeLabels: [String: String]? = nil,
            tmpfs: TmpfsOptions = TmpfsOptions()
        ) {
            self.readOnly = readOnly
            self.bindCreateHostPath = bindCreateHostPath
            self.bindPropagation = bindPropagation
            self.volumeLabels = volumeLabels
            self.tmpfs = tmpfs
        }
    }

    public var type: String?
    public var source: String?
    public var target: String?
    public var readOnly: Bool?
    public var bindCreateHostPath: Bool?
    public var bindPropagation: String?
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
        unsupportedFields: [String]? = nil
    ) {
        self.type = type
        self.source = source
        self.target = target
        self.readOnly = options.readOnly
        self.bindCreateHostPath = options.bindCreateHostPath
        self.bindPropagation = options.bindPropagation
        self.volumeLabels = options.volumeLabels
        self.tmpfsSize = options.tmpfs.size
        self.tmpfsMode = options.tmpfs.mode
        self.raw = raw
        self.unsupportedFields = unsupportedFields
    }

    public init(
        type: String? = nil,
        source: String? = nil,
        target: String? = nil,
        readOnly: Bool? = nil,
        bindCreateHostPath: Bool? = nil,
        bindPropagation: String? = nil,
        raw: String? = nil
    ) {
        self.init(
            type: type,
            source: source,
            target: target,
            options: MountOptions(readOnly: readOnly, bindCreateHostPath: bindCreateHostPath, bindPropagation: bindPropagation),
            raw: raw
        )
    }
}

/// Network definition normalized from the Compose project.
public struct ComposeNetwork: Codable, Equatable {
    /// IPAM subnets supported by apple/container network creation.
    public struct Subnets: Equatable {
        public var ipv4Subnet: String?
        public var ipv6Subnet: String?

        public init(ipv4Subnet: String? = nil, ipv6Subnet: String? = nil) {
            self.ipv4Subnet = ipv4Subnet
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
            unsupportedFields: [String]? = nil
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
    public var ipv6Subnet: String?
    public var unsupportedFields: [String]?

    public init(
        name: String,
        options: Options = Options()
    ) {
        self.name = name
        self.external = options.external
        self.driver = options.driver
        self.driverOpts = options.driverOpts
        self.isInternal = options.isInternal
        self.labels = options.labels
        self.ipv4Subnet = options.subnets.ipv4Subnet
        self.ipv6Subnet = options.subnets.ipv6Subnet
        self.unsupportedFields = options.unsupportedFields
    }

    enum CodingKeys: String, CodingKey {
        case name
        case external
        case driver
        case driverOpts
        case isInternal = "internal"
        case labels
        case ipv4Subnet
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
        labels: [String: String]? = nil
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
