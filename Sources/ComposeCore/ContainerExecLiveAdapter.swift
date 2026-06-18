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

import ContainerAPIClient
import ContainerResource
import Foundation
import Logging

/// Live apple/container process API entry point for detached exec.
public enum ContainerExecLiveAdapter {
    /// Creates a process inside `containerId` and starts it through `ContainerClient`.
    public static func createAndStartProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        let process = try await ContainerClient().createProcess(
            containerId: containerId,
            processId: processId,
            configuration: configuration,
            stdio: stdio
        )
        try await process.start()
    }

    /// Creates an attached process and pumps local stdio until it exits.
    public static func runAttachedProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        interactive: Bool,
        tty: Bool
    ) async throws -> Int32 {
        let client = ContainerClient()
        let io = try ProcessIO.create(tty: tty, interactive: interactive, detach: false)
        defer {
            try? io.close()
        }
        let process = try await client.createProcess(
            containerId: containerId,
            processId: processId,
            configuration: configuration,
            stdio: io.stdio
        )
        return try await io.handleProcess(
            process: process,
            log: Logger(label: "container-compose.exec")
        )
    }
}
