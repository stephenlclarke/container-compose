import Foundation

public struct ComposeProject: Codable, Equatable {
    public var name: String
    public var workingDirectory: String
    public var composeFiles: [String]
    public var services: [String: ComposeService]
    public var networks: [String: ComposeNetwork]
    public var volumes: [String: ComposeVolume]

    public init(
        name: String,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        composeFiles: [String] = [],
        services: [String: ComposeService],
        networks: [String: ComposeNetwork] = [:],
        volumes: [String: ComposeVolume] = [:]
    ) {
        self.name = name
        self.workingDirectory = workingDirectory
        self.composeFiles = composeFiles
        self.services = services
        self.networks = networks
        self.volumes = volumes
    }
}

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
        cpus: String? = nil
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
    }
}

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
