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

/// Direct-runtime log arguments used by dry-run rendering.
struct RuntimeLogArgumentRequest {
    let id: String
    let follow: Bool
    let tail: Int?
    let since: String?
    let until: String?
    let timestamps: Bool
}

private struct ComposeRunProjectConfiguration {
    let project: ComposeProject
    let service: ComposeService
}

private struct ComposeRunDependencyPreparation {
    let project: ComposeProject
    let service: ComposeService
    let dependencies: [ComposeService]
    let labelOverrides: [ComposeLabelOverride]
    let publishedPorts: [String]
}

private struct ComposeRunServicePreparation {
    let project: ComposeProject
    let service: ComposeService
    let externalVolumeMounts: ExternalVolumeMounts
    let imageHealthCheckCache: ComposeImageHealthCheckCache
}

private struct ComposeOneOffRunInvocation {
    let labelOverrides: [ComposeLabelOverride]
    let publishedPorts: [String]
    let containerName: String
    let managedLifecycleRun: Bool
}

public extension ComposeOrchestrator {
    /// Renders direct runtime arguments for log dry-run output.
    internal func logRuntimeArguments(_ request: RuntimeLogArgumentRequest) -> [String] {
        var args = ["logs"]
        if request.follow {
            args.append("--follow")
        }
        if let tail = request.tail {
            args.append(contentsOf: ["-n", String(tail)])
        }
        if let since = request.since {
            args.append(contentsOf: ["--since", since])
        }
        if let until = request.until {
            args.append(contentsOf: ["--until", until])
        }
        if request.timestamps {
            args.append("--timestamps")
        }
        args.append(request.id)
        return args
    }

    /// Follows all selected log targets concurrently.
    internal func followLogTargets(
        _ targets: [ServiceContainerTarget],
        options runtimeOptions: RuntimeLogOptions,
    ) async throws {
        let logManager = logManager
        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in targets {
                let request = RuntimeLogRequest(
                    id: target.name,
                    follow: true,
                    tail: runtimeOptions.tail,
                    since: runtimeOptions.since,
                    until: runtimeOptions.until,
                    timestamps: runtimeOptions.timestamps,
                    emit: logEmitter(
                        for: target,
                        noLogPrefix: runtimeOptions.noLogPrefix,
                        colorPrefixes: runtimeOptions.colorPrefixes,
                    ),
                )
                group.addTask { [request, logManager] in
                    try await logManager.logs(
                        id: request.id,
                        tail: request.tail,
                        follow: request.follow,
                        since: request.since,
                        until: request.until,
                        timestamps: request.timestamps,
                        emit: request.emit,
                    )
                }
            }
            while let completed = try await group.next() {
                _ = completed
            }
        }
    }

    /// Emits static or single-target followed logs.
    internal func emitLogs(_ request: RuntimeLogRequest) async throws {
        try await logManager.logs(
            id: request.id,
            tail: request.tail,
            follow: request.follow,
            since: request.since,
            until: request.until,
            timestamps: request.timestamps,
            emit: request.emit,
        )
    }

    /// Returns the user-facing log emitter for a selected service target.
    internal func logEmitter(
        for target: ServiceContainerTarget,
        noLogPrefix: Bool,
        colorPrefixes: Bool,
    ) -> @Sendable (Data) -> Void {
        let emit = options.emitData
        guard !noLogPrefix else {
            return emit
        }
        let prefix = colorPrefixes ? colorizedLogPrefix(for: target) : logPrefix(for: target)
        let prefixData = Data("\(prefix) | ".utf8)
        return { output in
            let lines = recordsForCompleteLogData(output)
            var prefixed = Data()
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    prefixed.append(UInt8(ascii: "\n"))
                }
                prefixed.append(prefixData)
                prefixed.append(line)
            }
            emit(prefixed)
        }
    }

    /// Returns the ANSI-colored Compose log prefix for a selected service target.
    internal func colorizedLogPrefix(for target: ServiceContainerTarget) -> String {
        let prefix = logPrefix(for: target)
        let code = logColorCode(for: target)
        return "\u{001B}[\(code)m\(prefix)\u{001B}[0m"
    }

    /// Returns the Compose log prefix for a selected service target.
    internal func logPrefix(for target: ServiceContainerTarget) -> String {
        if let containerName = target.service.containerName, !containerName.isEmpty {
            return containerName
        }
        guard target.index != Int.max else {
            return target.name
        }
        return "\(target.service.name)-\(target.index)"
    }

    /// Returns a deterministic ANSI foreground color code for a log target.
    internal func logColorCode(for target: ServiceContainerTarget) -> String {
        let palette = ["36", "32", "33", "35", "34", "31"]
        let replicaSeed = target.index == Int.max ? 0 : target.index
        let seed = target.service.name.unicodeScalars.reduce(replicaSeed) { partial, scalar in
            partial + Int(scalar.value)
        }
        return palette[seed % palette.count]
    }

    /// Runs `compose watch` by applying initial syncs and polling watched paths
    /// for Compose Develop Specification actions.
    func watch(project: ComposeProject, options watch: ComposeWatchOptions = ComposeWatchOptions()) async throws {
        let services = try selectedServices(project: project, selected: watch.services)
        let watchServices = services.filter { service in
            guard let triggers = service.develop?.watch else {
                return false
            }
            return !triggers.isEmpty
        }
        guard !watchServices.isEmpty else {
            let selected = watch.services.isEmpty ? "project" : "selected services"
            throw ComposeError.invalidProject("\(selected) does not declare develop.watch triggers")
        }
        try validateWatchTriggers(services: watchServices)
        if options.dryRun {
            emitWatchDryRunPlan(project: project, services: watchServices, watch: watch)
            return
        }

        let runtimeProject = projectWithoutDevelopMetadata(project)
        let runtimeServices = try watchServices.map { service in
            guard let runtimeService = runtimeProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return runtimeService
        }
        if !watch.noUp {
            var initialUp = watch.initialUpOptions ?? ComposeUpOptions()
            initialUp.services = runtimeServices.map(\.name)
            initialUp.detach = true
            initialUp.quietBuild = initialUp.quietBuild || watch.quiet
            initialUp.quietPull = initialUp.quietPull || watch.quiet
            try await up(
                project: runtimeProject,
                options: initialUp,
            )
        }

        var plans = try watchPlans(project: project, services: watchServices)
        try await performInitialWatchSync(project: runtimeProject, plans: plans, quiet: watch.quiet)
        do {
            try await runWatchLoop(project: runtimeProject, plans: &plans, options: watch)
        } catch is CancellationError {
            if !watch.quiet {
                options.emit("compose: watch stopped")
            }
        }
    }

    /// Attaches to service output using the apple/container log stream.
    func attach(project: ComposeProject, serviceName: String, options attach: ComposeAttachOptions) async throws {
        let proxySignals = try validateAttachOptions(attach)
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        let id = try await serviceContainerID(project: project, service: service, index: attach.index)
        let args = ["logs", "--follow", id]
        let followLogs: @Sendable () async throws -> Void = {
            try await self.logManager.logs(
                id: id,
                tail: nil,
                follow: true,
                since: nil,
                until: nil,
                timestamps: false,
                emit: self.options.emit,
            )
        }
        if options.dryRun {
            emitComposeRuntimeOperation(args)
        } else if proxySignals {
            try await signalProxy.withSignalProxy(
                signals: ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"],
                handler: { [lifecycleManager] signal in
                    try? await lifecycleManager.killContainer(id: id, signal: signal)
                },
                operation: followLogs,
            )
        } else {
            try await followLogs()
        }
    }

    /// Executes a command in an existing service container.
    func exec(
        project: ComposeProject,
        serviceName: String,
        command: [String],
        interactive: Bool = true,
        tty: Bool = true,
    ) async throws {
        try await exec(
            project: project,
            serviceName: serviceName,
            options: ComposeExecOptions {
                $0.command = command
                $0.interactive = interactive
                $0.tty = tty
            },
        )
    }

    /// Executes a command in an existing service container with Compose options.
    func exec(project: ComposeProject, serviceName: String, options exec: ComposeExecOptions) async throws {
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        guard !exec.command.isEmpty else {
            throw ComposeError.invalidProject("exec requires a command")
        }
        let containerID = try await serviceContainerID(project: project, service: service, index: exec.index)
        let arguments = execArguments(containerID: containerID, options: exec)
        try await executeCommand(
            service: service,
            containerID: containerID,
            options: exec,
            arguments: arguments,
        )
    }

    /// Renders the direct runtime argument vector for `compose exec`.
    private func execArguments(containerID: String, options exec: ComposeExecOptions) -> [String] {
        var arguments = ["exec"]
        if exec.detach {
            arguments.append("--detach")
        }
        for environment in exec.environment {
            arguments.append(contentsOf: ["--env", environment])
        }
        if let user = exec.user {
            arguments.append(contentsOf: ["--user", user])
        }
        if let workingDirectory = exec.workingDirectory {
            arguments.append(contentsOf: ["--workdir", workingDirectory])
        }
        if exec.privileged {
            arguments.append("--privileged")
        }
        if exec.interactive, !exec.detach {
            arguments.append("--interactive")
        }
        if exec.tty, !exec.detach {
            arguments.append("--tty")
        }
        arguments.append(containerID)
        arguments.append(contentsOf: exec.command)
        return arguments
    }

    /// Executes an already-rendered `compose exec` operation.
    private func executeCommand(
        service: ComposeService,
        containerID: String,
        options exec: ComposeExecOptions,
        arguments: [String],
    ) async throws {
        if options.dryRun {
            let interactive = !exec.detach && (exec.interactive || exec.tty)
            try await runContainer(
                arguments,
                inheritedIO: interactive,
                replaceProcess: interactive,
            )
            return
        }
        if exec.detach {
            try await execManager.execDetached(
                request: ContainerDetachedExecRequest(
                    id: containerID,
                    command: exec.command,
                    environment: exec.environment,
                    user: exec.user,
                    workingDirectory: exec.workingDirectory,
                    privileged: exec.privileged,
                ),
                emit: options.emit,
            )
            return
        }
        if exec.interactive || exec.tty {
            options.progress.handoff("Executing \(service.name)")
        }
        let status = try await execManager.execAttached(
            request: ContainerAttachedExecRequest(
                id: containerID,
                command: exec.command,
                environment: exec.environment,
                user: exec.user,
                workingDirectory: exec.workingDirectory,
                privileged: exec.privileged,
                terminal: .init(interactive: exec.interactive, tty: exec.tty),
            ),
        )
        guard status == 0 else {
            throw ComposeError.commandFailed(
                command: shellQuoted([options.containerBinary] + arguments),
                status: status,
                stderr: "",
            )
        }
    }

    /// Runs a one-off container for a service.
    func run(project: ComposeProject, serviceName: String, command: [String], remove: Bool) async throws {
        try await run(
            project: project,
            serviceName: serviceName,
            options: ComposeRunOptions {
                $0.command = command
                $0.remove = remove
            },
        )
    }

    /// Runs a one-off container for a service with Docker Compose compatible options.
    func run(project: ComposeProject, serviceName: String, options run: ComposeRunOptions) async throws {
        let configuration = try runProjectConfiguration(
            project: project,
            serviceName: serviceName,
            options: run,
        )
        let dependencies = try await prepareRunDependencies(
            project: configuration.project,
            service: configuration.service,
            serviceName: serviceName,
            options: run,
        )
        let preparation = try await prepareRunService(
            project: dependencies.project,
            service: dependencies.service,
            dependencies: dependencies.dependencies,
            options: run,
        )
        try await executeOneOffRun(
            preparation: preparation,
            labelOverrides: dependencies.labelOverrides,
            publishedPorts: dependencies.publishedPorts,
            options: run,
        )
    }

    /// Validates the selected service and its dependency graph for a one-off run.
    private func prepareRunDependencies(
        project: ComposeProject,
        service: ComposeService,
        serviceName: String,
        options run: ComposeRunOptions,
    ) async throws -> ComposeRunDependencyPreparation {
        var runProject = project
        var service = service
        try validateProjectNetworks(runProject)
        let labelOverrides = try parseRunLabelOverrides(run.labels)
        try validateRunLabelOverridesAgainstAnnotations(labelOverrides, service: service)
        try validatePullPolicy(run.pullPolicy)
        let selectedDependencyServices = try run.noDeps
            ? []
            : orderedServices(project: runProject, selected: [serviceName]).filter { $0.name != serviceName }
        var activeServiceNames = Set(selectedDependencyServices.map(\.name))
        activeServiceNames.insert(serviceName)
        runProject = try projectByApplyingLinks(project: runProject, activeServiceNames: activeServiceNames)
        service = runProject.services[serviceName] ?? service
        var dependencyServices = try selectedDependencyServices.map { service in
            guard let activeService = runProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return activeService
        }
        try validateRuntimeSupport(
            services: dependencyServices + [service],
            project: runProject,
            validateDependencies: !run.noDeps,
        )
        runProject = try await projectByResolvingExternalLinks(
            project: runProject,
            services: dependencyServices + [service],
        )
        service = runProject.services[serviceName] ?? service
        dependencyServices = try selectedDependencyServices.map { service in
            guard let activeService = runProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return activeService
        }
        try validateRunLifecycleHooks(service: service, options: run)
        try validatePublishedPorts(services: dependencyServices)
        let publishedPorts = (run.servicePorts ? service.ports ?? [] : []) + run.publish
        try validatePublishedPorts(publishedPorts, serviceName: service.name)
        return ComposeRunDependencyPreparation(
            project: runProject,
            service: service,
            dependencies: dependencyServices,
            labelOverrides: labelOverrides,
            publishedPorts: publishedPorts,
        )
    }

    /// Starts and runs the one-off service container after dependency preparation.
    private func executeOneOffRun(
        preparation: ComposeRunServicePreparation,
        labelOverrides: [ComposeLabelOverride],
        publishedPorts: [String],
        options run: ComposeRunOptions,
    ) async throws {
        let containerName = oneOffRunContainerName(
            project: preparation.project,
            service: preparation.service,
            requestedName: run.containerName,
        )
        let foregroundInteractiveRun = isForegroundInteractiveRun(
            service: preparation.service,
            options: run,
        )
        let managedLifecycleRun = !run.detach && hasLifecycleHooks(preparation.service)
        try await removeRunOrphans(
            project: preparation.project,
            requested: run.removeOrphans,
            foregroundInteractive: foregroundInteractiveRun,
        )
        try await ensureRunAnonymousVolumes(preparation: preparation)
        let invocation = ComposeOneOffRunInvocation(
            labelOverrides: labelOverrides,
            publishedPorts: publishedPorts,
            containerName: containerName,
            managedLifecycleRun: managedLifecycleRun,
        )
        let arguments = try await oneOffRunArguments(
            preparation: preparation,
            invocation: invocation,
            options: run,
        )
        try await runContainerWithProgress(
            arguments,
            message: "Running \(preparation.service.name)",
            quiet: run.quiet,
            inheritedIO: foregroundInteractiveRun,
            replaceProcess: foregroundInteractiveRun,
        )
        if run.detach {
            try await runPostStartHooks(service: preparation.service, containerID: containerName)
        }
        try await finishManagedLifecycleRun(
            service: preparation.service,
            containerName: containerName,
            arguments: arguments,
            managed: managedLifecycleRun,
            remove: run.remove,
        )
        try await removeRunOrphansAfterOneOffRun(
            preparation: preparation,
            options: run,
            foregroundInteractive: foregroundInteractiveRun,
        )
    }

    /// Determines whether the runtime should inherit terminal input and output for a run.
    private func isForegroundInteractiveRun(service: ComposeService, options run: ComposeRunOptions) -> Bool {
        !run.quiet && !run.detach && (service.tty == true || service.stdinOpen == true)
    }

    /// Validates hook execution before the run has allocated runtime resources.
    private func validateRunLifecycleHooks(service: ComposeService, options run: ComposeRunOptions) throws {
        try validateOneOffRunLifecycleHooks(
            service: service,
            options: run,
            foregroundInteractiveRun: isForegroundInteractiveRun(service: service, options: run),
        )
    }

    /// Removes requested project orphans after a non-interactive one-off run finishes.
    private func removeRunOrphansAfterOneOffRun(
        preparation: ComposeRunServicePreparation,
        options run: ComposeRunOptions,
        foregroundInteractive: Bool,
    ) async throws {
        try await removeRunOrphans(
            project: preparation.project,
            requested: run.removeOrphans,
            foregroundInteractive: !foregroundInteractive,
        )
    }

    /// Renders the direct runtime invocation for a one-off container.
    private func oneOffRunArguments(
        preparation: ComposeRunServicePreparation,
        invocation: ComposeOneOffRunInvocation,
        options run: ComposeRunOptions,
    ) async throws -> [String] {
        try await runArguments(
            project: preparation.project,
            service: preparation.service,
            options: RunArgumentOptions {
                $0.detach = run.detach || invocation.managedLifecycleRun
                // A lifecycle-managed foreground run starts detached so it can
                // run hooks before following output. Keep `--rm` out of that
                // invocation: runtimes can reject `--detach --rm`, and removal
                // could otherwise race log collection. Cleanup runs after the
                // one-off process and its log stream both finish.
                $0.remove = run.remove && !invocation.managedLifecycleRun
                $0.oneOff = true
                $0.publishedPorts = invocation.publishedPorts
                $0.containerNameOverride = invocation.containerName
                $0.labelOverrides = invocation.labelOverrides
                $0.envFiles = run.envFiles
            },
            externalVolumeMounts: preparation.externalVolumeMounts,
            imageHealthCheckCache: preparation.imageHealthCheckCache,
        )
    }

    /// Runs hooks and collects the exit status for a lifecycle-managed one-off run.
    private func finishManagedLifecycleRun(
        service: ComposeService,
        containerName: String,
        arguments: [String],
        managed: Bool,
        remove: Bool,
    ) async throws {
        guard managed else { return }
        let status: Int32
        do {
            try await runPostStartHooks(service: service, containerID: containerName)
            status = try await followForegroundOneOffRun(service: service, containerName: containerName)
        } catch {
            if remove {
                try? await lifecycleManager.deleteContainer(id: containerName, force: false)
            }
            throw error
        }
        if remove {
            try await lifecycleManager.deleteContainer(id: containerName, force: false)
        }
        guard status == 0 else {
            throw ComposeError.commandFailed(
                command: shellQuoted([options.containerBinary] + arguments),
                status: status,
                stderr: "",
            )
        }
    }

    /// Creates labeled anonymous volumes that the one-off service requires.
    private func ensureRunAnonymousVolumes(preparation: ComposeRunServicePreparation) async throws {
        try await ensureLabeledAnonymousVolumes(
            project: preparation.project,
            service: preparation.service,
            context: MountRenderContext(
                project: preparation.project,
                service: preparation.service,
                containerIndex: nil,
                replicaCount: nil,
            ),
            externalVolumeMounts: preparation.externalVolumeMounts,
        )
    }

    /// Applies one-off CLI overrides before validating the project graph.
    private func runProjectConfiguration(
        project: ComposeProject,
        serviceName: String,
        options run: ComposeRunOptions,
    ) throws -> ComposeRunProjectConfiguration {
        var project = project
        guard var service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        if !run.command.isEmpty {
            service.command = run.command
        }
        if let entrypoint = run.entrypoint {
            service.entrypoint = [entrypoint]
        }
        if let workingDirectory = run.workingDirectory {
            service.workingDir = workingDirectory
        }
        if let user = run.user {
            service.user = user
        }
        if run.noTty {
            service.tty = false
        }
        if run.interactive {
            service.stdinOpen = true
        }
        if !run.useAliases {
            service.networkAliases = nil
        }
        try applyRunEnvironmentOverrides(run, service: &service)
        try applyRunCapabilityOverrides(run, service: &service)
        try applyRunVolumeOverrides(run, project: &project, service: &service)
        project.services[serviceName] = service
        return ComposeRunProjectConfiguration(project: project, service: service)
    }

    /// Removes orphaned project containers at the lifecycle phase selected by Compose.
    private func removeRunOrphans(
        project: ComposeProject,
        requested: Bool,
        foregroundInteractive: Bool,
    ) async throws {
        guard requested, foregroundInteractive else { return }
        let declaredContainers = try declaredServiceContainerNames(project: project, scaleOverrides: [:])
        let preservedServices = orphanProtectedServiceNames(project: project, scaleOverrides: [:])
        try await removeRemainingProjectContainers(
            project: project,
            excluding: declaredContainers,
            preservingServices: preservedServices,
        )
    }

    /// Builds images and starts dependency services before the one-off container runs.
    private func prepareRunService(
        project: ComposeProject,
        service: ComposeService,
        dependencies: [ComposeService],
        options run: ComposeRunOptions,
    ) async throws -> ComposeRunServicePreparation {
        let cache = ComposeImageHealthCheckCache()
        let services = dependencies + [service]
        let externalVolumeMounts = try await resolveExternalVolumeMounts(
            project: project,
            services: services,
        )
        if run.build, service.build != nil {
            try await build(project: project, services: [service.name], noCache: false, quiet: run.quietBuild)
        }
        try await applyPullPolicy(
            run.pullPolicy,
            project: project,
            services: [service],
            quiet: run.quietPull,
            quietBuild: run.quietBuild,
        )
        try await validateRuntimeHealthChecks(project: project, services: services, cache: cache)
        try await ensureResources(
            project: projectBySelectingResources(project: project, services: services),
        )
        let preparedProject = try await startDependencyServices(
            project: project,
            services: dependencies,
            externalVolumeMounts: externalVolumeMounts,
            imageHealthCheckCache: cache,
        )
        let preparedService = preparedProject.services[service.name] ?? service
        if !run.noDeps {
            try await waitForDependencyConditions(project: preparedProject, service: preparedService)
        }
        return ComposeRunServicePreparation(
            project: preparedProject,
            service: preparedService,
            externalVolumeMounts: externalVolumeMounts,
            imageHealthCheckCache: cache,
        )
    }

    /// Starts selected service containers.
    func start(project: ComposeProject, services selected: [String]) async throws {
        try await start(project: project, options: ComposeStartOptions { $0.services = selected })
    }

    /// Starts selected service containers.
    func start(project: ComposeProject, options start: ComposeStartOptions) async throws {
        try validateTimeoutSeconds(start.waitTimeout, command: "start", option: "--wait-timeout")
        let services = try start.services.isEmpty
            ? orderedServices(project: project, selected: [])
            : selectedServices(project: project, selected: start.services)
        let targets = try await serviceContainerTargets(project: project, services: services)
        for target in targets {
            try await startContainer(service: target.service, containerName: target.name)
        }
        if start.wait {
            try await waitForReadyServiceTargets(targets, timeout: start.waitTimeout, command: "start --wait")
        }
    }

    /// Stops selected service containers.
    func stop(project: ComposeProject, services selected: [String], timeout: Int? = nil) async throws {
        try validateTimeoutSeconds(timeout, command: "stop")
        let services = try selected.isEmpty
            ? Array(orderedServices(project: project, selected: []).reversed())
            : selectedServices(project: project, selected: selected)
        for service in services where service.provider != nil {
            _ = try await runProvider(project: project, service: service, action: .stop)
        }
        for target in try await serviceContainerTargets(project: project, services: services) {
            try await stopContainer(service: target.service, containerName: target.name, timeout: timeout)
        }
    }

    /// Restarts selected service containers.
    func restart(project: ComposeProject, services selected: [String], timeout: Int? = nil) async throws {
        try await restart(project: project, options: ComposeRestartOptions {
            $0.services = selected
            $0.timeout = timeout
        })
    }

    /// Restarts selected service containers, including dependencies unless disabled.
    func restart(project: ComposeProject, options restart: ComposeRestartOptions) async throws {
        try validateTimeoutSeconds(restart.timeout, command: "restart")
        let services = try restart.noDeps && !restart.services.isEmpty
            ? selectedServices(project: project, selected: restart.services)
            : orderedServices(project: project, selected: restart.services)
        for service in services.reversed() where service.provider != nil {
            _ = try await runProvider(project: project, service: service, action: .stop)
        }
        for service in services.reversed() {
            for target in try await serviceContainerTargets(project: project, services: [service]) {
                try await stopContainer(service: target.service, containerName: target.name, timeout: restart.timeout)
            }
        }
        for service in services {
            for target in try await serviceContainerTargets(project: project, services: [service]) {
                try await startContainer(service: target.service, containerName: target.name)
            }
        }
    }

    /// Removes selected service containers.
    func rm(
        project: ComposeProject,
        services selected: [String],
        stopFirst: Bool,
        force: Bool = false,
        volumes: Bool = false,
    ) async throws {
        let services = try selectedServices(project: project, selected: selected)
        let targets = try await removableServiceContainerTargets(
            project: project,
            services: services,
            stopFirst: stopFirst,
        )
        if targets.isEmpty, !options.dryRun {
            options.emit("No stopped containers")
            return
        }
        if !targets.isEmpty, !force, !options.dryRun {
            let names = targets.map(\.name).joined(separator: ", ")
            guard try await options.confirm("Going to remove \(names)\nAre you sure? [yN] ") else {
                return
            }
        }
        if stopFirst {
            for target in targets where target.status.map({ !isRemovableStoppedContainerStatus($0) }) ?? true {
                try await ignoringMissingContainer {
                    try await stopContainer(service: target.service, containerName: target.name)
                }
            }
        }
        for target in targets {
            try await ignoringMissingContainer {
                try await deleteContainer(target.name, force: force)
            }
        }
        if volumes {
            for volume in try anonymousVolumeRuntimeNames(project: project, targets: targets) {
                let args = ["volume", "delete", volume]
                if options.dryRun {
                    try await runContainer(args, check: false)
                } else {
                    try await resourceManager.deleteVolume(name: volume)
                }
            }
        }
    }
}
