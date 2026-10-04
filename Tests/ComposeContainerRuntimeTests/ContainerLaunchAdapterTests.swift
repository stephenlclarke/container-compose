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

import ArgumentParser
@testable import ComposeContainerRuntime
import ComposeRuntimeSPI
import ContainerCommands
import ContainerResource
import Testing

@Suite("Container launch adapter")
struct ContainerLaunchAdapterTests {
    @Test
    func `injects exact logging request outside create arguments`() async throws {
        let recorder = LaunchRecorder()
        let manager = ContainerCommandLaunchManager(
            create: { arguments, logging in
                await recorder.record(command: .create, arguments: arguments, logging: logging)
                return 0
            },
            run: { _, _ in 91 },
        )

        let status = try await manager.launchContainer(ComposeRuntimeContainerLaunchRequest(
            command: .create,
            arguments: ["--name", "demo-api-1", "example/api"],
            logging: ComposeLogConfiguration(
                driver: "splunk",
                options: ["splunk-token": "protected-value"],
            ),
        ))

        #expect(status == 0)
        let invocation = try #require(await recorder.invocations.first)
        #expect(invocation.command == .create)
        #expect(invocation.arguments == ["--name", "demo-api-1", "example/api"])
        #expect(invocation.logging == ContainerLogRequest(
            driver: "splunk",
            options: ["splunk-token": "protected-value"],
        ))
        #expect(!invocation.arguments.contains(where: { $0.contains("protected-value") }))
    }

    @Test
    func `selects run executor and preserves its status`() async throws {
        let recorder = LaunchRecorder()
        let manager = ContainerCommandLaunchManager(
            create: { _, _ in 92 },
            run: { arguments, logging in
                await recorder.record(command: .run, arguments: arguments, logging: logging)
                return 17
            },
        )

        let status = try await manager.launchContainer(ComposeRuntimeContainerLaunchRequest(
            command: .run,
            arguments: ["--detach", "example/api"],
            logging: .standard,
        ))

        #expect(status == 17)
        #expect(await recorder.invocations.map(\.command) == [.run])
    }

    @Test
    func `typed launch carries bare configuration identity without changing guest arguments`() async throws {
        let recorder = LaunchRecorder()
        let manager = ContainerCommandLaunchManager(
            create: { arguments, logging in
                await recorder.record(command: .create, arguments: arguments, logging: logging)
                return 0
            },
            run: { arguments, logging in
                await recorder.record(command: .run, arguments: arguments, logging: logging)
                return 0
            }
        )
        let configID = "sha256:" + String(repeating: "b", count: 64)
        let options = ["--name", "demo", "--label", "purpose=fixture"]
        let guest = ["/bin/sh", "--label", "com.apple.container.compose.image-reference=guest"]
        for command in [ComposeRuntimeContainerLaunchCommand.create, .run] {
            _ = try await manager.launchContainer(.init(
                command: command, arguments: options + [configID] + guest, logging: .standard
            ))
        }
        for invocation in await recorder.invocations {
            #expect(invocation.arguments == options + [
                "--label", "com.apple.container.compose.image-reference=\(configID)", configID
            ] + guest)
        }
    }

    @Test
    func `typed launch preserves tags and rejects caller provenance labels`() async throws {
        let recorder = LaunchRecorder()
        let manager = ContainerCommandLaunchManager(
            create: { arguments, logging in
                await recorder.record(command: .create, arguments: arguments, logging: logging)
                return 0
            }, run: { _, _ in 0 }
        )
        let tagged = ["--name", "demo", "example/api:current", "echo", "--label"]
        _ = try await manager.launchContainer(.init(command: .create, arguments: tagged, logging: .standard))
        #expect(await recorder.invocations.first?.arguments == tagged)
        let pinned = "example/api@sha256:" + String(repeating: "a", count: 64)
        _ = try await manager.launchContainer(.init(
            command: .create, arguments: ["--name", "pinned", pinned], logging: .standard
        ))
        #expect(await recorder.invocations.last?.arguments == [
            "--name", "pinned", "--label", "com.apple.container.compose.image-reference=\(pinned)", pinned
        ])
        for reserved in [
            "com.apple.container.compose.image-reference=untrusted",
            "com.apple.container.compose.health-policy=untrusted",
        ] {
            await #expect(throws: Error.self) {
                try await manager.launchContainer(.init(command: .create, arguments: [
                    "--label", reserved, "example/api:current"
                ], logging: .standard))
            }
        }
        #expect(await recorder.invocations.count == 2)
    }

    @Test
    func `typed plan and native image operand must agree before create`() async throws {
        let recorder = LaunchRecorder()
        let manager = ContainerCommandLaunchManager(
            create: { arguments, logging in
                await recorder.record(command: .create, arguments: arguments, logging: logging)
                return 0
            }, run: { _, _ in 0 }
        )
        let plan = ContainerServiceCreatePlan(identity: .init(
            name: "demo", imageReference: "sha256:" + String(repeating: "b", count: 64)
        ))
        await #expect(throws: Error.self) {
            _ = try await manager.launchContainer(.init(
                command: .create,
                arguments: ["--name", "demo", "fixture:latest"],
                logging: .standard,
                configuration: plan
            ))
        }
        #expect(await recorder.invocations.isEmpty)
    }

    @Test(arguments: [
        "--memory-reclaim-floor", "--memory-reclaim-headroom", "--memory-reclaim-hysteresis",
        "--memory-reclaim-interval", "--memory-reclaim-cooldown",
    ])
    func `native valued memory options cannot hide a later reserved label`(option: String) async throws {
        let recorder = LaunchRecorder()
        let manager = ContainerCommandLaunchManager(
            create: { arguments, logging in
                await recorder.record(command: .create, arguments: arguments, logging: logging)
                return 0
            }, run: { _, _ in 0 }
        )
        let image = "sha256:" + String(repeating: "b", count: 64)
        _ = try await manager.launchContainer(.init(
            command: .create,
            arguments: [option, "64M", image, "--label", "guest=value"],
            logging: .standard
        ))
        #expect(await recorder.invocations.first?.arguments == [
            option, "64M", "--label", "com.apple.container.compose.image-reference=\(image)",
            image, "--label", "guest=value"
        ])
        await #expect(throws: Error.self) {
            _ = try await manager.launchContainer(.init(
                command: .create,
                arguments: [option, "64M", "--label", "com.apple.container.compose.image-reference=forged", image],
                logging: .standard
            ))
        }
        #expect(await recorder.invocations.count == 1)
    }

    @Test
    func `native create and run parsers accept all valued adaptive memory options`() throws {
        let arguments = [
            "--memory", "512M", "--memory-reclaim-floor", "64M",
            "--memory-reclaim-headroom", "64M", "--memory-reclaim-hysteresis", "32M",
            "--memory-reclaim-interval", "2s", "--memory-reclaim-cooldown", "30s",
            "fixture:latest",
        ]
        _ = try Application.ContainerCreate.parse(arguments)
        _ = try Application.ContainerRun.parse(arguments)
    }

    @Test
    func `inline and grouped options and separator preserve guest arguments`() async throws {
        let recorder = LaunchRecorder()
        let manager = ContainerCommandLaunchManager(
            create: { _, _ in 0 },
            run: { arguments, logging in
                await recorder.record(command: .run, arguments: arguments, logging: logging)
                return 0
            }
        )
        let image = "sha256:" + String(repeating: "c", count: 64)
        let arguments = ["--memory-reclaim-floor=64M", "-ieNAME=value", "--", image,
                         "--memory-reclaim-floor", "--label", "com.apple.container.compose.image-reference=guest"]
        _ = try await manager.launchContainer(.init(command: .run, arguments: arguments, logging: .standard))
        #expect(await recorder.invocations.first?.arguments == [
            "--memory-reclaim-floor=64M", "-ieNAME=value", "--label",
            "com.apple.container.compose.image-reference=\(image)", "--", image,
            "--memory-reclaim-floor", "--label", "com.apple.container.compose.image-reference=guest"
        ])
    }
}

private actor LaunchRecorder {
    struct Invocation: Equatable, Sendable {
        let command: ComposeRuntimeContainerLaunchCommand
        let arguments: [String]
        let logging: ContainerLogRequest
    }

    private var storage: [Invocation] = []

    var invocations: [Invocation] {
        storage
    }

    func record(
        command: ComposeRuntimeContainerLaunchCommand,
        arguments: [String],
        logging: ContainerLogRequest,
    ) {
        storage.append(Invocation(command: command, arguments: arguments, logging: logging))
    }
}
