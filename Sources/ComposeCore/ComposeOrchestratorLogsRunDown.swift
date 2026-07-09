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

public extension ComposeOrchestrator {
    /// Renders direct runtime arguments for log dry-run output.
    internal func logRuntimeArguments(id: String, follow: Bool, tail: Int?, since: String?, until: String?, timestamps: Bool) -> [String] {
        var args = ["logs"]
        if follow {
            args.append("--follow")
        }
        if let tail {
            args.append(contentsOf: ["-n", String(tail)])
        }
        if let since {
            args.append(contentsOf: ["--since", since])
        }
        if let until {
            args.append(contentsOf: ["--until", until])
        }
        if timestamps {
            args.append("--timestamps")
        }
        args.append(id)
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
        var args = ["exec"]
        if exec.detach {
            args.append("--detach")
        }
        for environment in exec.environment {
            args.append(contentsOf: ["--env", environment])
        }
        if let user = exec.user {
            args.append(contentsOf: ["--user", user])
        }
        if let workingDirectory = exec.workingDirectory {
            args.append(contentsOf: ["--workdir", workingDirectory])
        }
        if exec.privileged {
            args.append("--privileged")
        }
        if exec.interactive, !exec.detach {
            args.append("--interactive")
        }
        if exec.tty, !exec.detach {
            args.append("--tty")
        }
        let containerID = try await serviceContainerID(project: project, service: service, index: exec.index)
        args.append(containerID)
        args.append(contentsOf: exec.command)
        if !options.dryRun {
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
            if status != 0 {
                throw ComposeError.commandFailed(command: shellQuoted([options.containerBinary] + args), status: status, stderr: "")
            }
            return
        }
        let foregroundInteractiveExec = !exec.detach && (exec.interactive || exec.tty)
        try await runContainer(
            args,
            inheritedIO: foregroundInteractiveExec,
            replaceProcess: foregroundInteractiveExec,
        )
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
        var runProject = project
        guard var service = runProject.services[serviceName] else {
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
        try applyRunVolumeOverrides(run, project: &runProject, service: &service)
        runProject.services[serviceName] = service
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
        try validateRuntimeSupport(services: dependencyServices + [service], project: runProject, validateDependencies: !run.noDeps)
        runProject = try await projectByResolvingExternalLinks(project: runProject, services: dependencyServices + [service])
        service = runProject.services[serviceName] ?? service
        dependencyServices = try selectedDependencyServices.map { service in
            guard let activeService = runProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return activeService
        }
        try validateOneOffRunLifecycleHooks(service: service, options: run)
        try validatePublishedPorts(services: dependencyServices)
        let publishedPorts = (run.servicePorts ? service.ports ?? [] : []) + run.publish
        try validatePublishedPorts(publishedPorts, serviceName: service.name)
        let imageHealthCheckCache = ComposeImageHealthCheckCache()
        let externalVolumeMounts = try await resolveExternalVolumeMounts(
            project: runProject,
            services: dependencyServices + [service],
        )
        if run.build, service.build != nil {
            try await build(project: runProject, services: [service.name], noCache: false, quiet: run.quietBuild)
        }
        try await applyPullPolicy(
            run.pullPolicy,
            project: runProject,
            services: [service],
            quiet: run.quietPull,
            quietBuild: run.quietBuild,
        )
        try await validateRuntimeHealthChecks(project: runProject, services: dependencyServices + [service], cache: imageHealthCheckCache)
        try await ensureResources(project: projectBySelectingResources(
            project: runProject,
            services: dependencyServices + [service],
        ))
        runProject = try await startDependencyServices(
            project: runProject,
            services: dependencyServices,
            externalVolumeMounts: externalVolumeMounts,
            imageHealthCheckCache: imageHealthCheckCache,
        )
        service = runProject.services[serviceName] ?? service
        if !run.noDeps {
            try await waitForDependencyConditions(project: runProject, service: service)
        }
        let containerName = oneOffRunContainerName(project: runProject, service: service, requestedName: run.containerName)
        let foregroundInteractiveRun = !run.quiet && !run.detach && (service.tty == true || service.stdinOpen == true)
        if run.removeOrphans, foregroundInteractiveRun {
            let declaredContainers = try declaredServiceContainerNames(project: runProject, scaleOverrides: [:])
            let preservedServices = orphanProtectedServiceNames(project: runProject, scaleOverrides: [:])
            try await removeRemainingProjectContainers(
                project: runProject,
                excluding: declaredContainers,
                preservingServices: preservedServices,
            )
        }
        try await ensureLabeledAnonymousVolumes(
            project: runProject,
            service: service,
            context: MountRenderContext(
                project: runProject,
                service: service,
                containerIndex: nil,
                replicaCount: nil,
            ),
            externalVolumeMounts: externalVolumeMounts
        )
        let arguments = try await runArguments(
            project: runProject,
            service: service,
            options: RunArgumentOptions {
                $0.detach = run.detach
                $0.remove = run.remove
                $0.oneOff = true
                $0.publishedPorts = publishedPorts
                $0.containerNameOverride = containerName
                $0.labelOverrides = labelOverrides
                $0.envFiles = run.envFiles
            },
            externalVolumeMounts: externalVolumeMounts,
            imageHealthCheckCache: imageHealthCheckCache,
        )
        try await runContainerWithProgress(
            arguments,
            message: "Running \(service.name)",
            quiet: run.quiet,
            inheritedIO: foregroundInteractiveRun,
            replaceProcess: foregroundInteractiveRun,
        )
        if run.detach {
            try await runPostStartHooks(service: service, containerID: containerName)
        }
        if run.removeOrphans, !foregroundInteractiveRun {
            let declaredContainers = try declaredServiceContainerNames(project: runProject, scaleOverrides: [:])
            let preservedServices = orphanProtectedServiceNames(project: runProject, scaleOverrides: [:])
            try await removeRemainingProjectContainers(
                project: runProject,
                excluding: declaredContainers,
                preservingServices: preservedServices,
            )
        }
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
            try await waitForStartedServiceTargets(targets, timeout: start.waitTimeout, command: "start --wait")
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
        let targets = try await removableServiceContainerTargets(project: project, services: services, stopFirst: stopFirst)
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
            for target in targets {
                if target.status.map({ !isRemovableStoppedContainerStatus($0) }) ?? true {
                    try await ignoringMissingContainer {
                        try await stopContainer(service: target.service, containerName: target.name)
                    }
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
