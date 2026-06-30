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
    /// Returns services that are dependencies of explicitly selected services
    /// and should be recreated even when their config hash still matches.
    func servicesToRecreateBecauseDependencies(
        project: ComposeProject,
        selected: [String],
        noDeps: Bool,
        alwaysRecreateDeps: Bool,
        services: [ComposeService],
    ) throws -> Set<String> {
        guard alwaysRecreateDeps, !noDeps, !selected.isEmpty else {
            return []
        }
        let selectedNames = try Set(selectedServices(project: project, selected: selected).map(\.name))
        return Set(services.map(\.name)).subtracting(selectedNames)
    }

    /// Returns the deterministic container name for a service or one-off run.
    func containerName(project: ComposeProject, service: ComposeService, oneOff: Bool) -> String {
        if !oneOff, let containerName = service.containerName, !containerName.isEmpty {
            return slug(containerName)
        }
        let suffix = oneOff ? "run-\(slug(options.oneOffIdentifier()))" : "1"
        return "\(slug(project.name))-\(slug(service.name))-\(suffix)"
    }

    /// Returns the one-off container name requested by the CLI or generated
    /// from the configured identifier source.
    func oneOffRunContainerName(project: ComposeProject, service: ComposeService, requestedName: String?) -> String {
        guard let requestedName else {
            return containerName(project: project, service: service, oneOff: true)
        }
        return slug(requestedName)
    }

    /// Resolves the runtime ID for a service container index.
    func serviceContainerID(project: ComposeProject, service: ComposeService, index: Int) async throws -> String {
        let id = try serviceContainerName(project: project, service: service, index: index)
        guard index != 1, !options.dryRun else {
            return id
        }

        let containers = try await projectContainers(projectName: project.name, all: true)
        guard serviceContainerExists(containers, service: service, id: id) else {
            throw ComposeError.invalidProject("service '\(service.name)' container '\(id)' does not exist")
        }
        return id
    }

    /// Returns the deterministic runtime name for a service container index.
    func serviceContainerName(project: ComposeProject, service: ComposeService, index: Int) throws -> String {
        guard index >= 1 else {
            throw ComposeError.invalidProject("container index must be greater than zero")
        }
        if index == 1 {
            return containerName(project: project, service: service, oneOff: false)
        }
        if let containerName = service.containerName, !containerName.isEmpty {
            throw ComposeError.invalidProject("service '\(service.name)' uses container_name; --index \(index) requires Compose-managed replica names")
        }
        return "\(slug(project.name))-\(slug(service.name))-\(index)"
    }

    /// Returns desired deterministic container names for declared services.
    func declaredServiceContainerNames(project: ComposeProject, scaleOverrides: [String: Int]) throws -> Set<String> {
        var names = Set<String>()
        for service in project.services.values {
            let replicaCount = try serviceReplicaCount(service, scaleOverrides: scaleOverrides)
            guard replicaCount > 0 else {
                continue
            }
            for index in 1 ... replicaCount {
                try names.insert(serviceContainerName(project: project, service: service, index: index))
            }
        }
        return names
    }

    /// Resolves service containers from direct API state, falling back to deterministic names.
    func serviceContainerTargets(project: ComposeProject, services: [ComposeService]) async throws -> [ServiceContainerTarget] {
        if options.dryRun {
            return try configuredServiceContainerTargets(project: project, services: services)
        }

        let containers = try await projectContainers(projectName: project.name, all: true)
        return try services.flatMap { service in
            let matches = containers
                .filter { $0.serviceName == service.name && !$0.isOneOff }
                .sorted(by: serviceContainerSummaryOrder(project: project, service: service))
            guard !matches.isEmpty else {
                guard service.provider == nil else {
                    return [ServiceContainerTarget]()
                }
                return try [
                    ServiceContainerTarget(
                        service: service,
                        index: 1,
                        name: serviceContainerName(project: project, service: service, index: 1),
                    ),
                ]
            }
            return matches.map { container in
                ServiceContainerTarget(
                    service: service,
                    index: serviceContainerIndex(project: project, service: service, containerID: container.id) ?? Int.max,
                    name: container.id,
                )
            }
        }
    }

    /// Resolves service container targets for `compose logs`.
    func logTargets(project: ComposeProject, services: [ComposeService], index: Int?) async throws -> [ServiceContainerTarget] {
        guard let index else {
            return try await serviceContainerTargets(project: project, services: services)
        }
        var targets: [ServiceContainerTarget] = []
        for service in services {
            let name = try await serviceContainerID(project: project, service: service, index: index)
            targets.append(ServiceContainerTarget(
                service: service,
                index: index,
                name: name,
            ))
        }
        return targets
    }

    /// Returns configured service targets for dry-run rendering.
    func configuredServiceContainerTargets(project: ComposeProject, services: [ComposeService]) throws -> [ServiceContainerTarget] {
        try services.flatMap { service in
            let replicaCount = try serviceReplicaCount(service, scaleOverrides: [:])
            guard replicaCount > 0 else {
                return [ServiceContainerTarget]()
            }
            return try (1 ... replicaCount).map { index in
                try ServiceContainerTarget(
                    service: service,
                    index: index,
                    name: serviceContainerName(project: project, service: service, index: index),
                )
            }
        }
    }

    /// Removes service replicas above the desired count during scale-down.
    func removeServiceReplicasAbove(project: ComposeProject, service: ComposeService, desiredCount: Int, timeout: Int?) async throws {
        guard !options.dryRun else {
            return
        }
        let containers = try await projectContainers(projectName: project.name, all: true)
            .filter { $0.serviceName == service.name && !$0.isOneOff }
            .sorted(by: serviceContainerSummaryOrder(project: project, service: service))
        for container in containers {
            let index = serviceContainerIndex(project: project, service: service, containerID: container.id)
            guard desiredCount == 0 || (index.map { $0 > desiredCount } ?? false) else {
                continue
            }
            try await stopContainer(service: service, containerName: container.id, timeout: timeout)
            try await deleteContainer(container.id)
        }
    }

    /// Returns a stable ordering for service container discovery.
    func serviceContainerSummaryOrder(project: ComposeProject, service: ComposeService) -> (ComposeContainerSummary, ComposeContainerSummary) -> Bool {
        { [self] lhs, rhs in
            let lhsIndex = serviceContainerIndex(project: project, service: service, containerID: lhs.id) ?? Int.max
            let rhsIndex = serviceContainerIndex(project: project, service: service, containerID: rhs.id) ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.id < rhs.id
        }
    }

    /// Infers a Compose-managed replica index from a runtime container ID.
    func serviceContainerIndex(project: ComposeProject, service: ComposeService, containerID: String) -> Int? {
        if containerID == containerName(project: project, service: service, oneOff: false) {
            return 1
        }
        guard service.containerName?.isEmpty ?? true else {
            return nil
        }
        let prefix = "\(slug(project.name))-\(slug(service.name))-"
        guard containerID.hasPrefix(prefix) else {
            return nil
        }
        let suffix = String(containerID.dropFirst(prefix.count))
        guard let index = Int(suffix), index >= 1 else {
            return nil
        }
        return index
    }

    /// Validates project-level invariants before runtime orchestration starts.
    func validate(project: ComposeProject) throws {
        guard !project.name.isEmpty else {
            throw ComposeError.invalidProject("project name is empty")
        }
        guard !project.services.isEmpty else {
            throw ComposeError.invalidProject("no services defined")
        }
        try validateProjectNetworks(project)
    }

    /// Rejects Compose features that need runtime support not available yet.
    func validateRuntimeSupport(
        service: ComposeService,
        project: ComposeProject,
        validateDependencies: Bool = true,
    ) throws {
        try validateBuildSupport(service: service)
        try validateDeploySupport(service: service)
        try validateProviderAndModelSupport(service: service)
        try validateLifecycleHookSupport(service: service)
        let networks = service.networks ?? []
        if networks.count > 1 {
            throw ComposeError.unsupported("service '\(service.name)' declares multiple networks; apple/container does not expose network connect yet")
        }
        try validateNetworkAliasSupport(service: service, networks: networks)
        if let networkOptions = service.networkOptions {
            for (network, options) in networkOptions.sorted(by: { $0.key < $1.key }) {
                let fields = try options.unsupportedFieldNames()
                if !fields.isEmpty {
                    let fieldList = fields.joined(separator: ", ")
                    throw ComposeError.unsupported("service '\(service.name)' uses network attachment options \(fieldList) on network '\(network)'; network attachment options need an apple/container runtime gap PR")
                }
            }
        }
        if let networkMode = service.networkMode, !networkMode.isEmpty, !isSupportedNetworkMode(networkMode) {
            throw ComposeError.unsupported("service '\(service.name)' uses network_mode '\(networkMode)'; network mode support needs an apple/container runtime gap PR")
        }
        _ = try runtimePIDArgument(service: service)
        if let gap = unsupportedRuntimeStringFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName) '\(gap.value)'; \(gap.reason)")
        }
        if let gap = unsupportedCPUResourceFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName) '\(gap.value)'; \(gap.reason)")
        }
        if let gap = unsupportedMemoryAndProcessResourceFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName) '\(gap.value)'; \(gap.reason)")
        }
        _ = try runtimeBlkioArguments(service: service)
        _ = try runtimeDeviceCgroupRuleArguments(service: service)
        if let gap = unsupportedUserAndSecurityOptionFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName) '\(gap.value)'; \(gap.reason)")
        }
        if let gap = unsupportedDeviceAccessFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        if let scale = service.scale, scale < 0 {
            throw ComposeError.invalidProject("service '\(service.name)' scale must be a non-negative integer")
        }
        if let gap = unsupportedServiceMetadataAndLoggingFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        try validateServiceLabels(project: project, service: service)
        try validateVolumesFromSupport(service: service, project: project)
        try validateBindMountSourcePolicy(project: project, service: service)
        if let gap = unsupportedServiceVolumeShortcutFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        if let fields = try unsupportedServiceMountFields(service: service, project: project) {
            if fields == ["volume.subpath"] {
                throw ComposeError.unsupported("service '\(service.name)' uses volume.subpath; volume subpath mounts need an apple/container mount primitive gap PR")
            }
            let fieldList = fields.joined(separator: ", ")
            throw ComposeError.unsupported("service '\(service.name)' uses unsupported volume fields \(fieldList); advanced service volume options need an apple/container mount primitive gap PR")
        }
        if service.useAPISocket == true {
            throw ComposeError.unsupported("service '\(service.name)' uses use_api_socket; Docker-compatible API socket and credential handoff need an apple/container runtime boundary")
        }
        try validateNetworkMACAddressSupport(service: service, networks: networks)
        if validateDependencies, let dependsOn = service.dependsOn {
            for (dependency, metadata) in dependsOn.sorted(by: { $0.key < $1.key }) {
                if metadata.required == false, project.services[dependency] == nil {
                    continue
                }
                let condition = metadata.condition
                if condition != "service_started", condition != "", condition != "service_completed_successfully", condition != "service_healthy" {
                    let reason = unsupportedDependencyConditionReason(condition)
                    throw ComposeError.unsupported("service '\(service.name)' depends on '\(dependency)' with condition '\(condition)'; \(reason)")
                }
            }
        }
        _ = try serviceLinkReferences(service: service, project: project)
        _ = try serviceExternalLinkReferences(service: service)
        _ = try runtimeExtraHostArguments(service: service)
        _ = try runtimeHostnameArgument(service: service)
        _ = try runtimeDomainnameArgument(service: service)
        _ = try runtimeSysctlArguments(service: service)
        try validateHealthCheckSupport(service: service)
        _ = try serviceConfigSecretMounts(project: project, service: service)
        if let pullPolicy = service.pullPolicy, !pullPolicy.isEmpty, !isSupportedServicePullPolicy(pullPolicy) {
            throw ComposeError.unsupported("service '\(service.name)' uses pull_policy '\(pullPolicy)'; supported values are always, missing, if_not_present, never, build, daily, weekly, and every_<duration>")
        }
        _ = try runtimeRestartPolicyArguments(service: service)
    }

    /// Rejects project network fields that are not mapped to apple/container network creation.
    func validateProjectNetworks(_ project: ComposeProject) throws {
        for (name, network) in project.networks.sorted(by: { $0.key < $1.key }) {
            guard let fields = network.unsupportedFields, !fields.isEmpty else {
                continue
            }
            let fieldList = fields.joined(separator: ", ")
            throw ComposeError.unsupported("network '\(name)' uses unsupported fields \(fieldList); only internal and one IPv4/IPv6 IPAM subnet are mapped to apple/container networks")
        }
    }

    /// Returns whether the service explicitly disables container networking.
    func isNoNetworkMode(_ networkMode: String?) -> Bool {
        networkMode == "none"
    }

    /// Returns whether the service requests Docker Compose host network mode.
    func isHostNetworkMode(_ networkMode: String?) -> Bool {
        networkMode == "host"
    }

    /// Returns whether the service selects a network namespace mode this runtime can represent.
    func isSupportedNetworkMode(_ networkMode: String) -> Bool {
        isNoNetworkMode(networkMode) || isHostNetworkMode(networkMode)
    }

    /// Allows MAC addresses only for the single-network attachment that apple/container
    /// `container --network name,mac=...` can represent.
    func validateNetworkMACAddressSupport(service: ComposeService, networks: [String]) throws {
        let serviceMACAddress = nonEmpty(service.macAddress)
        let networkMACAddresses = (service.networkOptions ?? [:]).compactMapValues { nonEmpty($0.macAddress) }
        guard serviceMACAddress != nil || !networkMACAddresses.isEmpty else {
            return
        }
        guard networks.count == 1, let network = networks.first else {
            throw ComposeError.unsupported("service '\(service.name)' uses mac_address; MAC address support requires exactly one Compose network")
        }
        for networkName in networkMACAddresses.keys.sorted() where networkName != network {
            throw ComposeError.unsupported("service '\(service.name)' sets mac_address on unattached network '\(networkName)'")
        }
        if let serviceMACAddress,
           let networkMACAddress = networkMACAddresses[network],
           serviceMACAddress != networkMACAddress
        {
            throw ComposeError.invalidProject("service '\(service.name)' sets conflicting mac_address values '\(serviceMACAddress)' and '\(networkMACAddress)' on network '\(network)'")
        }
    }

    /// Allows aliases only for the single-network attachment that apple/container
    /// `container --network name,alias=...` can represent.
    func validateNetworkAliasSupport(service: ComposeService, networks: [String]) throws {
        guard let networkAliases = service.networkAliases else {
            return
        }
        let aliasNetworks = networkAliases
            .filter { !$0.value.isEmpty }
            .map(\.key)
            .sorted()
        guard !aliasNetworks.isEmpty else {
            return
        }
        guard networks.count == 1, let network = networks.first else {
            throw ComposeError.unsupported("service '\(service.name)' uses network aliases; network aliases require exactly one Compose network until apple/container exposes multi-network alias attachment")
        }
        for aliasNetwork in aliasNetworks where aliasNetwork != network {
            throw ComposeError.invalidProject("service '\(service.name)' sets network aliases on unattached network '\(aliasNetwork)'")
        }
        _ = try networkAliasValues(service: service, network: network)
    }

    /// Rejects build fields that apple/container `container build` cannot represent yet.
    func validateBuildSupport(service: ComposeService) throws {
        guard let fields = service.build?.unsupportedFields, !fields.isEmpty else {
            return
        }
        let fieldList = fields.joined(separator: ", ")
        throw ComposeError.unsupported("service '\(service.name)' uses unsupported build fields \(fieldList); advanced build fields need Docker Compose compatible apple/container build primitives")
    }

    /// Rejects deploy fields that are not part of the supported local subset.
    func validateDeploySupport(service: ComposeService) throws {
        guard let fields = service.unsupportedDeployFields, !fields.isEmpty else {
            return
        }
        if fields.contains("update_config.order.start-first") {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.update_config.order: start-first; start-first updates need an apple/container container rename or service alias handoff primitive")
        }
        if fields.contains("mode") {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.mode; deploy modes outside local replicated/global behavior need apple/container scheduler or job lifecycle primitives")
        }
        if fields.contains("update_config.order") {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.update_config.order; unsupported update orders need Docker Compose compatible apple/container update orchestration primitives")
        }
        if let field = unsupportedDeployResourceLimitField(in: fields) {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.\(field); apple/container exposes local deploy CPU and memory limits but not this deploy resource limit yet")
        }
        if let field = unsupportedDeployResourceReservationField(in: fields) {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.\(field); resource reservations need an apple/container scheduler/resource reservation gap PR")
        }
        let fieldList = fields.joined(separator: ", ")
        throw ComposeError.unsupported("service '\(service.name)' uses unsupported deploy fields \(fieldList); remaining Compose Deploy Specification fields need Docker Compose compatible apple/container deploy or runtime primitives")
    }

    /// Returns unsupported deploy resource limits that need apple/container runtime support.
    func unsupportedDeployResourceLimitField(in fields: [String]) -> String? {
        fields.first { $0.hasPrefix("resources.limits.") }
    }

    /// Returns unsupported deploy resource reservations that need scheduler support.
    func unsupportedDeployResourceReservationField(in fields: [String]) -> String? {
        fields.first { $0.hasPrefix("resources.reservations.") }
    }

    /// Rejects service extension points that need explicit orchestration design.
    func validateProviderAndModelSupport(service: ComposeService) throws {
        if let provider = service.provider {
            let type = provider.type.trimmingCharacters(in: .whitespacesAndNewlines)
            if type.isEmpty {
                throw ComposeError.invalidProject("service '\(service.name)' provider.type must not be empty")
            }
            if type == "compose" {
                throw ComposeError.invalidProject("service '\(service.name)' provider.type 'compose' is reserved")
            }
        }
        if let models = service.models, !models.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses models; Compose model bindings need a model-runner backend and endpoint injection primitive that is not available through apple/container yet")
        }
    }

    /// Runs a provider-backed service lifecycle command.
    func runProvider(
        project: ComposeProject,
        service: ComposeService,
        action: ComposeProviderAction,
    ) async throws -> [String: String] {
        guard let provider = service.provider else {
            return [:]
        }
        let executable = options.dryRun
            ? provider.type
            : try providerExecutablePath(provider.type, project: project)

        let metadata = options.dryRun
            ? ComposeProviderMetadata()
            : await providerMetadata(executable: executable, project: project)
        if action == .stop && metadata.commandMetadata(for: .stop) == nil && !options.dryRun {
            return [:]
        }
        if !metadata.isEmpty {
            try validateProviderOptions(provider: provider, metadata: metadata, action: action)
        }

        let arguments = providerArguments(
            project: project,
            service: service,
            provider: provider,
            action: action,
            metadata: metadata,
        )
        if options.dryRun {
            options.emit("+ " + shellQuoted([executable] + arguments))
            return [:]
        }

        let result = try await runner.run(
            executable,
            arguments,
            workingDirectory: URL(fileURLWithPath: project.workingDirectory, isDirectory: true),
            environment: nil,
            io: .captured(input: nil),
        )
        let variables = try parseProviderOutput(result.stdout, service: service, action: action)
        if !result.succeeded {
            throw ComposeError.commandFailed(
                command: shellQuoted([executable] + arguments),
                status: result.status,
                stderr: result.stderr,
            )
        }
        return action == .stop ? [:] : variables
    }

    /// Reads optional provider metadata. Metadata failures intentionally fall
    /// back to the protocol's no-metadata behavior for backward compatibility.
    func providerMetadata(executable: String, project: ComposeProject) async -> ComposeProviderMetadata {
        do {
            let result = try await runner.run(
                executable,
                ["compose", "metadata"],
                workingDirectory: URL(fileURLWithPath: project.workingDirectory, isDirectory: true),
                environment: nil,
                io: .captured(input: nil),
            )
            guard result.succeeded,
                  let data = result.stdout.data(using: .utf8),
                  !data.isEmpty
            else {
                return ComposeProviderMetadata()
            }
            return (try? JSONDecoder().decode(ComposeProviderMetadata.self, from: data)) ?? ComposeProviderMetadata()
        } catch {
            return ComposeProviderMetadata()
        }
    }

    /// Builds the provider command arguments for one lifecycle action.
    func providerArguments(
        project: ComposeProject,
        service: ComposeService,
        provider: ComposeProvider,
        action: ComposeProviderAction,
        metadata: ComposeProviderMetadata,
    ) -> [String] {
        let commandMetadata = metadata.commandMetadata(for: action)
        let hasMetadata = !metadata.isEmpty
        var arguments = ["compose", "--project-name=\(project.name)", action.rawValue]
        for (key, values) in (provider.options ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !hasMetadata || commandMetadata?.parameter(named: key) != nil else {
                continue
            }
            for value in values {
                arguments.append("--\(key)=\(value)")
            }
        }
        arguments.append(service.name)
        return arguments
    }

    /// Validates required provider options declared by metadata.
    func validateProviderOptions(
        provider: ComposeProvider,
        metadata: ComposeProviderMetadata,
        action: ComposeProviderAction,
    ) throws {
        guard let commandMetadata = metadata.commandMetadata(for: action) else {
            return
        }
        for parameter in commandMetadata.parameters ?? [] where parameter.required == true {
            if (provider.options?[parameter.name] ?? []).isEmpty {
                throw ComposeError.invalidProject("required parameter '\(parameter.name)' is missing from provider '\(provider.type)' definition")
            }
        }
    }

    /// Decodes newline-delimited provider JSON messages.
    func parseProviderOutput(
        _ output: String,
        service: ComposeService,
        action: ComposeProviderAction,
    ) throws -> [String: String] {
        var variables: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            guard let data = text.data(using: .utf8),
                  let message = try? JSONDecoder().decode(ComposeProviderMessage.self, from: data)
            else {
                throw ComposeError.invalidProject("invalid response from provider service '\(service.name)': \(text)")
            }
            switch message.type {
            case "info":
                options.emit("compose: provider \(service.name): \(message.message)")
            case "debug":
                continue
            case "error":
                throw ComposeError.invalidProject("provider service '\(service.name)' failed during \(action.rawValue): \(message.message)")
            case "setenv":
                let parts = message.message.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw ComposeError.invalidProject("invalid setenv response from provider service '\(service.name)': \(message.message)")
                }
                variables[String(parts[0])] = String(parts[1])
            default:
                throw ComposeError.invalidProject("invalid response type '\(message.type)' from provider service '\(service.name)'")
            }
        }
        return variables
    }

    /// Injects provider variables into services that directly depend on it.
    func projectByInjectingProviderEnvironment(
        project: ComposeProject,
        providerServiceName: String,
        variables: [String: String],
    ) -> ComposeProject {
        var updatedProject = project
        let prefix = providerServiceName.uppercased() + "_"
        for entry in project.services.sorted(by: { $0.key < $1.key }) {
            let name = entry.key
            var service = entry.value
            guard service.dependsOn?[providerServiceName] != nil else {
                continue
            }
            var environment = service.environment ?? [:]
            for (key, value) in variables.sorted(by: { $0.key < $1.key }) {
                environment[prefix + key] = value
            }
            service.environment = environment
            updatedProject.services[name] = service
        }
        return updatedProject
    }

    /// Resolves the provider executable path using Compose-compatible rules.
    func providerExecutablePath(_ rawType: String, project: ComposeProject) throws -> String {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "compose" {
            throw ComposeError.invalidProject("provider.type 'compose' is reserved")
        }
        if type.contains("/") {
            let url = type.hasPrefix("/")
                ? URL(fileURLWithPath: type)
                : URL(fileURLWithPath: project.workingDirectory, isDirectory: true)
                .appendingPathComponent(type)
                .standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ComposeError.invalidProject("provider executable '\(type)' was not found or is not executable")
            }
            return url.path
        }
        let candidates = type.hasPrefix("docker-") ? [type] : ["docker-\(type)", type]
        for candidate in candidates {
            if let path = findExecutable(named: candidate) {
                return path
            }
        }
        throw ComposeError.invalidProject("provider executable '\(type)' was not found in PATH")
    }

    /// Finds an executable in PATH.
    func findExecutable(named name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directoryPath = directory.isEmpty ? "." : String(directory)
            let candidate = URL(fileURLWithPath: directoryPath, isDirectory: true)
                .appendingPathComponent(name)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Validates lifecycle hook metadata before runtime side effects.
    func validateLifecycleHookSupport(service: ComposeService) throws {
        let hookSets: [(composeName: String, hooks: [ComposeServiceHook]?)] = [
            ("post_start", service.postStart),
            ("pre_stop", service.preStop),
        ]
        for hookSet in hookSets {
            for (index, hook) in (hookSet.hooks ?? []).enumerated() {
                guard let command = hook.command, !command.isEmpty else {
                    throw ComposeError.invalidProject("service '\(service.name)' \(hookSet.composeName)[\(index)] requires a command")
                }
            }
        }
    }

    /// Rejects foreground `up` when `post_start` would otherwise run too late.
    func validateAttachedPostStartSupport(target: ServiceContainerTarget?) throws {
        guard let service = target?.service, hasPostStartHooks(service) else {
            return
        }
        throw ComposeError.unsupported("service '\(service.name)' uses post_start; attached up cannot run lifecycle hooks before foreground attach because apple/container does not expose reattaching to the init process after a hookable detached start, use --detach")
    }

    /// Validates lifecycle hooks for one-off containers.
    func validateOneOffRunLifecycleHooks(service: ComposeService, options run: ComposeRunOptions) throws {
        if hasPreStopHooks(service), !run.detach {
            throw ComposeError.unsupported("service '\(service.name)' uses pre_stop; foreground compose run cannot execute pre_stop before the one-off init process exits because apple/container does not expose an interceptable foreground stop boundary")
        }
        guard hasPostStartHooks(service), !run.detach else {
            return
        }
        throw ComposeError.unsupported("service '\(service.name)' uses post_start; foreground compose run cannot execute post_start before attach because apple/container does not expose reattaching to the init process after a hookable detached start, use --detach")
    }

    /// Validates normalized develop.watch trigger metadata for command-level
    /// `watch` execution.
    func validateWatchTriggers(services: [ComposeService]) throws {
        for service in services {
            guard let triggers = service.develop?.watch else {
                continue
            }
            for trigger in triggers {
                try validateWatchTrigger(trigger, service: service)
            }
        }
    }

    /// Validates one develop.watch trigger before runtime watch execution.
    func validateWatchTrigger(_ trigger: ComposeDevelopWatch, service: ComposeService) throws {
        guard nonEmpty(trigger.path) != nil else {
            throw ComposeError.invalidProject("service '\(service.name)' has a develop.watch trigger without a path")
        }
        let action = trigger.action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' has a develop.watch trigger without an action")
        }
        let supportedActions = ["rebuild", "restart", "sync", "sync+restart", "sync+exec"]
        guard supportedActions.contains(action) else {
            let supportedActionList = supportedActions.joined(separator: ", ")
            throw ComposeError.unsupported(
                "service '\(service.name)' uses develop.watch action '\(trigger.action)'; supported Compose watch actions are \(supportedActionList)",
            )
        }
        if action.contains("sync"), nonEmpty(trigger.target) == nil {
            throw ComposeError.invalidProject("service '\(service.name)' develop.watch action '\(action)' requires a target")
        }
        if action == "sync+exec" {
            _ = try watchExecHook(trigger: trigger, service: service)
        }
    }

    /// Emits the validated watch plan without starting the file-watcher loop.
    func emitWatchDryRunPlan(project: ComposeProject, services: [ComposeService], watch: ComposeWatchOptions) {
        let serviceNames = services.map(\.name).joined(separator: ",")
        options.emit("compose: watch project \(project.name) services \(serviceNames)")
        options.emit("compose: watch initial-up \(watch.noUp ? "disabled" : "enabled")")
        options.emit("compose: watch prune \(watch.prune ? "enabled" : "disabled")")
        options.emit("compose: watch quiet \(watch.quiet ? "enabled" : "disabled")")
        for service in services {
            for trigger in service.develop?.watch ?? [] {
                options.emit(watchDryRunLine(service: service, trigger: trigger))
            }
        }
    }
}
