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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

struct IPv4Address: CustomStringConvertible, Hashable, Sendable {
    let value: UInt32

    var isUnspecified: Bool {
        value == 0
    }

    var description: String {
        var address = in_addr(s_addr: value.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)).map(String.init(cString:)) ?? ""
    }

    init(_ input: String) throws {
        guard input.count >= 7, input.count <= 15 else {
            throw POSIXError(.EINVAL)
        }

        var result: UInt32 = 0
        var octetCount = 0
        var currentOctet = 0
        var digitCount = 0
        for byte in input.utf8 {
            if byte == 46 {
                guard octetCount < 3, digitCount > 0, digitCount <= 3, currentOctet <= 255 else {
                    throw POSIXError(.EINVAL)
                }
                result = result << 8 | UInt32(currentOctet)
                octetCount += 1
                currentOctet = 0
                digitCount = 0
            } else if byte >= 48, byte <= 57 {
                let digit = Int(byte - 48)
                digitCount += 1
                if digitCount == 1, digit == 0 {
                    currentOctet = 0
                } else if digitCount > 1, currentOctet == 0 {
                    throw POSIXError(.EINVAL)
                } else {
                    currentOctet = currentOctet * 10 + digit
                }
                guard currentOctet <= 255, digitCount <= 3 else {
                    throw POSIXError(.EINVAL)
                }
            } else {
                throw POSIXError(.EINVAL)
            }
        }

        guard octetCount == 3, digitCount > 0, digitCount <= 3, currentOctet <= 255 else {
            throw POSIXError(.EINVAL)
        }
        value = result << 8 | UInt32(currentOctet)
    }

    init(value: UInt32) {
        self.value = value
    }
}

struct CIDRv4: CustomStringConvertible, Sendable {
    let address: IPv4Address
    let prefixLength: UInt8

    var lower: IPv4Address {
        IPv4Address(value: address.value & mask)
    }

    var upper: IPv4Address {
        IPv4Address(value: lower.value | ~mask)
    }

    var description: String {
        "\(address)/\(prefixLength)"
    }

    private var mask: UInt32 {
        prefixLength == 0 ? 0 : UInt32.max << (32 - UInt32(prefixLength))
    }

    init(_ input: String) throws {
        let fields = input.split(separator: "/")
        guard fields.count == 2, let prefixLength = UInt8(fields[1]), prefixLength <= 32 else {
            throw POSIXError(.EINVAL)
        }
        address = try IPv4Address(String(fields[0]))
        self.prefixLength = prefixLength
    }

    func contains(_ candidate: IPv4Address) -> Bool {
        candidate.value & mask == address.value & mask
    }
}

struct IPv6Address: CustomStringConvertible, Hashable, Sendable {
    let bytes: [UInt8]
    let zone: String?

    var isUnspecified: Bool {
        bytes.allSatisfy { $0 == 0 }
    }

    var description: String {
        let groups = stride(from: 0, to: bytes.count, by: 2).map {
            UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }

        var longestZeroStart = -1
        var longestZeroLength = 0
        var currentZeroStart = -1
        var currentZeroLength = 0
        for (index, group) in groups.enumerated() {
            if group == 0 {
                if currentZeroStart == -1 {
                    currentZeroStart = index
                    currentZeroLength = 1
                } else {
                    currentZeroLength += 1
                }
            } else {
                if currentZeroLength > longestZeroLength {
                    longestZeroStart = currentZeroStart
                    longestZeroLength = currentZeroLength
                }
                currentZeroStart = -1
                currentZeroLength = 0
            }
        }
        if currentZeroLength > longestZeroLength {
            longestZeroStart = currentZeroStart
            longestZeroLength = currentZeroLength
        }

        var result = ""
        var index = 0
        while index < groups.count {
            if longestZeroLength >= 2, index == longestZeroStart {
                result += index == 0 ? "::" : ":"
                index += longestZeroLength
                if index >= groups.count {
                    break
                }
            } else {
                result += String(groups[index], radix: 16)
                index += 1
                if index < groups.count {
                    result += ":"
                }
            }
        }
        if let zone {
            result += "%\(zone)"
        }
        return result
    }

    init(_ input: String) throws {
        let fields = input.split(separator: "%", omittingEmptySubsequences: false)
        guard let addressText = fields.first, !addressText.isEmpty, fields.count < 2 || !fields[1].isEmpty else {
            throw POSIXError(.EINVAL)
        }
        guard fields.count <= 2 else {
            throw POSIXError(.EINVAL)
        }
        if addressText.contains(".") {
            guard let separator = addressText.lastIndex(of: ":") else {
                throw POSIXError(.EINVAL)
            }
            let suffixStart = addressText.index(after: separator)
            guard suffixStart < addressText.endIndex else {
                throw POSIXError(.EINVAL)
            }
            _ = try IPv4Address(String(addressText[suffixStart...]))
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, String(addressText), &address) == 1 else {
            throw POSIXError(.EINVAL)
        }
        bytes = withUnsafeBytes(of: &address) { Array($0) }
        zone = fields.count == 2 ? String(fields[1]) : nil
    }
}

struct CIDRv6: CustomStringConvertible, Sendable {
    let address: IPv6Address
    let prefixLength: UInt8

    var description: String {
        "\(address)/\(prefixLength)"
    }

    init(_ input: String) throws {
        let fields = input.split(separator: "/")
        guard fields.count == 2, let prefixLength = UInt8(fields[1]), prefixLength <= 128 else {
            throw POSIXError(.EINVAL)
        }
        address = try IPv6Address(String(fields[0]))
        self.prefixLength = prefixLength
    }

    func contains(_ candidate: IPv6Address) -> Bool {
        guard candidate.zone == address.zone else {
            return false
        }
        let fullBytes = Int(prefixLength / 8)
        let remainingBits = Int(prefixLength % 8)
        guard candidate.bytes.prefix(fullBytes) == address.bytes.prefix(fullBytes) else {
            return false
        }
        guard remainingBits > 0 else {
            return true
        }
        let mask = UInt8.max << (8 - remainingBits)
        return candidate.bytes[fullBytes] & mask == address.bytes[fullBytes] & mask
    }
}

func isValidIPAddress(_ input: String) -> Bool {
    (try? IPv4Address(input)) != nil || (try? IPv6Address(input)) != nil
}

func isUnspecifiedIPAddress(_ input: String) -> Bool? {
    if let address = try? IPv4Address(input) {
        return address.isUnspecified
    }
    if let address = try? IPv6Address(input) {
        return address.isUnspecified
    }
    return nil
}
