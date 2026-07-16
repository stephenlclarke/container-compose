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
import Foundation

/// Reads immutable, non-secret configuration content from apple/container.
public protocol ContainerConfigReading: Sendable {
    /// Returns the stored bytes for a named external configuration.
    func readConfig(name: String) async throws -> Data
}

/// `ClientConfig`-backed reader for Compose external configuration mounts.
public struct ContainerClientConfigReader: ContainerConfigReading {
    public init() {}

    public func readConfig(name: String) async throws -> Data {
        try await ClientConfig.read(name: name)
    }
}
