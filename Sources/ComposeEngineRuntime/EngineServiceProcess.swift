// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
import ComposeRuntimeSPI

/// Resolves Compose's clear/inherit rules before encoding the Engine request.
/// Image metadata must belong to the exact descriptor selected for creation.
struct EngineServiceProcess: Encodable, Equatable {
    let entrypoint: [String]
    let command: [String]
    let environment: [String]
    let workingDirectory: String
    let user: String
    let terminal: Bool
    let openStandardInput: Bool

    enum CodingKeys: String, CodingKey {
        case entrypoint = "Entrypoint", command = "Cmd", environment = "Env"
        case workingDirectory = "WorkingDir", user = "User", terminal = "Tty"
        case openStandardInput = "OpenStdin"
    }

    init(_ overrides: ComposeProcessOverrides, image: EngineImageConfig) throws {
        let selectedEntrypoint = overrides.entrypoint ?? image.entrypoint ?? []
        let selectedCommand = overrides.command ?? (overrides.entrypoint == nil ? image.command ?? [] : [])
        let executable = selectedEntrypoint.first ?? selectedCommand.first
        guard let executable, !executable.isEmpty else {
            throw ComposeError.invalidProject("Service image and process overrides provide no executable")
        }
        // Docker merges an empty entrypoint/command with image defaults. The
        // reset sentinel suppresses that merge before Docker clears the sentinel.
        entrypoint = selectedEntrypoint.isEmpty ? [""] : selectedEntrypoint
        command = selectedCommand
        // Keep bare keys: Engine interprets these as removals of inherited values.
        // Environment-file resolution belongs to the caller before this boundary.
        environment = overrides.environment.sorted { $0.key < $1.key }.map { key, value in
            value.map { "\(key)=\($0)" } ?? key
        }
        workingDirectory = overrides.workingDirectory ?? image.workingDirectory
        user = overrides.user ?? image.user
        terminal = overrides.terminal
        openStandardInput = overrides.openStandardInput
    }
}
