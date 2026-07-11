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
import Testing

@Suite("Compose up menu detach")
struct ComposeUpMenuDetachTests {
    @Test
    func `detach shortcut marks session detached and cancels operation`() async throws {
        let statuses = UpMenuStringRecorder()
        let actions = UpMenuStringRecorder()
        let state = ComposeUpMenuSessionState(watchEnabled: false)
        let operationTask = pendingOperationTask()
        let configuration = menuConfiguration(
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: { actions.append("graceful") },
                forceStop: { actions.append("force") },
                toggleWatch: { actions.append("toggle") },
            ),
        )

        await TerminalComposeUpMenuController.handle(
            key: .detach,
            state: state,
            operationTask: operationTask,
            configuration: configuration,
        )

        #expect(actions.values.isEmpty)
        #expect(statuses.values == ["compose: detached from demo"])
        #expect(await state.wasDetached)
        do {
            try await operationTask.value
            Issue.record("Expected detach to cancel the followed operation")
        } catch is CancellationError {
            // Expected after detach.
        }
    }
}
