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
}
