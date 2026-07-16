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
    /// Returns deterministic image references affected by `down --rmi`.
    func removableDownImages(project: ComposeProject, services: [ComposeService], policy: DownImageRemovalPolicy) -> [String] {
        let images: [String] = switch policy {
        case .none:
            []
        case .local:
            services.compactMap { generatedBuildImage(project: project, service: $0) }
        case .all:
            services.compactMap { serviceImage(project: project, service: $0) }
        }
        return Array(Set(images)).sorted()
    }

    /// Returns the runtime image reference for a service, including generated build tags.
    func serviceImage(project: ComposeProject, service: ComposeService) -> String? {
        service.image ?? generatedBuildImage(project: project, service: service)
    }

    /// Returns the generated image tag used for services that only declare `build`.
    func generatedBuildImage(project: ComposeProject, service: ComposeService) -> String? {
        guard service.build != nil, service.image == nil else {
            return nil
        }
        return "\(project.name)_\(service.name):latest"
    }

    /// Converts Compose's log tail value to a validated line count.
    func runtimeLogTail(_ tail: String?) throws -> Int? {
        guard let tail, !tail.isEmpty else {
            return nil
        }
        if tail.lowercased() == "all" {
            return nil
        }
        guard let lines = Int(tail), lines >= 0 else {
            throw ComposeError.invalidProject("logs --tail must be 'all' or a non-negative integer")
        }
        return lines
    }

    /// Converts Compose log timestamp filters to absolute dates.
    func runtimeLogTimestamp(_ value: String?) throws -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        if let date = ComposeTimeParser.parseTimestamp(value, relativeTo: options.currentDate()) {
            return date
        }
        throw ComposeError.invalidProject("logs time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations")
    }

    /// Converts Compose event timestamp filters to absolute dates.
    func runtimeEventTimestamp(_ value: String?) throws -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        if let date = ComposeTimeParser.parseTimestamp(value, relativeTo: options.currentDate()) {
            return date
        }
        throw ComposeError.invalidProject("events time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations")
    }

    /// Waits for Compose dependency conditions that require runtime state.
    func waitForDependencyConditions(project: ComposeProject, service: ComposeService) async throws {
        for (dependencyName, metadata) in serviceDependencies(service) {
            if metadata.required == false, project.services[dependencyName] == nil {
                continue
            }
            guard let dependency = project.services[dependencyName] else {
                throw ComposeError.invalidProject("service '\(service.name)' depends on unknown service '\(dependencyName)'")
            }
            switch metadata.condition {
            case "service_completed_successfully":
                try await waitForCompletedDependency(project: project, service: service, dependency: dependency)
            case "service_healthy":
                try await waitForHealthyDependency(project: project, service: service, dependency: dependency)
            default:
                continue
            }
        }
    }

    /// Waits for a local Compose Deploy job service to finish successfully.
    func waitForDeployJobService(service: ComposeService, targets: [ServiceContainerTarget]) async throws {
        guard isDeployJobService(service), !targets.isEmpty else {
            return
        }
        for target in targets {
            let exitCode: Int32
            if options.dryRun {
                emitComposeRuntimeOperation(["wait", target.name])
                exitCode = 0
            } else {
                exitCode = try await lifecycleManager.waitContainer(id: target.name)
            }
            guard exitCode == 0 else {
                throw ComposeError.invalidProject("service '\(service.name)' job container '\(target.name)' exited with status \(exitCode)")
            }
        }
    }

    /// Waits for every target container of a dependency service to finish
    /// successfully before starting the dependent service.
    func waitForCompletedDependency(
        project: ComposeProject,
        service: ComposeService,
        dependency: ComposeService,
    ) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [dependency])
        guard !targets.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' dependency '\(dependency.name)' has no containers")
        }
        for target in targets {
            let exitCode = try await completedDependencyExitCode(for: target, dependentService: service)
            guard exitCode == 0 else {
                throw ComposeError.invalidProject("service '\(service.name)' dependency '\(dependency.name)' container '\(target.name)' exited with status \(exitCode)")
            }
        }
    }

    /// Resolves a dependency target's exit code, using stored exit metadata
    /// for stopped containers and runtime wait for live containers.
    func completedDependencyExitCode(
        for target: ServiceContainerTarget,
        dependentService: ComposeService,
    ) async throws -> Int32 {
        if options.dryRun {
            emitComposeRuntimeOperation(["wait", target.name])
            return 0
        }
        guard let container = try await discoveryManager.getContainer(id: target.name) else {
            throw ComposeError.invalidProject("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' does not exist")
        }
        switch container.status.lowercased() {
        case "stopped":
            guard let exitCode = container.exitCode else {
                throw ComposeError.unsupported("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' is stopped but has no stored exit code")
            }
            return exitCode
        case "running", "stopping":
            return try await lifecycleManager.waitContainer(id: target.name)
        default:
            throw ComposeError.unsupported("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' is \(container.status)")
        }
    }

    /// Waits for every target container of a dependency service to report a
    /// healthy status before starting the dependent service.
    func waitForHealthyDependency(
        project: ComposeProject,
        service: ComposeService,
        dependency: ComposeService,
    ) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [dependency])
        guard !targets.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' dependency '\(dependency.name)' has no containers")
        }
        for target in targets {
            try await waitForHealthyDependencyTarget(target, dependentService: service)
        }
    }

    /// Waits for one dependency target to transition from starting to healthy.
    func waitForHealthyDependencyTarget(
        _ target: ServiceContainerTarget,
        dependentService: ComposeService,
    ) async throws {
        if options.dryRun {
            try await runContainer(["inspect", target.name])
            return
        }
        while true {
            let health = try await dependencyHealthStatus(target, dependentService: dependentService)
            switch health {
            case "healthy":
                return
            case "starting":
                break
            case "unhealthy":
                throw ComposeError.invalidProject("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' is unhealthy")
            case "none", nil:
                throw ComposeError.unsupported("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' has no health status")
            case let health?:
                throw ComposeError.unsupported("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' has unsupported health status '\(health)'")
            }
            if options.usesDefaultSleep {
                try sleepForHealthPoll()
            } else {
                try await options.sleep(.milliseconds(250))
            }
        }
    }

    /// Keeps the large runtime summary out of the polling frame for swiftlang/swift#81771.
    @inline(never)
    func dependencyHealthStatus(
        _ target: ServiceContainerTarget,
        dependentService: ComposeService,
    ) async throws -> String? {
        guard let container = try await discoveryManager.getContainer(id: target.name) else {
            throw ComposeError.invalidProject("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' does not exist")
        }
        return container.health
    }

    /// Avoids allocating another async frame after live discovery on affected Swift 6.3 toolchains.
    @inline(never)
    func sleepForHealthPoll() throws {
        try Task.checkCancellation()
        usleep(250_000)
    }

    /// Waits for service containers to be running, and healthy when configured.
    func waitForReadyServiceTargets(_ targets: [ServiceContainerTarget], timeout: Int?, command: String) async throws {
        guard !targets.isEmpty else {
            return
        }
        if options.dryRun {
            for target in targets {
                var args = ["wait-ready"]
                if let timeout {
                    args.append(contentsOf: ["--timeout", String(timeout)])
                }
                args.append(target.name)
                emitComposeRuntimeOperation(args)
            }
            return
        }

        let deadline = timeout.map { options.currentDate().addingTimeInterval(TimeInterval($0)) }
        var pending = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })
        while !pending.isEmpty {
            for (name, target) in pending.sorted(by: { $0.key < $1.key }) {
                guard let container = try await discoveryManager.getContainer(id: name) else {
                    throw ComposeError.invalidProject("service '\(target.service.name)' container '\(name)' does not exist")
                }
                switch startWaitState(container) {
                case .ready:
                    pending.removeValue(forKey: name)
                case .pending:
                    break
                case let .failed(message):
                    throw ComposeError.invalidProject("service '\(target.service.name)' container '\(name)' \(message)")
                }
            }
            guard !pending.isEmpty else {
                return
            }
            if let deadline, options.currentDate() >= deadline {
                let names = pending.keys.sorted().joined(separator: ", ")
                throw ComposeError.invalidProject("\(command) timed out waiting for \(names)")
            }
            if options.usesDefaultSleep {
                try sleepForHealthPoll()
            } else {
                try await options.sleep(.milliseconds(250))
            }
        }
    }

    /// Validates Compose attach client options before selecting its stream path.
    func validateAttachOptions(_ attach: ComposeAttachOptions) throws -> Bool {
        let sigProxy = attach.sigProxy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch sigProxy {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            throw ComposeError.invalidProject("attach --sig-proxy must be true or false")
        }
    }

    /// Returns a stopped container's stored exit code, or nil when the target
    /// is live and should be waited through apple/container.
    func stoppedWaitExitCode(_ target: ServiceContainerTarget) async throws -> Int32? {
        guard let container = try await discoveryManager.getContainer(id: target.name) else {
            throw ComposeError.invalidProject("service '\(target.service.name)' container '\(target.name)' does not exist")
        }
        return try stoppedWaitExitCode(container, service: target.service)
    }

    /// Returns a stopped container's stored exit code, or nil when the target
    /// is live and should be waited through apple/container.
    func stoppedWaitExitCode(_ container: ComposeContainerSummary, service: ComposeService) throws -> Int32? {
        let status = container.status.lowercased()
        switch status {
        case "stopped":
            guard let exitCode = container.exitCode else {
                throw ComposeError.unsupported("wait: service '\(service.name)' container '\(container.id)' is stopped but has no stored exit code")
            }
            return exitCode
        case "running", "stopping":
            return nil
        default:
            throw ComposeError.unsupported("wait: service '\(service.name)' container '\(container.id)' is \(container.status)")
        }
    }

    /// Waits for the first selected service container to exit, then drops the project.
    func waitThenDownProject(project: ComposeProject, targets: [ServiceContainerTarget]) async throws {
        if options.dryRun {
            for target in targets {
                emitComposeRuntimeOperation(["wait", target.name])
            }
            try await down(project: project, options: ComposeDownOptions())
            return
        }
        for target in targets {
            if let exitCode = try await stoppedWaitExitCode(target) {
                options.emit(String(exitCode))
                try await down(project: project, options: ComposeDownOptions())
                return
            }
        }
        let result = try await waitForFirstServiceContainerExit(targets)
        options.emit(String(result.exitCode))
        try await down(project: project, options: ComposeDownOptions())
    }

    /// Races service container waits so `--down-project` can clean up after
    /// the first selected service container exits.
    func waitForFirstServiceContainerExit(_ targets: [ServiceContainerTarget]) async throws -> ServiceContainerWaitResult {
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
            guard let result = try await group.next() else {
                throw ComposeError.invalidProject("wait requires at least one service container")
            }
            group.cancelAll()
            return result
        }
    }

    /// Parses the `compose port` lookup target and protocol.
    func parsePortLookup(privatePort: String, protocolName: String) throws -> (target: String, protocolName: String) {
        let normalizedProtocol = try normalizedPortProtocol(protocolName)
        let parts = privatePort.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let target = parts.first, !target.isEmpty else {
            throw ComposeError.invalidProject("port requires a private container port")
        }
        guard !target.contains("-") else {
            throw ComposeError.invalidProject("port requires a single private container port")
        }
        if parts.count == 2 {
            let requestedProtocol = try normalizedPortProtocol(parts[1])
            guard requestedProtocol == normalizedProtocol else {
                throw ComposeError.invalidProject("port protocol '\(requestedProtocol)' conflicts with --protocol \(normalizedProtocol)")
            }
        }
        return (target, normalizedProtocol)
    }

    /// Finds the host port mapped to the requested single container port.
    func publishedPort(
        in ports: [ComposeContainerPublishedPort],
        target: String,
        protocolName: String,
    ) -> ComposeContainerPublishedPort? {
        guard let targetPort = UInt16(target) else {
            return nil
        }
        for port in ports where port.protocolName == protocolName {
            let lowerBound = Int(port.containerPort)
            let upperBound = lowerBound + Int(port.count) - 1
            guard Int(targetPort) >= lowerBound, Int(targetPort) <= upperBound else {
                continue
            }
            let offset = Int(targetPort) - Int(port.containerPort)
            guard let hostPort = UInt16(exactly: Int(port.hostPort) + offset) else {
                return nil
            }
            return ComposeContainerPublishedPort(
                hostAddress: port.hostAddress,
                hostPort: hostPort,
                containerPort: targetPort,
                protocolName: port.protocolName,
                count: 1,
            )
        }
        return nil
    }

    /// Emits a dry-run `port` answer from normalized Compose metadata.
    func emitDryRunPort(
        service: ComposeService,
        requested: (target: String, protocolName: String),
        index: Int,
    ) throws {
        guard index >= 1 else {
            throw ComposeError.invalidProject("container index must be greater than zero")
        }
        let replicaCount = max(service.scale ?? 1, index)
        let ports = try dryRunPublishedPorts(service: service, replicaIndex: index, replicaCount: replicaCount)
        guard let mapping = publishedPort(in: ports, target: requested.target, protocolName: requested.protocolName) else {
            throw ComposeError.invalidProject("service '\(service.name)' does not publish target port \(requested.target)/\(requested.protocolName)")
        }
        options.emit("\(mapping.hostAddress):\(mapping.hostPort)")
    }

    /// Expands Compose metadata into dry-run published ports for one service replica.
    func dryRunPublishedPorts(service: ComposeService, replicaIndex: Int, replicaCount: Int) throws -> [ComposeContainerPublishedPort] {
        let portArguments = try publishedPortArguments(
            ports: service.ports ?? [],
            serviceName: service.name,
            replicaIndex: replicaCount > 1 ? replicaIndex : nil,
            replicaCount: replicaCount > 1 ? replicaCount : nil,
        )
        return try portArguments.flatMap {
            try dryRunPublishedPorts(from: $0, serviceName: service.name)
        }
    }

    /// Expands one explicit Compose port mapping for dry-run `port` previews.
    func dryRunPublishedPorts(from value: String, serviceName: String) throws -> [ComposeContainerPublishedPort] {
        let mapping = try parsePublishedPortMapping(value, serviceName: serviceName)
        if mapping.usesDynamicHostPorts {
            return try dynamicPublishedPortArguments(mapping).flatMap {
                try dryRunPublishedPorts(from: $0, serviceName: serviceName)
            }
        }
        guard let hostRange = mapping.hostRange,
              hostRange.count == mapping.targetRange.count
        else {
            throw ComposeError.invalidProject("service '\(serviceName)' has mismatched port ranges '\(value)'")
        }

        return (0 ..< hostRange.count).map { offset in
            ComposeContainerPublishedPort(
                hostAddress: mapping.hostAddress ?? "0.0.0.0",
                hostPort: UInt16(hostRange.start + offset),
                containerPort: UInt16(mapping.targetRange.start + offset),
                protocolName: mapping.protocolName,
            )
        }
    }

    /// Parses a single port or inclusive port range in a Compose mapping.
    func portRange(
        _ value: String,
        field: String,
        mapping: String,
        serviceName: String,
    ) throws -> (start: Int, count: Int) {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard [1, 2].contains(parts.count),
              let start = parts.first.flatMap({ UInt16($0) }),
              start > 1
        else {
            throw ComposeError.invalidProject("service '\(serviceName)' has invalid \(field) port range '\(mapping)'")
        }
        if parts.count == 1 {
            return (Int(start), 1)
        }
        guard let end = UInt16(parts[1]), end >= start else {
            throw ComposeError.invalidProject("service '\(serviceName)' has invalid \(field) port range '\(mapping)'")
        }
        return (Int(start), Int(end - start + 1))
    }

    /// Normalizes Docker Compose port protocols accepted by `compose port`.
    func normalizedPortProtocol(_ value: String) throws -> String {
        switch value.lowercased() {
        case "tcp", "udp":
            return value.lowercased()
        default:
            throw ComposeError.invalidProject("port --protocol must be tcp or udp")
        }
    }
}
