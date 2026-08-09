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

/// Runtime capability identifiers discovered during executable preflight.
///
/// Unknown identifiers are retained so a newer runtime remains forward
/// compatible with an older Compose binary. Feature-specific call sites opt in
/// only when the identifier they understand is present.
public struct ComposeRuntimeCapabilities: Equatable, Sendable {
    public static let loggingDriversV1Identifier =
        "io.github.stephenlclarke.container.logging-drivers.v1"

    public private(set) var identifiers: Set<String>

    public init(identifiers: some Sequence<String> = []) {
        self.identifiers = Set(identifiers)
    }

    /// Whether the selected Container authority accepts the lossless logging
    /// request and exposes driver-neutral read and attach operations.
    public var supportsLoggingDriversV1: Bool {
        identifiers.contains(Self.loggingDriversV1Identifier)
    }
}
