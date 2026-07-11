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

struct ComposeUpMenuTests {
    @Test
    func `menu bytes decode supported shortcut keys`() {
        #expect(TerminalComposeUpMenuController.menuKey(for: 3) == .interrupt)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "d")) == .detach)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "D")) == .detach)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "w")) == .toggleWatch)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "W")) == .toggleWatch)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "\n")) == .redraw)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "\r")) == .redraw)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "x")) == nil)
    }

    @Test
    func `watch toggle updates menu state and redraw text`() async {
        let statuses = UpMenuStringRecorder()
        let actions = UpMenuStringRecorder()
        let state = ComposeUpMenuSessionState(watchEnabled: false)
        let operationTask = pendingOperationTask()
        defer {
            operationTask.cancel()
        }
        let configuration = menuConfiguration(
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: { actions.append("graceful") },
                forceStop: { actions.append("force") },
                toggleWatch: { actions.append("toggle") },
            ),
        )

        await TerminalComposeUpMenuController.handle(
            key: .toggleWatch,
            state: state,
            operationTask: operationTask,
            configuration: configuration,
        )
        #expect(actions.values == ["toggle"])
        #expect(statuses.values == ["d Detach   w Disable Watch"])
        #expect(await state.watchIsEnabled)

        await TerminalComposeUpMenuController.handle(
            key: .redraw,
            state: state,
            operationTask: operationTask,
            configuration: configuration,
        )
        #expect(statuses.values.last == "d Detach   w Disable Watch")

        await TerminalComposeUpMenuController.handle(
            key: .toggleWatch,
            state: state,
            operationTask: operationTask,
            configuration: configuration,
        )
        #expect(actions.values == ["toggle", "toggle"])
        #expect(statuses.values.last == "d Detach   w Enable Watch")
        #expect(await !(state.watchIsEnabled))
    }

    @Test
    func `watch toggle redraws disabled state when asynchronous watch stops`() async throws {
        let statuses = UpMenuStringRecorder()
        let releaseStop = AsyncSignal()
        let watchStopped = AsyncSignal()
        let state = ComposeUpMenuSessionState(watchEnabled: false)
        let operationTask = pendingOperationTask()
        defer {
            operationTask.cancel()
        }
        let configuration = menuConfiguration(
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: {},
                forceStop: {},
                toggleWatch: { desiredEnabled, stateChanged in
                    if desiredEnabled {
                        Task {
                            await releaseStop.wait()
                            await stateChanged(false)
                            await watchStopped.signal()
                        }
                    }
                    return desiredEnabled
                },
            ),
        )

        await TerminalComposeUpMenuController.handle(
            key: .toggleWatch,
            state: state,
            operationTask: operationTask,
            configuration: configuration,
        )
        #expect(statuses.values == ["d Detach   w Disable Watch"])
        #expect(await state.watchIsEnabled)

        await releaseStop.signal()
        try await wait(for: watchStopped, timeout: .seconds(1))

        #expect(statuses.values == [
            "d Detach   w Disable Watch",
            "d Detach   w Enable Watch",
        ])
        #expect(await !(state.watchIsEnabled))
    }

    @Test
    func `watch toggle keeps callback state when watch stops before action returns`() async {
        let statuses = UpMenuStringRecorder()
        let state = ComposeUpMenuSessionState(watchEnabled: false)
        let operationTask = pendingOperationTask()
        defer {
            operationTask.cancel()
        }
        let configuration = menuConfiguration(
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: {},
                forceStop: {},
                toggleWatch: { desiredEnabled, stateChanged in
                    if desiredEnabled {
                        await stateChanged(false)
                    }
                    return desiredEnabled
                },
            ),
        )

        await TerminalComposeUpMenuController.handle(
            key: .toggleWatch,
            state: state,
            operationTask: operationTask,
            configuration: configuration,
        )

        #expect(statuses.values == ["d Detach   w Enable Watch"])
        #expect(await !(state.watchIsEnabled))
    }

    @Test
    func `initial watch enable shares menu session state`() async throws {
        let statuses = UpMenuStringRecorder()
        let actions = UpMenuStringRecorder()
        let releaseStop = AsyncSignal()
        let watchStopped = AsyncSignal()
        let state = ComposeUpMenuSessionState(watchEnabled: true)
        let configuration = menuConfiguration(
            watchEnabled: true,
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: {},
                forceStop: {},
                toggleWatch: { desiredEnabled, stateChanged in
                    actions.append("watch=\(desiredEnabled)")
                    Task {
                        await releaseStop.wait()
                        await stateChanged(false)
                        await watchStopped.signal()
                    }
                    return desiredEnabled
                },
            ),
        )

        await TerminalComposeUpMenuController.enableInitialWatchIfNeeded(configuration: configuration, state: state)
        #expect(actions.values == ["watch=true"])
        #expect(await state.watchIsEnabled)

        await releaseStop.signal()
        try await wait(for: watchStopped, timeout: .seconds(1))
        #expect(statuses.values == ["d Detach   w Enable Watch"])
        #expect(await !(state.watchIsEnabled))
    }

    @Test
    func `watch toggle without watch configuration does not run action`() async {
        let statuses = UpMenuStringRecorder()
        let actions = UpMenuStringRecorder()
        let state = ComposeUpMenuSessionState(watchEnabled: false)
        let operationTask = pendingOperationTask()
        defer {
            operationTask.cancel()
        }
        let configuration = menuConfiguration(
            watchAvailable: false,
            statuses: statuses,
            actions: ComposeUpMenuActions(
                gracefulStop: { actions.append("graceful") },
                forceStop: { actions.append("force") },
                toggleWatch: { actions.append("toggle") },
            ),
        )

        await TerminalComposeUpMenuController.handle(
            key: .toggleWatch,
            state: state,
            operationTask: operationTask,
            configuration: configuration,
        )

        #expect(actions.values.isEmpty)
        #expect(statuses.values == [
            "compose: watch is not configured for the selected services",
            "d Detach   w Enable Watch (not configured)",
        ])
        #expect(await !(state.watchIsEnabled))
    }

    @Test
    func `interrupt shortcuts run graceful and force stop actions`() async throws {
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
            key: .interrupt,
            state: state,
            operationTask: operationTask,
            configuration: configuration,
        )
        #expect(actions.values == ["graceful"])
        #expect(statuses.values == ["compose: gracefully stopping... press Ctrl+C again to force"])
        #expect(await !(state.wasDetached))

        await TerminalComposeUpMenuController.handle(
            key: .interrupt,
            state: state,
            operationTask: operationTask,
            configuration: configuration,
        )
        #expect(actions.values == ["graceful", "force"])
        #expect(statuses.values.last == "compose: forcing stop...")
        #expect(await state.wasDetached)
        do {
            try await operationTask.value
            Issue.record("Expected force stop to cancel the followed operation")
        } catch is CancellationError {
            // Expected after the second interrupt.
        }
    }
}

private struct AsyncSignalTimeout: Error {}

private actor AsyncSignal {
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !signaled else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private func wait(for signal: AsyncSignal, timeout: Duration) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await signal.wait()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw AsyncSignalTimeout()
        }
        _ = try await group.next()
        group.cancelAll()
    }
}
