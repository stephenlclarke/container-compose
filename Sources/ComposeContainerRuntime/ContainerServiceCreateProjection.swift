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
import ContainerizationOCI
import ContainerResource
import Foundation

/// Failures produced by the temporary v1 Container logging projection.
///
/// The lossless Compose request remains intact; these errors disappear when
/// the negotiated Container logging-v2 request is available.
public enum ContainerServiceCreateProjectionError: Error, Equatable, Sendable {
    case unsupportedLoggingDriver(String)
    case unsupportedLoggingOption(String)
    case invalidLoggingOption(key: String, value: String)
    case loggingOptionsDisabled
}

/// Apple runtime DTOs projected from a runtime-neutral Compose create plan.
public struct ContainerServiceCreateRuntimeProjection {
    public var initProcess: ProcessConfiguration
    public var logging: ContainerLogConfiguration
    public var healthCheck: ContainerHealthCheck?
    public var restartPolicy: ContainerRestartPolicy
    public var hostname: String?
    public var domainname: String?
    public var hosts: [ContainerConfiguration.HostEntry]
    public var sysctls: [String: String]
    public var blockIO: ContainerizationOCI.LinuxBlockIO?
    public var cpuShares: UInt64?
    public var cgroupParent: String?
    public var memoryReservationInBytes: Int64?
    public var memorySwapLimitInBytes: Int64?

    public init(_ plan: ContainerServiceCreatePlan) throws {
        initProcess = plan.initProcess.containerProcessConfiguration
        logging = try plan.logging.containerV1LogConfiguration
        healthCheck = plan.healthCheck?.containerHealthCheck
        restartPolicy = plan.restartPolicy.containerRestartPolicy
        hostname = plan.hostname
        domainname = plan.domainname
        hosts = plan.hosts.map(\.containerHostEntry)
        sysctls = plan.sysctls
        blockIO = plan.blockIO?.containerLinuxBlockIO
        cpuShares = plan.cpuShares
        cgroupParent = plan.cgroupParent
        memoryReservationInBytes = plan.memoryReservationInBytes
        memorySwapLimitInBytes = plan.memorySwapLimitInBytes
    }
}

public extension ContainerServiceCreatePlan {
    /// Translates the Compose-owned create plan into Apple runtime DTOs.
    var containerRuntimeProjection: ContainerServiceCreateRuntimeProjection {
        get throws {
            try ContainerServiceCreateRuntimeProjection(self)
        }
    }
}

public extension ComposeProcessConfiguration {
    /// Translates the runtime-neutral process definition to apple/container.
    var containerProcessConfiguration: ProcessConfiguration {
        ProcessConfiguration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            terminal: terminal,
            user: user.containerProcessUser,
            supplementalGroups: supplementalGroups,
            supplementalGroupNames: supplementalGroupNames,
            rlimits: rlimits.map {
                ProcessConfiguration.Rlimit(limit: $0.limit, soft: $0.soft, hard: $0.hard)
            },
            oomScoreAdj: oomScoreAdj,
            privileged: privileged,
            noNewPrivileges: noNewPrivileges,
        )
    }
}

private extension ComposeProcessConfiguration.User {
    var containerProcessUser: ProcessConfiguration.User {
        switch self {
        case let .raw(userString):
            .raw(userString: userString)
        case let .id(uid, gid):
            .id(uid: uid, gid: gid)
        }
    }
}

public extension ComposeLogConfiguration {
    /// Down-converts the lossless request only for the capabilities available
    /// in Container's v1 logging contract.
    var containerV1LogConfiguration: ContainerLogConfiguration {
        get throws {
            let storage: ContainerLogConfiguration.Storage
            switch driver {
            case nil, "", "json-file", "local":
                storage = .local
            case "none":
                guard options.isEmpty else {
                    throw ContainerServiceCreateProjectionError.loggingOptionsDisabled
                }
                storage = .none
            case let driver?:
                throw ContainerServiceCreateProjectionError.unsupportedLoggingDriver(driver)
            }

            var maxSizeInBytes: UInt64?
            var maxFileCount: Int?
            for (key, value) in options {
                switch key {
                case "max-size":
                    guard let parsed = Self.v1LogSizeInBytes(value) else {
                        throw ContainerServiceCreateProjectionError.invalidLoggingOption(key: key, value: value)
                    }
                    maxSizeInBytes = parsed
                case "max-file":
                    guard let parsed = Int(value), parsed > 0 else {
                        throw ContainerServiceCreateProjectionError.invalidLoggingOption(key: key, value: value)
                    }
                    maxFileCount = parsed
                default:
                    throw ContainerServiceCreateProjectionError.unsupportedLoggingOption(key)
                }
            }
            return ContainerLogConfiguration(
                storage: storage,
                maxSizeInBytes: maxSizeInBytes,
                maxFileCount: maxFileCount,
            )
        }
    }

    private static func v1LogSizeInBytes(_ input: String) -> UInt64? {
        let value = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else {
            return nil
        }
        let unitIndex = value.firstIndex { !$0.isNumber && $0 != "." }
        let numberText = unitIndex.map { value[..<$0].trimmingCharacters(in: .whitespaces) } ?? value
        let unitText = unitIndex.map { value[$0...].trimmingCharacters(in: .whitespaces) } ?? ""
        guard let number = Double(numberText), number.isFinite, number > 0 else {
            return nil
        }
        let unit = unitText.first ?? "b"
        guard let exponent = "bkmgtp".firstIndex(of: unit).map({ "bkmgtp".distance(from: "bkmgtp".startIndex, to: $0) }) else {
            return nil
        }
        let suffix = String(unitText.dropFirst())
        guard suffix.isEmpty || suffix == "b" || suffix == "ib" else {
            return nil
        }
        let bytes = number * pow(1024, Double(exponent))
        guard bytes.isFinite, bytes <= Double(UInt64.max) else {
            return nil
        }
        return UInt64(bytes)
    }
}

public extension ComposeHealthCheck {
    /// Translates the runtime-neutral healthcheck to apple/container.
    var containerHealthCheck: ContainerHealthCheck {
        ContainerHealthCheck(
            process: process.containerProcessConfiguration,
            intervalInNanoseconds: intervalInNanoseconds,
            timeoutInNanoseconds: timeoutInNanoseconds,
            startPeriodInNanoseconds: startPeriodInNanoseconds,
            startIntervalInNanoseconds: startIntervalInNanoseconds,
            retries: retries,
        )
    }
}

public extension ComposeRestartPolicy {
    /// Translates the runtime-neutral restart policy to apple/container.
    var containerRestartPolicy: ContainerRestartPolicy {
        ContainerRestartPolicy(
            mode: mode.containerRestartMode,
            maximumRetryCount: maximumRetryCount,
            retryDelayInNanoseconds: retryDelayInNanoseconds,
            successfulRunDurationInNanoseconds: successfulRunDurationInNanoseconds,
        )
    }
}

private extension ComposeRestartPolicy.Mode {
    var containerRestartMode: ContainerRestartPolicy.Mode {
        switch self {
        case .no:
            .no
        case .onFailure:
            .onFailure
        case .always:
            .always
        case .unlessStopped:
            .unlessStopped
        }
    }
}

public extension ComposeHostEntry {
    /// Translates the runtime-neutral host entry to apple/container.
    var containerHostEntry: ContainerConfiguration.HostEntry {
        ContainerConfiguration.HostEntry(ipAddress: ipAddress, hostnames: hostnames)
    }
}

public extension ComposeLinuxBlockIO {
    /// Translates runtime-neutral block I/O values to the OCI runtime DTO.
    var containerLinuxBlockIO: ContainerizationOCI.LinuxBlockIO {
        ContainerizationOCI.LinuxBlockIO(
            weight: weight,
            leafWeight: leafWeight,
            weightDevice: weightDevice.map {
                ContainerizationOCI.LinuxWeightDevice(
                    major: $0.major,
                    minor: $0.minor,
                    weight: $0.weight,
                    leafWeight: $0.leafWeight,
                )
            },
            throttleReadBpsDevice: throttleReadBpsDevice.map(\.containerLinuxThrottleDevice),
            throttleWriteBpsDevice: throttleWriteBpsDevice.map(\.containerLinuxThrottleDevice),
            throttleReadIOPSDevice: throttleReadIOPSDevice.map(\.containerLinuxThrottleDevice),
            throttleWriteIOPSDevice: throttleWriteIOPSDevice.map(\.containerLinuxThrottleDevice),
        )
    }
}

private extension ComposeLinuxThrottleDevice {
    var containerLinuxThrottleDevice: ContainerizationOCI.LinuxThrottleDevice {
        ContainerizationOCI.LinuxThrottleDevice(major: major, minor: minor, rate: rate)
    }
}
