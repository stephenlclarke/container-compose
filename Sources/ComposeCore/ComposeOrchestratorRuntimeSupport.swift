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

import ContainerAPIClient
import ContainerizationExtras
import ContainerResource
import Foundation

struct ComposeRuntimeUnsupportedValue {
    let composeName: String
    let value: String
    let reason: String
}

struct ComposeRuntimeUnsupportedField {
    let composeName: String
    let reason: String
}

private struct ComposeRuntimeUnsupportedOptionalValue {
    let composeName: String
    let value: String?
    let reason: String
}

extension ComposeOrchestrator {
    /// Validates all selected services before any runtime side effects occur.
    func validateRuntimeSupport(
        services: [ComposeService],
        project: ComposeProject,
        validateDependencies: Bool = true,
    ) throws {
        for service in services {
            try validateRuntimeSupport(service: service, project: project, validateDependencies: validateDependencies)
        }
    }

    /// Returns unsupported string-valued fields that need missing runtime primitives.
    func unsupportedRuntimeStringFields(service: ComposeService) -> [ComposeRuntimeUnsupportedValue] {
        [
            ComposeRuntimeUnsupportedOptionalValue(
                composeName: "cgroup",
                value: service.cgroup,
                reason: "cgroup namespace support needs an apple/container runtime gap PR",
            ),
            ComposeRuntimeUnsupportedOptionalValue(
                composeName: "cgroup_parent",
                value: service.cgroupParent,
                reason: "cgroup parent support needs an apple/container runtime gap PR",
            ),
            ComposeRuntimeUnsupportedOptionalValue(
                composeName: "ipc",
                value: service.ipc,
                reason: "IPC namespace support needs an apple/container runtime gap PR",
            ),
            ComposeRuntimeUnsupportedOptionalValue(
                composeName: "isolation",
                value: service.isolation,
                reason: "isolation support needs an apple/container runtime gap PR",
            ),
            ComposeRuntimeUnsupportedOptionalValue(
                composeName: "userns_mode",
                value: service.usernsMode,
                reason: "user namespace support needs an apple/container runtime gap PR",
            ),
            ComposeRuntimeUnsupportedOptionalValue(
                composeName: "uts",
                value: service.uts,
                reason: "UTS namespace support needs an apple/container runtime gap PR",
            ),
        ].compactMap { candidate in
            guard let value = candidate.value, !value.isEmpty else {
                return nil
            }
            return ComposeRuntimeUnsupportedValue(
                composeName: candidate.composeName,
                value: value,
                reason: candidate.reason,
            )
        }
    }

    /// Returns the apple/container PID namespace argument for Docker-compatible Compose PID modes.
    func runtimePIDArgument(service: ComposeService) throws -> String? {
        guard let pid = service.pid, !pid.isEmpty else {
            return nil
        }
        guard pid == "host" else {
            throw ComposeError.unsupported("service '\(service.name)' uses pid '\(pid)'; only pid: host is supported")
        }
        return "host"
    }

    /// Returns unsupported CPU scheduler fields beyond the supported `cpus` and
    /// relative `cpu_shares` controls.
    func unsupportedCPUResourceFields(service: ComposeService) -> [ComposeRuntimeUnsupportedValue] {
        let reason = "advanced CPU resource support needs an apple/container runtime gap PR"
        var fields: [ComposeRuntimeUnsupportedValue] = []
        appendUnsupportedIntegerField("cpu_count", value: service.cpuCount, reason: reason, to: &fields)
        appendUnsupportedFloatingPointField("cpu_percent", value: service.cpuPercent, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_period", value: service.cpuPeriod, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_quota", value: service.cpuQuota, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_rt_period", value: service.cpuRealtimePeriod, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_rt_runtime", value: service.cpuRealtimeRuntime, reason: reason, to: &fields)
        if let cpuset = service.cpuset, !cpuset.isEmpty {
            fields.append(.init(composeName: "cpuset", value: cpuset, reason: reason))
        }
        return fields
    }

    /// Returns unsupported memory, OOM, and process resource controls beyond
    /// `mem_limit`, `mem_reservation`, and `oom_score_adj`.
    func unsupportedMemoryAndProcessResourceFields(service: ComposeService) -> [ComposeRuntimeUnsupportedValue] {
        let reason = "memory, OOM, and process resource support needs an apple/container runtime gap PR"
        var fields: [ComposeRuntimeUnsupportedValue] = []
        appendUnsupportedStringField("mem_swappiness", value: service.memSwappiness, reason: reason, to: &fields)
        if service.oomKillDisable == true {
            fields.append(.init(composeName: "oom_kill_disable", value: "true", reason: reason))
        }
        return fields
    }

    /// Returns a Linux-compatible OOM score adjustment for the service process.
    func runtimeOOMScoreAdj(service: ComposeService) throws -> Int? {
        guard let oomScoreAdj = service.oomScoreAdj else {
            return nil
        }
        guard (-1000 ... 1000).contains(oomScoreAdj) else {
            throw ComposeError.invalidProject(
                "service '\(service.name)' uses oom_score_adj '\(oomScoreAdj)' outside the supported range -1000...1000",
            )
        }
        return oomScoreAdj
    }

    /// Returns a Docker-compatible relative CPU scheduling weight. Zero leaves
    /// the runtime default unchanged; non-zero weights start at two.
    func runtimeCPUShares(service: ComposeService) throws -> UInt64? {
        guard let cpuShares = service.cpuShares, cpuShares != 0 else {
            return nil
        }
        guard cpuShares >= 2 else {
            throw ComposeError.invalidProject(
                "service '\(service.name)' uses cpu_shares '\(cpuShares)'; cpu_shares must be 0 or at least 2",
            )
        }
        return UInt64(cpuShares)
    }

    /// Returns a Docker-compatible soft memory reservation in bytes. Zero
    /// leaves the runtime default unchanged; an explicit hard memory limit must
    /// be strictly higher than the reservation.
    func runtimeMemoryReservationInBytes(service: ComposeService) throws -> Int64? {
        guard let reservation = service.memReservation, !reservation.isEmpty else {
            return nil
        }
        guard let reservationInBytes = Int64(reservation), reservationInBytes >= 0 else {
            throw ComposeError.invalidProject(
                "service '\(service.name)' uses invalid mem_reservation '\(reservation)'; expected a non-negative byte value",
            )
        }
        guard reservationInBytes != 0 else {
            return nil
        }
        if let memoryLimit = service.memLimit, !memoryLimit.isEmpty,
           let memoryLimitInBytes = Int64(memoryLimit), reservationInBytes >= memoryLimitInBytes
        {
            throw ComposeError.invalidProject(
                "service '\(service.name)' uses mem_reservation '\(reservation)'; mem_reservation must be lower than mem_limit '\(memoryLimit)'",
            )
        }
        return reservationInBytes
    }

    /// Returns Docker-compatible combined memory and swap usage in bytes. A
    /// zero value is treated as unset; when a hard memory limit is set without
    /// an explicit swap value, Docker limits total memory plus swap to twice
    /// the hard memory limit.
    func runtimeMemorySwapLimitInBytes(service: ComposeService) throws -> Int64? {
        let requestedLimit: Int64?
        if let swapLimit = service.memSwapLimit, !swapLimit.isEmpty {
            guard let parsedLimit = Int64(swapLimit), parsedLimit == -1 || parsedLimit >= 0 else {
                throw ComposeError.invalidProject(
                    "service '\(service.name)' uses invalid memswap_limit '\(swapLimit)'; expected -1, 0, or a positive byte value",
                )
            }
            requestedLimit = parsedLimit == 0 ? nil : parsedLimit
        } else {
            requestedLimit = nil
        }

        guard let memoryLimit = service.memLimit, !memoryLimit.isEmpty else {
            guard requestedLimit == nil else {
                throw ComposeError.invalidProject(
                    "service '\(service.name)' uses memswap_limit; memswap_limit requires a positive mem_limit",
                )
            }
            return nil
        }
        guard let memoryLimitInBytes = Int64(memoryLimit), memoryLimitInBytes > 0 else {
            guard requestedLimit == nil else {
                throw ComposeError.invalidProject(
                    "service '\(service.name)' uses memswap_limit; memswap_limit requires a positive mem_limit",
                )
            }
            return nil
        }

        if let requestedLimit {
            guard requestedLimit == -1 || requestedLimit >= memoryLimitInBytes else {
                throw ComposeError.invalidProject(
                    "service '\(service.name)' uses memswap_limit '\(requestedLimit)'; memswap_limit must be at least mem_limit '\(memoryLimit)'",
                )
            }
            return requestedLimit
        }

        let (defaultLimit, overflow) = memoryLimitInBytes.multipliedReportingOverflow(by: 2)
        guard !overflow else {
            throw ComposeError.invalidProject(
                "service '\(service.name)' uses mem_limit '\(memoryLimit)'; Docker-compatible default memswap_limit exceeds the runtime range",
            )
        }
        return defaultLimit
    }

    /// Splits Compose supplemental groups into numeric IDs and guest-image group names.
    func runtimeSupplementalGroups(service: ComposeService) throws -> (ids: [UInt32], names: [String]) {
        var identifiers: [UInt32] = []
        var names: [String] = []
        var seenIdentifiers = Set<UInt32>()
        var seenNames = Set<String>()

        for group in service.groupAdd ?? [] {
            guard !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ComposeError.invalidProject("service '\(service.name)' uses an empty group_add value")
            }
            if let identifier = UInt32(group) {
                if seenIdentifiers.insert(identifier).inserted {
                    identifiers.append(identifier)
                }
            } else if group.allSatisfy(\.isNumber) {
                throw ComposeError.invalidProject("service '\(service.name)' uses group_add numeric ID '\(group)' outside the UInt32 range")
            } else if seenNames.insert(group).inserted {
                names.append(group)
            }
        }
        return (identifiers, names)
    }

    /// Returns repeatable generic runtime arguments for numeric IDs and named groups.
    func runtimeSupplementalGroupArguments(service: ComposeService) throws -> [String] {
        let groups = try runtimeSupplementalGroups(service: service)
        return groups.ids.map(String.init) + groups.names
    }

    /// Returns unsupported user and security option fields.
    func unsupportedUserAndSecurityOptionFields(service: ComposeService) -> [ComposeRuntimeUnsupportedValue] {
        var fields: [ComposeRuntimeUnsupportedValue] = []
        if let securityOption = service.securityOpt?.first(where: { !$0.isEmpty }) {
            fields.append(.init(
                composeName: "security_opt",
                value: securityOption,
                reason: "security option support needs an apple/container runtime gap PR",
            ))
        }
        return fields
    }

    /// Returns unsupported credential access fields.
    func unsupportedDeviceAccessFields(service: ComposeService) -> [ComposeRuntimeUnsupportedField] {
        var fields: [ComposeRuntimeUnsupportedField] = []
        if service.credentialSpec != nil {
            fields.append(.init(
                composeName: "credential_spec",
                reason: "credential spec support needs an apple/container runtime gap PR",
            ))
        }
        return fields
    }

    /// Returns the runtime gap that prevents a dependency condition.
    func unsupportedDependencyConditionReason(_ condition: String) -> String {
        switch condition {
        case "service_healthy":
            "health status support requires apple/container healthcheck runtime support"
        case "service_completed_successfully":
            "exit code and completion time need an apple/container runtime gap PR"
        default:
            "dependency condition support needs an apple/container runtime gap PR"
        }
    }

    /// Returns logging and storage fields that need apple/container runtime primitives.
    func unsupportedServiceMetadataAndLoggingFields(service: ComposeService) -> [ComposeRuntimeUnsupportedField] {
        var fields: [ComposeRuntimeUnsupportedField] = []
        let loggingReason = "service logging driver/options need an apple/container runtime gap PR"
        if !isSupportedRuntimeLogging(service.logging) {
            fields.append(.init(composeName: "logging", reason: loggingReason))
        }
        if let logDriver = service.logDriver,
           !logDriver.isEmpty,
           !isSupportedRuntimeLogDriver(logDriver)
        {
            fields.append(.init(composeName: "log_driver", reason: loggingReason))
        }
        if !isSupportedLegacyRuntimeLogOptions(service: service) {
            fields.append(.init(composeName: "log_opt", reason: loggingReason))
        }
        if let storageOptions = service.storageOptions, !storageOptions.isEmpty {
            fields.append(.init(
                composeName: "storage_opt",
                reason: "per-container storage options need an apple/container rootfs storage runtime gap PR",
            ))
        }
        return fields
    }

    /// Returns whether Compose logging maps to an apple/container runtime log policy.
    func isSupportedRuntimeLogging(_ logging: ComposeValue?) -> Bool {
        guard let logging else {
            return true
        }
        switch logging {
        case .null:
            return true
        case let .object(fields):
            let knownKeys = Set(["driver", "options"])
            guard fields.keys.allSatisfy({ knownKeys.contains($0) }) else {
                return false
            }
            let driver = fields["driver"]?.stringValue
            let options = fields["options"]
            return isSupportedRuntimeLogDriver(driver) && isSupportedRuntimeLogOptions(options, driver: driver)
        default:
            return false
        }
    }

    /// Returns whether a logging driver can be represented by apple/container.
    func isSupportedRuntimeLogDriver(_ driver: String?) -> Bool {
        driver == nil || driver == "json-file" || driver == "local" || driver == "none"
    }

    /// Returns whether Compose logging options map to local apple/container options.
    func isSupportedRuntimeLogOptions(_ options: ComposeValue?, driver: String?) -> Bool {
        guard let options else {
            return true
        }
        switch options {
        case .null:
            return true
        case let .object(fields):
            if fields.isEmpty {
                return true
            }
            guard driver != "none" else {
                return false
            }
            return fields.allSatisfy { key, value in
                isSupportedRuntimeLogOptionKey(key) && value.stringValue != nil
            }
        default:
            return false
        }
    }

    /// Returns whether legacy Compose log options map to local apple/container options.
    func isSupportedLegacyRuntimeLogOptions(service: ComposeService) -> Bool {
        guard let logOptions = service.logOptions, !logOptions.isEmpty else {
            return true
        }
        guard isSupportedRuntimeLogDriver(service.logDriver), service.logDriver != "none" else {
            return false
        }
        return logOptions.keys.allSatisfy(isSupportedRuntimeLogOptionKey)
    }

    /// Returns whether an option key is supported by apple/container local logging.
    func isSupportedRuntimeLogOptionKey(_ key: String) -> Bool {
        key == "max-size" || key == "max-file"
    }

    /// Returns the Compose-owned typed logging policy for service create/run.
    func runtimeLogConfiguration(service: ComposeService) throws -> ContainerLogConfiguration {
        let driver = runtimeLogDriver(service: service)
        var configuration: ContainerLogConfiguration
        switch driver {
        case nil, "", "json-file", "local":
            configuration = .default
        case "none":
            configuration = ContainerLogConfiguration(storage: .none)
        case let driver?:
            throw ComposeError.unsupported("service '\(service.name)' uses unsupported logging driver '\(driver)'; supported drivers are json-file, local, and none")
        }

        let options = runtimeLogOptions(service: service)
        guard options.isEmpty else {
            guard configuration.storage == .local else {
                let driverName = driver ?? "local"
                throw ComposeError.unsupported("service '\(service.name)' uses logging options with driver '\(driverName)'; log options are only supported with local logging")
            }
            for (key, value) in options {
                switch key {
                case "max-size":
                    configuration.maxSizeInBytes = try logOptionSizeInBytes(value, serviceName: service.name)
                case "max-file":
                    configuration.maxFileCount = try logOptionFileCount(value, serviceName: service.name)
                default:
                    throw ComposeError.unsupported("service '\(service.name)' uses unsupported logging option '\(key)'; supported options are max-size and max-file")
                }
            }
            return configuration
        }

        return configuration
    }

    /// Returns the runtime log driver name from Compose's legacy and structured fields.
    func runtimeLogDriver(service: ComposeService) -> String? {
        if case let .object(fields)? = service.logging,
           let driver = fields["driver"]?.stringValue
        {
            return driver
        }
        return service.logDriver
    }

    /// Returns normalized local logging options from Compose's legacy and structured fields.
    func runtimeLogOptions(service: ComposeService) -> [String: String] {
        var options: [String: String] = [:]
        if case let .object(fields)? = service.logging,
           case let .object(logOptions)? = fields["options"]
        {
            for (key, value) in logOptions {
                if let stringValue = value.stringValue {
                    options[key] = stringValue
                }
            }
        }
        for (key, value) in service.logOptions ?? [:] {
            options[key] = value
        }
        return options
    }

    /// Returns the runtime log driver override needed for non-default Compose logging.
    func runtimeLogDriverArgument(service: ComposeService) throws -> String? {
        try runtimeLogConfiguration(service: service).storage == .none ? "none" : nil
    }

    /// Returns local apple/container logging options for service create/run.
    func runtimeLogOptionArguments(service: ComposeService) throws -> [String] {
        _ = try runtimeLogConfiguration(service: service)
        return runtimeLogOptions(service: service).sorted(by: { $0.key < $1.key }).flatMap { key, value in
            ["--log-opt", "\(key)=\(value)"]
        }
    }

    /// Parses a Compose log size option into bytes.
    func logOptionSizeInBytes(_ value: String, serviceName: String) throws -> UInt64 {
        let bytes: Double
        do {
            bytes = try Measurement<UnitInformationStorage>.parse(parsing: value).converted(to: .bytes).value
        } catch {
            throw ComposeError.invalidProject("service '\(serviceName)' logging option max-size '\(value)' must be a size")
        }
        guard bytes.isFinite, bytes > 0, bytes <= Double(UInt64.max) else {
            throw ComposeError.invalidProject("service '\(serviceName)' logging option max-size '\(value)' is outside the supported range")
        }
        return UInt64(bytes)
    }

    /// Parses a Compose log file-count option.
    func logOptionFileCount(_ value: String, serviceName: String) throws -> Int {
        guard let count = Int(value), count > 0 else {
            throw ComposeError.invalidProject("service '\(serviceName)' logging option max-file '\(value)' must be a positive integer")
        }
        return count
    }

    /// Returns the runtime hostname argument for Compose `hostname`.
    func runtimeHostnameArgument(service: ComposeService) throws -> String? {
        guard let hostname = service.hostname?.trimmingCharacters(in: .whitespacesAndNewlines), !hostname.isEmpty else {
            return nil
        }
        return try validatedRFC1123Hostname(hostname, field: "hostname", service: service)
    }

    /// Returns the runtime NIS domain-name argument for Compose `domainname`.
    func runtimeDomainnameArgument(service: ComposeService) throws -> String? {
        let domainName = service.domainName?.trimmingCharacters(
            in: .whitespacesAndNewlines,
        )
        guard let domainName, !domainName.isEmpty else {
            return nil
        }
        return try validatedRFC1123Hostname(domainName, field: "domainname", service: service)
    }

    /// Validates a Compose hostname using RFC1123 label rules.
    func validatedRFC1123Hostname(_ raw: String, field: String, service: ComposeService) throws -> String {
        guard let hostname = canonicalRFC1123Hostname(raw) else {
            throw invalidRFC1123HostnameError(raw, field: field, service: service)
        }
        return hostname
    }

    /// Returns runtime host-entry arguments for Compose `extra_hosts`.
    func runtimeExtraHostArguments(service: ComposeService) throws -> [String] {
        try runtimeHostEntries(service: service).flatMap { entry in
            entry.hostnames.map { hostname in
                "\(hostname):\(entry.ipAddress)"
            }
        }
    }

    /// Returns typed host entries for Compose `extra_hosts`.
    func runtimeHostEntries(service: ComposeService) throws -> [ContainerConfiguration.HostEntry] {
        try (service.extraHosts ?? []).map { raw in
            try runtimeHostEntry(raw, service: service)
        }
    }

    /// Returns runtime sysctl arguments for Compose `sysctls`.
    func runtimeSysctlArguments(service: ComposeService) throws -> [String] {
        try runtimeSysctls(service: service)
            .sorted(by: { $0.key < $1.key })
            .map { name, value in
                "\(name)=\(value)"
            }
    }

    /// Returns typed sysctl values for `ContainerConfiguration.sysctls`.
    func runtimeSysctls(service: ComposeService) throws -> [String: String] {
        try (service.sysctls ?? [:]).reduce(into: [String: String]()) { result, item in
            let trimmedName = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw ComposeError.invalidProject("service '\(service.name)' uses sysctls with an empty name")
            }
            guard !trimmedName.contains("=") else {
                throw ComposeError.invalidProject("service '\(service.name)' uses sysctl name '\(trimmedName)'; sysctl names must not contain '='")
            }
            result[trimmedName] = item.value
        }
    }

    /// Returns a Docker-compatible positive pids cgroup limit for service create/run.
    /// Docker Compose local mode preserves non-positive values in config output
    /// but does not project them to Docker Engine HostConfig.
    func runtimePidsLimitArgument(service: ComposeService) -> String? {
        guard let pidsLimit = service.pidsLimit, pidsLimit > 0 else {
            return nil
        }
        return "\(pidsLimit)"
    }

    /// Converts Compose `blkio_config` into apple/container#1595 `--blkio`
    /// specifications. Device path resolution stays inside apple/container.
    func runtimeBlkioArguments(service: ComposeService) throws -> [String] {
        guard let blkio = service.blkioConfig else {
            return []
        }
        var result: [String] = []
        if let weight = blkio.weight {
            try validateBlockIOWeight(weight, serviceName: service.name, field: "blkio_config.weight")
            result.append("weight=\(weight)")
        }
        for device in blkio.weightDevice ?? [] {
            try validateBlockIODevicePath(
                device.path,
                serviceName: service.name,
                field: "blkio_config.weight_device.path",
            )
            try validateBlockIOWeight(
                device.weight,
                serviceName: service.name,
                field: "blkio_config.weight_device.weight",
            )
            result.append("device=\(device.path),weight=\(device.weight)")
        }
        try appendThrottleArguments(
            blkio.deviceReadBps,
            key: "read-bps",
            field: "blkio_config.device_read_bps",
            serviceName: service.name,
            to: &result,
        )
        try appendThrottleArguments(
            blkio.deviceWriteBps,
            key: "write-bps",
            field: "blkio_config.device_write_bps",
            serviceName: service.name,
            to: &result,
        )
        try appendThrottleArguments(
            blkio.deviceReadIOps,
            key: "read-iops",
            field: "blkio_config.device_read_iops",
            serviceName: service.name,
            to: &result,
        )
        try appendThrottleArguments(
            blkio.deviceWriteIOps,
            key: "write-iops",
            field: "blkio_config.device_write_iops",
            serviceName: service.name,
            to: &result,
        )
        return result
    }

    /// Returns Docker-compatible device cgroup rules for service create/run.
    func runtimeDeviceCgroupRuleArguments(service: ComposeService) throws -> [String] {
        guard let rules = service.deviceCgroupRules, !rules.isEmpty else {
            return []
        }
        do {
            _ = try Parser.deviceCgroupRules(rules)
        } catch {
            throw ComposeError.invalidProject("service '\(service.name)' has invalid device_cgroup_rules; entries must use '<type> <major>:<minor> <access>' such as 'c 1:3 mr'")
        }
        return rules
    }

    /// Returns Docker-compatible Linux device mappings for service create/run.
    func runtimeDeviceArguments(service: ComposeService) throws -> [String] {
        guard let devices = service.devices, !devices.isEmpty else {
            return []
        }
        do {
            return try devices.map { try runtimeDeviceArgument($0) }
        } catch {
            throw ComposeError.invalidProject("service '\(service.name)' has invalid devices; entries must use HOST[:CONTAINER[:PERMISSIONS]] with absolute paths and r/w/m permissions")
        }
    }

    /// Returns Docker-compatible GPU requests for service create/run.
    func runtimeGPUArguments(service: ComposeService) throws -> [String] {
        let values = (service.gpus ?? []) + (service.deployGPURequests ?? [])
        guard !values.isEmpty else {
            return []
        }

        let arguments: [String]
        do {
            arguments = try values.map(runtimeGPUArgument)
        } catch let error as ComposeError {
            throw error
        } catch {
            throw ComposeError.invalidProject("service '\(service.name)' has an invalid GPU device request")
        }

        let requests: [ParsedGPURequest]
        do {
            requests = try Parser.gpus(arguments)
        } catch {
            throw ComposeError.invalidProject("service '\(service.name)' has an invalid GPU device request")
        }
        try validateGPUBackendSupport(requests, serviceName: service.name)
        return arguments
    }

    private func runtimeGPUArgument(_ value: ComposeValue) throws -> String {
        switch value {
        case let .string(spec):
            return spec
        case let .object(object):
            return try runtimeGPUArgument(object)
        default:
            throw ComposeError.invalidProject("GPU request must be a string or object")
        }
    }

    private func runtimeGPUArgument(_ object: [String: ComposeValue]) throws -> String {
        let driver = try optionalGPUStringField("driver", in: object)
        let count = try optionalGPUCountField("count", in: object)
        let deviceIDs = try optionalGPUStringArrayField("device_ids", in: object)
        let capabilities = try optionalGPUStringArrayField("capabilities", in: object)
        let options = try optionalGPUStringMapField("options", in: object)

        if count != nil, !(deviceIDs ?? []).isEmpty {
            throw ComposeError.invalidProject("GPU request count and device_ids are mutually exclusive")
        }
        let onlyGenericGPU = driver == nil
            && options == nil
            && (capabilities ?? []).allSatisfy { $0 == "gpu" }
        if onlyGenericGPU {
            if count == "-1" {
                return "all"
            }
            if count == nil, deviceIDs == ["0"] {
                return "device=0"
            }
        }

        var fields: [String] = []
        if let driver {
            fields.append("driver=\(driver)")
        }
        if let count {
            fields.append("count=\(count == "-1" ? "all" : count)")
        }
        if let deviceIDs, !deviceIDs.isEmpty {
            fields.append("device=\(csvQuoteIfNeeded(deviceIDs.joined(separator: ",")))")
        }
        if let capabilities, !capabilities.isEmpty, capabilities != ["gpu"] {
            fields.append("capabilities=\(csvQuoteIfNeeded(capabilities.joined(separator: ",")))")
        }
        if let options, !options.isEmpty {
            let value = options.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            fields.append("options=\(csvQuoteIfNeeded(value))")
        }
        if fields.isEmpty {
            return "count=1"
        }
        return fields.joined(separator: ",")
    }

    private func validateGPUBackendSupport(_ requests: [ParsedGPURequest], serviceName: String) throws {
        guard requests.count == 1 else {
            throw ComposeError.unsupported("service '\(serviceName)' requests multiple GPUs; the Apple virtio-gpu backend exposes one GPU")
        }

        let request = requests[0]
        guard request.driver.isEmpty || request.driver == "virtio" else {
            throw ComposeError.unsupported("service '\(serviceName)' requests GPU driver '\(request.driver)'; the Apple backend supports only virtio-gpu")
        }
        guard request.options.isEmpty else {
            throw ComposeError.unsupported("service '\(serviceName)' uses GPU driver options; the Apple virtio-gpu backend does not expose driver options")
        }
        guard request.capabilities.allSatisfy({ $0 == "gpu" }) else {
            throw ComposeError.unsupported("service '\(serviceName)' requests GPU capabilities beyond 'gpu'; the Apple virtio-gpu backend exposes only the generic GPU capability")
        }
        if request.deviceIDs.isEmpty {
            guard request.count == -1 || request.count == 1 else {
                throw ComposeError.unsupported("service '\(serviceName)' requests \(request.count) GPUs; the Apple virtio-gpu backend exposes one GPU")
            }
        } else {
            guard request.count == 0, request.deviceIDs == ["0"] else {
                throw ComposeError.unsupported("service '\(serviceName)' requests GPU device IDs \(request.deviceIDs.joined(separator: ",")); the Apple virtio-gpu backend exposes only device 0")
            }
        }
    }

    private func optionalGPUStringField(_ name: String, in object: [String: ComposeValue]) throws -> String? {
        guard let value = object[name] else {
            return nil
        }
        guard case let .string(string) = value else {
            throw ComposeError.invalidProject("GPU request \(name) must be a string")
        }
        return string
    }

    private func optionalGPUCountField(_ name: String, in object: [String: ComposeValue]) throws -> String? {
        guard let value = object[name] else {
            return nil
        }
        switch value {
        case let .number(number):
            let decimal = NSDecimalNumber(decimal: number)
            guard decimal.doubleValue.rounded() == decimal.doubleValue else {
                throw ComposeError.invalidProject("GPU request \(name) must be 'all' or an integer")
            }
            return decimal.stringValue
        case let .string(string):
            guard string == "all" || Int(string) != nil else {
                throw ComposeError.invalidProject("GPU request \(name) must be 'all' or an integer")
            }
            return string == "all" ? "-1" : string
        default:
            throw ComposeError.invalidProject("GPU request \(name) must be 'all' or an integer")
        }
    }

    private func optionalGPUStringArrayField(_ name: String, in object: [String: ComposeValue]) throws -> [String]? {
        guard let value = object[name] else {
            return nil
        }
        guard case let .array(values) = value else {
            throw ComposeError.invalidProject("GPU request \(name) must be a list")
        }
        return try values.map {
            guard case let .string(string) = $0 else {
                throw ComposeError.invalidProject("GPU request \(name) entries must be strings")
            }
            return string
        }
    }

    private func optionalGPUStringMapField(_ name: String, in object: [String: ComposeValue]) throws -> [String: String]? {
        guard let value = object[name] else {
            return nil
        }
        guard case let .object(values) = value else {
            throw ComposeError.invalidProject("GPU request \(name) must be a mapping")
        }
        return try values.mapValues {
            guard case let .string(string) = $0 else {
                throw ComposeError.invalidProject("GPU request \(name) values must be strings")
            }
            return string
        }
    }

    private func csvQuoteIfNeeded(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func runtimeDeviceArgument(_ value: ComposeValue) throws -> String {
        switch value {
        case let .string(spec):
            return try runtimeDeviceArgument(spec)
        case let .object(object):
            guard case let .string(source)? = object["source"] else {
                throw ComposeError.invalidProject("missing device source")
            }
            let target = try optionalStringField("target", in: object)
            let permissions = try optionalStringField("permissions", in: object)

            return try runtimeDeviceArgument(source: source, target: target, permissions: permissions)
        default:
            throw ComposeError.invalidProject("invalid device value")
        }
    }

    private func runtimeDeviceArgument(_ spec: String) throws -> String {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else {
            throw ComposeError.invalidProject("invalid device string")
        }

        let source = parts[0]
        let target = parts.count >= 2 ? parts[1] : nil
        let permissions = parts.count == 3 ? parts[2] : nil
        return try runtimeDeviceArgument(source: source, target: target, permissions: permissions)
    }

    private func runtimeDeviceArgument(source: String, target: String?, permissions: String?) throws -> String {
        guard isAbsoluteDevicePath(source) else {
            throw ComposeError.invalidProject("device source must be absolute")
        }
        if let target, !isAbsoluteDevicePath(target) {
            throw ComposeError.invalidProject("device target must be absolute")
        }
        if let permissions, !isDevicePermissions(permissions) {
            throw ComposeError.invalidProject("invalid device permissions")
        }

        let spec: String = if let target, let permissions {
            "\(source):\(target):\(permissions)"
        } else if let target {
            "\(source):\(target)"
        } else if let permissions {
            "\(source):\(permissions)"
        } else {
            source
        }
        _ = try Parser.devices([spec])
        return spec
    }

    private func optionalStringField(_ name: String, in object: [String: ComposeValue]) throws -> String? {
        guard let value = object[name] else {
            return nil
        }
        guard case let .string(rawValue) = value else {
            throw ComposeError.invalidProject("device \(name) must be a string")
        }
        return rawValue
    }

    private func isAbsoluteDevicePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.isEmpty
    }

    private func isDevicePermissions(_ value: String) -> Bool {
        let allowed = Set("rwm")
        return !value.isEmpty && value.allSatisfy { allowed.contains($0) }
    }

    /// Canonicalizes one Compose host entry into the typed runtime hosts entry.
    func runtimeHostEntry(_ raw: String, service: ComposeService) throws -> ContainerConfiguration.HostEntry {
        let separator = raw.firstIndex(of: "=") ?? raw.firstIndex(of: ":")
        guard let separator else {
            throw ComposeError.invalidProject("service '\(service.name)' extra_hosts entry '\(raw)' must use HOST=IP or HOST:IP")
        }

        let hostname = String(raw[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAddress = String(raw[raw.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' extra_hosts entry '\(raw)' has an empty hostname")
        }
        guard !rawAddress.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' extra_hosts entry '\(raw)' has an empty IP address")
        }

        if rawAddress == ContainerConfiguration.HostEntry.hostGatewayAddress {
            return ContainerConfiguration.HostEntry(
                ipAddress: ContainerConfiguration.HostEntry.hostGatewayAddress,
                hostnames: [hostname],
            )
        }

        let ipAddress = unbracketedIPAddress(rawAddress)
        guard (try? IPAddress(ipAddress)) != nil else {
            throw ComposeError.invalidProject("service '\(service.name)' extra_hosts entry '\(raw)' has invalid IP address '\(rawAddress)'")
        }
        return ContainerConfiguration.HostEntry(ipAddress: ipAddress, hostnames: [hostname])
    }

    /// Canonicalizes one Compose host entry into the runtime `--add-host` form.
    func runtimeExtraHostArgument(_ raw: String, service: ComposeService) throws -> String {
        let entry = try runtimeHostEntry(raw, service: service)
        return entry.hostnames.map { "\($0):\(entry.ipAddress)" }.joined(separator: " ")
    }

    /// Removes brackets accepted by Compose around IPv6 literals.
    func unbracketedIPAddress(_ value: String) -> String {
        if value.hasPrefix("["), value.hasSuffix("]") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
