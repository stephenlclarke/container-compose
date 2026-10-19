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

import Foundation

/// Versioned requested policy for stock Container; never an observed health result.
public struct ComposeNativeHealthPolicy: Codable, Equatable, Sendable {
    public static let label = "com.apple.container.compose.health-policy"
    public let version: Int
    public let test: [String]
    public let intervalNanoseconds: Int64
    public let timeoutNanoseconds: Int64
    public let retries: Int
    public let startPeriodNanoseconds: Int64

    public static func resolve(arguments: [String]) throws -> Self? {
        guard !arguments.isEmpty else { return nil }
        var fields: [String: String] = [:]
        var index = 0
        let valued: Set = [
            "--health-cmd", "--health-interval", "--health-timeout", "--health-retries", "--health-start-period",
        ]
        while index < arguments.count {
            let option = arguments[index]
            guard fields[option] == nil else {
                throw ComposeError.invalidProject("Duplicate health-check option: \(option)")
            }
            if option == "--no-healthcheck" {
                fields[option] = "true"
                index += 1
            } else {
                guard valued.contains(option), arguments.indices.contains(index + 1) else {
                    throw ComposeError.unsupported("Stock health policy does not support \(option)")
                }
                fields[option] = arguments[index + 1]
                index += 2
            }
        }
        if fields["--no-healthcheck"] != nil {
            guard fields.count == 1 else {
                throw ComposeError.invalidProject("Disabled health check conflicts with health options")
            }
            return Self(version: 1, test: ["NONE"], intervalNanoseconds: 30_000_000_000,
                        timeoutNanoseconds: 30_000_000_000, retries: 3, startPeriodNanoseconds: 0)
        }
        guard let command = fields["--health-cmd"], !command.isEmpty,
              command.utf8.count <= 4096, !command.contains("\0")
        else {
            throw ComposeError.invalidProject("Stock health policy requires a bounded nonempty command")
        }
        let retries: Int
        if let value = fields["--health-retries"] {
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsed = UInt32(value)
            else {
                throw ComposeError.invalidProject("Invalid health-check retry count")
            }
            retries = parsed == 0 ? 3 : Int(parsed)
        } else {
            retries = 3
        }
        return try Self(version: 1, test: ["CMD-SHELL", command],
                        intervalNanoseconds: duration(fields["--health-interval"], fallback: 30_000_000_000),
                        timeoutNanoseconds: duration(fields["--health-timeout"], fallback: 30_000_000_000),
                        retries: retries,
                        startPeriodNanoseconds: duration(fields["--health-start-period"], fallback: 0))
    }

    public func encodedLabel() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 16384, let value = String(data: data, encoding: .utf8) else {
            throw ComposeError.invalidProject("Stock health policy exceeds its transport bound")
        }
        return Self.label + "=" + value
    }

    private static func duration(_ value: String?, fallback: Int64) throws -> Int64 {
        guard let value else { return fallback }
        guard let seconds = ComposeTimeParser.parseDuration(value) else {
            throw ComposeError.invalidProject("Invalid health-check duration")
        }
        let nanoseconds = (seconds * 1_000_000_000).rounded()
        guard nanoseconds.isFinite, nanoseconds >= 0, nanoseconds < Double(Int64.max) else {
            throw ComposeError.invalidProject("Health-check duration is outside the supported range")
        }
        return nanoseconds == 0 ? fallback : Int64(nanoseconds)
    }
}
