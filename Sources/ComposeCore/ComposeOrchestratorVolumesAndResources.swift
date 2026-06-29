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
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
import Foundation

extension ComposeOrchestrator {
    /// Returns unsupported service-level volume driver fields.
    func unsupportedServiceVolumeShortcutFields(service: ComposeService) -> [(composeName: String, reason: String)] {
        var fields: [(composeName: String, reason: String)] = []
        if let volumeDriver = service.volumeDriver, !volumeDriver.isEmpty, volumeDriver.lowercased() != "local" {
            fields.append(("volume_driver", "non-local service volume drivers need an apple/container volume driver runtime gap PR"))
        }
        return fields
    }

    /// Validates service-to-service volume inheritance before side effects.
    func validateVolumesFromSupport(service: ComposeService, project: ComposeProject) throws {
        _ = try volumesFromReferences(service: service, project: project)
    }

    /// Resolves external `volumes_from` references through direct container
    /// inspection before any runtime resources are created.
    func resolveExternalVolumeMounts(project: ComposeProject, services: [ComposeService]) async throws -> ExternalVolumeMounts {
        var resolved: ExternalVolumeMounts = [:]
        let references = try externalVolumesFromReferences(project: project, services: services)
        for reference in references.sorted(by: { $0.containerName < $1.containerName }) where resolved[reference.containerName] == nil {
            guard let container = try await discoveryManager.getContainer(id: reference.containerName) else {
                throw ComposeError.invalidProject("service '\(reference.serviceName)' volumes_from '\(reference.rawValue)' references missing external container '\(reference.containerName)'")
            }
            try validateExternalVolumeMounts(container, reference: reference)
            resolved[reference.containerName] = container.mounts
        }
        return resolved
    }

    /// Rejects external mounts that cannot be represented by apple/container
    /// create/run volume arguments.
    func validateExternalVolumeMounts(_ container: ComposeContainerSummary, reference: ExternalVolumesFromReference) throws {
        for mount in container.mounts {
            let fields = (mount.unsupportedFields ?? []).filter { $0 != "volume.nocopy" }
            guard fields.isEmpty else {
                let fieldList = fields.joined(separator: ", ")
                throw ComposeError.unsupported("service '\(reference.serviceName)' uses volumes_from '\(reference.rawValue)'; external container '\(reference.containerName)' has unsupported mount fields \(fieldList)")
            }
        }
    }

    /// Returns unsupported long-form service mount fields that cannot be
    /// represented by the current apple/container `container --volume/--tmpfs` mapping.
    func unsupportedServiceMountFields(service: ComposeService, project: ComposeProject) throws -> [String]? {
        var seen = Set<String>()
        let fields = try effectiveServiceVolumes(project: project, service: service)
            .flatMap { $0.unsupportedFields ?? [] }
            .filter { $0 != "volume.nocopy" }
            .filter { field in
                seen.insert(field).inserted
            }
        return fields.isEmpty ? nil : fields
    }

    /// Appends an unsupported string field only when Compose supplied a non-empty value.
    func appendUnsupportedStringField(
        _ composeName: String,
        value: String?,
        reason: String,
        to fields: inout [(composeName: String, value: String, reason: String)],
    ) {
        guard let value, !value.isEmpty else {
            return
        }
        fields.append((composeName, value, reason))
    }

    /// Appends an unsupported integer field only when Compose supplied a non-zero value.
    func appendUnsupportedIntegerField(
        _ composeName: String,
        value: Int?,
        reason: String,
        to fields: inout [(composeName: String, value: String, reason: String)],
    ) {
        guard let value, value != 0 else {
            return
        }
        fields.append((composeName, String(value), reason))
    }

    /// Appends an unsupported floating-point field only when Compose supplied a non-zero value.
    func appendUnsupportedFloatingPointField(
        _ composeName: String,
        value: Double?,
        reason: String,
        to fields: inout [(composeName: String, value: String, reason: String)],
    ) {
        guard let value, value != 0 else {
            return
        }
        let displayValue = value.rounded() == value ? String(Int(value)) : String(value)
        fields.append((composeName, displayValue, reason))
    }

    /// Validates the global `up --pull` policy before resources are created.
    func validatePullPolicy(_ policy: String?) throws {
        guard let policy, !policy.isEmpty else {
            return
        }
        if !["always", "missing", "if_not_present", "never"].contains(policy) {
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
        }
    }

    /// Validates the command-level `pull --policy` subset from Docker Compose.
    func validateComposePullPolicy(_ policy: String?) throws {
        guard let policy, !policy.isEmpty else {
            return
        }
        if !["always", "missing"].contains(policy) {
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
        }
    }

    /// Validates command-level `compose up` option combinations before runtime side effects.
    func validateUpOptions(_ options: ComposeUpOptions) throws {
        try validateTimeoutSeconds(options.timeout, command: "up")
        try validateTimeoutSeconds(options.waitTimeout, command: "up", option: "--wait-timeout")
        if options.build, options.noBuild {
            throw ComposeError.invalidProject("--build and --no-build are incompatible")
        }
        if options.wait, options.noStart {
            throw ComposeError.invalidProject("--wait and --no-start are incompatible")
        }
        if options.detach, options.abortOnContainerExit {
            throw ComposeError.invalidProject("--abort-on-container-exit and --detach are incompatible")
        }
        if options.detach, options.abortOnContainerFailure {
            throw ComposeError.invalidProject("--abort-on-container-failure and --detach are incompatible")
        }
        if options.detach, options.exitCodeFrom != nil {
            throw ComposeError.invalidProject("--exit-code-from and --detach are incompatible")
        }
        if options.wait, options.abortOnContainerExit || options.abortOnContainerFailure || options.exitCodeFrom != nil {
            throw ComposeError.invalidProject("--wait cannot be combined with exit-control options")
        }
        if options.noStart, options.abortOnContainerExit || options.abortOnContainerFailure || options.exitCodeFrom != nil {
            throw ComposeError.invalidProject("--no-start cannot be combined with exit-control options")
        }
        if options.noRecreate, options.renewAnonymousVolumes {
            throw ComposeError.invalidProject("--no-recreate and --renew-anon-volumes are incompatible")
        }
        if options.forceRecreate, options.noRecreate {
            throw ComposeError.invalidProject("--force-recreate and --no-recreate are incompatible")
        }
        if options.alwaysRecreateDeps, options.noRecreate {
            throw ComposeError.invalidProject("--always-recreate-deps and --no-recreate are incompatible")
        }
        if options.menu, options.abortOnContainerExit || options.abortOnContainerFailure || options.exitCodeFrom != nil {
            throw ComposeError.unsupported("up --menu with exit-control options")
        }
    }

    /// Validates command-level `compose create` option combinations before runtime side effects.
    func validateCreateOptions(_ options: ComposeCreateOptions) throws {
        if options.build, options.noBuild {
            throw ComposeError.invalidProject("--build and --no-build are incompatible")
        }
        if options.noRecreate, options.renewAnonymousVolumes {
            throw ComposeError.invalidProject("--no-recreate and --renew-anon-volumes are incompatible")
        }
        if options.forceRecreate, options.noRecreate {
            throw ComposeError.invalidProject("--force-recreate and --no-recreate are incompatible")
        }
    }

    /// Parses Docker Compose `--scale SERVICE=NUM` overrides.
    func parseScaleOverrides(project: ComposeProject, scales: [String]) throws -> [String: Int] {
        var overrides: [String: Int] = [:]
        for scale in scales {
            let parts = scale.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ComposeError.invalidProject("--scale requires SERVICE=NUM")
            }
            let serviceName = parts[0]
            guard project.services[serviceName] != nil else {
                throw ComposeError.invalidProject("unknown service '\(serviceName)'")
            }
            guard let count = Int(parts[1]), count >= 0 else {
                throw ComposeError.invalidProject("--scale for service '\(serviceName)' must be a non-negative integer")
            }
            overrides[serviceName] = count
        }
        return overrides
    }

    /// Returns the desired replica count for a service after CLI overrides.
    func serviceReplicaCount(_ service: ComposeService, scaleOverrides: [String: Int]) throws -> Int {
        if service.provider != nil {
            return 0
        }
        let count = scaleOverrides[service.name] ?? service.scale ?? 1
        guard count >= 0 else {
            throw ComposeError.invalidProject("service '\(service.name)' scale must be a non-negative integer")
        }
        return count
    }

    /// Returns whether a service has an explicit scale source that should prune extra replicas.
    func shouldPruneServiceReplicas(_ service: ComposeService, scaleOverrides: [String: Int]) -> Bool {
        scaleOverrides[service.name] != nil || service.scale != nil
    }

    /// Returns declared services whose existing replicas should not be treated as orphans.
    func orphanProtectedServiceNames(project: ComposeProject, scaleOverrides: [String: Int]) -> Set<String> {
        Set(project.services.values.filter { service in
            !shouldPruneServiceReplicas(service, scaleOverrides: scaleOverrides)
        }.map(\.name))
    }

    /// Validates scaled services that would collide under current local runtime primitives.
    func validateReplicaSupport(
        services: [ComposeService],
        scaleOverrides: [String: Int],
    ) throws {
        for service in services {
            let replicaCount = try serviceReplicaCount(service, scaleOverrides: scaleOverrides)
            guard replicaCount > 1 else {
                continue
            }
            if let containerName = service.containerName, !containerName.isEmpty {
                throw ComposeError.invalidProject("service '\(service.name)' uses container_name; scale greater than 1 requires Compose-managed replica names")
            }
            if let ports = service.ports, !ports.isEmpty {
                try validateScaledPublishedPorts(ports, serviceName: service.name, replicaCount: replicaCount)
            }
            if hasExplicitMACAddress(service) {
                throw ComposeError.unsupported("service '\(service.name)' uses mac_address; scaled MAC addresses would collide across replicas")
            }
        }
    }

    /// Returns true when a service sets a fixed MAC address on itself or a network.
    func hasExplicitMACAddress(_ service: ComposeService) -> Bool {
        if nonEmpty(service.macAddress) != nil {
            return true
        }
        return (service.networkOptions ?? [:]).values.contains { nonEmpty($0.macAddress) != nil }
    }

    /// Validates `create --pull`, including Docker Compose's build policy.
    func validateCreatePullPolicy(_ policy: String?) throws {
        guard let policy, !policy.isEmpty else {
            return
        }
        if !["always", "missing", "if_not_present", "never", "build"].contains(policy) {
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
        }
    }

    /// Validates `compose stats` options before invoking runtime stats.
    func validateStatsOptions(_ options: ComposeStatsOptions) throws {
        try validateComposeStatsFormat(options.format)
    }

    /// Validates service port mappings before resource creation.
    func validatePublishedPorts(services: [ComposeService]) throws {
        for service in services {
            try validatePublishedPorts(service.ports ?? [], serviceName: service.name)
        }
    }

    /// Validates one service's port mappings before they reach apple/container.
    func validatePublishedPorts(_ ports: [String], serviceName: String) throws {
        for port in ports {
            try validatePublishedPort(port, serviceName: serviceName)
        }
    }

    /// Validates one Docker Compose published port mapping.
    func validatePublishedPort(_ value: String, serviceName: String) throws {
        _ = try parsePublishedPortMapping(value, serviceName: serviceName)
    }

    /// Validates that a scaled service has enough explicit host ports for every replica.
    func validateScaledPublishedPorts(_ ports: [String], serviceName: String, replicaCount: Int) throws {
        guard replicaCount > 1 else {
            return
        }
        for port in ports {
            let mapping = try parsePublishedPortMapping(port, serviceName: serviceName)
            guard let hostRange = mapping.hostRange else {
                continue
            }
            let requiredHostPorts = mapping.targetRange.count * replicaCount
            guard hostRange.count >= requiredHostPorts else {
                throw ComposeError.unsupported("service '\(serviceName)' publishes '\(port)'; scaled published ports require at least \(requiredHostPorts) explicit host ports for \(replicaCount) replicas")
            }
        }
    }

    /// Parses one Compose port mapping with explicit or dynamic host ports.
    func parsePublishedPortMapping(_ value: String, serviceName: String) throws -> ParsedPublishedPortMapping {
        let protocolSplit = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let rawBinding = protocolSplit.first, !rawBinding.isEmpty else {
            throw ComposeError.invalidProject("service '\(serviceName)' has an empty port mapping")
        }
        let protocolName = try normalizedPortProtocol(protocolSplit.count == 2 ? protocolSplit[1] : "tcp")
        let parts = rawBinding.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 1 || parts.last?.isEmpty == false else {
            throw ComposeError.invalidProject("service '\(serviceName)' has invalid port mapping '\(value)'")
        }
        let target = parts[parts.count - 1]
        let targetRange = try portRange(target, field: "container", mapping: value, serviceName: serviceName)
        guard parts.count >= 2 else {
            return ParsedPublishedPortMapping(
                hostAddress: nil,
                hostRange: nil,
                targetRange: targetRange,
                protocolName: protocolName,
            )
        }

        let published = parts[parts.count - 2]
        let hostParts = parts.dropLast(2)
        let hostAddress = hostParts.isEmpty ? nil : hostParts.joined(separator: ":")
        guard !published.isEmpty else {
            return ParsedPublishedPortMapping(
                hostAddress: hostAddress,
                hostRange: nil,
                targetRange: targetRange,
                protocolName: protocolName,
            )
        }
        guard isExplicitHostPort(published) else {
            throw ComposeError.invalidProject("service '\(serviceName)' has invalid host port range '\(value)'")
        }
        return try ParsedPublishedPortMapping(
            hostAddress: hostAddress,
            hostRange: portRange(published, field: "host", mapping: value, serviceName: serviceName),
            targetRange: targetRange,
            protocolName: protocolName,
        )
    }

    /// Returns concrete apple/container `--publish` arguments for a service replica.
    func publishedPortArguments(
        ports: [String],
        serviceName: String,
        replicaIndex: Int?,
        replicaCount: Int?,
    ) throws -> [String] {
        guard let replicaIndex,
              let replicaCount,
              replicaCount > 1
        else {
            for port in ports {
                try validatePublishedPort(port, serviceName: serviceName)
            }
            return try ports.flatMap {
                try publishedPortArguments(port: $0, serviceName: serviceName)
            }
        }
        guard replicaIndex >= 1, replicaIndex <= replicaCount else {
            throw ComposeError.invalidProject("container index must be between 1 and \(replicaCount)")
        }
        return try ports.flatMap { port in
            try publishedPortArguments(
                port: port,
                serviceName: serviceName,
                replicaIndex: replicaIndex,
                replicaCount: replicaCount,
            )
        }
    }

    /// Expands one Compose port mapping into concrete apple/container `--publish` values.
    func publishedPortArguments(port: String, serviceName: String) throws -> [String] {
        let mapping = try parsePublishedPortMapping(port, serviceName: serviceName)
        guard let hostRange = mapping.hostRange else {
            return try dynamicPublishedPortArguments(mapping)
        }
        guard hostRange.count == mapping.targetRange.count else {
            throw ComposeError.invalidProject("service '\(serviceName)' has mismatched port ranges '\(port)'")
        }
        return (0 ..< mapping.targetRange.count).map { offset in
            formatPublishedPort(
                hostAddress: mapping.hostAddress,
                hostPort: hostRange.start + offset,
                targetPort: mapping.targetRange.start + offset,
                protocolName: mapping.protocolName,
            )
        }
    }

    /// Splits one scaled Compose port range into this replica's concrete mappings.
    func publishedPortArguments(
        port: String,
        serviceName: String,
        replicaIndex: Int,
        replicaCount: Int,
    ) throws -> [String] {
        let mapping = try parsePublishedPortMapping(port, serviceName: serviceName)
        guard let hostRange = mapping.hostRange else {
            return try dynamicPublishedPortArguments(mapping)
        }
        let targetCount = mapping.targetRange.count
        let requiredHostPorts = targetCount * replicaCount
        guard hostRange.count >= requiredHostPorts else {
            throw ComposeError.unsupported("service '\(serviceName)' publishes '\(port)'; scaled published ports require at least \(requiredHostPorts) explicit host ports for \(replicaCount) replicas")
        }

        let replicaOffset = (replicaIndex - 1) * targetCount
        return (0 ..< targetCount).map { offset in
            formatPublishedPort(
                hostAddress: mapping.hostAddress,
                hostPort: hostRange.start + replicaOffset + offset,
                targetPort: mapping.targetRange.start + offset,
                protocolName: mapping.protocolName,
            )
        }
    }

    /// Allocates concrete host ports for a dynamic Compose port mapping.
    func dynamicPublishedPortArguments(_ mapping: ParsedPublishedPortMapping) throws -> [String] {
        try (0 ..< mapping.targetRange.count).map { offset in
            let hostPort = try options.hostPortAllocator(mapping.hostAddress, mapping.protocolName)
            return formatPublishedPort(
                hostAddress: mapping.hostAddress,
                hostPort: Int(hostPort),
                targetPort: mapping.targetRange.start + offset,
                protocolName: mapping.protocolName,
            )
        }
    }

    /// Formats a normalized published-port mapping for apple/container.
    func formatPublishedPort(hostAddress: String?, hostPort: Int, targetPort: Int, protocolName: String) -> String {
        var value = "\(hostPort):\(targetPort)"
        if let hostAddress, !hostAddress.isEmpty {
            value = "\(formatPublishedPortHostAddress(hostAddress)):\(value)"
        }
        if protocolName != "tcp" {
            value += "/\(protocolName)"
        }
        return value
    }

    /// Brackets IPv6 host literals so colon-delimited publish strings remain parseable.
    func formatPublishedPortHostAddress(_ hostAddress: String) -> String {
        let value = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains(":"), !value.hasPrefix("[") else {
            return value
        }
        return "[\(value)]"
    }

    /// Returns true when a publish field names concrete apple/container host ports.
    func isExplicitHostPort(_ value: String) -> Bool {
        let bounds = value.split(separator: "-", omittingEmptySubsequences: false)
        guard [1, 2].contains(bounds.count) else {
            return false
        }
        let ports = bounds.compactMap { UInt16($0) }
        guard ports.count == bounds.count, ports.allSatisfy({ $0 > 1 }) else {
            return false
        }
        return ports.count == 1 || ports[0] <= ports[1]
    }

    /// Validates a Compose CLI shutdown timeout before runtime side effects.
    func validateTimeoutSeconds(_ timeout: Int?, command: String, option: String = "--timeout") throws {
        guard let timeout else {
            return
        }
        guard timeout >= 0, timeout <= Int(Int32.max) else {
            throw ComposeError.invalidProject("\(command) \(option) must be between 0 and \(Int32.max) seconds")
        }
    }

    /// Validates the `down --rmi` policy before removing resources.
    func downImageRemovalPolicy(_ policy: String?) throws -> DownImageRemovalPolicy {
        guard let policy else {
            return .none
        }
        switch policy {
        case "all":
            return .all
        case "local":
            return .local
        default:
            throw ComposeError.invalidProject("down --rmi must be 'all' or 'local'")
        }
    }

    /// Creates project networks and volumes required before containers start.
    func ensureResources(project: ComposeProject) async throws {
        for (name, network) in project.networks.sorted(by: { $0.key < $1.key }) where network.external != true {
            try await ensureNetwork(project: project, composeName: name, network: network)
        }
        for (name, volume) in project.volumes.sorted(by: { $0.key < $1.key }) where volume.external != true {
            try await ensureVolume(project: project, composeName: name, volume: volume)
        }
    }

    /// Returns a project view containing only resources referenced by active services.
    func projectBySelectingResources(project: ComposeProject, services: [ComposeService]) -> ComposeProject {
        let networkNames = Set(services.flatMap { $0.networks ?? [] })
        let volumeNames = Set(services.flatMap { service in
            (service.volumes ?? []).compactMap { mount -> String? in
                guard mount.type == "volume", let source = mount.source, project.volumes[source] != nil else {
                    return nil
                }
                return source
            }
        })
        var selected = project
        selected.networks = project.networks.filter { networkNames.contains($0.key) }
        selected.volumes = project.volumes.filter { volumeNames.contains($0.key) }
        return selected
    }

    /// Creates a project network unless it already exists.
    func ensureNetwork(project: ComposeProject, composeName: String, network: ComposeNetwork) async throws {
        var args = ["network", "create"]
        if network.isInternal == true {
            args.append("--internal")
        }
        if let ipv4Subnet = network.ipv4Subnet, !ipv4Subnet.isEmpty {
            args.append(contentsOf: ["--subnet", ipv4Subnet])
        }
        if let ipv6Subnet = network.ipv6Subnet, !ipv6Subnet.isEmpty {
            args.append(contentsOf: ["--subnet-v6", ipv6Subnet])
        }
        for label in resourceLabels(project: project) {
            args.append(contentsOf: ["--label", label])
        }
        for label in (network.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(label.key)=\(label.value)"])
        }
        let runtimeName = networkRuntimeName(project: project, composeName: composeName, network: network)
        args.append(runtimeName)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await resourceManager.createNetwork(ComposeNetworkCreateRequest(
                name: runtimeName,
                isInternal: network.isInternal == true,
                ipv4Subnet: network.ipv4Subnet,
                ipv6Subnet: network.ipv6Subnet,
                labels: resourceLabels(project: project, labels: network.labels),
            ))
        }
    }

    /// Creates a project volume unless it already exists.
    func ensureVolume(project: ComposeProject, composeName: String, volume: ComposeVolume) async throws {
        var args = ["volume", "create"]
        let driverOpts = volume.driverOpts ?? [:]
        for option in driverOpts.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--opt", "\(option.key)=\(option.value)"])
        }
        for label in resourceLabels(project: project) {
            args.append(contentsOf: ["--label", label])
        }
        for label in (volume.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(label.key)=\(label.value)"])
        }
        let runtimeName = volumeRuntimeName(project: project, composeName: composeName, volume: volume)
        args.append(runtimeName)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await resourceManager.createVolume(ComposeVolumeCreateRequest(
                name: runtimeName,
                driver: volume.driver,
                driverOpts: driverOpts,
                labels: resourceLabels(project: project, labels: volume.labels),
            ))
        }
    }
}
