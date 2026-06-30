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

private enum ComposeUpMenuOperationResult {
    case logsFinished
    case exitCode(Int32)
}

private actor ComposeUpMenuExitCode {
    private var storage: Int32?

    var value: Int32? {
        storage
    }

    func set(_ value: Int32) {
        storage = value
    }
}

extension ComposeOrchestrator {
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
            return try lineProjection(selectedServices(project: project, selected: options.services).map(\.name).sorted())
        }
        if let variables = options.variables {
            return configVariables(variables)
        }
        if options.volumes {
            return lineProjection(project.volumes.keys.sorted())
        }

        let scopedProject = try project.filtered(to: options.services)
        return try config(project: scopedProject, format: options.format)
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
        var workingProject = try projectByApplyingLinks(project: project, activeServiceNames: Set(selectedServiceReferences.map(\.name)))
        var services = try selectedServiceReferences.map { service in
            guard let activeService = workingProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return activeService
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
        workingProject = try await projectByResolvingExternalLinks(project: workingProject, services: services)
        services = try selectedServiceReferences.map { service in
            guard let activeService = workingProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return activeService
        }
        let attachLogMode = upUsesAttachLogFollow(up)
        let exitControlMode = upUsesExitControl(up)
        let attachedLogServices = try upAttachedLogServices(project: workingProject, services: services, options: up)
        let externalVolumeMounts = try await resolveExternalVolumeMounts(project: workingProject, services: services)
        try validatePublishedPorts(services: services)
        try validateReplicaSupport(services: services, scaleOverrides: scaleOverrides)
        let attachedOutputService = try foregroundServiceTarget(
            project: workingProject,
            services: services,
            scaleOverrides: scaleOverrides,
            detach: up.detach || up.wait || attachLogMode || exitControlMode || up.menu,
        )
        let attachedForegroundService = up.timestamps ? nil : attachedOutputService
        if !up.timestamps {
            try validateAttachedPostStartSupport(target: attachedForegroundService)
        }
        let imageHealthCheckCache = ComposeImageHealthCheckCache()

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
        try await ensureResources(project: workingProject)

        var changedServices = Set<String>()
        for serviceReference in services {
            let service = workingProject.services[serviceReference.name] ?? serviceReference
            if validateDependencies {
                try await waitForDependencyConditions(project: workingProject, service: service)
            }
            if service.provider != nil {
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

            if shouldBuildServiceForUp(up, service: service) {
                try await build(project: workingProject, services: [service.name], noCache: false, quiet: up.quietBuild)
            }

            let replicaCount = try serviceReplicaCount(service, scaleOverrides: scaleOverrides)
            var serviceChanged = false
            var jobTargets: [ServiceContainerTarget] = []
            if replicaCount > 0 {
                var priorReplicaRecreated = false
                for replicaIndex in 1 ... replicaCount {
                    let name = try serviceContainerName(project: workingProject, service: service, index: replicaIndex)
                    if isDeployJobService(service) {
                        jobTargets.append(ServiceContainerTarget(service: service, index: replicaIndex, name: name))
                    }
                    let reconcileOutcome = try await reconcileServiceContainer(
                        project: workingProject,
                        service: service,
                        request: ServiceContainerReconcileRequest(
                            name: name,
                            runOptions: RunArgumentOptions {
                                $0.detach = up.detach || up.wait || isDeployJobService(service) || attachedForegroundService?.name != name
                                $0.containerIndex = replicaIndex
                                $0.replicaCount = replicaCount
                            },
                            externalVolumeMounts: externalVolumeMounts,
                            imageHealthCheckCache: imageHealthCheckCache,
                            forceRecreate: up.forceRecreate,
                            noRecreate: up.noRecreate,
                            renewAnonymousVolumes: up.renewAnonymousVolumes,
                            dependencyRecreateServices: dependencyRecreateServices,
                            recreateTimeout: up.timeout,
                            delayBeforeRecreate: priorReplicaRecreated,
                        ),
                    )
                    serviceChanged = serviceChanged || reconcileOutcome.changed
                    if reconcileOutcome.recreated {
                        priorReplicaRecreated = true
                    }
                    if up.wait, !isDeployJobService(service) {
                        waitTargets.append(ServiceContainerTarget(service: service, index: replicaIndex, name: name))
                    }
                }
            }
            if shouldPruneServiceReplicas(service, scaleOverrides: scaleOverrides) {
                try await removeServiceReplicasAbove(project: workingProject, service: service, desiredCount: replicaCount, timeout: up.timeout)
            }
            try await waitForDeployJobService(service: service, targets: jobTargets)

            if serviceChanged {
                changedServices.insert(service.name)
                continue
            }
            if shouldRestartAfterDependencyChange(service: service, changedServices: changedServices) {
                let targets = try await serviceContainerTargets(project: workingProject, services: [service])
                for target in targets {
                    try await restartContainer(service: service, containerName: target.name, timeout: up.timeout)
                }
                if !targets.isEmpty {
                    changedServices.insert(service.name)
                }
            }
        }

        if up.removeOrphans {
            let declaredContainers = try declaredServiceContainerNames(project: workingProject, scaleOverrides: scaleOverrides)
            let preservedServices = orphanProtectedServiceNames(project: workingProject, scaleOverrides: scaleOverrides)
            try await removeRemainingProjectContainers(
                project: workingProject,
                excluding: declaredContainers,
                preservingServices: preservedServices,
                timeout: up.timeout,
                confirmBeforeRemoval: !up.assumeYes,
            )
        }
        if up.wait {
            try await waitForStartedServiceTargets(waitTargets, timeout: up.waitTimeout, command: "up --wait")
        }
        if up.menu {
            let menuServices = try upMenuLogServices(
                project: workingProject,
                services: services,
                attachLogServices: attachedLogServices,
                options: up,
            )
            let targets = try await serviceContainerTargets(project: workingProject, services: menuServices)
            let startedTargets = try await serviceContainerTargets(project: workingProject, services: services)
            let exitControlOperation: (@Sendable () async throws -> Int32)?
            if exitControlMode {
                let exitControlProject = UncheckedSendable(value: workingProject)
                let exitControlServices = UncheckedSendable(value: services)
                let exitControlOptions = UncheckedSendable(value: up)
                exitControlOperation = { [self] in
                    try await self.waitForUpExitControl(
                        project: exitControlProject.value,
                        services: exitControlServices.value,
                        options: exitControlOptions.value,
                    )
                }
            } else {
                exitControlOperation = nil
            }
            let menuExitCode = try await followMenuUpLogs(
                project: workingProject,
                services: services,
                targets: targets,
                startedTargets: startedTargets,
                options: up,
                exitControlOperation: exitControlOperation,
            )
            return menuExitCode
        }
        if exitControlMode {
            return try await waitForUpExitControl(project: workingProject, services: services, options: up)
        }
        if attachLogMode {
            let targets = try await serviceContainerTargets(project: workingProject, services: attachedLogServices)
            try await followAttachedUpLogs(targets: targets, options: up)
            return nil
        }
        if up.timestamps, let attachedOutputService, !up.detach, !up.wait {
            try await followTimestampedUpLogs(target: attachedOutputService, options: up)
        }
        return nil
    }

    /// Returns whether `up` should use Compose-owned followed log attachment.
    func upUsesAttachLogFollow(_ up: ComposeUpOptions) -> Bool {
        !up.detach && !up.wait && !up.noStart && (!up.attach.isEmpty || up.attachDependencies)
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

    /// Follows service logs for `up --attach` and `up --attach-dependencies`.
    func followAttachedUpLogs(targets: [ServiceContainerTarget], options up: ComposeUpOptions) async throws {
        guard !targets.isEmpty else {
            return
        }
        if options.dryRun {
            for target in targets {
                emitComposeRuntimeOperation(logRuntimeArguments(
                    id: target.name,
                    follow: true,
                    tail: nil,
                    since: nil,
                    until: nil,
                    timestamps: up.timestamps,
                ))
            }
            return
        }

        let runtimeOptions = RuntimeLogOptions(
            tail: nil,
            since: nil,
            until: nil,
            timestamps: up.timestamps,
            noLogPrefix: up.noLogPrefix,
            colorPrefixes: up.colorPrefixes,
        )
        if targets.count > 1 {
            try await followLogTargets(targets, options: runtimeOptions)
            return
        }
        guard let target = targets.first else {
            return
        }
        try await emitLogs(
            RuntimeLogRequest(
                id: target.name,
                follow: true,
                tail: nil,
                since: nil,
                until: nil,
                timestamps: up.timestamps,
                emit: logEmitter(
                    for: target,
                    noLogPrefix: up.noLogPrefix,
                    colorPrefixes: up.colorPrefixes,
                ),
            ),
        )
    }

    /// Follows attached `up` logs while a Compose-owned menu handles shortcuts.
    func followMenuUpLogs(
        project: ComposeProject,
        services: [ComposeService],
        targets: [ServiceContainerTarget],
        startedTargets: [ServiceContainerTarget],
        options up: ComposeUpOptions,
        exitControlOperation: (@Sendable () async throws -> Int32)? = nil,
    ) async throws -> Int32? {
        if options.dryRun {
            for target in targets {
                emitComposeRuntimeOperation(logRuntimeArguments(
                    id: target.name,
                    follow: true,
                    tail: nil,
                    since: nil,
                    until: nil,
                    timestamps: up.timestamps,
                ))
            }
            if let exitControlOperation {
                return try await exitControlOperation()
            }
            return nil
        }
        guard !targets.isEmpty || !startedTargets.isEmpty || exitControlOperation != nil else {
            return nil
        }

        let watchToggle = ComposeUpMenuWatchToggle()
        let menuExitCode = ComposeUpMenuExitCode()
        let runtimeOptions = RuntimeLogOptions(
            tail: nil,
            since: nil,
            until: nil,
            timestamps: up.timestamps,
            noLogPrefix: up.noLogPrefix,
            colorPrefixes: up.colorPrefixes,
        )
        let sendableProject = UncheckedSendable(value: project)
        let sendableServices = UncheckedSendable(value: services)
        let sendableTargets = UncheckedSendable(value: targets)
        let sendableStartedTargets = UncheckedSendable(value: startedTargets)
        let sendableRuntimeOptions = UncheckedSendable(value: runtimeOptions)
        let serviceNames = services.map(\.name)
        let timeout = up.timeout
        let quietBuild = up.quietBuild
        let emitStatus = options.emit
        let configuration = ComposeUpMenuConfiguration(
            projectName: project.name,
            watchEnabled: false,
            watchAvailable: services.contains { service in
                !(service.develop?.watch ?? []).isEmpty
            },
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
                toggleWatch: { [self, sendableProject, serviceNames, quietBuild] desiredEnabled, stateChanged in
                    if desiredEnabled {
                        try validateUpMenuWatchToggle(project: sendableProject.value, serviceNames: serviceNames)
                    }
                    return await watchToggle.setEnabled(
                        desiredEnabled,
                        emit: emitStatus,
                        stateChanged: stateChanged,
                        start: { [self, sendableProject, serviceNames, quietBuild] in
                            try await self.watch(
                                project: sendableProject.value,
                                options: ComposeWatchOptions(
                                    services: serviceNames,
                                    noUp: true,
                                    prune: true,
                                    quiet: quietBuild,
                                ),
                            )
                        },
                    )
                },
            ),
        )

        do {
            try await upMenuController.runMenuSession(
                configuration: configuration
            ) { [self, sendableTargets, sendableStartedTargets, sendableRuntimeOptions, exitControlOperation, menuExitCode] in
                if let exitControlOperation {
                    let code = try await self.runMenuLogOperationUntilExitControl(
                        targets: sendableTargets.value,
                        startedTargets: sendableStartedTargets.value,
                        runtimeOptions: sendableRuntimeOptions.value,
                        exitControlOperation: exitControlOperation,
                    )
                    await menuExitCode.set(code)
                    return
                }
                if sendableTargets.value.isEmpty {
                    try await waitForMenuServiceTargets(sendableStartedTargets.value)
                    return
                }
                try await followLogTargets(sendableTargets.value, options: sendableRuntimeOptions.value)
            }
        } catch {
            await watchToggle.stop()
            throw error
        }
        await watchToggle.stop()
        return await menuExitCode.value
    }

    /// Follows menu logs until exit-control decides the attached `up` result.
    func runMenuLogOperationUntilExitControl(
        targets: [ServiceContainerTarget],
        startedTargets: [ServiceContainerTarget],
        runtimeOptions: RuntimeLogOptions,
        exitControlOperation: @Sendable @escaping () async throws -> Int32,
    ) async throws -> Int32 {
        let sendableTargets = UncheckedSendable(value: targets)
        let sendableStartedTargets = UncheckedSendable(value: startedTargets)
        let sendableRuntimeOptions = UncheckedSendable(value: runtimeOptions)
        return try await withThrowingTaskGroup(of: ComposeUpMenuOperationResult.self) { group in
            if targets.isEmpty, !startedTargets.isEmpty {
                group.addTask { [self, sendableStartedTargets] in
                    try await waitForMenuServiceTargets(sendableStartedTargets.value)
                    return .logsFinished
                }
            } else if !targets.isEmpty {
                group.addTask { [self, sendableTargets, sendableRuntimeOptions] in
                    try await followLogTargets(sendableTargets.value, options: sendableRuntimeOptions.value)
                    return .logsFinished
                }
            }
            group.addTask {
                .exitCode(try await exitControlOperation())
            }

            while let result = try await group.next() {
                switch result {
                case .logsFinished:
                    continue
                case .exitCode(let code):
                    group.cancelAll()
                    return code
                }
            }

            throw ComposeError.invalidProject("up exit-control requires at least one service container")
        }
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

    /// Keeps a menu session alive when selected services intentionally have no attached logs.
    func waitForMenuServiceTargets(_ targets: [ServiceContainerTarget]) async throws {
        guard !targets.isEmpty else {
            return
        }
        let lifecycleManager = lifecycleManager
        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in targets {
                let name = target.name
                group.addTask {
                    _ = try await lifecycleManager.waitContainer(id: name)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Waits for `up` exit-control conditions, tears the project down, and returns the CLI exit code.
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
            try await down(project: project, options: ComposeDownOptions())
            return 0
        }

        if up.exitCodeFrom != nil {
            return try await waitForExitCodeFromAndDown(project: project, targets: allTargets, exitCodeTargets: exitCodeTargets)
        }
        let result = try await up.abortOnContainerFailure && !up.abortOnContainerExit
            ? waitForFirstServiceContainerFailureOrCompletion(allTargets)
            : waitForFirstServiceContainerExit(allTargets)
        try await down(project: project, options: ComposeDownOptions())
        return result.exitCode
    }

    /// Waits for any started service to exit, then returns the selected service status.
    func waitForExitCodeFromAndDown(
        project: ComposeProject,
        targets: [ServiceContainerTarget],
        exitCodeTargets: [ServiceContainerTarget],
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
            try await down(project: project, options: ComposeDownOptions())
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

    /// Follows the service that would normally own foreground output for `up --timestamps`.
    func followTimestampedUpLogs(target: ServiceContainerTarget, options up: ComposeUpOptions) async throws {
        let args = ["logs", "--follow", "--timestamps", target.name]
        if options.dryRun {
            emitComposeRuntimeOperation(args)
            return
        }
        try await logManager.logs(
            id: target.name,
            tail: nil,
            follow: true,
            since: nil,
            until: nil,
            timestamps: true,
            emit: logEmitter(
                for: target,
                noLogPrefix: up.noLogPrefix,
                colorPrefixes: up.colorPrefixes,
            ),
        )
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
        let existing = try await inspectContainer(name)
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
            try await sleepBeforeDeployUpdateIfNeeded(service: service, enabled: request.delayBeforeRecreate)
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
        )
        if request.runOptions.command == "run" {
            try await runPostStartHooks(service: service, containerID: name)
        }
        return didRecreate ? .recreated : .created
    }

    /// Applies a supported stop-first deploy update delay before the next local replica replacement.
    func sleepBeforeDeployUpdateIfNeeded(service: ComposeService, enabled: Bool) async throws {
        guard enabled,
              !options.dryRun,
              let nanoseconds = service.deployUpdateDelayNanoseconds,
              nanoseconds > 0
        else {
            return
        }
        try await options.sleep(.nanoseconds(nanoseconds))
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

private struct UncheckedSendable<Value>: @unchecked Sendable {
    var value: Value
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
