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

@testable import ComposeCore
import Foundation
import Testing

struct ComposeNativeHealthPolicyTests {
    @Test
    func `absent and disabled healthchecks remain distinct`() throws {
        #expect(try ComposeNativeHealthPolicy.resolve(arguments: []) == nil)
        let disabled = try #require(try ComposeNativeHealthPolicy.resolve(arguments: ["--no-healthcheck"]))
        #expect(disabled.version == 1)
        #expect(disabled.test == ["NONE"])
        #expect(disabled.intervalNanoseconds == 30_000_000_000)
        #expect(disabled.timeoutNanoseconds == 30_000_000_000)
        #expect(disabled.retries == 3)
        #expect(disabled.startPeriodNanoseconds == 0)
    }

    @Test
    func `command and zero values retain the documented defaults`() throws {
        let defaults = try #require(try ComposeNativeHealthPolicy.resolve(arguments: ["--health-cmd", "true"]))
        let zeros = try #require(try ComposeNativeHealthPolicy.resolve(arguments: [
            "--health-cmd", "true", "--health-interval", "0s", "--health-timeout", "0ms",
            "--health-retries", "0", "--health-start-period", "0ns",
        ]))
        #expect(defaults == zeros)
        #expect(defaults.version == 1)
        #expect(defaults.test == ["CMD-SHELL", "true"])
        #expect(defaults.intervalNanoseconds == 30_000_000_000)
        #expect(defaults.timeoutNanoseconds == 30_000_000_000)
        #expect(defaults.retries == 3)
        #expect(defaults.startPeriodNanoseconds == 0)
    }

    @Test
    func `explicit policy preserves command bytes and nanosecond units`() throws {
        let command = "printf '%s' \"a=b\"\nexit 0"
        let policy = try #require(try ComposeNativeHealthPolicy.resolve(arguments: [
            "--health-start-period", "1m2s", "--health-retries", "4294967295",
            "--health-timeout", "0.5ns", "--health-interval", "1.25ms", "--health-cmd", command,
        ]))
        #expect(policy.test == ["CMD-SHELL", command])
        #expect(policy.intervalNanoseconds == 1_250_000)
        #expect(policy.timeoutNanoseconds == 1)
        #expect(policy.retries == Int(UInt32.max))
        #expect(policy.startPeriodNanoseconds == 62_000_000_000)
        let label = try policy.encodedLabel()
        let prefix = ComposeNativeHealthPolicy.label + "="
        #expect(label.hasPrefix(prefix))
        let decoded = try JSONDecoder().decode(
            ComposeNativeHealthPolicy.self, from: Data(label.dropFirst(prefix.count).utf8)
        )
        #expect(decoded == policy)
        #expect(try decoded.encodedLabel() == label)
    }

    @Test(arguments: [
        ["--health-cmd", "true", "--health-cmd", "false"],
        ["--no-healthcheck", "--no-healthcheck"],
        ["--no-healthcheck", "--health-cmd", "true"],
        ["--health-cmd", "true", "--no-healthcheck"],
    ])
    func `duplicate and conflicting policies are rejected`(arguments: [String]) {
        #expect(throws: ComposeError.self) { try ComposeNativeHealthPolicy.resolve(arguments: arguments) }
    }

    @Test(arguments: ["--health-cmd", "--health-interval", "--health-timeout", "--health-retries",
                      "--health-start-period", "--unknown"])
    func `missing values and unknown options fail before encoding`(option: String) {
        #expect(throws: ComposeError.unsupported("Stock health policy does not support \(option)")) {
            try ComposeNativeHealthPolicy.resolve(arguments: [option])
        }
    }

    @Test(arguments: ["", "a\0b", String(repeating: "a", count: 4097), String(repeating: "é", count: 2049)])
    func `command bound is measured in UTF8 bytes`(command: String) {
        #expect(throws: ComposeError.invalidProject("Stock health policy requires a bounded nonempty command")) {
            try ComposeNativeHealthPolicy.resolve(arguments: ["--health-cmd", command])
        }
    }

    @Test
    func `missing command is not a defaults only healthcheck`() {
        #expect(throws: ComposeError.invalidProject("Stock health policy requires a bounded nonempty command")) {
            try ComposeNativeHealthPolicy.resolve(arguments: ["--health-interval", "2s"])
        }
    }

    @Test(arguments: [String(repeating: "a", count: 4096), String(repeating: "é", count: 2048)])
    func `exact byte bound is accepted`(command: String) throws {
        let policy = try #require(try ComposeNativeHealthPolicy.resolve(arguments: ["--health-cmd", command]))
        #expect(policy.test == ["CMD-SHELL", command])
        #expect(try policy.encodedLabel().hasPrefix(ComposeNativeHealthPolicy.label + "="))
    }

    @Test(arguments: ["", "-1", "+1", "1.0", " 1", "١", "4294967296"])
    func `retry count requires an ASCII unsigned 32 bit integer`(value: String) {
        #expect(throws: ComposeError.invalidProject("Invalid health-check retry count")) {
            try ComposeNativeHealthPolicy.resolve(arguments: ["--health-cmd", "true", "--health-retries", value])
        }
    }

    @Test(arguments: ["", "-1s", "1", "nan", "1s-junk"])
    func `invalid durations are rejected`(value: String) {
        #expect(throws: ComposeError.invalidProject("Invalid health-check duration")) {
            try ComposeNativeHealthPolicy.resolve(arguments: ["--health-cmd", "true", "--health-interval", value])
        }
    }

    @Test(arguments: ["9223372037s", String(repeating: "9", count: 300) + "h"])
    func `duration conversion rejects overflow before integer conversion`(value: String) {
        #expect(throws: ComposeError.invalidProject("Health-check duration is outside the supported range")) {
            try ComposeNativeHealthPolicy.resolve(arguments: ["--health-cmd", "true", "--health-timeout", value])
        }
    }

    @Test
    func `escaped JSON cannot exceed the label transport bound`() throws {
        // JSON escaping can exceed the transport bound even for a valid 4-KiB command.
        let policy = try #require(try ComposeNativeHealthPolicy.resolve(arguments: [
            "--health-cmd", String(repeating: "\u{01}", count: 4096),
        ]))
        #expect(throws: ComposeError.invalidProject("Stock health policy exceeds its transport bound")) {
            try policy.encodedLabel()
        }
    }
}
