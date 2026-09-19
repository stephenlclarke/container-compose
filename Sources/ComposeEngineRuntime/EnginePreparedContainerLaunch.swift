// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
import ComposeRuntimeSPI
import Foundation

extension EngineRuntimeProvider {
    func launchPreparedContainer(
        _ launch: ComposeRuntimeContainerLaunchRequest, configuration: ContainerServiceCreatePlan
    ) async throws -> Int32 {
        guard launch.logging == configuration.logging else {
            throw ComposeError.invalidProject("Prepared launch has conflicting logging policies")
        }
        guard launch.command == .create || configuration.detach else {
            // Starting without an established attach channel can lose output or
            // stdin. Do not escape the gateway's pre-start transaction via CLI.
            throw ComposeError.unsupported("Prepared foreground launch requires gateway attached I/O")
        }
        guard !configuration.name.isEmpty else {
            throw ComposeError.invalidProject("Prepared gateway launch requires a container name")
        }
        let version: PreparedLaunchVersion = try await request(.get, "/v1.53/version")
        let engines = version.components.filter { $0.name == "Engine" }
        guard engines.count == 1, engines[0].details["ContainerImageReference"] == "1" else {
            throw ComposeError.unsupported("Gateway lacks immutable image reference presentation v1")
        }
        let body = try await preparedServiceCreateRequest(configuration)
        var target = "/v1.53/containers/create?name=\(query(configuration.name))"
        if let platform = configuration.imageSelection?.platform ?? configuration.launchOptions.platform?.nilIfEmpty {
            target += "&platform=\(query(platform))"
        }
        let created: PreparedContainerIdentity = try await request(.post, target, body: body)
        guard !created.id.isEmpty else {
            throw ComposeError.invalidProject("Gateway creation returned no container identity")
        }
        if launch.command == .run {
            // Keep a failed start inspectable. Never retry creation or delete by
            // name: an ambiguous response may already represent a live resource.
            try await startContainer(id: created.id)
        }
        return 0
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
