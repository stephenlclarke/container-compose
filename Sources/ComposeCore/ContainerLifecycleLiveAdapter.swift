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

/// Live apple/container lifecycle API bridge used by production starts.
public enum ContainerLifecycleLiveAdapter {
    /// Bootstraps and starts the init process without attaching stdio.
    public static func start(id: String) async throws {
        var dynamicEnv: [String: String] = [:]
        if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
        }
        let process = try await ContainerClient().bootstrap(id: id, stdio: [], dynamicEnv: dynamicEnv)
        try await process.start()
    }

    /// Waits for a running container's init process without replaying stopped
    /// container state that apple/container snapshots do not expose yet.
    public static func wait(id: String) async throws -> Int32 {
        let client = ContainerClient()
        let container = try await client.get(id: id)
        guard container.status == .running || container.status == .stopping else {
            throw ComposeError.unsupported("wait: container '\(id)' is \(container.status.rawValue); apple/container does not expose stored exit codes for already-stopped containers")
        }
        let process = try await client.bootstrap(id: id, stdio: [], dynamicEnv: [:])
        return try await process.wait()
    }
}
