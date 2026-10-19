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

import ComposeCore
import ComposeRuntimeSPI
import Foundation

extension EngineRuntimeProvider {
    func launchPreparedContainer(
        _ launch: ComposeRuntimeContainerLaunchRequest, configuration: ContainerServiceCreatePlan,
        foregroundIO: EngineForegroundIO? = nil
    ) async throws -> Int32 {
        guard launch.logging == configuration.logging else {
            throw ComposeError.invalidProject("Prepared launch has conflicting logging policies")
        }
        guard !configuration.name.isEmpty else {
            throw ComposeError.invalidProject("Prepared gateway launch requires a container name")
        }
        let version: PreparedLaunchVersion = try await request(.get, "/v1.53/version")
        let engines = version.components.filter { $0.name == "Engine" }
        guard engines.count == 1, engines[0].details["ContainerImageReference"] == "1" else {
            throw ComposeError.unsupported("Gateway lacks immutable image reference presentation v1")
        }
        let attached = launch.command == .run && !configuration.detach
        if attached, engines[0].details["ContainerExitWaitRegistration"] != "1" {
            throw ComposeError.unsupported("Gateway lacks acknowledged container exit registration v1")
        }
        let body = try await preparedServiceCreateRequest(configuration)
        var target = "/v1.53/containers/create?name=\(query(configuration.name))"
        if let platform = configuration.imageSelection?.platform ?? configuration.launchOptions.platform?.nilIfEmpty {
            target += "&platform=\(query(platform))"
        }
        let io = try attached ? foregroundIO ?? .system(
            terminal: body.process.terminal, standardInput: body.process.openStandardInput
        ) : nil
        do {
            let created: PreparedContainerIdentity = try await request(.post, target, body: body)
            guard !created.id.isEmpty else {
                throw ComposeError.invalidProject("Gateway creation returned no container identity")
            }
            let status: Int32
            if let io {
                status = try await runSignalProxiedContainer(
                    id: created.id, terminal: body.process.terminal,
                    standardInput: body.process.openStandardInput, io: io
                )
            } else {
                if launch.command == .run {
                    // Keep a failed start inspectable. Never retry creation or
                    // delete by name after an ambiguous response.
                    try await startContainer(id: created.id)
                }
                status = 0
            }
            try io?.restore()
            return status
        } catch {
            try? io?.restore()
            throw error
        }
    }
}

private struct PreparedContainerIdentity: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

private struct PreparedLaunchVersion: Decodable {
    let components: [PreparedLaunchComponent]
    enum CodingKeys: String, CodingKey { case components = "Components" }
}

private struct PreparedLaunchComponent: Decodable {
    let name: String
    let details: [String: String]
    enum CodingKeys: String, CodingKey { case name = "Name", details = "Details" }
}
