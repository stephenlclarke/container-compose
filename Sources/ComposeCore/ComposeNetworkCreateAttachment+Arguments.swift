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

import ComposeRuntimeSPI

extension ComposeNetworkCreateAttachment {
    /// Legacy native rendering consumes the same effective fields as typed creation.
    var nativeArgument: String {
        var options = aliases.map { "alias=\($0)" }
        options += scopedAliasMappings.map { "dns-alias=\($0)" }
        if let macAddress {
            options.append("mac=\(macAddress)")
        }
        if let mtu {
            options.append("mtu=\(mtu)")
        }
        if let interfaceName {
            options.append("interface=\(interfaceName)")
        }
        if let ipv4Address {
            options.append("ip=\(ipv4Address)")
        }
        if let ipv6Address {
            options.append("ip6=\(ipv6Address)")
        }
        options += linkLocalAddresses.map { "address=\($0)" }
        return ([network] + options).joined(separator: ",")
    }
}
