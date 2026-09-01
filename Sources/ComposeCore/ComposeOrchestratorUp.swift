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
import Foundation

private struct ComposeUpServiceContext {
    let project: ComposeProject
    let options: ComposeUpOptions
    let scaleOverrides: [String: Int]
    let externalVolumeMounts: ExternalVolumeMounts
    let imageHealthCheckCache: ComposeImageHealthCheckCache
    let dependencyRecreateServices: Set<String>
    let changedServices: Set<String>
    let validateDependencies: Bool
    let detachStartedContainers: Bool
    let outputAttachedServiceNames: Set<String>
}

private struct ComposeUpServiceResult {
    let serviceName: String
    let waitTargets: [ServiceContainerTarget]
    let outputAttachments: [ComposeUpOutputAttachment]
    let changed: Bool
}

extension ComposeOrchestrator {
    /// Returns whether a service declares `pre_start` hooks.
    func hasPreStartHooks(_ service: ComposeService) -> Bool {
        !(service.preStart ?? []).isEmpty
    }

    /// Returns whether a service declares `post_start` hooks.
    func hasPostStartHooks(_ service: ComposeService) -> Bool {
        !(service.postStart ?? []).isEmpty
    }

    /// Returns whether a service declares `pre_stop` hooks.
    func hasPreStopHooks(_ service: ComposeService) -> Bool {
        !(service.preStop ?? []).isEmpty
    }

    /// Returns whether a service declares any lifecycle hooks.
    func hasLifecycleHooks(_ service: ComposeService) -> Bool {
        hasPostStartHooks(service) || hasPreStopHooks(service)
    }

    /// Returns canonical project JSON for `compose config`.
    public func config(project: ComposeProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns canonical project YAML for `compose config --format yaml`.
    public func configYAML(project: ComposeProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(project)
        let object = try JSONSerialization.jsonObject(with: data)
        return YAMLDocumentRenderer.render(object)
    }

    /// Returns Docker Compose compatible config projections for supported flags.
    public func config(project: ComposeProject, options: ComposeConfigOptions) throws -> String {
        if options.lockImageDigests || options.resolveImageDigests {
            throw ComposeError.invalidProject("config image digest options require async image resolution")
        }
        if options.quiet {
            _ = try selectedServices(project: project, selected: options.services)
            return ""
        }

        if options.environment {
            return configEnvironment(project: project)
        }
        if let hash = options.hash {
            return try configHashes(project: project, services: options.services, hash: hash)
        }
        if options.images {
            return try lineProjection(configImages(project: project, services: options.services))
        }
        if options.models {
            return lineProjection((project.models ?? [:]).keys.sorted())
        }
        if options.networks {
            return lineProjection(project.networks.keys.sorted())
        }
        if options.profiles {
            return lineProjection(Array(Set(project.profiles)).sorted())
        }
        if options.servicesOnly {
            return lineProjection(project.services.keys.sorted())
        }
        if let variables = options.variables {
            return configVariables(variables)
        }
        if options.volumes {
            return lineProjection(project.volumes.keys.sorted())
        }

        let scopedProject = try project.filtered(to: options.services, allResources: options.allResources)
        return try config(project: scopedProject, format: options.format, commandName: options.commandName)
    }

    /// Returns Docker Compose compatible config output that may resolve image digests.
    public func config(project: ComposeProject, resolvingImageDigests options: ComposeConfigOptions) async throws -> String {
        if options.lockImageDigests {
            return try await configImageDigestLock(project: project, options: options)
        }
        guard options.resolveImageDigests else {
            return try config(project: project, options: options)
        }

        var renderOptions = options
        renderOptions.resolveImageDigests = false
        renderOptions.lockImageDigests = false
        guard configOutputUsesImageDigests(options: renderOptions) else {
            return try config(project: project, options: renderOptions)
        }
        let resolvedProject = try await projectResolvingImageDigests(project: project, selected: options.services)
        return try config(project: resolvedProject, options: renderOptions)
    }

    /// Returns Docker Compose compatible variable projection output.
    public func config(variables: [ComposeVariable]) -> String {
        configVariables(variables)
    }

    /// Creates project resources and starts selected services in dependency order.
    @discardableResult
    public func up(project: ComposeProject, options up: ComposeUpOptions) async throws -> Int32? {
        try validate(project: project)
        try validateUpOptions(up)
        let project = try projectByApplyingNoAttach(project: project, services: up.noAttach)
        try validateUpAttachSelections(project: project, options: up)
        if up.noStart {
            try await create(
                project: project,
                options: createOptions(from: up),
                alwaysRecreateDeps: up.alwaysRecreateDeps,
                recreateTimeout: up.timeout,
            )
            return nil
        }
        let selectedServiceReferences = try up.noDeps && !up.services.isEmpty
            ? selectedServices(project: project, selected: up.services)
            : orderedServices(project: project, selected: up.services)
        var waitTargets: [ServiceContainerTarget] = []
        var workingProject = try projectByValidatingLinks(project: project, activeServiceNames: Set(selectedServiceReferences.map(\.name)))
        let services = try selectedServiceReferences.map { service in
            guard let activeService = workingProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return activeService
        }
        let serviceLayers = try serviceDependencyLayers(services: services)
        if up.menuWatch {
            try validateUpMenuWatchToggle(project: workingProject, serviceNames: services.map(\.name))
        }
        let scaleOverrides = try parseScaleOverrides(project: project, scales: up.scales)
        let dependencyRecreateServices = try servicesToRecreateBecauseDependencies(
            project: workingProject,
            selected: up.services,
            noDeps: up.noDeps,
            alwaysRecreateDeps: up.alwaysRecreateDeps,
            services: services,
        )
        let validateDependencies = !(up.noDeps && !up.services.isEmpty)
        try validatePullPolicy(up.pullPolicy)
        try validateRuntimeSupport(services: services, project: workingProject, validateDependencies: validateDependencies)
        let attachLogMode = upUsesAttachLogFollow(up)
        let exitControlMode = upUsesExitControl(up)
        let attachedLogServices = try upAttachedLogServices(project: workingProject, services: services, options: up)
        let outputAttachedServices = up.menu
            ? try upMenuLogServices(
                project: workingProject,
                services: services,
                attachLogServices: attachedLogServices,
                options: up,
            )
            : attachedLogServices
        let outputAttachedServiceNames = Set(outputAttachedServices.map(\.name))
        let externalVolumeMounts = try await resolveExternalVolumeMounts(project: workingProject, services: services)
        try validatePublishedPorts(services: services)
        try validateReplicaSupport(services: services, scaleOverrides: scaleOverrides)
        let detachStartedContainers = up.detach || up.wait || attachLogMode || exitControlMode || up.menu
        let imageHealthCheckCache = ComposeImageHealthCheckCache()
        var outputAttachments: [ComposeUpOutputAttachment] = []
        defer {
            for attachment in outputAttachments {
                attachment.cancel()
            }
        }

        let buildBeforePull = up.build && !up.noBuild && isMissingPullPolicy(up.pullPolicy)
        if buildBeforePull {
            try await build(project: workingProject, services: services.map(\.name), noCache: false, quiet: up.quietBuild)
        }

        try await applyPullPolicy(
            up.pullPolicy,
            project: workingProject,
            services: services,
            quiet: up.quietPull,
            quietBuild: up.quietBuild,
            allowBuild: !up.noBuild && !up.build,
            skipBuildableMissingImages: buildBeforePull,
        )

        if up.build, !buildBeforePull {
            try await build(project: workingProject, services: services.map(\.name), noCache: false, quiet: up.quietBuild)
        }

        try await validateRuntimeHealthChecks(project: workingProject, services: services, cache: imageHealthCheckCache)
        try await validateRuntimeImageVolumes(
            project: workingProject,
            services: services,
            externalVolumeMounts: externalVolumeMounts,
            pullPolicy: up.pullPolicy,
        )
        try await ensureResources(
            project: projectBySelectingResources(project: workingProject, services: services)
        )

        var changedServices = Set<String>()
        for serviceLayer in serviceLayers {
            let activeServices = serviceLayer.map { workingProject.services[$0.name] ?? $0 }
            let parallelLimit = try engineOperationParallelLimit(operationCount: activeServices.count)
            if parallelLimit == nil || activeServices.contains(where: { $0.provider != nil }) {
                for service in activeServices {
                    if service.provider != nil {
                        if validateDependencies {
                            try await waitForDependencyConditions(project: workingProject, service: service)
                        }
                        let variables = try await runProvider(project: workingProject, service: service, action: .up)
                        if !variables.isEmpty {
                            workingProject = projectByInjectingProviderEnvironment(
                                project: workingProject,
                                providerServiceName: service.name,
                                variables: variables,
                            )
                        }
                        changedServices.insert(service.name)
                        continue
                    }
                    let result = try await reconcileUpService(
                        service: service,
                        context: ComposeUpServiceContext(
                            project: workingProject,
                            options: up,
                            scaleOverrides: scaleOverrides,
                            externalVolumeMounts: externalVolumeMounts,
                            imageHealthCheckCache: imageHealthCheckCache,
                            dependencyRecreateServices: dependencyRecreateServices,
                            changedServices: changedServices,
                            validateDependencies: validateDependencies,
                            detachStartedContainers: detachStartedContainers,
                            outputAttachedServiceNames: outputAttachedServiceNames,
                        ),
                    )
                    waitTargets.append(contentsOf: result.waitTargets)
                    outputAttachments.append(contentsOf: result.outputAttachments)
                    if result.changed {
                        changedServices.insert(result.serviceName)
                    }
                }
                continue
            }

            guard let parallelLimit else {
                continue
            }
            let concurrentContext = ConcurrentEngineOperationValue(value: ComposeUpServiceContext(
                project: workingProject,
                options: up,
                scaleOverrides: scaleOverrides,
                externalVolumeMounts: externalVolumeMounts,
                imageHealthCheckCache: imageHealthCheckCache,
                dependencyRecreateServices: dependencyRecreateServices,
                changedServices: changedServices,
                validateDependencies: validateDependencies,
                detachStartedContainers: detachStartedContainers,
                outputAttachedServiceNames: outputAttachedServiceNames,
            ))
            let results = try await runBoundedEngineOperationResults(
                activeServices,
                limit: parallelLimit,
            ) { [self, concurrentContext] service in
                try await reconcileUpService(
                    service: service,
                    context: concurrentContext.value,
                )
            }
            for result in results {
                waitTargets.append(contentsOf: result.waitTargets)
                outputAttachments.append(contentsOf: result.outputAttachments)
                if result.changed {
                    changedServices.insert(result.serviceName)
                }
            }
        }

        let removeOrphans = up.removeOrphans || options.removeOrphans
        let declaredContainers = try declaredServiceContainerNames(project: workingProject, scaleOverrides: scaleOverrides)
        let preservedServices = orphanProtectedServiceNames(project: workingProject, scaleOverrides: scaleOverrides)
        if removeOrphans {
            try await removeRemainingProjectContainers(
                project: workingProject,
                excluding: declaredContainers,
                preservingServices: preservedServices,
                timeout: up.timeout,
                confirmBeforeRemoval: !up.assumeYes,
            )
        } else {
            try await warnAboutRemainingProjectContainers(
                project: workingProject,
                excluding: declaredContainers,
                preservingServices: preservedServices,
            )
        }
        if up.wait {
            try await waitForReadyServiceTargets(waitTargets, timeout: up.waitTimeout, command: "up --wait")
        }
        if up.menu {
            let menuServices = try upMenuLogServices(
                project: workingProject,
                services: services,
                attachLogServices: attachedLogServices,
                options: up,
            )
            let targets = try await serviceContainerTargets(project: workingProject, services: menuServices)
            outputAttachments = try await completeUpOutputAttachments(
                targets: targets,
                prepared: outputAttachments,
                options: up,
            )
            let startedTargets = try await serviceContainerTargets(project: workingProject, services: services)
            let exitControlOperation: (@Sendable () async throws -> Int32)?
            if exitControlMode {
                let exitControlProject = UncheckedSendable(value: workingProject)
                let exitControlServices = UncheckedSendable(value: services)
                let exitControlOptions = UncheckedSendable(value: up)
                exitControlOperation = { [self] in
                    try await waitForUpExitControl(
                        project: exitControlProject.value,
                        services: exitControlServices.value,
                        options: exitControlOptions.value,
                    )
                }
            } else {
                exitControlOperation = nil
            }
            return try await followMenuUpLogs(
                project: workingProject,
                services: services,
                targets: targets,
                outputAttachments: outputAttachments,
                startedTargets: startedTargets,
                options: up,
                exitControlOperation: exitControlOperation,
            )
        }
        if attachLogMode {
            let targets = try await serviceContainerTargets(project: workingProject, services: attachedLogServices)
            outputAttachments = try await completeUpOutputAttachments(
                targets: targets,
                prepared: outputAttachments,
                options: up,
            )
            if exitControlMode {
                let startedTargets = try await serviceContainerTargets(project: workingProject, services: services)
                let exitControlProject = UncheckedSendable(value: workingProject)
                let exitControlServices = UncheckedSendable(value: services)
                let exitControlOptions = UncheckedSendable(value: up)
                return try await followAttachedUpLogsUntilExitControl(
                    session: ComposeUpLogSession(
                        project: workingProject,
                        targets: targets,
                        outputAttachments: outputAttachments,
                        startedTargets: startedTargets,
                        stopServices: services.map(\.name),
                        options: up,
                    ),
                    exitControlOperation: { [self] in
                        try await waitForUpExitControl(
                            project: exitControlProject.value,
                            services: exitControlServices.value,
                            options: exitControlOptions.value,
                        )
                    },
                )
            }
            try await followAttachedUpLogs(
                session: ComposeUpLogSession(
                    project: workingProject,
                    targets: targets,
                    outputAttachments: outputAttachments,
                    startedTargets: [],
                    stopServices: services.map(\.name),
                    options: up,
                ),
            )
        }
        return nil
    }

    /// Reconciles one non-provider service after its dependency layer is ready.
    private func reconcileUpService(
        service: ComposeService,
        context: ComposeUpServiceContext,
    ) async throws -> ComposeUpServiceResult {
        let project = context.project
        let up = context.options
        if context.validateDependencies {
            try await waitForDependencyConditions(project: project, service: service)
        }
        if shouldBuildServiceForUp(up, service: service) {
            try await build(project: project, services: [service.name], noCache: false, quiet: up.quietBuild)
        }

        let replicaCount = try serviceReplicaCount(service, scaleOverrides: context.scaleOverrides)
        var serviceChanged = false
        var preStartTargets: [ServiceContainerTarget] = []
        var outputStartTargets: [ServiceContainerTarget] = []
        var outputAttachments: [ComposeUpOutputAttachment] = []
        var waitTargets: [ServiceContainerTarget] = []
        let outputAttached = context.outputAttachedServiceNames.contains(service.name)
        if replicaCount > 0 {
            for replicaIndex in 1 ... replicaCount {
                let name = try serviceContainerName(project: project, service: service, index: replicaIndex)
                let existing = try await inspectContainer(name)
                let reconcileOutcome = try await reconcileServiceContainer(
                    project: project,
                    service: service,
                    request: ServiceContainerReconcileRequest(
                        name: name,
                        existing: existing,
                        runOptions: RunArgumentOptions {
                            $0.command = hasPreStartHooks(service) || outputAttached ? "create" : "run"
                            $0.detach = !hasPreStartHooks(service) && !outputAttached
                                && context.detachStartedContainers
                            $0.containerIndex = replicaIndex
                            $0.replicaCount = replicaCount
                        },
                        externalVolumeMounts: context.externalVolumeMounts,
                        imageHealthCheckCache: context.imageHealthCheckCache,
                        forceRecreate: up.forceRecreate,
                        noRecreate: up.noRecreate,
                        renewAnonymousVolumes: up.renewAnonymousVolumes,
                        dependencyRecreateServices: context.dependencyRecreateServices,
                        recreateTimeout: up.timeout,
                    ),
                )
                serviceChanged = serviceChanged || reconcileOutcome.changed
                if hasPreStartHooks(service) {
                    preStartTargets.append(ServiceContainerTarget(
                        service: service,
                        index: replicaIndex,
                        name: name,
                        status: reconcileOutcome.changed ? "created" : existing?.status,
                    ))
                }
                let target = ServiceContainerTarget(
                    service: service,
                    index: replicaIndex,
                    name: name,
                    status: reconcileOutcome.changed ? "created" : existing?.status,
                )
                if outputAttached {
                    outputStartTargets.append(target)
                }
                if up.wait {
                    waitTargets.append(ServiceContainerTarget(service: service, index: replicaIndex, name: name))
                }
            }
        }
        if outputAttached, !outputStartTargets.isEmpty {
            outputAttachments = try await startOutputAttachedServiceTargets(
                project: project,
                service: service,
                targets: outputStartTargets,
                options: up,
            )
        } else if !preStartTargets.isEmpty {
            try await startServiceTargets(
                project: project,
                service: service,
                targets: preStartTargets,
            )
        }
        if shouldPruneServiceReplicas(service, scaleOverrides: context.scaleOverrides) {
            try await removeServiceReplicasAbove(
                project: project,
                service: service,
                desiredCount: replicaCount,
                timeout: up.timeout,
            )
        }
        if serviceChanged {
            return ComposeUpServiceResult(
                serviceName: service.name,
                waitTargets: waitTargets,
                outputAttachments: outputAttachments,
                changed: true,
            )
        }
        guard shouldRestartAfterDependencyChange(
            service: service,
            changedServices: context.changedServices,
        ) else {
            return ComposeUpServiceResult(
                serviceName: service.name,
                waitTargets: waitTargets,
                outputAttachments: outputAttachments,
                changed: false,
            )
        }

        let targets = try await serviceContainerTargets(project: project, services: [service])
        for target in targets {
            if outputAttached {
                try await stopContainer(service: service, containerName: target.name, timeout: up.timeout)
                let attachment = try await prepareUpOutputAttachment(
                    target: target,
                    mode: .beforeStart,
                    options: up,
                )
                do {
                    if options.dryRun {
                        try await startContainer(service: service, containerName: target.name)
                    } else {
                        try await runPostStartHooks(service: service, containerID: target.name)
                    }
                    outputAttachments.append(attachment)
                } catch {
                    attachment.cancel()
                    throw error
                }
            } else {
                try await restartContainer(service: service, containerName: target.name, timeout: up.timeout)
            }
        }
        return ComposeUpServiceResult(
            serviceName: service.name,
            waitTargets: waitTargets,
            outputAttachments: outputAttachments,
            changed: !targets.isEmpty,
        )
    }

    /// Runs service-level pre-start hooks, attaches each stopped replica, and
    /// starts it only after the runtime has registered output descriptors.
    private func startOutputAttachedServiceTargets(
        project: ComposeProject,
        service: ComposeService,
        targets: [ServiceContainerTarget],
        options up: ComposeUpOptions,
    ) async throws -> [ComposeUpOutputAttachment] {
        let orderedTargets = targets.sorted { $0.index < $1.index }
        let targetsToStart = orderedTargets.filter { !isStartedServiceTarget($0) }
        guard !targetsToStart.isEmpty else {
            return []
        }
        if hasPreStartHooks(service), targetsToStart.count == orderedTargets.count {
            try await runPreStartHooks(
                project: project,
                service: service,
                target: targetsToStart[0],
            )
        }

        var attachments: [ComposeUpOutputAttachment] = []
        do {
            for target in targetsToStart {
                let attachment = try await prepareUpOutputAttachment(
                    target: target,
                    mode: .beforeStart,
                    options: up,
                )
                do {
                    if options.dryRun {
                        try await startContainer(service: service, containerName: target.name)
                    } else {
                        try await runPostStartHooks(service: service, containerID: target.name)
                    }
                    attachments.append(attachment)
                } catch {
                    attachment.cancel()
                    throw error
                }
            }
            return attachments
        } catch {
            for attachment in attachments {
                attachment.cancel()
            }
            throw error
        }
    }

    /// Returns whether foreground `up` should aggregate service output through followed logs.
    func upUsesAttachLogFollow(_ up: ComposeUpOptions) -> Bool {
        !up.detach && !up.wait && !up.noStart && !up.menu
    }

    /// Returns whether `up` should stop the project after service exits.
    func upUsesExitControl(_ up: ComposeUpOptions) -> Bool {
        !up.detach && !up.wait && !up.noStart && (up.abortOnContainerExit || up.abortOnContainerFailure || up.exitCodeFrom != nil)
    }

    /// Returns the services whose logs should be followed while `up --menu` owns shortcuts.
    func upMenuLogServices(
        project: ComposeProject,
        services: [ComposeService],
        attachLogServices: [ComposeService],
        options up: ComposeUpOptions,
    ) throws -> [ComposeService] {
        if upUsesAttachLogFollow(up) {
            return attachLogServices
        }
        let noAttachNames = try up.noAttach.isEmpty
            ? Set<String>()
            : Set(selectedServices(project: project, selected: up.noAttach).map(\.name))
        return services.filter { service in
            service.attach != false && !noAttachNames.contains(service.name)
        }
    }

    /// Validates attach-related service selections before runtime side effects.
    func validateUpAttachSelections(project: ComposeProject, options up: ComposeUpOptions) throws {
        guard !up.attach.isEmpty else {
            return
        }
        let attachNames = try Set(selectedServices(project: project, selected: up.attach).map(\.name))
        let noAttachNames = try up.noAttach.isEmpty
            ? Set<String>()
            : Set(selectedServices(project: project, selected: up.noAttach).map(\.name))
        let conflictingNames = attachNames.intersection(noAttachNames)
        if let name = conflictingNames.sorted().first {
            throw ComposeError.invalidProject("service '\(name)' cannot be used with both --attach and --no-attach")
        }
    }

    /// Returns the services whose logs should be followed for `up --attach`.
    func upAttachedLogServices(
        project: ComposeProject,
        services: [ComposeService],
        options up: ComposeUpOptions,
    ) throws -> [ComposeService] {
        guard upUsesAttachLogFollow(up) else {
            return []
        }
        let startedNames = Set(services.map(\.name))
        let noAttachNames = try up.noAttach.isEmpty
            ? Set<String>()
            : Set(selectedServices(project: project, selected: up.noAttach).map(\.name))
        if up.attach.isEmpty {
            return services.filter { service in
                !noAttachNames.contains(service.name) && service.attach != false
            }
        }

        let requestedAttachNames = try Set(selectedServices(project: project, selected: up.attach).map(\.name))
        let attachNames: Set<String> = if up.attachDependencies, !up.noDeps {
            try Set(orderedServices(project: project, selected: up.attach).map(\.name))
        } else {
            requestedAttachNames
        }
        let outsideStartedServices = attachNames.subtracting(startedNames)
        if let name = outsideStartedServices.sorted().first {
            throw ComposeError.invalidProject("up --attach service '\(name)' is not being started")
        }
        return services.filter { attachNames.contains($0.name) && !noAttachNames.contains($0.name) }
    }

    /// Follows attached `up` output while a Compose-owned menu handles shortcuts.
    func followMenuUpLogs(
        project: ComposeProject,
        services: [ComposeService],
        targets: [ServiceContainerTarget],
        outputAttachments: [ComposeUpOutputAttachment],
        startedTargets: [ServiceContainerTarget],
        options up: ComposeUpOptions,
        exitControlOperation: (@Sendable () async throws -> Int32)? = nil,
    ) async throws -> Int32? {
        if options.dryRun {
            for target in targets {
                emitComposeRuntimeOperation(["attach", "--no-stdin", target.name])
            }
            if let exitControlOperation {
                return try await exitControlOperation()
            }
            return nil
        }
        guard !outputAttachments.isEmpty || !startedTargets.isEmpty || exitControlOperation != nil else {
            return nil
        }

        let watchToggle = ComposeUpMenuWatchToggle()
        let menuExitCode = ComposeUpExitCode()
        let sendableProject = UncheckedSendable(value: project)
        let sendableServices = UncheckedSendable(value: services)
        let sendableStartedTargets = UncheckedSendable(value: startedTargets)
        let serviceNames = services.map(\.name)
        let menuLogSession = UncheckedSendable(value: ComposeUpLogSession(
            project: project,
            targets: targets,
            outputAttachments: outputAttachments,
            startedTargets: startedTargets,
            stopServices: serviceNames,
            options: up,
        ))
        let timeout = up.timeout
        let quietBuild = up.quietBuild
        let emitStatus = options.emit
        let watchAvailable = services.contains { service in
            !(service.develop?.watch ?? []).isEmpty
        }
        let startMenuWatch: @Sendable () async throws -> Void = { [self, sendableProject, serviceNames, quietBuild] in
            try await watch(
                project: sendableProject.value,
                options: ComposeWatchOptions(
                    services: serviceNames,
                    noUp: true,
                    prune: true,
                    quiet: quietBuild,
                ),
            )
        }
        let setMenuWatchEnabled: @Sendable (
            Bool,
            @escaping @Sendable (Bool) async -> Void,
        ) async throws -> Bool = { [self, sendableProject, serviceNames, emitStatus, startMenuWatch] desiredEnabled, stateChanged in
            if desiredEnabled {
                try validateUpMenuWatchToggle(project: sendableProject.value, serviceNames: serviceNames)
            }
            return await watchToggle.setEnabled(
                desiredEnabled,
                emit: emitStatus,
                stateChanged: stateChanged,
                start: startMenuWatch,
            )
        }
        let configuration = ComposeUpMenuConfiguration(
            projectName: project.name,
            watchEnabled: up.menuWatch,
            watchAvailable: watchAvailable,
            colorEnabled: up.colorPrefixes,
            emitStatus: emitStatus,
            actions: ComposeUpMenuActions(
                gracefulStop: { [self, sendableProject, serviceNames, timeout] in
                    try await stop(project: sendableProject.value, services: serviceNames, timeout: timeout)
                },
                forceStop: { [self, sendableProject, sendableServices] in
                    for target in try await serviceContainerTargets(project: sendableProject.value, services: sendableServices.value) {
                        try await lifecycleManager.killContainer(id: target.name, signal: "KILL")
                    }
                },
                toggleWatch: { desiredEnabled, stateChanged in
                    try await setMenuWatchEnabled(desiredEnabled, stateChanged)
                },
            ),
        )

        do {
            try await upMenuController.runMenuSession(
                configuration: configuration,
            ) { [self, sendableStartedTargets, menuLogSession, exitControlOperation, menuExitCode] in
                if let exitControlOperation {
                    let code = try await runUpLogOperationUntilExitControl(
                        session: menuLogSession.value,
                        exitControlOperation: exitControlOperation,
                    )
                    await menuExitCode.set(code)
                    return
                }
                if menuLogSession.value.outputAttachments.isEmpty {
                    try await waitForUpServiceTargets(sendableStartedTargets.value)
                    return
                }
                try await upLogFollowOperation(menuLogSession.value)()
            }
        } catch {
            await watchToggle.stop()
            throw error
        }
        await watchToggle.stop()
        return await menuExitCode.value
    }

    /// Validates a menu watch toggle before the UI reports watch as enabled.
    func validateUpMenuWatchToggle(project: ComposeProject, serviceNames: [String]) throws {
        let selected = try selectedServices(project: project, selected: serviceNames)
        let watchServices = selected.filter { service in
            guard let triggers = service.develop?.watch else {
                return false
            }
            return !triggers.isEmpty
        }
        guard !watchServices.isEmpty else {
            let selected = serviceNames.isEmpty ? "project" : "selected services"
            throw ComposeError.invalidProject("\(selected) does not declare develop.watch triggers")
        }
        try validateWatchTriggers(services: watchServices)
        _ = try watchPlans(project: project, services: watchServices)
    }

    /// Waits for `up` exit-control conditions, stops the project, and returns the CLI exit code.
    func waitForUpExitControl(project: ComposeProject, services: [ComposeService], options up: ComposeUpOptions) async throws -> Int32 {
        let allTargets = try await serviceContainerTargets(project: project, services: services)
        let exitCodeTargets: [ServiceContainerTarget]
        if let exitCodeFrom = up.exitCodeFrom {
            let selected = try selectedServices(project: project, selected: [exitCodeFrom])
            let startedNames = Set(services.map(\.name))
            if let service = selected.first, !startedNames.contains(service.name) {
                throw ComposeError.invalidProject("up --exit-code-from service '\(service.name)' is not being started")
            }
            let selectedNames = Set(selected.map(\.name))
            exitCodeTargets = allTargets.filter { selectedNames.contains($0.service.name) }
        } else {
            exitCodeTargets = []
        }
        guard !allTargets.isEmpty else {
            throw ComposeError.invalidProject("up exit-control requires at least one service container")
        }
        if up.exitCodeFrom != nil, exitCodeTargets.isEmpty {
            throw ComposeError.invalidProject("up --exit-code-from service has no started containers")
        }

        if options.dryRun {
            for target in allTargets {
                emitComposeRuntimeOperation(["wait", target.name])
            }
            try await stopUpExitControlServices(
                project: project,
                services: services,
                targets: allTargets,
                timeout: up.timeout,
            )
            return 0
        }

        if up.exitCodeFrom != nil {
            return try await waitForExitCodeFromAndStop(
                project: project,
                services: services,
                targets: allTargets,
                exitCodeTargets: exitCodeTargets,
                timeout: up.timeout,
            )
        }
        let result = try await up.abortOnContainerFailure && !up.abortOnContainerExit
            ? waitForFirstServiceContainerFailureOrCompletion(allTargets)
            : waitForFirstServiceContainerExit(allTargets)
        try await stopUpExitControlServices(
            project: project,
            services: services,
            targets: allTargets,
            timeout: up.timeout,
        )
        return result.exitCode
    }

    /// Waits for any started service to exit, then returns the selected service status.
    func waitForExitCodeFromAndStop(
        project: ComposeProject,
        services: [ComposeService],
        targets: [ServiceContainerTarget],
        exitCodeTargets: [ServiceContainerTarget],
        timeout: Int?,
    ) async throws -> Int32 {
        let exitCodeTargetNames = Set(exitCodeTargets.map(\.name))
        let lifecycleManager = lifecycleManager
        let waitTasks: [Task<ServiceContainerWaitResult, Error>] = targets.map { target in
            let containerName = target.name
            return Task {
                try await ServiceContainerWaitResult(
                    containerName: containerName,
                    exitCode: lifecycleManager.waitContainer(id: containerName),
                )
            }
        }
        defer {
            waitTasks.forEach { $0.cancel() }
        }
        return try await withThrowingTaskGroup(of: ServiceContainerWaitResult.self) { group in
            for waitTask in waitTasks {
                group.addTask {
                    try await waitTask.value
                }
            }

            guard let firstResult = try await group.next() else {
                throw ComposeError.invalidProject("up exit-control requires at least one service container")
            }
            try await stopUpExitControlServices(
                project: project,
                services: services,
                targets: targets,
                timeout: timeout,
            )
            if exitCodeTargetNames.contains(firstResult.containerName) {
                group.cancelAll()
                return firstResult.exitCode
            }
            while let result = try await group.next() {
                if exitCodeTargetNames.contains(result.containerName) {
                    group.cancelAll()
                    return result.exitCode
                }
            }
            throw ComposeError.invalidProject("up --exit-code-from service did not report an exit status")
        }
    }

    /// Stops exit-controlled services without deleting their containers or logs.
    private func stopUpExitControlServices(
        project: ComposeProject,
        services: [ComposeService],
        targets: [ServiceContainerTarget],
        timeout: Int?,
    ) async throws {
        for serviceLayer in try serviceDependencyLayers(services: services).reversed() {
            let serviceNames = Set(serviceLayer.map(\.name))
            for service in serviceLayer.reversed() where service.provider != nil {
                _ = try await runProvider(project: project, service: service, action: .stop)
            }
            let lifecycleTargets = targets.filter {
                serviceNames.contains($0.service.name) && $0.service.provider == nil
            }
            guard let limit = try engineOperationParallelLimit(operationCount: lifecycleTargets.count) else {
                for target in lifecycleTargets.reversed() {
                    try await ignoringMissingContainer {
                        try await stopContainer(
                            service: target.service,
                            containerName: target.name,
                            timeout: timeout,
                        )
                    }
                }
                continue
            }
            try await runBoundedEngineOperations(lifecycleTargets, limit: limit) { [self] target in
                try await ignoringMissingContainer {
                    try await stopContainer(
                        service: target.service,
                        containerName: target.name,
                        timeout: timeout,
                    )
                }
            }
        }
    }

    /// Waits until a selected service container fails or all selected targets exit successfully.
    func waitForFirstServiceContainerFailureOrCompletion(_ targets: [ServiceContainerTarget]) async throws -> ServiceContainerWaitResult {
        let lifecycleManager = lifecycleManager
        let waitTasks: [Task<ServiceContainerWaitResult, Error>] = targets.map { target in
            let containerName = target.name
            return Task {
                try await ServiceContainerWaitResult(
                    containerName: containerName,
                    exitCode: lifecycleManager.waitContainer(id: containerName),
                )
            }
        }
        defer {
            waitTasks.forEach { $0.cancel() }
        }
        return try await withThrowingTaskGroup(of: ServiceContainerWaitResult.self) { group in
            for waitTask in waitTasks {
                group.addTask {
                    try await waitTask.value
                }
            }

            var successfulCompletions = 0
            while let result = try await group.next() {
                if result.exitCode != 0 {
                    group.cancelAll()
                    return result
                }
                successfulCompletions += 1
                if successfulCompletions == targets.count {
                    return result
                }
            }
            throw ComposeError.invalidProject("up exit-control requires at least one service container")
        }
    }

    /// Marks services excluded from attached `up` output before target selection.
    func projectByApplyingNoAttach(project: ComposeProject, services: [String]) throws -> ComposeProject {
        guard !services.isEmpty else {
            return project
        }
        let noAttachServices = try Set(selectedServices(project: project, selected: services).map(\.name))
        var project = project
        for serviceName in noAttachServices {
            project.services[serviceName]?.attach = false
        }
        return project
    }

    /// Reuses or recreates one deterministic service container.
    func reconcileServiceContainer(
        project: ComposeProject,
        service: ComposeService,
        request: ServiceContainerReconcileRequest,
    ) async throws -> ServiceContainerReconcileOutcome {
        let name = request.name
        let existing = request.existing
        var didRecreate = false
        if let existing {
            if request.noRecreate {
                options.emit("compose: reusing existing container \(name)")
                return .unchanged
            }
            if !request.forceRecreate,
               !request.renewAnonymousVolumes,
               !request.dependencyRecreateServices.contains(service.name),
               try existing.configHash == configHash(
                   project: project,
                   service: service,
                   externalVolumeMounts: request.externalVolumeMounts,
                   materializedConfigSecretRoot: options.materializedConfigSecretDirectory,
               )
            {
                options.emit("compose: reusing existing container \(name)")
                return .unchanged
            }
            try await stopContainer(service: service, containerName: name, timeout: request.recreateTimeout)
            try await deleteContainer(name)
            didRecreate = true
        }
        if request.renewAnonymousVolumes {
            try await removeExistingAnonymousVolumes(
                project: project,
                target: ServiceContainerTarget(
                    service: service,
                    index: request.runOptions.containerIndex ?? 1,
                    name: name,
                ),
            )
        }
        try await ensureLabeledAnonymousVolumes(
            project: project,
            service: service,
            context: MountRenderContext(
                project: project,
                service: service,
                containerName: name,
                oneOff: false,
                containerIndex: request.runOptions.containerIndex,
            ),
            externalVolumeMounts: request.externalVolumeMounts,
        )

        let arguments = try await runArguments(
            project: project,
            service: service,
            options: request.runOptions,
            externalVolumeMounts: request.externalVolumeMounts,
            imageHealthCheckCache: request.imageHealthCheckCache,
        )
        try await runContainerWithProgress(
            arguments,
            message: reconcileProgressMessage(service: service, command: request.runOptions.command),
            emitOutput: false,
            logging: try runtimeLogConfiguration(service: service),
        )
        if request.runOptions.command == "run" {
            try await runPostStartHooks(service: service, containerID: name)
        }
        return didRecreate ? .recreated : .created
    }

    /// Creates project resources and selected service containers without starting them.
    public func create(project: ComposeProject, options createOptions: ComposeCreateOptions) async throws {
        try await create(project: project, options: createOptions, alwaysRecreateDeps: false, recreateTimeout: nil)
    }

    /// Scales selected services through the detached `up` reconciliation path.
    public func scale(project: ComposeProject, options scale: ComposeScaleOptions) async throws {
        guard !scale.scales.isEmpty else {
            throw ComposeError.invalidProject("scale requires at least one SERVICE=REPLICAS argument")
        }
        let scaleOverrides = try parseScaleOverrides(project: project, scales: scale.scales)
        try await up(
            project: project,
            options: ComposeUpOptions {
                $0.services = scaleOverrides.keys.sorted()
                $0.scales = scale.scales
                $0.detach = true
                $0.noDeps = scale.noDeps
            },
        )
    }
}

private actor ComposeUpMenuWatchToggle {
    private var taskID: UUID?
    private var task: Task<Void, Never>?

    func setEnabled(
        _ enabled: Bool,
        emit: @escaping @Sendable (String) -> Void,
        stateChanged: @escaping @Sendable (Bool) async -> Void,
        start: @escaping @Sendable () async throws -> Void,
    ) -> Bool {
        guard enabled else {
            if let task {
                task.cancel()
                self.task = nil
                taskID = nil
                emit("compose: watch stopping")
            }
            return false
        }
        if task != nil {
            return true
        }

        let id = UUID()
        taskID = id
        task = Task {
            do {
                try await start()
            } catch is CancellationError {
                // Normal when the menu disables watch or detaches.
            } catch {
                emit("Watch -> \(error)")
            }
            if finish(id: id) {
                await stateChanged(false)
            }
        }
        return true
    }

    func stop() {
        if let task {
            task.cancel()
            self.task = nil
            taskID = nil
        }
    }

    private func finish(id: UUID) -> Bool {
        guard taskID == id else {
            return false
        }
        task = nil
        taskID = nil
        return true
    }
}
