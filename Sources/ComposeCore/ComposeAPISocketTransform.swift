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
    static let apiSocketConfigName = "#apisocket"
    static let apiSocketConfigDirectory = "/run/secrets/docker"
    static let apiSocketConfigTarget = "/run/secrets/docker/config.json"

    /// Applies Docker Compose's invocation-local `use_api_socket` transform.
    /// The normalized source project remains unchanged for `config` output;
    /// only the effective create/run project receives the credential snapshot.
    func projectByApplyingAPISocket(_ project: ComposeProject) async throws
        -> ComposeProject
    {
        guard
            project.services.values.contains(where: {
                $0.useAPISocket == true
            })
        else {
            return project
        }

        let data = try await apiSocketCredentialData()
        guard let contents = String(data: data, encoding: .utf8) else {
            throw ComposeError.invalidProject(
                "resolved credentials for use_api_socket are not UTF-8 JSON",
            )
        }

        var transformed = project
        var configs = transformed.configs ?? [:]
        configs[Self.apiSocketConfigName] = .object([
            "content": .string(contents),
        ])
        transformed.configs = configs

        for name in transformed.services.keys.sorted() {
            guard var service = transformed.services[name],
                  service.useAPISocket == true
            else {
                continue
            }
            var environment = service.environment ?? [:]
            if !environment.keys.contains("DOCKER_CONFIG") {
                environment["DOCKER_CONFIG"] = Self.apiSocketConfigDirectory
            }
            service.environment = environment
            var serviceConfigs = service.configs ?? []
            serviceConfigs.append(
                .object([
                    "source": .string(Self.apiSocketConfigName),
                    "target": .string(Self.apiSocketConfigTarget),
                ]),
            )
            service.configs = serviceConfigs
            transformed.services[name] = service
        }
        return transformed
    }

    private func apiSocketCredentialData() async throws -> Data {
        if options.dryRun {
            // A dry run must remain side-effect free. In particular it must
            // not invoke a native Docker credential helper, which can prompt
            // for Keychain access on macOS.
            return Data("{\"auths\":{}}".utf8)
        }
        do {
            return try await apiSocketCredentialResolver
                .resolvedCredentialConfig()
        } catch let error as ComposeError {
            throw error
        } catch {
            throw ComposeError.invalidProject(
                "resolving credentials for use_api_socket failed: \(error.localizedDescription)",
            )
        }
    }
}
