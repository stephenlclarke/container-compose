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
        let suffix = oneOff ? ["run", options.oneOffIdentifier()] : ["1"]
        return composeManagedContainerName(project: project, service: service, suffix: suffix)
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
        return composeManagedContainerName(project: project, service: service, suffix: [String(index)])
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
                let index = serviceContainerIndex(
                    project: project,
                    service: service,
                    containerID: container.id,
                ) ?? Int.max
                return ServiceContainerTarget(
                    service: service,
                    index: index,
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
        let prefix = composeManagedContainerNamePrefix(project: project, service: service)
        guard containerID.hasPrefix(prefix) else {
            return nil
        }
        let suffix = String(containerID.dropFirst(prefix.count))
        guard let index = Int(suffix), index >= 1 else {
            return nil
        }
        return index
    }

    /// Returns a Docker Compose-style generated container name.
    private func composeManagedContainerName(project: ComposeProject, service: ComposeService, suffix: [String]) -> String {
        ([
            slug(project.name),
            slug(service.name),
        ] + suffix.map(slug)).joined(separator: options.serviceContainerNameSeparator)
    }

    /// Returns the generated service container name prefix used for index parsing.
    private func composeManagedContainerNamePrefix(project: ComposeProject, service: ComposeService) -> String {
        "\(composeManagedContainerName(project: project, service: service, suffix: []))\(options.serviceContainerNameSeparator)"
    }
}
