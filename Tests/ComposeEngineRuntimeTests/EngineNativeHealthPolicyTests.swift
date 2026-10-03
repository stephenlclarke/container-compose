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
@testable import ComposeEngineRuntime
import ContainerEngineWire
import ContainerUnixHTTPServer
import Foundation
import Testing

@Suite(.serialized)
struct EngineNativeHealthPolicyTests {
    @Test(arguments: [false, true])
    func `stock health options require advertised policy and preserve guest arguments`(supported: Bool) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let server = fixture.server(HealthPolicyResponder(supported: supported))
        try await server.start()
        let runner = RecordingRunner()
        let provider = EngineRuntimeProvider(socketPath: fixture.socketPath, runner: runner)
        let options = [
            "--health-cmd",
            "wget -qO- http://127.0.0.1/ready",
            "--health-interval",
            "1s",
            "--health-retries",
            "20"
        ]
        do {
            if supported {
                try await provider.validateHealthCheckArguments(options)
                _ = try await provider.launchContainer(.init(
                    command: .run,
                    arguments: options + ["--detach", "--", "alpine", "--health-cmd", "guest-argument"],
                    logging: .init(driver: nil, options: [:])
                ))
                try assertLaunch(try #require(runner.commands.first?.arguments), command: options[1])
                for options in [["--no-healthcheck"], ["--health-cmd=true", "--health-timeout=2s"]] {
                    _ = try await provider.launchContainer(.init(
                        command: .create,
                        arguments: options + ["alpine"],
                        logging: .init()
                    ))
                }
                #expect(runner.commands.count == 3)
            } else {
                await #expect(throws: ComposeError.self) { try await provider.validateHealthCheckArguments(options) }
                await #expect(throws: ComposeError.self) {
                    _ = try await provider.launchContainer(.init(
                        command: .create,
                        arguments: options + ["alpine"],
                        logging: .init()
                    ))
                }
                #expect(runner.commands.isEmpty)
            }
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    private func assertLaunch(_ args: [String], command: String) throws {
        let index = try #require(args.firstIndex(of: "--label"))
        let value = args[index + 1]
        #expect(value.hasPrefix(ComposeNativeHealthPolicy.label + "="))
        let data = Data(value.dropFirst(ComposeNativeHealthPolicy.label.count + 1).utf8)
        let policy = try JSONDecoder().decode(ComposeNativeHealthPolicy.self, from: data)
        #expect(policy.version == 1)
        #expect(policy.test == ["CMD-SHELL", command])
        #expect(policy.intervalNanoseconds == 1_000_000_000)
        #expect(policy.retries == 20)
        #expect(Array(args.suffix(5)) == ["--detach", "--", "alpine", "--health-cmd", "guest-argument"])
    }

    @Test
    func `policy defaults durations and disabled health retain exact semantics`() throws {
        #expect(try ComposeNativeHealthPolicy.resolve(arguments: []) == nil)
        let disabled = try #require(try ComposeNativeHealthPolicy.resolve(arguments: ["--no-healthcheck"]))
        #expect(disabled.test == ["NONE"])
        let policy = try #require(try ComposeNativeHealthPolicy.resolve(arguments: [
            "--health-cmd", "true", "--health-interval", "1m2.5s", "--health-timeout", "500ms",
            "--health-start-period", "2s", "--health-retries", "0",
        ]))
        #expect(policy.intervalNanoseconds == 62_500_000_000)
        #expect(policy.timeoutNanoseconds == 500_000_000)
        #expect(policy.startPeriodNanoseconds == 2_000_000_000)
        #expect(policy.retries == 3)
        let defaults = try #require(try ComposeNativeHealthPolicy.resolve(arguments: [
            "--health-cmd",
            "true",
            "--health-interval",
            "0s"
        ]))
        #expect(defaults.intervalNanoseconds == 30_000_000_000)
        #expect(defaults.timeoutNanoseconds == 30_000_000_000)
        #expect(defaults.startPeriodNanoseconds == 0)
        #expect(try disabled.encodedLabel().hasPrefix(ComposeNativeHealthPolicy.label + "="))
    }

    @Test(arguments: [
        ["--health-cmd"], ["--health-cmd", ""], ["--health-cmd", "a\0b"],
        ["--health-cmd", String(repeating: "x", count: 4097)],
        ["--health-cmd", String(repeating: "\u{1}", count: 4096)],
        ["--health-cmd", "true", "--health-cmd", "false"],
        ["--no-healthcheck", "--health-cmd", "true"], ["--health-interval", "1s"],
        ["--health-cmd", "true", "--health-timeout", "bad"],
        ["--health-cmd", "true", "--health-timeout", "-1s"],
        ["--health-cmd", "true", "--health-timeout", "9223372037s"],
        ["--health-cmd", "true", "--health-retries", "4294967296"],
        ["--health-cmd", "true", "--health-retries", "-1"],
        ["--health-cmd", "true", "--health-start-interval", "1s"],
    ])
    func `invalid policies fail without accessing runtime`(arguments: [String]) async throws {
        let runner = RecordingRunner()
        let provider = EngineRuntimeProvider(socketPath: "/unused", runner: runner)
        await #expect(throws: ComposeError.self) { try await provider.validateHealthCheckArguments(arguments) }
        #expect(runner.commands.isEmpty)
    }

    @Test(arguments: [
        ["--health-cmd"],
        ["--health-cmd=true"],
        ["--health-cmd", "true", "--"],
        ["--no-healthcheck=true", "alpine"]
    ])
    func `malformed health launch cannot start a native command`(arguments: [String]) async throws {
        let runner = RecordingRunner()
        let provider = EngineRuntimeProvider(socketPath: "/unused", runner: runner)
        await #expect(throws: ComposeError.self) {
            _ = try await provider.launchContainer(.init(command: .create, arguments: arguments, logging: .init()))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test(arguments: ["--label", "--label=", "-l", "-l=", "-dl"])
    func `caller cannot forge reserved health policy`(spelling: String) async throws {
        let runner = RecordingRunner()
        let provider = EngineRuntimeProvider(socketPath: "/unused", runner: runner)
        let value = ComposeNativeHealthPolicy.label + "=forged"
        let arguments = spelling == "--label" || spelling == "-l" || spelling == "-dl"
            ? [spelling, value, "alpine"] : [spelling + value, "alpine"]
        await #expect(throws: ComposeError.self) {
            _ = try await provider.launchContainer(.init(command: .create, arguments: arguments, logging: .init()))
        }
        #expect(runner.commands.isEmpty)
    }
}

private struct HealthPolicyResponder: DockerHTTPResponder {
    let supported: Bool
    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        guard request.target == "/v1.53/version" else { return .empty(status: 404) }
        let details = supported ? #""NativeComposeHealthPolicy":"1""# : #""Provider":"stock""#
        let body = #"{"Components":[{"Name":"Engine","Details":{"# + details + #"}}]}"#
        return DockerHTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: .bytes(Data(body.utf8))
        )
    }
}
