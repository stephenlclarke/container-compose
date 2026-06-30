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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import ContainerAPIClient
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
import Foundation

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
    func unsupportedRuntimeStringFields(service: ComposeService) -> [(composeName: String, value: String, reason: String)] {
        [
            ("cgroup", service.cgroup, "cgroup namespace support needs an apple/container runtime gap PR"),
            ("cgroup_parent", service.cgroupParent, "cgroup parent support needs an apple/container runtime gap PR"),
            ("ipc", service.ipc, "IPC namespace support needs an apple/container runtime gap PR"),
            ("isolation", service.isolation, "isolation support needs an apple/container runtime gap PR"),
            ("userns_mode", service.usernsMode, "user namespace support needs an apple/container runtime gap PR"),
            ("uts", service.uts, "UTS namespace support needs an apple/container runtime gap PR"),
        ].compactMap { composeName, value, reason in
            guard let value, !value.isEmpty else {
                return nil
            }
            return (composeName, value, reason)
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

    /// Returns unsupported CPU scheduler fields beyond the supported `cpus` limit.
    func unsupportedCPUResourceFields(service: ComposeService) -> [(composeName: String, value: String, reason: String)] {
        let reason = "advanced CPU resource support needs an apple/container runtime gap PR"
        var fields: [(composeName: String, value: String, reason: String)] = []
        appendUnsupportedIntegerField("cpu_count", value: service.cpuCount, reason: reason, to: &fields)
        appendUnsupportedFloatingPointField("cpu_percent", value: service.cpuPercent, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_period", value: service.cpuPeriod, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_quota", value: service.cpuQuota, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_rt_period", value: service.cpuRealtimePeriod, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_rt_runtime", value: service.cpuRealtimeRuntime, reason: reason, to: &fields)
        if let cpuset = service.cpuset, !cpuset.isEmpty {
            fields.append(("cpuset", cpuset, reason))
        }
        appendUnsupportedIntegerField("cpu_shares", value: service.cpuShares, reason: reason, to: &fields)
        return fields
    }

    /// Returns unsupported memory, OOM, and process resource controls beyond `mem_limit`.
    func unsupportedMemoryAndProcessResourceFields(service: ComposeService) -> [(composeName: String, value: String, reason: String)] {
        let reason = "memory, OOM, and process resource support needs an apple/container runtime gap PR"
        var fields: [(composeName: String, value: String, reason: String)] = []
        appendUnsupportedStringField("mem_reservation", value: service.memReservation, reason: reason, to: &fields)
        appendUnsupportedStringField("memswap_limit", value: service.memSwapLimit, reason: reason, to: &fields)
        appendUnsupportedStringField("mem_swappiness", value: service.memSwappiness, reason: reason, to: &fields)
        if service.oomKillDisable == true {
            fields.append(("oom_kill_disable", "true", reason))
        }
        appendUnsupportedIntegerField("oom_score_adj", value: service.oomScoreAdj, reason: reason, to: &fields)
        appendUnsupportedIntegerField("pids_limit", value: service.pidsLimit, reason: reason, to: &fields)
        return fields
    }

    /// Returns unsupported user and security option fields.
    func unsupportedUserAndSecurityOptionFields(service: ComposeService) -> [(composeName: String, value: String, reason: String)] {
        var fields: [(composeName: String, value: String, reason: String)] = []
        if let group = service.groupAdd?.first(where: { !$0.isEmpty }) {
            fields.append(("group_add", group, "supplemental group support needs an apple/container runtime gap PR"))
        }
        if let securityOption = service.securityOpt?.first(where: { !$0.isEmpty }) {
            fields.append(("security_opt", securityOption, "security option support needs an apple/container runtime gap PR"))
        }
        return fields
    }

    /// Returns unsupported GPU and credential access fields.
    func unsupportedDeviceAccessFields(service: ComposeService) -> [(composeName: String, reason: String)] {
        var fields: [(composeName: String, reason: String)] = []
        if service.credentialSpec != nil {
            fields.append(("credential_spec", "credential spec support needs an apple/container runtime gap PR"))
        }
        if let gpus = service.gpus, !gpus.isEmpty {
            fields.append(("gpus", "GPU device access support needs an apple/container runtime gap PR"))
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
    func unsupportedServiceMetadataAndLoggingFields(service: ComposeService) -> [(composeName: String, reason: String)] {
        var fields: [(composeName: String, reason: String)] = []
        let loggingReason = "service logging driver/options need an apple/container runtime gap PR"
        if !isSupportedRuntimeLogging(service.logging) {
            fields.append(("logging", loggingReason))
        }
        if let logDriver = service.logDriver,
           !logDriver.isEmpty,
           !isSupportedRuntimeLogDriver(logDriver)
        {
            fields.append(("log_driver", loggingReason))
        }
        if !isSupportedLegacyRuntimeLogOptions(service: service) {
            fields.append(("log_opt", loggingReason))
        }
        if let storageOptions = service.storageOptions, !storageOptions.isEmpty {
            fields.append(("storage_opt", "per-container storage options need an apple/container rootfs storage runtime gap PR"))
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
        guard let domainName = service.domainName?.trimmingCharacters(in: .whitespacesAndNewlines), !domainName.isEmpty else {
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
            try validateBlockIODevicePath(device.path, serviceName: service.name, field: "blkio_config.weight_device.path")
            try validateBlockIOWeight(device.weight, serviceName: service.name, field: "blkio_config.weight_device.weight")
            result.append("device=\(device.path),weight=\(device.weight)")
        }
        try appendThrottleArguments(blkio.deviceReadBps, key: "read-bps", field: "blkio_config.device_read_bps", serviceName: service.name, to: &result)
        try appendThrottleArguments(blkio.deviceWriteBps, key: "write-bps", field: "blkio_config.device_write_bps", serviceName: service.name, to: &result)
        try appendThrottleArguments(blkio.deviceReadIOps, key: "read-iops", field: "blkio_config.device_read_iops", serviceName: service.name, to: &result)
        try appendThrottleArguments(blkio.deviceWriteIOps, key: "write-iops", field: "blkio_config.device_write_iops", serviceName: service.name, to: &result)
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

    private func runtimeDeviceArgument(_ value: ComposeValue) throws -> String {
        switch value {
        case .string(let spec):
            return try runtimeDeviceArgument(spec)
        case .object(let object):
            guard case .string(let source)? = object["source"] else {
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

        let spec: String
        if let target, let permissions {
            spec = "\(source):\(target):\(permissions)"
        } else if let target {
            spec = "\(source):\(target)"
        } else if let permissions {
            spec = "\(source):\(permissions)"
        } else {
            spec = source
        }
        _ = try Parser.devices([spec])
        return spec
    }

    private func optionalStringField(_ name: String, in object: [String: ComposeValue]) throws -> String? {
        guard let value = object[name] else {
            return nil
        }
        guard case .string(let rawValue) = value else {
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

    /// Converts Compose `blkio_config` into typed OCI block I/O runtime data.
    func runtimeBlockIO(service: ComposeService) throws -> LinuxBlockIO? {
        guard let blkio = service.blkioConfig else {
            return nil
        }
        var weight: UInt16?
        if let rawWeight = blkio.weight {
            try validateBlockIOWeight(rawWeight, serviceName: service.name, field: "blkio_config.weight")
            weight = UInt16(rawWeight)
        }

        let weightDevices = try (blkio.weightDevice ?? []).map { device in
            try validateBlockIODevicePath(device.path, serviceName: service.name, field: "blkio_config.weight_device.path")
            try validateBlockIOWeight(device.weight, serviceName: service.name, field: "blkio_config.weight_device.weight")
            let id = try blockIODeviceID(device.path, serviceName: service.name)
            return LinuxWeightDevice(major: id.major, minor: id.minor, weight: UInt16(device.weight), leafWeight: nil)
        }

        return try LinuxBlockIO(
            weight: weight,
            leafWeight: nil,
            weightDevice: weightDevices,
            throttleReadBpsDevice: blockIOThrottleDevices(blkio.deviceReadBps, field: "blkio_config.device_read_bps", serviceName: service.name, parseRate: blockIOByteRate),
            throttleWriteBpsDevice: blockIOThrottleDevices(blkio.deviceWriteBps, field: "blkio_config.device_write_bps", serviceName: service.name, parseRate: blockIOByteRate),
            throttleReadIOPSDevice: blockIOThrottleDevices(blkio.deviceReadIOps, field: "blkio_config.device_read_iops", serviceName: service.name, parseRate: blockIOIntegerRate),
            throttleWriteIOPSDevice: blockIOThrottleDevices(blkio.deviceWriteIOps, field: "blkio_config.device_write_iops", serviceName: service.name, parseRate: blockIOIntegerRate),
        )
    }

    func blockIOThrottleDevices(
        _ devices: [ComposeBlkioThrottleDevice]?,
        field: String,
        serviceName: String,
        parseRate: (String, String, String) throws -> UInt64,
    ) throws -> [LinuxThrottleDevice] {
        try (devices ?? []).map { device in
            try validateBlockIODevicePath(device.path, serviceName: serviceName, field: "\(field).path")
            let id = try blockIODeviceID(device.path, serviceName: serviceName)
            let rate = try parseRate(device.rate, "\(field).rate", serviceName)
            return LinuxThrottleDevice(major: id.major, minor: id.minor, rate: rate)
        }
    }

    func blockIODeviceID(_ value: String, serviceName: String) throws -> (major: Int64, minor: Int64) {
        if value.hasPrefix("/") {
            var info = stat()
            guard stat(value, &info) == 0 else {
                throw ComposeError.invalidProject("service '\(serviceName)' uses blkio_config device path '\(value)', but the path could not be statted")
            }
            let rawDevice = UInt32(bitPattern: info.st_rdev)
            return (Int64((rawDevice >> 24) & 0xFF), Int64(rawDevice & 0x00FF_FFFF))
        }

        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int64(parts[0]), let minor = Int64(parts[1]) else {
            throw ComposeError.invalidProject("service '\(serviceName)' uses blkio_config device '\(value)'; device must be an absolute path or '<major>:<minor>'")
        }
        return (major, minor)
    }

    func blockIOByteRate(_ value: String, field: String, serviceName: String) throws -> UInt64 {
        let bytes: Double
        do {
            bytes = try Measurement<UnitInformationStorage>.parse(parsing: value).converted(to: .bytes).value
        } catch {
            throw ComposeError.invalidProject("service '\(serviceName)' uses \(field) '\(value)'; block I/O byte rates must be sizes")
        }
        guard bytes.isFinite, bytes >= 0, bytes <= Double(UInt64.max) else {
            throw ComposeError.invalidProject("service '\(serviceName)' uses \(field) '\(value)'; block I/O byte rate is outside the supported range")
        }
        return UInt64(bytes)
    }

    func blockIOIntegerRate(_ value: String, field: String, serviceName: String) throws -> UInt64 {
        guard let rate = UInt64(value) else {
            throw ComposeError.invalidProject("service '\(serviceName)' uses \(field) '\(value)'; block I/O throttle rates must be non-negative integers")
        }
        return rate
    }

    func appendThrottleArguments(
        _ devices: [ComposeBlkioThrottleDevice]?,
        key: String,
        field: String,
        serviceName: String,
        to result: inout [String],
    ) throws {
        for device in devices ?? [] {
            try validateBlockIODevicePath(device.path, serviceName: serviceName, field: "\(field).path")
            guard UInt64(device.rate) != nil else {
                throw ComposeError.invalidProject("service '\(serviceName)' uses \(field).rate '\(device.rate)'; block I/O throttle rates must be non-negative integers")
            }
            result.append("device=\(device.path),\(key)=\(device.rate)")
        }
    }

    func validateBlockIOWeight(_ weight: Int, serviceName: String, field: String) throws {
        guard (10 ... 1000).contains(weight) else {
            throw ComposeError.invalidProject("service '\(serviceName)' uses \(field) \(weight); block I/O weight must be between 10 and 1000")
        }
    }

    func validateBlockIODevicePath(_ path: String, serviceName: String, field: String) throws {
        guard !path.isEmpty else {
            throw ComposeError.invalidProject("service '\(serviceName)' uses \(field) with an empty device path")
        }
        if path.contains(",") {
            throw ComposeError.invalidProject("service '\(serviceName)' uses \(field) '\(path)'; block I/O device paths must not contain commas")
        }
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
            return ContainerConfiguration.HostEntry(ipAddress: ContainerConfiguration.HostEntry.hostGatewayAddress, hostnames: [hostname])
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
