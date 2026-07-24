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

enum ComposeBuildSecretSource: Equatable {
    case file(String)
    case environment(String)
    case external(String)
}

struct ComposeMaterializedBuildSecrets {
    var secrets: [ComposeBuildSecret]
    var directory: URL?

    func remove() throws {
        guard let directory else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }
}

extension ComposeOrchestrator {
    /// Resolves external build secrets into invocation-private files.
    ///
    /// The caller's secure-store reader remains a Compose-layer dependency.
    /// Secret bytes live only for the duration of one build command and never
    /// enter normalized JSON, bake output, labels, or command-line values.
    func materializeBuildSecrets(
        project: ComposeProject,
        service: ComposeService,
        build: ComposeBuild,
    ) async throws -> ComposeMaterializedBuildSecrets {
        let resolved = try (build.secrets ?? []).map { secret in
            try (secret, buildSecretSource(secret))
        }
        guard
            resolved.contains(where: {
                if case .external = $0.1 {
                    return true
                }
                return false
            })
        else {
            return ComposeMaterializedBuildSecrets(
                secrets: resolved.map { normalizedBuildSecret($0.0, source: $0.1) },
                directory: nil,
            )
        }

        let projectDirectory = materializedProjectDirectory(
            project: project,
            root: options.materializedConfigSecretDirectory,
        )
        if options.dryRun {
            let directory =
                projectDirectory
                    .appendingPathComponent("build-secrets", isDirectory: true)
                    .appendingPathComponent("dry-run", isDirectory: true)
            return ComposeMaterializedBuildSecrets(
                secrets: resolved.enumerated().map { index, item in
                    switch item.1 {
                    case .external:
                        ComposeBuildSecret(
                            id: item.0.id,
                            file: directory.appendingPathComponent("secret-\(index)").path,
                        )
                    default:
                        normalizedBuildSecret(item.0, source: item.1)
                    }
                },
                directory: nil,
            )
        }

        let directory =
            projectDirectory
                .appendingPathComponent("build-secrets", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            var materialized: [ComposeBuildSecret] = []
            for (index, item) in resolved.enumerated() {
                let secret = item.0
                switch item.1 {
                case let .external(name):
                    let contents: Data
                    do {
                        contents = try await secretReader.readSecret(name: name)
                    } catch {
                        throw ComposeError.invalidProject(
                            "service '\(service.name)' could not read external build secret "
                                + "'\(secret.id)' as '\(name)': \(error.localizedDescription)",
                        )
                    }
                    let file = directory.appendingPathComponent("secret-\(index)", isDirectory: false)
                    try ComposeMaterializedFile(
                        url: file,
                        contents: contents,
                        permissions: 0o400,
                    ).write()
                    materialized.append(ComposeBuildSecret(id: secret.id, file: file.path))
                default:
                    materialized.append(normalizedBuildSecret(secret, source: item.1))
                }
            }
            return ComposeMaterializedBuildSecrets(
                secrets: materialized,
                directory: directory,
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func buildSecretSource(_ secret: ComposeBuildSecret) throws -> ComposeBuildSecretSource {
        let id = secret.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw ComposeError.invalidProject("build secret id must not be empty")
        }
        let file = nonEmpty(secret.file?.trimmingCharacters(in: .whitespacesAndNewlines))
        let environment = nonEmpty(secret.environment?.trimmingCharacters(in: .whitespacesAndNewlines))
        let externalName = nonEmpty(
            secret.externalName?.trimmingCharacters(in: .whitespacesAndNewlines),
        )
        if file != nil, environment != nil {
            throw ComposeError.invalidProject(
                "build secret '\(id)' cannot define both file and environment",
            )
        }
        if externalName != nil, file != nil || environment != nil {
            throw ComposeError.invalidProject(
                "build secret '\(id)' cannot combine an external resource with file or environment",
            )
        }
        if let file {
            return .file(file)
        }
        if let environment {
            return .environment(environment)
        }
        if let externalName {
            return .external(externalName)
        }
        throw ComposeError.invalidProject(
            "build secret '\(id)' must define file, environment, or an external resource",
        )
    }

    private func normalizedBuildSecret(
        _ secret: ComposeBuildSecret,
        source: ComposeBuildSecretSource,
    ) -> ComposeBuildSecret {
        switch source {
        case let .file(file):
            ComposeBuildSecret(id: secret.id, file: file)
        case let .environment(environment):
            ComposeBuildSecret(id: secret.id, environment: environment)
        case let .external(name):
            ComposeBuildSecret(id: secret.id, externalName: name)
        }
    }
}
