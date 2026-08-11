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

@testable import ComposeContainerRuntime
import ComposeRuntimeSPI
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
