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

/// A concrete create-time binding, after range expansion and dynamic allocation.
/// A nil host address preserves the runtime's default rather than selecting IPv4.
public struct ComposePublishedPortBinding: Codable, Equatable, Sendable {
    public var hostAddress: String?
    public var hostPort: UInt16
    public var containerPort: UInt16
    public var protocolName: String

    public init(hostAddress: String?, hostPort: UInt16, containerPort: UInt16, protocolName: String) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
    }
}
