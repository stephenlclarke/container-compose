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

/// Direct Apple container API used for lifecycle signal operations.
public protocol ContainerKilling: Sendable {
    /// Sends `signal` to container `id`.
    func killContainer(id: String, signal: String) async throws
}

/// `ContainerClient`-backed killer for real service container signal delivery.
public struct ContainerClientKiller: ContainerKilling {
    public init() {
        // Stateless adapter; public initializer supports dependency injection.
    }

    /// Sends a signal through `ContainerClient.kill(id:signal:)`.
    public func killContainer(id: String, signal: String) async throws {
        let client = ContainerClient()
        try await client.kill(id: id, signal: signal)
    }
}
