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
    /// Returns the service replica that should inherit foreground IO for `up`.
    func foregroundServiceTarget(
        project: ComposeProject,
        services: [ComposeService],
        scaleOverrides: [String: Int],
        detach: Bool,
    ) throws -> ServiceContainerTarget? {
        guard !detach else {
            return nil
        }
        guard let service = try services.reversed().first(where: { service in
            guard service.attach != false else {
                return false
            }
            return try serviceReplicaCount(service, scaleOverrides: scaleOverrides) > 0
        }) else {
            return nil
        }
        return try ServiceContainerTarget(
            service: service,
            index: 1,
            name: serviceContainerName(project: project, service: service, index: 1),
        )
    }
}
