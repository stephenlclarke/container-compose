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

/// Effective create-time network options, after Compose policy and capability checks.
/// Unlike discovery attachments, these retain aliases, addresses and interface settings.
public struct ComposeNetworkCreateAttachment: Codable, Equatable, Sendable {
    public var network: String
    public var aliases: [String] = []
    /// Source-scoped alias:target mappings validated by Compose link policy.
    public var scopedAliasMappings: [String] = []
    public var macAddress: String?
    public var mtu: String?
    public var interfaceName: String?
    public var ipv4Address: String?
    public var ipv6Address: String?
    public var linkLocalAddresses: [String] = []

    public init(network: String) {
        self.network = network
    }
}
