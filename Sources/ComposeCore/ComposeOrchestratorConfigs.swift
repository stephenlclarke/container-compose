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
    /// Stages external Compose configs and secrets as private read-only files.
    func materializeExternalConfigSecrets(project: ComposeProject, service: ComposeService) async throws {
        try await materializeExternalComposeFileGrants(
            project: project,
            service: service,
            kind: .config,
            grants: service.configs ?? [],
            definitions: project.configs ?? [:],
            read: { [configReader] name in
                try await configReader.readConfig(name: name)
            },
        )
        try await materializeExternalComposeFileGrants(
            project: project,
            service: service,
            kind: .secret,
            grants: service.secrets ?? [],
            definitions: project.secrets ?? [:],
            read: { [secretReader] name in
                try await secretReader.readSecret(name: name)
            },
        )
    }

    private func materializeExternalComposeFileGrants(
        project: ComposeProject,
        service: ComposeService,
        kind: ComposeFileMountKind,
        grants: [ComposeValue],
        definitions: [String: ComposeValue],
        read: @Sendable (String) async throws -> Data,
    ) async throws {
        for value in grants {
            let grant = try parseComposeFileGrant(value, kind: kind, service: service)
            guard let definition = definitions[grant.source] else {
                throw ComposeError.invalidProject("service '\(service.name)' references undefined \(kind.singularName) '\(grant.source)'")
            }
            guard case let .object(fields) = definition else {
                throw ComposeError.invalidProject("\(kind.singularName.capitalized) '\(grant.source)' definition must be an object")
            }
            guard fields["external"]?.boolValue == true else {
                continue
            }

            try validateMaterializedGrantOwnership(grant: grant, service: service, kind: kind)
            let runtimeName = try externalComposeFileRuntimeName(
                project: project,
                composeName: grant.source,
                fields: fields,
                kind: kind,
            )
            let contents: Data
            do {
                contents = try await read(runtimeName)
            } catch {
                throw ComposeError.invalidProject("service '\(service.name)' could not read external \(kind.singularName) '\(grant.source)' as '\(runtimeName)': \(error.localizedDescription)")
            }

            let permissions = try composeFileGrantPermissions(grant: grant, kind: kind, service: service)
            let materialized = ComposeMaterializedFile(
                url: materializedExternalComposeFileURL(
                    project: project,
                    grant: grant,
                    runtimeName: runtimeName,
                    permissions: permissions,
                    kind: kind,
                    root: options.materializedConfigSecretDirectory,
                ),
                contents: contents,
                permissions: permissions,
            )
            try materialized.write()
        }
    }
}
