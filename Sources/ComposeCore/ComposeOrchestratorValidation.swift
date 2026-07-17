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

extension ComposeOrchestrator {
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
        let networks = try validateRuntimeNetworkSupport(service: service, project: project)
        try validateRuntimeResourceSupport(service: service)
        try validateRuntimeMountSupport(service: service, project: project)
        try validateNetworkMACAddressSupport(service: service, networks: networks)
        if validateDependencies {
            try validateRuntimeDependencySupport(service: service, project: project)
        }
        try validateRemainingRuntimeSupport(service: service, project: project)
    }

    /// Validates network modes and attachment metadata, returning selected networks.
    func validateRuntimeNetworkSupport(service: ComposeService, project: ComposeProject) throws -> [String] {
        let networks = service.networks ?? []
        try validateNetworkAliasSupport(service: service, networks: networks)
        if let networkOptions = service.networkOptions {
            for (network, options) in networkOptions.sorted(by: { $0.key < $1.key }) {
                let fields = try options.unsupportedFieldNames()
                if !fields.isEmpty {
                    let fieldList = fields.joined(separator: ", ")
                    throw ComposeError.unsupported("service '\(service.name)' uses network attachment options \(fieldList) on network '\(network)'; network attachment options need an apple/container runtime gap PR")
                }
                _ = try networkGuestInterfaceName(service: service, network: network)
                _ = try networkLinkLocalIPValues(service: service, network: network)
                _ = try networkStaticAddressOptions(project: project, service: service, network: network)
            }
        }
        if let networkMode = service.networkMode, !networkMode.isEmpty, !isSupportedNetworkMode(networkMode) {
            throw ComposeError.unsupported("service '\(service.name)' uses network_mode '\(networkMode)'; network mode support needs an apple/container runtime gap PR")
        }
        return networks
    }

    /// Validates runtime resource and security fields before side effects.
    func validateRuntimeResourceSupport(service: ComposeService) throws {
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
        _ = try runtimeOOMScoreAdj(service: service)
        _ = try runtimeBlkioArguments(service: service)
        _ = try runtimeDeviceCgroupRuleArguments(service: service)
        _ = try runtimeDeviceArguments(service: service)
        _ = try runtimeGPUArguments(service: service)
        _ = try runtimeSupplementalGroups(service: service)
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
    }

    /// Validates service mount and generated-resource fields before side effects.
    func validateRuntimeMountSupport(service: ComposeService, project: ComposeProject) throws {
        try validateServiceLabels(project: project, service: service)
        try validateVolumesFromSupport(service: service, project: project)
        try validateBindMountSourcePolicy(project: project, service: service)
        if let gap = unsupportedServiceVolumeShortcutFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        if let fields = try unsupportedServiceMountFields(service: service, project: project) {
            let fieldList = fields.joined(separator: ", ")
            throw ComposeError.unsupported("service '\(service.name)' uses unsupported volume fields \(fieldList); advanced service volume options need an apple/container mount primitive gap PR")
        }
        if service.useAPISocket == true {
            throw ComposeError.unsupported("service '\(service.name)' uses use_api_socket; Docker-compatible API socket and credential handoff need an apple/container runtime boundary")
        }
    }

    /// Validates dependency conditions in the same order as runtime orchestration.
    func validateRuntimeDependencySupport(service: ComposeService, project: ComposeProject) throws {
        let supportedConditions: Set = ["", "service_completed_successfully", "service_healthy", "service_started"]
        for (dependency, metadata) in (service.dependsOn ?? [:]).sorted(by: { $0.key < $1.key }) {
            if metadata.required == false, project.services[dependency] == nil {
                continue
            }
            let condition = metadata.condition
            if !supportedConditions.contains(condition) {
                let reason = unsupportedDependencyConditionReason(condition)
                throw ComposeError.unsupported("service '\(service.name)' depends on '\(dependency)' with condition '\(condition)'; \(reason)")
            }
        }
    }

    /// Validates remaining fields whose adapters already own detailed diagnostics.
    func validateRemainingRuntimeSupport(service: ComposeService, project: ComposeProject) throws {
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
                try validateNetworkIPv4Gateway(network, name: name)
                try validateNetworkIPv4AllocationRange(network, name: name)
                try validateNetworkIPv4ReservedAddresses(network, name: name)
                continue
            }
            let fieldList = fields.joined(separator: ", ")
            throw ComposeError.unsupported("network '\(name)' uses unsupported fields \(fieldList); supported project network fields are name, external, internal, labels, driver_opts, the default bridge driver, and one IPv4 IPAM subnet with optional gateway, allocation range, and reserved addresses plus one IPv6 IPAM subnet")
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

    /// Validates per-network MAC addresses and selects a service MAC by Compose priority.
    func validateNetworkMACAddressSupport(service: ComposeService, networks: [String]) throws {
        let serviceMACAddress = nonEmpty(service.macAddress)
        let networkMACAddresses = (service.networkOptions ?? [:]).compactMapValues { nonEmpty($0.macAddress) }
        guard serviceMACAddress != nil || !networkMACAddresses.isEmpty else {
            return
        }
        for networkName in networkMACAddresses.keys.sorted() where !networks.contains(networkName) {
            throw ComposeError.unsupported("service '\(service.name)' sets mac_address on unattached network '\(networkName)'")
        }
        guard let serviceMACAddress else {
            return
        }
        guard let network = serviceMACAddressNetwork(service: service) else {
            throw ComposeError.unsupported("service '\(service.name)' uses mac_address; MAC address support requires a Compose network")
        }
        if let networkMACAddress = networkMACAddresses[network], serviceMACAddress != networkMACAddress {
            throw ComposeError.invalidProject("service '\(service.name)' sets conflicting mac_address values '\(serviceMACAddress)' and '\(networkMACAddress)' on network '\(network)'")
        }
    }

    /// Validates aliases then rejects them until apple/container can resolve
    /// network registry names from inside service containers.
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
        for aliasNetwork in aliasNetworks {
            guard networks.contains(aliasNetwork) else {
                throw ComposeError.invalidProject("service '\(service.name)' sets network aliases on unattached network '\(aliasNetwork)'")
            }
            _ = try networkAliasValues(service: service, network: aliasNetwork)
        }
        throw ComposeError.unsupported("service '\(service.name)' uses network aliases; apple/container registers aliases but cannot resolve them inside service containers until it exposes container-facing DNS")
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
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.\(field); apple/container exposes local deploy CPU, memory, and pids limits but not this deploy resource limit yet")
        }
        if fields.contains("resources.reservations.devices") {
            throw ComposeError.unsupported("service '\(service.name)' uses a non-GPU deploy device reservation; the Apple backend supports only the generic GPU capability")
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

    /// Validates lifecycle hook metadata before runtime side effects.
    func validateLifecycleHookSupport(service: ComposeService) throws {
        if let preStart = service.preStart, !preStart.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses pre_start; Docker Compose init containers need an apple/container ephemeral-container lifecycle primitive")
        }
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

    /// Validates lifecycle hooks for one-off containers.
    func validateOneOffRunLifecycleHooks(
        service: ComposeService,
        options run: ComposeRunOptions,
        foregroundInteractiveRun: Bool,
    ) throws {
        try validateLifecycleHookSupport(service: service)
        guard !run.detach, hasLifecycleHooks(service), foregroundInteractiveRun else {
            return
        }
        throw ComposeError.unsupported("service '\(service.name)' uses lifecycle hooks; interactive foreground compose run requires Apple runtime stdio reattach support")
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
