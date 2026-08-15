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

public extension ComposeOrchestrator {
    /// Builds the typed create-time plan for a service container without
    /// invoking the current command-vector bridge.
    func serviceCreatePlan(
        project: ComposeProject,
        serviceName: String,
        options: ContainerServiceCreatePlanOptions = ContainerServiceCreatePlanOptions(),
    ) async throws -> ContainerServiceCreatePlan {
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        let runtimeName = options.name ?? containerName(project: project, service: service, oneOff: options.oneOff)
        return try await serviceCreatePlan(request: ServiceCreatePlanRequest(
            project: project,
            service: service,
            runtimeName: runtimeName,
            options: options,
            externalVolumeMounts: [:],
            labelOverrides: [],
            imageHealthCheckCache: nil,
        ))
    }

    /// Returns selected services after their dependencies using a stable
    /// depth-first traversal. Optional dependencies are included when the
    /// service exists and skipped when the project does not define it.
    func orderedServices(project: ComposeProject, selected: [String]) throws -> [ComposeService] {
        let selectedSet = Set(selected)
        var visiting = Set<String>()
        var visited = Set<String>()
        var ordered: [ComposeService] = []

        func visit(_ name: String) throws {
            if visited.contains(name) {
                return
            }
            if visiting.contains(name) {
                throw ComposeError.invalidProject("dependency cycle involving '\(name)'")
            }
            guard let service = project.services[name] else {
                throw ComposeError.invalidProject("unknown service '\(name)'")
            }
            visiting.insert(name)
            for (dependency, metadata) in serviceDependencies(service) {
                if metadata.required == false, project.services[dependency] == nil {
                    continue
                }
                try visit(dependency)
            }
            visiting.remove(name)
            visited.insert(name)
            ordered.append(service)
        }

        let roots = selected.isEmpty ? project.services.keys.sorted() : selectedSet.sorted()
        for name in roots {
            try visit(name)
        }
        return ordered
    }

    /// Resolves Docker Compose restart propagation and dependency order.
    internal func restartServices(
        project: ComposeProject,
        selected: [String],
        noDeps: Bool,
    ) throws -> [ComposeService] {
        var included = selected.isEmpty ? Set(project.services.keys) : Set(selected)
        for name in included where project.services[name] == nil {
            throw ComposeError.invalidProject("unknown service '\(name)'")
        }

        if !noDeps, !selected.isEmpty {
            var insertedDependent = true
            while insertedDependent {
                insertedDependent = false
                for service in project.services.values where !included.contains(service.name) {
                    let restartsAfterIncludedDependency = service.dependsOn?.contains { dependency in
                        dependency.value.restart && included.contains(dependency.key)
                    } ?? false
                    if restartsAfterIncludedDependency {
                        included.insert(service.name)
                        insertedDependent = true
                    }
                }
            }
        }

        let services = try selectedServices(project: project, selected: included.sorted())
        let restartGraph = services.map { service in
            var service = service
            service.dependsOn = service.dependsOn?.filter { dependency in
                dependency.value.restart && included.contains(dependency.key)
            }
            return service
        }
        return try Array(serviceDependencyLayers(services: restartGraph).joined())
    }

    /// Groups selected services into dependency-safe runtime layers.
    func serviceDependencyLayers(
        services: [ComposeService],
    ) throws -> [[ComposeService]] {
        let selectedNames = Set(services.map(\.name))
        let servicesByName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var dependencies = [String: Set<String>]()
        for service in services {
            dependencies[service.name] = Set(serviceDependencies(service).map(\.key))
                .intersection(selectedNames)
        }

        var remaining = selectedNames
        var completed = Set<String>()
        var layers: [[ComposeService]] = []
        while !remaining.isEmpty {
            let ready = remaining
                .filter { dependencies[$0, default: []].isSubset(of: completed) }
                .sorted()
            guard !ready.isEmpty else {
                let names = remaining.sorted().joined(separator: ", ")
                throw ComposeError.invalidProject("dependency cycle involving \(names)")
            }
            layers.append(ready.compactMap { servicesByName[$0] })
            remaining.subtract(ready)
            completed.formUnion(ready)
        }
        return layers
    }
}
