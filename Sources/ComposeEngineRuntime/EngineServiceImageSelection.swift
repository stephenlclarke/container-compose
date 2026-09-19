// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
import ComposeRuntimeSPI
import Foundation

extension EngineServiceCreateRequest {
    static func validImageID(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && value.utf8.count == 71
            && value.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
    }
}

extension EngineRuntimeProvider {
    /// Freeze the config identity before resolving process defaults. Reinspection
    /// addresses that identity, never a replacement tag or a temporary alias.
    func preparedServiceCreateRequest(_ plan: ContainerServiceCreatePlan) async throws -> EngineServiceCreateRequest {
        let environment = try await capturedServiceEnvironment(plan)
        let requested = try await inspectImage(plan.imageReference, platform: plan.launchOptions.platform)
        guard EngineServiceCreateRequest.validImageID(requested.id) else {
            throw ComposeError.invalidProject("Gateway returned an invalid immutable image ID")
        }
        let selectedPlatform = [
            requested.operatingSystem, requested.architecture, requested.variant?.nilIfEmpty,
        ].compactMap { $0 }.joined(separator: "/")
        let platform = plan.launchOptions.platform?.nilIfEmpty ?? selectedPlatform
        let selected = try await inspectImage(requested.id, platform: platform)
        guard selected.id == requested.id else {
            throw ComposeError.invalidProject("Gateway changed the immutable image identity during selection")
        }
        return try EngineServiceCreateRequest(
            plan: plan, image: selected.config, environmentFileContents: environment, resolvedImageID: selected.id
        )
    }
}
