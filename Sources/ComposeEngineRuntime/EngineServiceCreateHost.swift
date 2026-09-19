// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
import ComposeRuntimeSPI
import Foundation

extension EngineServiceCreateRequest {
    static func hostConfiguration(
        _ plan: ContainerServiceCreatePlan, ports: [ComposePublishedPortBinding], mounts: [ComposeResolvedMount]
    ) throws -> EngineCreateValue {
        let options = plan.launchOptions
        var host: [String: EngineCreateValue] = [
            "AutoRemove": .boolean(plan.autoRemove), "Init": .boolean(options.initEnabled),
            "Annotations": .dictionary(plan.annotations), "PortBindings": try portBindings(ports),
            "Mounts": .array(try mounts.map(mountConfiguration)),
            "Dns": .strings(options.dnsServers), "DnsSearch": .strings(options.dnsSearch),
            "DnsOptions": .strings(options.dnsOptions), "Sysctls": .dictionary(plan.sysctls),
            "ExtraHosts": .strings(plan.hosts.flatMap { host in host.hostnames.map { "\($0):\(host.ipAddress)" } }),
            "RestartPolicy": .object([
                "Name": .string(plan.restartPolicy.mode.rawValue),
                "MaximumRetryCount": .integer(Int64(plan.restartPolicy.maximumRetryCount ?? 0)),
            ]),
        ]
        var logging: [String: EngineCreateValue] = ["Config": .dictionary(plan.logging.options)]
        logging["Type"] = plan.logging.driver.map(EngineCreateValue.string)
        host["LogConfig"] = .object(logging)
        host["Runtime"] = options.runtime.map(EngineCreateValue.string)
        if let mode = plan.networkAttachments.first?.network, ["none", "host", "default"].contains(mode) {
            guard plan.networkAttachments.count == 1 else {
                throw ComposeError.invalidProject("Special network mode cannot be combined with attachments")
            }
            host["NetworkMode"] = .string(mode)
        }
        host["CgroupParent"] = plan.cgroupParent.map(EngineCreateValue.string)
        host["MemoryReservation"] = plan.memoryReservationInBytes.map(EngineCreateValue.integer)
        host["MemorySwap"] = plan.memorySwapLimitInBytes.map(EngineCreateValue.integer)
        if let shares = plan.cpuShares {
            guard let value = Int64(exactly: shares) else { throw ComposeError.invalidProject("CPU shares overflow") }
            host["CpuShares"] = .integer(value)
        }
        for (key, value) in [
            ("Isolation", options.namespaces.isolation), ("PidMode", options.namespaces.pid),
            ("CgroupnsMode", options.namespaces.cgroup), ("IpcMode", options.namespaces.ipc),
            ("UTSMode", options.namespaces.uts), ("UsernsMode", options.namespaces.user),
        ] { host[key] = value.map(EngineCreateValue.string) }
        try addResources(options.resources, to: &host)
        addSecurity(options.security, to: &host)
        var tmpfs: [String: EngineCreateValue] = [:]
        for entry in plan.tmpfs {
            let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard !parts[0].isEmpty, tmpfs[String(parts[0])] == nil else {
                throw ComposeError.invalidProject("Empty or duplicate tmpfs destination")
            }
            tmpfs[String(parts[0])] = .string(parts.count == 2 ? String(parts[1]) : "")
        }
        host["Tmpfs"] = .object(tmpfs)
        return .object(host)
    }

    private static func addSecurity(_ security: ComposeSecurityOptions, to host: inout [String: EngineCreateValue]) {
        host["Privileged"] = .boolean(security.privileged)
        host["ReadonlyRootfs"] = .boolean(security.readOnlyRootFilesystem)
        host["GroupAdd"] = .strings(security.supplementalGroups)
        host["CapAdd"] = .strings(security.capabilitiesAdded)
        host["CapDrop"] = .strings(security.capabilitiesDropped)
        host["SecurityOpt"] = .strings(security.options)
        host["DeviceCgroupRules"] = .strings(security.deviceCgroupRules)
    }

    private static func addResources(
        _ resources: ComposeResourceOptions, to host: inout [String: EngineCreateValue]
    ) throws {
        for (key, value) in [
            ("OomScoreAdj", resources.oomScoreAdjustment), ("PidsLimit", resources.pidsLimit),
            ("CpuPeriod", resources.cpuPeriod), ("CpuQuota", resources.cpuQuota),
        ] { host[key] = value.map { .integer(Int64($0)) } }
        host["CpusetCpus"] = resources.cpuSet.map(EngineCreateValue.string)
        for (key, value) in [("Memory", resources.memoryLimit), ("ShmSize", resources.sharedMemorySize)] {
            if let value {
                let bytes = try byteQuantity(value)
                host[key] = .integer(bytes)
            }
        }
        if let cpus = resources.cpus {
            guard !cpus.isEmpty, cpus.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  cpus.filter({ $0 == "." }).count <= 1,
                  let decimal = Decimal(string: cpus, locale: Locale(identifier: "en_US_POSIX")), decimal >= 0 else {
                throw ComposeError.invalidProject("Invalid prepared CPU quantity")
            }
            let nanos = decimal * 1_000_000_000
            guard nanos <= Decimal(Int64.max) else { throw ComposeError.invalidProject("CPU quantity overflow") }
            let value = NSDecimalNumber(decimal: nanos).int64Value
            guard Decimal(value) == nanos else {
                throw ComposeError.invalidProject("CPU quantity exceeds nanocpu precision")
            }
            host["NanoCpus"] = .integer(value)
        }
        host["Ulimits"] = .array(try resources.ulimits.map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { throw ComposeError.invalidProject("Invalid ulimit") }
            let limits = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let soft = Int64(limits[0]), let hard = Int64(limits.last!), soft >= -1, hard >= -1 else {
                throw ComposeError.invalidProject("Invalid ulimit bounds")
            }
            return .object(["Name": .string(String(parts[0])), "Soft": .integer(soft), "Hard": .integer(hard)])
        })
    }
}
