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
    public func selectImageForCreation(
        _ reference: String, platform: String?
    ) async throws -> ComposeImageSelection? {
        let image = try await inspectImage(reference, platform: platform)
        guard EngineServiceCreateRequest.validImageID(image.id) else {
            throw ComposeError.invalidProject("Gateway returned an invalid immutable image ID")
        }
        let selectedPlatform = [image.operatingSystem, image.architecture, image.variant?.nilIfEmpty]
            .compactMap { $0 }.joined(separator: "/")
        return ComposeImageSelection(reference: image.id, platform: selectedPlatform)
    }

    /// Freeze the config identity before resolving process defaults. Reinspection
    /// addresses that identity, never a replacement tag or a temporary alias.
    func preparedServiceCreateRequest(_ plan: ContainerServiceCreatePlan) async throws -> EngineServiceCreateRequest {
        let environment = try await capturedServiceEnvironment(plan)
        let selection: ComposeImageSelection
        if let prepared = plan.imageSelection {
            selection = prepared
        } else {
            guard let selected = try await selectImageForCreation(
                plan.imageReference, platform: plan.launchOptions.platform
            ) else {
                throw ComposeError.invalidProject("Gateway did not select an image")
            }
            selection = selected
        }
        guard EngineServiceCreateRequest.validImageID(selection.reference), !selection.platform.isEmpty else {
            throw ComposeError.invalidProject("Gateway returned an invalid immutable image ID")
        }
        let selected = try await inspectImage(selection.reference, platform: selection.platform)
        if let platform = plan.launchOptions.platform?.nilIfEmpty {
            try Self.validateImagePlatform(selected, requested: EngineImagePlatformQuery(platform), argument: platform)
        }
        guard selected.id == selection.reference else {
            throw ComposeError.invalidProject("Gateway changed the immutable image identity during selection")
        }
        return try EngineServiceCreateRequest(
            plan: plan, image: selected.config, environmentFileContents: environment, resolvedImageID: selected.id
        )
    }
}
