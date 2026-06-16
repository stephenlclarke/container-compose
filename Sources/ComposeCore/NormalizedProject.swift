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
    public var workingDirectory: String
    public var composeFiles: [String]
    public var services: [String: ComposeService]
    public var networks: [String: ComposeNetwork]
    public var volumes: [String: ComposeVolume]
    public var configs: [String: ComposeValue]?
    public var secrets: [String: ComposeValue]?
    public var extensions: [String: ComposeValue]?

    public init(
        name: String,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        composeFiles: [String] = [],
        services: [String: ComposeService],
        networks: [String: ComposeNetwork] = [:],
        volumes: [String: ComposeVolume] = [:],
        configs: [String: ComposeValue]? = nil,
        secrets: [String: ComposeValue]? = nil,
        extensions: [String: ComposeValue]? = nil
    ) {
        self.name = name
        self.workingDirectory = workingDirectory
        self.composeFiles = composeFiles
        self.services = services
        self.networks = networks
        self.volumes = volumes
        self.configs = configs
        self.secrets = secrets
        self.extensions = extensions
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
    public var image: String?
    public var build: ComposeBuild?
    public var command: [String]?
    public var entrypoint: [String]?
    public var environment: [String: String?]?
    public var envFiles: [String]?
    public var ports: [String]?
    public var volumes: [ComposeMount]?
    public var networks: [String]?
    public var dependsOn: [String: String]?
    public var labels: [String: String]?
    public var containerName: String?
    public var hostname: String?
    public var workingDir: String?
    public var user: String?
    public var tty: Bool?
    public var stdinOpen: Bool?
    public var readOnly: Bool?
    public var privileged: Bool?
    public var `init`: Bool?
    public var tmpfs: [String]?
    public var dns: [String]?
    public var dnsSearch: [String]?
    public var extraHosts: [String]?
    public var capAdd: [String]?
    public var capDrop: [String]?
    public var memLimit: String?
    public var cpus: String?
    public var healthcheck: ComposeValue?
    public var configs: [ComposeValue]?
    public var secrets: [ComposeValue]?
    public var extensions: [String: ComposeValue]?

    public init(
        name: String,
        image: String? = nil,
        build: ComposeBuild? = nil,
        command: [String]? = nil,
        entrypoint: [String]? = nil,
        environment: [String: String?]? = nil,
        envFiles: [String]? = nil,
        ports: [String]? = nil,
        volumes: [ComposeMount]? = nil,
        networks: [String]? = nil,
        dependsOn: [String: String]? = nil,
        labels: [String: String]? = nil,
        containerName: String? = nil,
        hostname: String? = nil,
        workingDir: String? = nil,
        user: String? = nil,
        tty: Bool? = nil,
        stdinOpen: Bool? = nil,
        readOnly: Bool? = nil,
        privileged: Bool? = nil,
        init: Bool? = nil,
        tmpfs: [String]? = nil,
        dns: [String]? = nil,
        dnsSearch: [String]? = nil,
        extraHosts: [String]? = nil,
        capAdd: [String]? = nil,
        capDrop: [String]? = nil,
        memLimit: String? = nil,
        cpus: String? = nil,
        healthcheck: ComposeValue? = nil,
        configs: [ComposeValue]? = nil,
        secrets: [ComposeValue]? = nil,
        extensions: [String: ComposeValue]? = nil
    ) {
        self.name = name
        self.image = image
        self.build = build
        self.command = command
        self.entrypoint = entrypoint
        self.environment = environment
        self.envFiles = envFiles
        self.ports = ports
        self.volumes = volumes
        self.networks = networks
        self.dependsOn = dependsOn
        self.labels = labels
        self.containerName = containerName
        self.hostname = hostname
        self.workingDir = workingDir
        self.user = user
        self.tty = tty
        self.stdinOpen = stdinOpen
        self.readOnly = readOnly
        self.privileged = privileged
        self.`init` = `init`
        self.tmpfs = tmpfs
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.extraHosts = extraHosts
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.memLimit = memLimit
        self.cpus = cpus
        self.healthcheck = healthcheck
        self.configs = configs
        self.secrets = secrets
        self.extensions = extensions
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
