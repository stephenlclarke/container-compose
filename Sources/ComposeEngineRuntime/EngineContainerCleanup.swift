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
import ContainerEngineWire
import ContainerUnixHTTPClient

extension EngineRuntimeProvider {
    /// Teardown alone treats a confirmed missing target as absent; other responses remain failures.
    func requestContainerCleanup(_ method: DockerHTTPMethod, _ target: String, id: String) async throws {
        do {
            try await request(method, target)
        } catch let error as ContainerUnixHTTPClientError {
            guard case let .server(status, message) = error,
                  status == 404, message == "container \(id) was not found"
            else {
                throw error
            }
            throw EngineMissingContainerError(underlying: error)
        }
    }
}

struct EngineMissingContainerError: ComposeRuntimeErrorProviding, CustomStringConvertible {
    let underlying: ContainerUnixHTTPClientError
    var composeRuntimeErrorCode: ComposeRuntimeErrorCode {
        .notFound
    }

    var composeRuntimeUnderlyingError: (any Error)? {
        underlying
    }

    var description: String {
        underlying.description
    }
}
