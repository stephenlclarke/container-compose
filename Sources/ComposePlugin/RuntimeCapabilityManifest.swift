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

/// Versioned lower-runtime contracts required by the Compose provider.
enum ComposeRuntimeCapability: String, CaseIterable, Codable, Sendable {
    case archiveCopy = "io.github.stephenlclarke.container.compose.archive-copy.v1"
    case buildExtensions = "io.github.stephenlclarke.container.compose.build-extensions.v1"
    case createConfiguration = "io.github.stephenlclarke.container.compose.create-configuration.v1"
    case imageFilesystem = "io.github.stephenlclarke.container.compose.image-filesystem.v1"
    case lifecycle = "io.github.stephenlclarke.container.compose.lifecycle.v1"
    case networkScopedAliases = "io.github.stephenlclarke.container.compose.network-scoped-aliases.v1"
    case observation = "io.github.stephenlclarke.container.compose.observation.v1"
    case inboundUnixSocket = "io.github.stephenlclarke.container.inbound-unix-socket.v1"
    case loggingDrivers = "io.github.stephenlclarke.container.logging-drivers.v1"
}

/// The complete runtime contract required by this Compose binary.
struct ComposeRuntimeCapabilityManifest: Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let capabilities: [ComposeRuntimeCapability]

    static var required: ComposeRuntimeCapabilityManifest {
        ComposeRuntimeCapabilityManifest(
            schemaVersion: currentSchemaVersion,
            capabilities: ComposeRuntimeCapability.allCases.sorted { $0.rawValue < $1.rawValue },
        )
    }

    var identifiers: [String] {
        capabilities.map(\.rawValue)
    }
}
