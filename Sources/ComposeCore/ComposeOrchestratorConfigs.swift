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

import Foundation

extension ComposeOrchestrator {
    /// Stages external Compose configs as private files for read-only bind mounts.
    func materializeExternalConfigs(project: ComposeProject, service: ComposeService) async throws {
        for value in service.configs ?? [] {
            let grant = try parseComposeFileGrant(value, kind: .config, service: service)
            guard let definition = project.configs?[grant.source] else {
                throw ComposeError.invalidProject("service '\(service.name)' references undefined config '\(grant.source)'")
            }
            guard case let .object(fields) = definition else {
                throw ComposeError.invalidProject("config '\(grant.source)' definition must be an object")
            }
            guard fields["external"]?.boolValue == true else {
                continue
            }

            try validateMaterializedGrantOwnership(grant: grant, service: service, kind: .config)
            let runtimeName = try externalConfigRuntimeName(project: project, composeName: grant.source, fields: fields)
            let contents: Data
            do {
                contents = try await configReader.readConfig(name: runtimeName)
            } catch {
                throw ComposeError.invalidProject("service '\(service.name)' could not read external config '\(grant.source)' as '\(runtimeName)': \(error.localizedDescription)")
            }

            let permissions = try composeFileGrantPermissions(grant: grant, kind: .config, service: service)
            let materialized = ComposeMaterializedFile(
                url: materializedExternalConfigURL(
                    project: project,
                    grant: grant,
                    runtimeName: runtimeName,
                    permissions: permissions,
                    root: options.materializedConfigSecretDirectory,
                ),
                contents: contents,
                permissions: permissions,
            )
            try materialized.write()
        }
    }
}
