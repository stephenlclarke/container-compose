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
    @Test("menu bytes decode supported shortcut keys")
    func menuBytesDecodeSupportedShortcutKeys() {
        #expect(TerminalComposeUpMenuController.menuKey(for: 3) == .interrupt)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "d")) == .detach)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "D")) == .detach)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "w")) == .toggleWatch)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "W")) == .toggleWatch)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "\n")) == .redraw)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "\r")) == .redraw)
        #expect(TerminalComposeUpMenuController.menuKey(for: UInt8(ascii: "x")) == nil)
    }

    @Test("watch toggle updates menu state and redraw text")
    func watchToggleUpdatesMenuStateAndRedrawText() async throws {
        let statuses = LockedStringRecorder()
        let actions = LockedStringRecorder()
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
        #expect(!(await state.watchIsEnabled))
    }

    @Test("watch toggle redraws disabled state when asynchronous watch stops")
    func watchToggleRedrawsDisabledStateWhenAsynchronousWatchStops() async throws {
        let statuses = LockedStringRecorder()
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
        try await wait(for: watchStopped, timeout: .seconds(1))

        #expect(statuses.values == [
            "d Detach   w Disable Watch",
            "d Detach   w Enable Watch",
        ])
        #expect(!(await state.watchIsEnabled))
    }

    @Test("watch toggle without watch configuration does not run action")
    func watchToggleWithoutWatchConfigurationDoesNotRunAction() async throws {
        let statuses = LockedStringRecorder()
        let actions = LockedStringRecorder()
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
        #expect(!(await state.watchIsEnabled))
    }

    @Test("interrupt shortcuts run graceful and force stop actions")
    func interruptShortcutsRunGracefulAndForceStopActions() async throws {
        let statuses = LockedStringRecorder()
        let actions = LockedStringRecorder()
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
        #expect(!(await state.wasDetached))

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

    @Test("detach shortcut marks session detached and cancels operation")
    func detachShortcutMarksSessionDetachedAndCancelsOperation() async throws {
        let statuses = LockedStringRecorder()
        let actions = LockedStringRecorder()
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

private func menuConfiguration(
    watchAvailable: Bool = true,
    statuses: LockedStringRecorder,
    actions: ComposeUpMenuActions,
) -> ComposeUpMenuConfiguration {
    ComposeUpMenuConfiguration(
        projectName: "demo",
        watchEnabled: false,
        watchAvailable: watchAvailable,
        colorEnabled: false,
        emitStatus: { statuses.append($0) },
        actions: actions,
    )
}

private func pendingOperationTask() -> Task<Void, any Error> {
    Task {
        try await Task.sleep(for: .seconds(60))
    }
}

private final class LockedStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
