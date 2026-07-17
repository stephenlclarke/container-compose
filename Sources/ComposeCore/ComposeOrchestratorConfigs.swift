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

private struct ExternalComposeFileGrantContext {
    let project: ComposeProject
    let service: ComposeService
    let kind: ComposeFileMountKind
    let grants: [ComposeValue]
    let definitions: [String: ComposeValue]
    let read: @Sendable (String) async throws -> Data
}

extension ComposeOrchestrator {
    /// Stages external Compose configs and secrets as private read-only files.
    func materializeExternalConfigSecrets(project: ComposeProject, service: ComposeService) async throws {
        try await materializeExternalComposeFileGrants(context: .init(
            project: project,
            service: service,
            kind: .config,
            grants: service.configs ?? [],
            definitions: project.configs ?? [:],
            read: { [configReader] name in
                try await configReader.readConfig(name: name)
            },
        ))
        try await materializeExternalComposeFileGrants(context: .init(
            project: project,
            service: service,
            kind: .secret,
            grants: service.secrets ?? [],
            definitions: project.secrets ?? [:],
            read: { [secretReader] name in
                try await secretReader.readSecret(name: name)
            },
        ))
    }

    private func materializeExternalComposeFileGrants(
        context: ExternalComposeFileGrantContext,
    ) async throws {
        for value in context.grants {
            try await materializeExternalComposeFileGrant(value, context: context)
        }
    }

    private func materializeExternalComposeFileGrant(
        _ value: ComposeValue,
        context: ExternalComposeFileGrantContext,
    ) async throws {
        let grant = try parseComposeFileGrant(value, kind: context.kind, service: context.service)
        guard let definition = context.definitions[grant.source] else {
            throw ComposeError.invalidProject(
                "service '\(context.service.name)' references undefined \(context.kind.singularName) '\(grant.source)'",
            )
        }
        guard case let .object(fields) = definition else {
            throw ComposeError.invalidProject(
                "\(context.kind.singularName.capitalized) '\(grant.source)' definition must be an object",
            )
        }
        guard fields["external"]?.boolValue == true else {
            return
        }
        try await materializeExternalComposeFileGrant(
            grant,
            fields: fields,
            context: context,
        )
    }

    private func materializeExternalComposeFileGrant(
        _ grant: ComposeFileGrant,
        fields: [String: ComposeValue],
        context: ExternalComposeFileGrantContext,
    ) async throws {
        _ = try composeFileGrantOwnership(grant: grant, service: context.service, kind: context.kind)
        let runtimeName = try externalComposeFileRuntimeName(
            project: context.project,
            composeName: grant.source,
            fields: fields,
            kind: context.kind,
        )
        let contents: Data
        do {
            contents = try await context.read(runtimeName)
        } catch {
            throw ComposeError.invalidProject(
                "service '\(context.service.name)' could not read external \(context.kind.singularName) "
                    + "'\(grant.source)' as '\(runtimeName)': \(error.localizedDescription)",
            )
        }

        let permissions = try composeFileGrantPermissions(
            grant: grant,
            kind: context.kind,
            service: context.service,
        )
        let materialized = ComposeMaterializedFile(
            url: materializedExternalComposeFileURL(
                grant: grant,
                runtimeName: runtimeName,
                permissions: permissions,
                context: ComposeFileGrantSourceContext(
                    project: context.project,
                    service: context.service,
                    kind: context.kind,
                    materializedConfigSecretRoot: options.materializedConfigSecretDirectory,
                    materialize: true,
                ),
            ),
            contents: contents,
            permissions: permissions,
        )
        try materialized.write()
    }
}
