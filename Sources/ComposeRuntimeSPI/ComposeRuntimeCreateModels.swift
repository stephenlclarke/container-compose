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

/// Runtime process configuration projected from a Compose service.
public struct ComposeProcessConfiguration: Codable, Sendable {
    public struct Rlimit: Codable, Equatable, Sendable {
        public let limit: String
        public let soft: UInt64
        public let hard: UInt64

        public init(limit: String, soft: UInt64, hard: UInt64) {
            self.limit = limit
            self.soft = soft
            self.hard = hard
        }
    }

    public enum User: Codable, CustomStringConvertible, Equatable, Sendable {
        case raw(userString: String)
        case id(uid: UInt32, gid: UInt32)

        public var description: String {
            switch self {
            case let .id(uid, gid):
                "\(uid):\(gid)"
            case let .raw(name):
                name
            }
        }
    }

    public struct RuntimeOptions: Sendable {
        public var supplementalGroups: [UInt32]
        public var supplementalGroupNames: [String]
        public var rlimits: [Rlimit]
        public var oomScoreAdj: Int?
        public var privileged: Bool
        public var noNewPrivileges: Bool

        public init(
            supplementalGroups: [UInt32] = [],
            supplementalGroupNames: [String] = [],
            rlimits: [Rlimit] = [],
            oomScoreAdj: Int? = nil,
            privileged: Bool = false,
            noNewPrivileges: Bool = false,
        ) {
            self.supplementalGroups = supplementalGroups
            self.supplementalGroupNames = supplementalGroupNames
            self.rlimits = rlimits
            self.oomScoreAdj = oomScoreAdj
            self.privileged = privileged
            self.noNewPrivileges = noNewPrivileges
        }
    }

    public var executable: String
    public var arguments: [String]
    public var environment: [String]
    public var workingDirectory: String
    public var terminal: Bool
    public var user: User
    public var supplementalGroups: [UInt32]
    public var supplementalGroupNames: [String]
    public var rlimits: [Rlimit]
    public var oomScoreAdj: Int?
    public var privileged: Bool
    public var noNewPrivileges: Bool

    public init(
        executable: String,
        arguments: [String],
        environment: [String],
        workingDirectory: String = "/",
        terminal: Bool = false,
        user: User = .id(uid: 0, gid: 0),
        runtimeOptions: RuntimeOptions = RuntimeOptions(),
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.user = user
        supplementalGroups = runtimeOptions.supplementalGroups
        supplementalGroupNames = runtimeOptions.supplementalGroupNames
        rlimits = runtimeOptions.rlimits
        oomScoreAdj = runtimeOptions.oomScoreAdj
        privileged = runtimeOptions.privileged
        noNewPrivileges = runtimeOptions.noNewPrivileges
    }

    @available(*, deprecated, message: "Use init(executable:arguments:environment:workingDirectory:terminal:user:runtimeOptions:)")
    public init(
        executable: String,
        arguments: [String],
        environment: [String],
        workingDirectory: String = "/",
        terminal: Bool = false,
        user: User = .id(uid: 0, gid: 0),
        supplementalGroups: [UInt32] = [],
        supplementalGroupNames: [String] = [],
        rlimits: [Rlimit] = [],
        oomScoreAdj: Int? = nil,
        privileged: Bool = false,
        noNewPrivileges: Bool = false,
    ) {
        self.init(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            terminal: terminal,
            user: user,
            runtimeOptions: RuntimeOptions(
                supplementalGroups: supplementalGroups,
                supplementalGroupNames: supplementalGroupNames,
                rlimits: rlimits,
                oomScoreAdj: oomScoreAdj,
                privileged: privileged,
                noNewPrivileges: noNewPrivileges,
            ),
        )
    }

    private enum CodingKeys: String, CodingKey {
        case executable
        case arguments
        case environment
        case workingDirectory
        case terminal
        case user
        case supplementalGroups
        case supplementalGroupNames
        case rlimits
        case oomScoreAdj
        case privileged
        case noNewPrivileges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executable = try container.decode(String.self, forKey: .executable)
        arguments = try container.decode([String].self, forKey: .arguments)
        environment = try container.decode([String].self, forKey: .environment)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        terminal = try container.decode(Bool.self, forKey: .terminal)
        user = try container.decode(User.self, forKey: .user)
        supplementalGroups = try container.decode([UInt32].self, forKey: .supplementalGroups)
        supplementalGroupNames = try container.decodeIfPresent([String].self, forKey: .supplementalGroupNames) ?? []
        rlimits = try container.decode([Rlimit].self, forKey: .rlimits)
        oomScoreAdj = try container.decodeIfPresent(Int.self, forKey: .oomScoreAdj)
        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged) ?? false
        noNewPrivileges = try container.decodeIfPresent(Bool.self, forKey: .noNewPrivileges) ?? false
    }
}

/// Runtime logging policy projected from a Compose service.
public struct ComposeLogConfiguration: Codable, Equatable, Sendable {
    /// The exact driver requested by Compose. `nil` delegates selection to the
    /// runtime default and remains distinct from an explicitly named driver.
    public var driver: String?

    /// The complete compose-go-normalised option map. Driver-specific parsing
    /// and default resolution belong to the runtime authority.
    public var options: [String: String]

    public static let standard = ComposeLogConfiguration()

    @available(*, deprecated, renamed: "standard")
    public static var `default`: ComposeLogConfiguration {
        standard
    }

    public init(
        driver: String? = nil,
        options: [String: String] = [:],
    ) {
        self.driver = driver
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case driver
        case options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(driver, forKey: .driver)
        if !options.isEmpty {
            try container.encode(options, forKey: .options)
        }
    }
}

/// Create command selected after Compose has completed service planning.
public enum ComposeRuntimeContainerLaunchCommand: String, Equatable, Sendable {
    case create
    case run
}

/// In-process create/run request for a negotiated Container authority.
///
/// `arguments` contains the non-logging Container command arguments. Logging
/// travels as a separate typed value so protected provider options never enter
/// a child-process argument vector.
public struct ComposeRuntimeContainerLaunchRequest: Equatable, Sendable {
    public var command: ComposeRuntimeContainerLaunchCommand
    public var arguments: [String]
    public var logging: ComposeLogConfiguration

    public init(
        command: ComposeRuntimeContainerLaunchCommand,
        arguments: [String],
        logging: ComposeLogConfiguration,
    ) {
        self.command = command
        self.arguments = arguments
        self.logging = logging
    }
}

/// Authority-backed container creation without a child `container` process.
public protocol ComposeRuntimeContainerLaunching: Sendable {
    /// Creates or runs one container and returns its process status.
    func launchContainer(_ request: ComposeRuntimeContainerLaunchRequest) async throws -> Int32
}

/// Runtime healthcheck projected from Compose or inherited image metadata.
public struct ComposeHealthCheck: Codable, Sendable {
    public static let defaultIntervalInNanoseconds: UInt64 = 30_000_000_000
    public static let defaultTimeoutInNanoseconds: UInt64 = 30_000_000_000
    public static let defaultStartPeriodInNanoseconds: UInt64 = 0
    public static let defaultStartIntervalInNanoseconds: UInt64 = 5_000_000_000
    public static let defaultRetries: UInt32 = 3

    public var process: ComposeProcessConfiguration
    public var intervalInNanoseconds: UInt64
    public var timeoutInNanoseconds: UInt64
    public var startPeriodInNanoseconds: UInt64
    public var startIntervalInNanoseconds: UInt64?
    public var retries: UInt32

    public init(
        process: ComposeProcessConfiguration,
        intervalInNanoseconds: UInt64 = Self.defaultIntervalInNanoseconds,
        timeoutInNanoseconds: UInt64 = Self.defaultTimeoutInNanoseconds,
        startPeriodInNanoseconds: UInt64 = Self.defaultStartPeriodInNanoseconds,
        startIntervalInNanoseconds: UInt64? = nil,
        retries: UInt32 = Self.defaultRetries,
    ) {
        self.process = process
        self.intervalInNanoseconds = intervalInNanoseconds
        self.timeoutInNanoseconds = timeoutInNanoseconds
        self.startPeriodInNanoseconds = startPeriodInNanoseconds
        self.startIntervalInNanoseconds = startIntervalInNanoseconds
        self.retries = retries
    }
}

/// Runtime restart behaviour projected from a Compose service.
public struct ComposeRestartPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, CaseIterable, Codable, Sendable {
        // The spelling is part of the Docker Compose restart-policy vocabulary.
        // swiftlint:disable:next identifier_name
        case no
        case onFailure = "on-failure"
        case always
        case unlessStopped = "unless-stopped"
    }

    public let mode: Mode
    public let maximumRetryCount: UInt32?
    public let retryDelayInNanoseconds: UInt64?
    public let successfulRunDurationInNanoseconds: UInt64?

    public init(
        mode: Mode,
        maximumRetryCount: UInt32? = nil,
        retryDelayInNanoseconds: UInt64? = nil,
        successfulRunDurationInNanoseconds: UInt64? = nil,
    ) {
        self.mode = mode
        self.maximumRetryCount = mode == .onFailure && maximumRetryCount != 0
            ? maximumRetryCount
            : nil
        switch mode {
        case .no:
            self.retryDelayInNanoseconds = nil
            self.successfulRunDurationInNanoseconds = nil
        case .onFailure, .always, .unlessStopped:
            self.retryDelayInNanoseconds = retryDelayInNanoseconds
            self.successfulRunDurationInNanoseconds = successfulRunDurationInNanoseconds
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case maximumRetryCount
        case retryDelayInNanoseconds
        case successfulRunDurationInNanoseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(Mode.self, forKey: .mode),
            maximumRetryCount: container.decodeIfPresent(UInt32.self, forKey: .maximumRetryCount),
            retryDelayInNanoseconds: container.decodeIfPresent(UInt64.self, forKey: .retryDelayInNanoseconds),
            successfulRunDurationInNanoseconds: container.decodeIfPresent(
                UInt64.self,
                forKey: .successfulRunDurationInNanoseconds,
            ),
        )
    }

    // The spelling is part of the Docker Compose restart-policy vocabulary.
    // swiftlint:disable:next identifier_name
    public static let no = ComposeRestartPolicy(mode: .no)
}

/// Static host entry projected from Compose `extra_hosts`.
public struct ComposeHostEntry: Codable, Equatable, Sendable {
    public static let hostGatewayAddress = "host-gateway"

    public let ipAddress: String
    public let hostnames: [String]

    public var requiresHostGateway: Bool {
        ipAddress == Self.hostGatewayAddress
    }

    public init(ipAddress: String, hostnames: [String]) {
        self.ipAddress = ipAddress
        self.hostnames = hostnames
    }
}

public struct ComposeLinuxWeightDevice: Codable, Equatable, Sendable {
    public var major: Int64
    public var minor: Int64
    public var weight: UInt16?
    public var leafWeight: UInt16?

    public init(major: Int64, minor: Int64, weight: UInt16?, leafWeight: UInt16?) {
        self.major = major
        self.minor = minor
        self.weight = weight
        self.leafWeight = leafWeight
    }
}

public struct ComposeLinuxThrottleDevice: Codable, Equatable, Sendable {
    public var major: Int64
    public var minor: Int64
    public var rate: UInt64

    public init(major: Int64, minor: Int64, rate: UInt64) {
        self.major = major
        self.minor = minor
        self.rate = rate
    }
}

/// OCI-compatible block I/O values without an OCI package dependency.
public struct ComposeLinuxBlockIO: Codable, Equatable, Sendable {
    public var weight: UInt16?
    public var leafWeight: UInt16?
    public var weightDevice: [ComposeLinuxWeightDevice]
    public var throttleReadBpsDevice: [ComposeLinuxThrottleDevice]
    public var throttleWriteBpsDevice: [ComposeLinuxThrottleDevice]
    public var throttleReadIOPSDevice: [ComposeLinuxThrottleDevice]
    public var throttleWriteIOPSDevice: [ComposeLinuxThrottleDevice]

    public init(
        weight: UInt16?,
        leafWeight: UInt16?,
        weightDevice: [ComposeLinuxWeightDevice],
        throttleReadBpsDevice: [ComposeLinuxThrottleDevice],
        throttleWriteBpsDevice: [ComposeLinuxThrottleDevice],
        throttleReadIOPSDevice: [ComposeLinuxThrottleDevice],
        throttleWriteIOPSDevice: [ComposeLinuxThrottleDevice],
    ) {
        self.weight = weight
        self.leafWeight = leafWeight
        self.weightDevice = weightDevice
        self.throttleReadBpsDevice = throttleReadBpsDevice
        self.throttleWriteBpsDevice = throttleWriteBpsDevice
        self.throttleReadIOPSDevice = throttleReadIOPSDevice
        self.throttleWriteIOPSDevice = throttleWriteIOPSDevice
    }
}
