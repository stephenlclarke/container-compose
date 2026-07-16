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
    /// Creates project resources and selected service containers without starting them.
    internal func create(
        project: ComposeProject,
        options create: ComposeCreateOptions,
        alwaysRecreateDeps: Bool,
        recreateTimeout: Int?,
    ) async throws {
        try validate(project: project)
        try validateCreateOptions(create)
        let selectedServiceReferences = try create.noDeps && !create.services.isEmpty
            ? selectedServices(project: project, selected: create.services)
            : orderedServices(project: project, selected: create.services)
        var workingProject = try projectByValidatingLinks(project: project, activeServiceNames: Set(selectedServiceReferences.map(\.name)))
        var services = try selectedServiceReferences.map { service in
            guard let activeService = workingProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return activeService
        }
        let scaleOverrides = try parseScaleOverrides(project: project, scales: create.scales)
        let dependencyRecreateServices = try servicesToRecreateBecauseDependencies(
            project: workingProject,
            selected: create.services,
            noDeps: create.noDeps,
            alwaysRecreateDeps: alwaysRecreateDeps,
            services: services,
        )
        let validateDependencies = !(create.noDeps && !create.services.isEmpty)
        try validateCreatePullPolicy(create.pullPolicy)
        try validateRuntimeSupport(services: services, project: workingProject, validateDependencies: validateDependencies)
        workingProject = try await projectByResolvingExternalLinks(project: workingProject, services: services)
        services = try selectedServiceReferences.map { service in
            guard let activeService = workingProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return activeService
        }
        let externalVolumeMounts = try await resolveExternalVolumeMounts(project: workingProject, services: services)
        try validatePublishedPorts(services: services)
        try validateReplicaSupport(services: services, scaleOverrides: scaleOverrides)
        let imageHealthCheckCache = ComposeImageHealthCheckCache()

        try await applyCreateImagePolicy(create, project: workingProject, services: services)
        try await validateRuntimeHealthChecks(project: workingProject, services: services, cache: imageHealthCheckCache)

        try await ensureResources(project: workingProject)

        for serviceReference in services {
            var service = workingProject.services[serviceReference.name] ?? serviceReference
            if shouldBuildServiceForCreate(create, service: service) {
                try await build(project: project, services: [service.name], noCache: false, quiet: create.quietBuild)
            }

            service = try await serviceByResolvingLinkHosts(
                project: workingProject,
                service: service,
                scaleOverrides: scaleOverrides,
            )
            workingProject.services[service.name] = service

            let replicaCount = try serviceReplicaCount(service, scaleOverrides: scaleOverrides)
            if replicaCount > 0 {
                for replicaIndex in 1 ... replicaCount {
                    let name = try serviceContainerName(project: workingProject, service: service, index: replicaIndex)
                    _ = try await reconcileServiceContainer(
                        project: workingProject,
                        service: service,
                        request: ServiceContainerReconcileRequest(
                            name: name,
                            runOptions: RunArgumentOptions {
                                $0.command = "create"
                                $0.containerIndex = replicaIndex
                                $0.replicaCount = replicaCount
                            },
                            externalVolumeMounts: externalVolumeMounts,
                            imageHealthCheckCache: imageHealthCheckCache,
                            forceRecreate: create.forceRecreate,
                            noRecreate: create.noRecreate,
                            renewAnonymousVolumes: create.renewAnonymousVolumes,
                            dependencyRecreateServices: dependencyRecreateServices,
                            recreateTimeout: recreateTimeout,
                        ),
                    )
                }
            }
            if shouldPruneServiceReplicas(service, scaleOverrides: scaleOverrides) {
                try await removeServiceReplicasAbove(project: workingProject, service: service, desiredCount: replicaCount, timeout: recreateTimeout)
            }
        }

        if create.removeOrphans {
            let declaredContainers = try declaredServiceContainerNames(project: workingProject, scaleOverrides: scaleOverrides)
            let preservedServices = orphanProtectedServiceNames(project: workingProject, scaleOverrides: scaleOverrides)
            try await removeRemainingProjectContainers(
                project: workingProject,
                excluding: declaredContainers,
                preservingServices: preservedServices,
                timeout: recreateTimeout,
                confirmBeforeRemoval: !create.assumeYes,
            )
        }
    }

    /// Converts `up --no-start` options into the equivalent `create` request.
    internal func createOptions(from up: ComposeUpOptions) -> ComposeCreateOptions {
        ComposeCreateOptions {
            $0.services = up.services
            $0.build = up.build
            $0.noBuild = up.noBuild
            $0.forceRecreate = up.forceRecreate
            $0.noRecreate = up.noRecreate
            $0.removeOrphans = up.removeOrphans
            $0.pullPolicy = up.pullPolicy
            $0.scales = up.scales
            $0.noDeps = up.noDeps
            $0.quietBuild = up.quietBuild
            $0.quietPull = up.quietPull
            $0.renewAnonymousVolumes = up.renewAnonymousVolumes
            $0.assumeYes = up.assumeYes
        }
    }

    /// Stops and removes project-scoped resources.
    func down(project: ComposeProject, options down: ComposeDownOptions) async throws {
        try validateTimeoutSeconds(down.timeout, command: "down")
        let imageRemovalPolicy = try downImageRemovalPolicy(down.rmi)
        let projectWideCleanup = down.services.isEmpty
        let services = try projectWideCleanup
            ? orderedServices(project: project, selected: [])
            : selectedServices(project: project, selected: down.services)
        let declaredContainers = try declaredServiceContainerNames(project: project, scaleOverrides: [:])
        let targets = try await serviceContainerTargets(project: project, services: services)
        for service in services.reversed() {
            if service.provider != nil {
                _ = try await runProvider(project: project, service: service, action: .down)
                continue
            }
            for target in targets.filter({ $0.service.name == service.name }).reversed() {
                try await ignoringMissingContainer {
                    try await stopContainer(service: service, containerName: target.name, timeout: down.timeout)
                }
                try await ignoringMissingContainer {
                    try await deleteContainer(target.name)
                }
            }
        }
        if down.removeOrphans {
            try await removeRemainingProjectContainers(project: project, excluding: declaredContainers, timeout: down.timeout)
        }

        if projectWideCleanup, !options.dryRun {
            try removeMaterializedConfigSecrets(
                project: project,
                root: options.materializedConfigSecretDirectory,
            )
        }

        if projectWideCleanup {
            for (name, network) in project.networks.sorted(by: { $0.key < $1.key }) where network.external != true {
                let runtimeName = networkRuntimeName(project: project, composeName: name, network: network)
                let args = ["network", "delete", runtimeName]
                if options.dryRun {
                    try await runContainer(args, check: false)
                } else {
                    try await resourceManager.deleteNetwork(id: runtimeName)
                }
            }
        }

        if down.volumes {
            for volume in try anonymousVolumeRuntimeNames(project: project, targets: targets) {
                let args = ["volume", "delete", volume]
                if options.dryRun {
                    try await runContainer(args, check: false)
                } else {
                    try await resourceManager.deleteVolume(name: volume)
                }
            }
            if projectWideCleanup {
                for (name, volume) in project.volumes.sorted(by: { $0.key < $1.key }) where volume.external != true {
                    let runtimeName = volumeRuntimeName(project: project, composeName: name, volume: volume)
                    let args = ["volume", "delete", runtimeName]
                    if options.dryRun {
                        try await runContainer(args, check: false)
                    } else {
                        try await resourceManager.deleteVolume(name: runtimeName)
                    }
                }
            }
        }

        try await removeImages(project: project, services: services, policy: imageRemovalPolicy)
    }

    /// Builds images for services that declare a build section.
    func build(project: ComposeProject, services selected: [String], noCache: Bool, quiet: Bool = false) async throws {
        try await build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = selected
                $0.noCache = noCache
                $0.quiet = quiet
            },
        )
    }

    /// Builds images for selected services with Docker Compose compatible options.
    func build(project: ComposeProject, options build: ComposeBuildOptions) async throws {
        let services = try orderedBuildServices(
            project: project,
            selected: build.services,
            includeRuntimeDependencies: build.withDependencies
        )
        if build.printBake {
            try options.emit(renderBuildBakeFile(project: project, services: services, options: build))
            return
        }
        for service in services where service.build != nil {
            if build.quiet || options.dryRun {
                try await buildService(project: project, service: service, options: build)
            } else {
                try await options.progress.activityWithExternalOutput("Building \(service.name)") {
                    try await buildService(project: project, service: service, options: build)
                }
            }
            if build.push, !build.check, let image = service.image {
                if options.dryRun {
                    try await runContainer(["image", "push", image])
                } else {
                    try await imageManager.pushImage(image, emit: options.emit)
                }
            }
        }
    }

    /// Pulls images for selected services.
    func pull(project: ComposeProject, services selected: [String]) async throws {
        try await pull(
            project: project,
            options: ComposePullOptions {
                $0.services = selected
            },
        )
    }

    /// Pulls images for selected services with Docker Compose compatible options.
    func pull(project: ComposeProject, options pull: ComposePullOptions) async throws {
        try validateComposePullPolicy(pull.policy)
        let services = try pull.includeDependencies
            ? orderedServices(project: project, selected: pull.services)
            : selectedServices(project: project, selected: pull.services)
        let images = services.compactMap { service -> String? in
            if pull.ignoreBuildable, service.build != nil {
                return nil
            }
            return service.image
        }
        let pullMissingOnly = pull.policy == "missing"
        let ignorePullFailures = pull.ignorePullFailures
        try await runImageOperations(
            images,
            progressMessage: pullMissingOnly ? "Preparing \(images.count) images" : "Pulling \(images.count) images",
            quiet: pull.quiet,
        ) { [self] image, quiet in
            do {
                if pullMissingOnly {
                    try await pullMissingImage(image, quiet: quiet)
                } else {
                    try await pullImage(image, quiet: quiet)
                }
            } catch {
                guard ignorePullFailures else {
                    throw error
                }
            }
        }
    }

    /// Pushes images for selected services.
    func push(project: ComposeProject, services selected: [String]) async throws {
        try await push(
            project: project,
            options: ComposePushOptions {
                $0.services = selected
            },
        )
    }

    /// Pushes images for selected services with Docker Compose compatible options.
    func push(project: ComposeProject, options push: ComposePushOptions) async throws {
        let services = try push.includeDependencies
            ? orderedServices(project: project, selected: push.services)
            : selectedServices(project: project, selected: push.services)
        let emit: @Sendable (String) -> Void = if push.quiet {
            { _ in
                // `push --quiet` intentionally suppresses per-image status lines.
            }
        } else {
            options.emit
        }
        let images = services.compactMap(\.image)
        let ignorePushFailures = push.ignorePushFailures
        try await runImageOperations(
            images,
            progressMessage: "Pushing \(images.count) images",
            quiet: push.quiet,
        ) { [self] image, _ in
            let args = ["image", "push", image]
            if options.dryRun {
                try await runContainer(args)
            } else {
                do {
                    try await imageManager.pushImage(image, emit: emit)
                } catch {
                    guard ignorePushFailures else {
                        throw error
                    }
                }
            }
        }
    }

    /// Lists Compose projects discovered through project-scoped container labels.
    func ls(options list: ComposeLsOptions = ComposeLsOptions()) async throws {
        let nameFilters = try lsNameFilters(list.filters)
        let format = try composeLsFormat(list.format)
        var args = ["list", "--format", "json"]
        if list.all {
            args.append("--all")
        }
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let containers = try await discoveryManager.listContainers(all: list.all)
        let records = composeProjectRecords(containers: containers, nameFilters: nameFilters)
        if list.quiet {
            let names = records.map(\.name)
            if !names.isEmpty {
                options.emit(names.joined(separator: "\n"))
            }
            return
        }

        switch format {
        case .table:
            let table = renderComposeProjectTable(records)
            if !table.isEmpty {
                options.emit(table)
            }
        case .json:
            try options.emit(renderComposeProjectJSON(records))
        }
    }

    /// Lists containers belonging to the Compose project.
    func ps(
        project: ComposeProject,
        options psOptions: ComposePsOptions = ComposePsOptions(),
    ) async throws {
        let statusFilters = try psStatusFilters(statuses: psOptions.statuses, filters: psOptions.filters)
        let outputFormat = try composePsFormat(psOptions.format)
        let selectedServiceNames = try psOptions.selectedServices.isEmpty
            ? nil
            : Set(selectedServices(project: project, selected: psOptions.selectedServices).map(\.name))
        var args = ["list", "--format", "json"]
        if psOptions.all || !statusFilters.isEmpty {
            args.append("--all")
        }
        if options.dryRun {
            try await runContainer(args)
            return
        }
        let containers = try await projectContainers(projectName: project.name, all: psOptions.all || !statusFilters.isEmpty)
        let serviceScopedContainers = filterContainersByOrphanPolicy(
            containers,
            project: project,
            includeOrphans: psOptions.orphans,
        )
        let selectedContainers = filterContainersByService(serviceScopedContainers, services: selectedServiceNames)
        let filteredContainers = filterContainersByStatus(selectedContainers, statuses: statusFilters)
        if psOptions.quiet {
            let identifiers = containerIdentifiers(filteredContainers)
            if !identifiers.isEmpty {
                options.emit(identifiers.joined(separator: "\n"))
            }
            return
        }
        if psOptions.services {
            let names = containerServiceNames(filteredContainers)
            if !names.isEmpty {
                options.emit(names.joined(separator: "\n"))
            }
            return
        }
        switch outputFormat {
        case .json:
            try options.emit(containerListJSON(filteredContainers))
        case .table:
            let table = renderComposeContainerTable(filteredContainers, noTrunc: psOptions.noTrunc)
            if !table.isEmpty {
                options.emit(table)
            }
        case let .template(template, table):
            let output = try renderComposeContainerTemplate(
                filteredContainers,
                template: template,
                table: table,
                noTrunc: psOptions.noTrunc,
            )
            if !output.isEmpty {
                options.emit(output)
            }
        }
    }

    /// Streams or prints logs for selected service containers.
    func logs(
        project: ComposeProject,
        services selected: [String],
        options logOptions: ComposeLogsOptions = ComposeLogsOptions(),
    ) async throws {
        let services = try selectedServices(project: project, selected: selected)
        let runtimeTail = try runtimeLogTail(logOptions.tail)
        let runtimeSince = try runtimeLogTimestamp(logOptions.since)
        let runtimeUntil = try runtimeLogTimestamp(logOptions.until)
        let runtimeOptions = RuntimeLogOptions(
            tail: runtimeTail,
            since: runtimeSince,
            until: runtimeUntil,
            timestamps: logOptions.timestamps,
            noLogPrefix: logOptions.noLogPrefix,
            colorPrefixes: logOptions.colorPrefixes,
        )
        let targets = try await logTargets(project: project, services: services, index: logOptions.index)
        if options.dryRun {
            for target in targets {
                let args = logRuntimeArguments(
                    .init(
                        id: target.name,
                        follow: logOptions.follow,
                        tail: runtimeTail,
                        since: logOptions.since,
                        until: logOptions.until,
                        timestamps: logOptions.timestamps,
                    )
                )
                emitComposeRuntimeOperation(args)
            }
            return
        }
        if logOptions.follow, targets.count > 1 {
            try await followLogTargets(
                targets,
                options: runtimeOptions,
            )
            return
        }
        for target in targets {
            try await emitLogs(
                RuntimeLogRequest(
                    id: target.name,
                    follow: logOptions.follow,
                    tail: runtimeOptions.tail,
                    since: runtimeOptions.since,
                    until: runtimeOptions.until,
                    timestamps: runtimeOptions.timestamps,
                    emit: logEmitter(
                        for: target,
                        noLogPrefix: runtimeOptions.noLogPrefix,
                        colorPrefixes: runtimeOptions.colorPrefixes,
                    ),
                ),
            )
        }
    }
}
