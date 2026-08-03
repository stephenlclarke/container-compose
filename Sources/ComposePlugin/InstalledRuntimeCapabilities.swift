//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ComposeCore
import Foundation

/// Known lower-runtime contracts that are negotiated only by the call sites
/// which can use them.
enum ComposeOptionalRuntimeCapability: String, Codable, Sendable {
    case loggingDrivers = "io.github.stephenlclarke.container.logging-drivers.v1"
}

/// Process-local handoff from async runtime preflight to the synchronously
/// constructed ArgumentParser command tree.
final class InstalledRuntimeCapabilities: @unchecked Sendable {
    private let lock = NSLock()
    private var capabilities = ComposeRuntimeCapabilities()

    func replace(with capabilities: ComposeRuntimeCapabilities) {
        lock.withLock {
            self.capabilities = capabilities
        }
    }

    func snapshot() -> ComposeRuntimeCapabilities {
        lock.withLock { capabilities }
    }
}

let installedRuntimeCapabilities = InstalledRuntimeCapabilities()
