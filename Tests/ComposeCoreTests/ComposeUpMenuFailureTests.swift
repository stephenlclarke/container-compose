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

@Suite("Compose up menu failure handling")
struct ComposeUpMenuFailureTests {
    @Test
    func `menu session falls back to the operation when stdin is not a terminal`() async throws {
        let statuses = UpMenuStringRecorder()
        let actions = UpMenuStringRecorder()
        let configuration = menuConfiguration(
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: {},
                forceStop: {},
                toggleWatch: {},
            ),
        )

        try await TerminalComposeUpMenuController().runMenuSession(configuration: configuration) {
            actions.append("operation")
        }

        #expect(actions.values == ["operation"])
        #expect(statuses.values.count == 1)
        #expect(statuses.values.first?.hasPrefix("compose: menu unavailable:") == true)
    }

    @Test
    func `initial watch honors disabled and unavailable states`() async {
        let statuses = UpMenuStringRecorder()
        let actions = UpMenuStringRecorder()
        let disabledState = ComposeUpMenuSessionState(watchEnabled: true)
        let disabledConfiguration = menuConfiguration(
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: {},
                forceStop: {},
                toggleWatch: { actions.append("toggle") },
            ),
        )

        await TerminalComposeUpMenuController.enableInitialWatchIfNeeded(
            configuration: disabledConfiguration,
            state: disabledState,
        )
        #expect(await disabledState.watchIsEnabled)

        let unavailableState = ComposeUpMenuSessionState(watchEnabled: true)
        let unavailableConfiguration = menuConfiguration(
            watchEnabled: true,
            watchAvailable: false,
            statuses: statuses,
            actions: disabledConfiguration.actions,
        )
        await TerminalComposeUpMenuController.enableInitialWatchIfNeeded(
            configuration: unavailableConfiguration,
            state: unavailableState,
        )

        #expect(await !(unavailableState.watchIsEnabled))
        #expect(actions.values.isEmpty)
        #expect(statuses.values.isEmpty)
    }

    @Test
    func `initial watch restores state after cancellation and failure`() async {
        let statuses = UpMenuStringRecorder()
        let cancelledState = ComposeUpMenuSessionState(watchEnabled: true)
        let cancelledConfiguration = menuConfiguration(
            watchEnabled: true,
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: {},
                forceStop: {},
                toggleWatch: { _, _ in throw CancellationError() },
            ),
        )
        await TerminalComposeUpMenuController.enableInitialWatchIfNeeded(
            configuration: cancelledConfiguration,
            state: cancelledState,
        )
        #expect(await !(cancelledState.watchIsEnabled))

        let failedState = ComposeUpMenuSessionState(watchEnabled: true)
        let failedConfiguration = menuConfiguration(
            watchEnabled: true,
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: {},
                forceStop: {},
                toggleWatch: { _, _ in throw MenuActionFailure.expected },
            ),
        )
        await TerminalComposeUpMenuController.enableInitialWatchIfNeeded(
            configuration: failedConfiguration,
            state: failedState,
        )

        #expect(await !(failedState.watchIsEnabled))
        #expect(statuses.values == ["Watch -> expected failure"])
    }

    @Test
    func `watch toggle restores state after cancellation and failure`() async {
        let statuses = UpMenuStringRecorder()
        let operationTask = pendingOperationTask()
        defer {
            operationTask.cancel()
        }

        let cancelledState = ComposeUpMenuSessionState(watchEnabled: false)
        await TerminalComposeUpMenuController.handle(
            key: .toggleWatch,
            state: cancelledState,
            operationTask: operationTask,
            configuration: failingMenuConfiguration(statuses: statuses, error: CancellationError()),
        )
        #expect(await !(cancelledState.watchIsEnabled))

        let failedState = ComposeUpMenuSessionState(watchEnabled: false)
        await TerminalComposeUpMenuController.handle(
            key: .toggleWatch,
            state: failedState,
            operationTask: operationTask,
            configuration: failingMenuConfiguration(statuses: statuses, error: MenuActionFailure.expected),
        )

        #expect(await !(failedState.watchIsEnabled))
        #expect(statuses.values == ["Watch -> expected failure"])
    }

    @Test
    func `menu stop actions report failures and accept cancellation`() async {
        let failedStatuses = UpMenuStringRecorder()
        let failedOperation = pendingOperationTask()
        defer {
            failedOperation.cancel()
        }
        await handleInterrupt(
            operationTask: failedOperation,
            statuses: failedStatuses,
            error: MenuActionFailure.expected,
        )
        #expect(failedStatuses.values == [
            "compose: gracefully stopping... press Ctrl+C again to force",
            "Stop -> expected failure",
        ])

        let cancelledStatuses = UpMenuStringRecorder()
        let cancelledOperation = pendingOperationTask()
        defer {
            cancelledOperation.cancel()
        }
        await handleInterrupt(
            operationTask: cancelledOperation,
            statuses: cancelledStatuses,
            error: CancellationError(),
        )
        #expect(cancelledStatuses.values == [
            "compose: gracefully stopping... press Ctrl+C again to force",
        ])
    }

    private func failingMenuConfiguration(
        statuses: UpMenuStringRecorder,
        error: any Error & Sendable,
    ) -> ComposeUpMenuConfiguration {
        menuConfiguration(
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: {},
                forceStop: {},
                toggleWatch: { _, _ in throw error },
            ),
        )
    }

    private func handleInterrupt(
        operationTask: Task<Void, any Error>,
        statuses: UpMenuStringRecorder,
        error: any Error & Sendable,
    ) async {
        await TerminalComposeUpMenuController.handle(
            key: .interrupt,
            state: ComposeUpMenuSessionState(watchEnabled: false),
            operationTask: operationTask,
            configuration: menuConfiguration(
                statuses: statuses,
                actions: ComposeUpMenuActions(
                    gracefulStop: { throw error },
                    forceStop: {},
                    toggleWatch: {},
                ),
            ),
        )
    }
}

private enum MenuActionFailure: Error, CustomStringConvertible {
    case expected

    var description: String {
        "expected failure"
    }
}
