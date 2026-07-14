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
    /// Resolves the service containers that `compose rm` may remove.
    internal func removableServiceContainerTargets(project: ComposeProject, services: [ComposeService], stopFirst: Bool) async throws -> [ServiceContainerTarget] {
        if options.dryRun {
            return try configuredServiceContainerTargets(project: project, services: services)
        }
        let containers = try await projectContainers(projectName: project.name, all: true)
        return services.flatMap { service in
            containers
                .filter { container in
                    guard container.serviceName == service.name, !container.isOneOff else {
                        return false
                    }
                    return stopFirst || isRemovableStoppedContainerStatus(container.status)
                }
                .sorted(by: serviceContainerSummaryOrder(project: project, service: service))
                .map { container in
                    let index = serviceContainerIndex(project: project, service: service, containerID: container.id)
                    return ServiceContainerTarget(
                        service: service,
                        index: index ?? Int.max,
                        name: container.id,
                        status: container.status,
                    )
                }
        }
    }

    /// Lists images used by created project containers.
    func images(project: ComposeProject, services selected: [String], options images: ComposeImagesOptions) async throws {
        let services = try selectedServices(project: project, selected: selected)
        let selectedServiceNames = selected.isEmpty ? nil : Set(services.map(\.name))
        let format = try composeImagesFormat(images.format)
        let args = ["list", "--format", "json", "--all"]
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let containers = try await projectContainers(projectName: project.name, all: true)
        let records = composeImageRecords(containers: containers, selectedServices: selectedServiceNames)
        if images.quiet {
            let identifiers = records.map(\.imageID).filter { !$0.isEmpty }
            if !identifiers.isEmpty {
                options.emit(identifiers.joined(separator: "\n"))
            }
            return
        }

        switch format {
        case .table:
            let table = renderComposeImageTable(records)
            options.emit(table)
        case .json:
            try options.emit(renderComposeImageJSON(records))
        }
    }

    /// Lists volumes that belong to the Compose project or selected services.
    func volumes(project: ComposeProject, options volumes: ComposeVolumesOptions) async throws {
        let services = try selectedServices(project: project, selected: volumes.services)
        let format = try composeVolumesFormat(volumes.format)
        let args = ["volume", "list", "--format", "json"]
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let records = try await composeVolumeRecords(
            project: project,
            services: services,
            restrictToSelectedServices: !volumes.services.isEmpty,
        )
        if volumes.quiet {
            let names = records.map(\.name)
            if !names.isEmpty {
                options.emit(names.joined(separator: "\n"))
            }
            return
        }

        switch format {
        case .table:
            let table = renderComposeVolumeTable(records)
            options.emit(table)
        case .json:
            let output = try renderComposeVolumeJSON(records)
            if !output.isEmpty {
                options.emit(output)
            }
        case let .template(template, table):
            let output = try renderComposeVolumeTemplate(records, template: template, table: table)
            if !output.isEmpty {
                options.emit(output)
            }
        }
    }

    /// Displays resource usage statistics for selected service containers.
    func stats(project: ComposeProject, options stats: ComposeStatsOptions) async throws {
        try validate(project: project)
        try validateStatsOptions(stats)
        let services = try selectedServices(project: project, selected: stats.services)
        var args = ["stats"]
        if stats.format != "table" {
            args.append(contentsOf: ["--format", stats.format])
        }
        if stats.noStream {
            args.append("--no-stream")
        }
        if stats.noTrunc {
            args.append("--no-trunc")
        }
        if stats.all {
            args.append("--all")
        }
        let ids = services.map { containerName(project: project, service: $0, oneOff: false) }
        args.append(contentsOf: ids)
        if options.dryRun {
            emitComposeRuntimeOperation(args)
            return
        }
        let format = stats.format
        let noStream = stats.noStream
        let noTrunc = stats.noTrunc
        let includeStopped = stats.all
        let collectStats: @Sendable () async throws -> Void = {
            try await self.statsManager.stats(
                ids: ids,
                format: format,
                noStream: noStream,
                noTrunc: noTrunc,
                includeStopped: includeStopped,
                emit: self.options.emit,
            )
        }
        guard !noStream else {
            try await collectStats()
            return
        }

        let streamingTask = Task {
            try await collectStats()
        }
        try await signalProxy.withSignalProxy(
            signals: ["SIGINT", "SIGTERM"],
            handler: { _ in
                streamingTask.cancel()
            },
            operation: {
                do {
                    try await streamingTask.value
                } catch is CancellationError {
                    // Ctrl-C/termination ends a local stats stream. The stats
                    // manager's defer restores the terminal before returning.
                }
            },
        )
    }

    /// Displays running process information for selected service containers.
    func top(project: ComposeProject, options top: ComposeTopOptions = ComposeTopOptions()) async throws {
        try validate(project: project)
        let services = try selectedServices(project: project, selected: top.services)
        let targets = try await serviceContainerTargets(project: project, services: services)
        if options.dryRun {
            for target in targets {
                emitComposeRuntimeOperation(["top", target.name])
            }
            return
        }
        try await topManager.top(
            targets: targets.map { ComposeTopTarget(service: $0.service.name, containerID: $0.name) },
            emit: options.emit,
        )
    }

    /// Streams project container lifecycle events in Docker Compose format.
    func events(project: ComposeProject, options events: ComposeEventsOptions) async throws {
        try validate(project: project)
        let runtimeSince = try runtimeEventTimestamp(events.since)
        let runtimeUntil = try runtimeEventTimestamp(events.until)
        let services = try selectedServices(project: project, selected: events.services)
        if options.dryRun {
            emitComposeRuntimeEventRead(since: events.since, until: events.until)
            return
        }
        try await eventsManager.events(
            projectName: project.name,
            services: services.map(\.name),
            format: events.outputFormat,
            since: runtimeSince,
            until: runtimeUntil,
            emit: options.emit,
        )
    }

    /// Sends a signal to selected service containers.
    func kill(project: ComposeProject, services selected: [String], signal: String?) async throws {
        try await kill(project: project, services: selected, signal: signal, removeOrphans: false)
    }

    /// Sends the requested signal to selected service containers.
    func kill(project: ComposeProject, services selected: [String], signal: String?, removeOrphans: Bool) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for target in try await serviceContainerTargets(project: project, services: services) {
            var args = ["kill"]
            if let signal {
                args.append(contentsOf: ["--signal", signal])
            }
            let containerID = target.name
            args.append(containerID)
            if options.dryRun {
                emitComposeRuntimeOperation(args)
                continue
            }
            try await lifecycleManager.killContainer(id: containerID, signal: signal ?? "KILL")
        }
        if removeOrphans {
            let declaredContainers = try declaredServiceContainerNames(project: project, scaleOverrides: [:])
            let preservedServices = orphanProtectedServiceNames(project: project, scaleOverrides: [:])
            try await removeRemainingProjectContainers(
                project: project,
                excluding: declaredContainers,
                preservingServices: preservedServices,
            )
        }
    }

    /// Pauses selected service containers.
    func pause(project: ComposeProject, services selected: [String]) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for target in try await serviceContainerTargets(project: project, services: services) {
            let containerID = target.name
            if options.dryRun {
                emitComposeRuntimeOperation(["pause", containerID])
                continue
            }
            try await lifecycleManager.pauseContainer(id: containerID)
        }
    }

    /// Resumes selected paused service containers.
    func unpause(project: ComposeProject, services selected: [String]) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for target in try await serviceContainerTargets(project: project, services: services) {
            let containerID = target.name
            if options.dryRun {
                emitComposeRuntimeOperation(["unpause", containerID])
                continue
            }
            try await lifecycleManager.unpauseContainer(id: containerID)
        }
    }

    /// Waits for selected service containers to exit and prints their exit codes.
    func wait(project: ComposeProject, options wait: ComposeWaitOptions = ComposeWaitOptions()) async throws {
        let services = try selectedServices(project: project, selected: wait.services)
        let targets = try await serviceContainerTargets(project: project, services: services)
        if wait.downProject {
            try await waitThenDownProject(project: project, targets: targets)
            return
        }
        for target in targets {
            let containerID = target.name
            if options.dryRun {
                emitComposeRuntimeOperation(["wait", containerID])
                continue
            }
            let exitCode: Int32 = if let stoppedExitCode = try await stoppedWaitExitCode(target) {
                stoppedExitCode
            } else {
                try await lifecycleManager.waitContainer(id: containerID)
            }
            options.emit(String(exitCode))
        }
    }

    /// Prints the public address for a published service port from runtime state.
    func port(
        project: ComposeProject,
        serviceName: String,
        privatePort: String,
        protocolName: String,
        index: Int,
    ) async throws {
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }

        let requested = try parsePortLookup(privatePort: privatePort, protocolName: protocolName)
        try validatePublishedPorts(service.ports ?? [], serviceName: service.name)
        if options.dryRun {
            try emitDryRunPort(service: service, requested: requested, index: index)
            return
        }

        let containerID = try await serviceContainerID(project: project, service: service, index: index)
        guard let container = try await discoveryManager.getContainer(id: containerID) else {
            throw ComposeError.invalidProject("service '\(service.name)' container '\(containerID)' does not exist")
        }

        guard let mapping = publishedPort(
            in: container.publishedPorts,
            target: requested.target,
            protocolName: requested.protocolName,
        ) else {
            throw ComposeError.invalidProject("service '\(service.name)' does not publish target port \(requested.target)/\(requested.protocolName)")
        }
        options.emit("\(mapping.hostAddress):\(mapping.hostPort)")
    }

    /// Throws a consistently formatted unsupported-feature error.
    func unsupported(_ feature: String, reason: String) throws -> Never {
        throw ComposeError.unsupported("\(feature): \(reason)")
    }
}
