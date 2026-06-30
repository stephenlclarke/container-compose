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
import Dispatch
import Foundation

/// One decoded keyboard action from the `compose up --menu` shortcut surface.
public enum ComposeUpMenuKey: Equatable, Sendable {
    case detach
    case toggleWatch
    case interrupt
    case redraw
}

/// Runtime actions available to an active `compose up --menu` session.
public struct ComposeUpMenuActions: Sendable {
    public var gracefulStop: @Sendable () async throws -> Void
    public var forceStop: @Sendable () async throws -> Void
    public var toggleWatch: @Sendable (
        _ desiredEnabled: Bool,
        _ stateChanged: @escaping @Sendable (Bool) async -> Void
    ) async throws -> Bool

    public init(
        gracefulStop: @escaping @Sendable () async throws -> Void,
        forceStop: @escaping @Sendable () async throws -> Void,
        toggleWatch: @escaping @Sendable () async throws -> Void,
    ) {
        self.gracefulStop = gracefulStop
        self.forceStop = forceStop
        self.toggleWatch = { desiredEnabled, _ in
            try await toggleWatch()
            return desiredEnabled
        }
    }

    public init(
        gracefulStop: @escaping @Sendable () async throws -> Void,
        forceStop: @escaping @Sendable () async throws -> Void,
        toggleWatch: @escaping @Sendable (
            _ desiredEnabled: Bool,
            _ stateChanged: @escaping @Sendable (Bool) async -> Void
        ) async throws -> Bool,
    ) {
        self.gracefulStop = gracefulStop
        self.forceStop = forceStop
        self.toggleWatch = toggleWatch
    }
}

/// Configuration for a live `compose up --menu` session.
public struct ComposeUpMenuConfiguration: Sendable {
    public var projectName: String
    public var watchEnabled: Bool
    public var watchAvailable: Bool
    public var colorEnabled: Bool
    public var emitStatus: @Sendable (String) -> Void
    public var actions: ComposeUpMenuActions

    public init(
        projectName: String,
        watchEnabled: Bool,
        watchAvailable: Bool,
        colorEnabled: Bool,
        emitStatus: @escaping @Sendable (String) -> Void,
        actions: ComposeUpMenuActions,
    ) {
        self.projectName = projectName
        self.watchEnabled = watchEnabled
        self.watchAvailable = watchAvailable
        self.colorEnabled = colorEnabled
        self.emitStatus = emitStatus
        self.actions = actions
    }
}

/// Runs an attached `up` operation while handling Docker Compose-style shortcut keys.
public protocol ComposeUpMenuControlling: Sendable {
    func runMenuSession(
        configuration: ComposeUpMenuConfiguration,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws
}

/// Terminal-backed `compose up --menu` controller.
public struct TerminalComposeUpMenuController: ComposeUpMenuControlling {
    public init() {
        // Public initializer keeps dependency construction straightforward.
    }

    public func runMenuSession(
        configuration: ComposeUpMenuConfiguration,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let terminal = RawTerminalMode(fileDescriptor: STDIN_FILENO)
        do {
            try terminal.enable()
        } catch {
            configuration.emitStatus("compose: menu unavailable: \(error)")
            try await operation()
            return
        }
        defer {
            terminal.restore()
        }

        let state = ComposeUpMenuSessionState(watchEnabled: configuration.watchEnabled && configuration.watchAvailable)
        await Self.enableInitialWatchIfNeeded(configuration: configuration, state: state)
        configuration.emitStatus(await Self.menuLine(configuration: configuration, state: state))
        let operationTask = Task {
            try await operation()
        }
        let inputTask = Task<Void, Never> {
            for await key in Self.keyEvents() {
                await Self.handle(
                    key: key,
                    state: state,
                    operationTask: operationTask,
                    configuration: configuration,
                )
            }
        }

        do {
            try await operationTask.value
        } catch is CancellationError {
            if await state.wasDetached {
                inputTask.cancel()
                await inputTask.value
                return
            }
            inputTask.cancel()
            await inputTask.value
            throw CancellationError()
        } catch {
            inputTask.cancel()
            await inputTask.value
            throw error
        }

        inputTask.cancel()
        await inputTask.value
    }

    static func enableInitialWatchIfNeeded(configuration: ComposeUpMenuConfiguration, state: ComposeUpMenuSessionState) async {
        guard configuration.watchEnabled else {
            return
        }
        guard configuration.watchAvailable else {
            await state.setWatchEnabled(false)
            return
        }
        do {
            let watchVersion = await state.watchChangeVersion
            let applied = try await configuration.actions.toggleWatch(true) { enabled in
                await state.setWatchEnabled(enabled)
                configuration.emitStatus(await menuLine(configuration: configuration, state: state))
            }
            await state.setWatchEnabled(applied, ifWatchVersion: watchVersion)
        } catch is CancellationError {
            await state.setWatchEnabled(false)
        } catch {
            await state.setWatchEnabled(false)
            configuration.emitStatus("Watch -> \(error)")
        }
    }

    static func handle(
        key: ComposeUpMenuKey,
        state: ComposeUpMenuSessionState,
        operationTask: Task<Void, any Error>,
        configuration: ComposeUpMenuConfiguration,
    ) async {
        switch key {
        case .detach:
            await state.markDetached()
            configuration.emitStatus("compose: detached from \(configuration.projectName)")
            operationTask.cancel()
        case .toggleWatch:
            guard configuration.watchAvailable else {
                configuration.emitStatus("compose: watch is not configured for the selected services")
                configuration.emitStatus(await menuLine(configuration: configuration, state: state))
                return
            }
            let previous = await state.watchIsEnabled
            let desired = !previous
            do {
                let watchVersion = await state.watchChangeVersion
                let applied = try await configuration.actions.toggleWatch(desired) { enabled in
                    await state.setWatchEnabled(enabled)
                    configuration.emitStatus(await menuLine(configuration: configuration, state: state))
                }
                let didApply = await state.setWatchEnabled(applied, ifWatchVersion: watchVersion)
                if didApply {
                    configuration.emitStatus(await menuLine(configuration: configuration, state: state))
                }
            } catch is CancellationError {
                await state.setWatchEnabled(previous)
            } catch {
                await state.setWatchEnabled(previous)
                configuration.emitStatus("Watch -> \(error)")
            }
        case .interrupt:
            let count = await state.recordInterrupt()
            if count == 1 {
                configuration.emitStatus("compose: gracefully stopping... press Ctrl+C again to force")
                await runMenuAction("Stop", configuration: configuration) {
                    try await configuration.actions.gracefulStop()
                }
            } else {
                configuration.emitStatus("compose: forcing stop...")
                await runMenuAction("Kill", configuration: configuration) {
                    try await configuration.actions.forceStop()
                }
                await state.markDetached()
                operationTask.cancel()
            }
        case .redraw:
            configuration.emitStatus(await menuLine(configuration: configuration, state: state))
        }
    }

    @discardableResult
    private static func runMenuAction(
        _ name: String,
        configuration: ComposeUpMenuConfiguration,
        action: () async throws -> Void,
    ) async -> Bool {
        do {
            try await action()
            return true
        } catch is CancellationError {
            // Cancellation is the normal path when a detached menu session ends.
            return true
        } catch {
            configuration.emitStatus("\(name) -> \(error)")
            return false
        }
    }

    static func menuLine(configuration: ComposeUpMenuConfiguration, state: ComposeUpMenuSessionState) async -> String {
        let watch = await state.watchIsEnabled ? "Disable Watch" : "Enable Watch"
        let watchSuffix = configuration.watchAvailable ? watch : "\(watch) (not configured)"
        return "d Detach   w \(watchSuffix)"
    }

    private static func keyEvents() -> AsyncStream<ComposeUpMenuKey> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "container-compose.up-menu-input")
            let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
            source.setEventHandler {
                var byte = UInt8(0)
                guard read(STDIN_FILENO, &byte, 1) == 1 else {
                    return
                }
                if let key = menuKey(for: byte) {
                    continuation.yield(key)
                }
            }
            source.setCancelHandler {
                continuation.finish()
            }
            source.resume()
            continuation.onTermination = { _ in
                source.cancel()
            }
        }
    }

    static func menuKey(for byte: UInt8) -> ComposeUpMenuKey? {
        switch byte {
        case 3:
            return .interrupt
        case UInt8(ascii: "d"), UInt8(ascii: "D"):
            return .detach
        case UInt8(ascii: "w"), UInt8(ascii: "W"):
            return .toggleWatch
        case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
            return .redraw
        default:
            return nil
        }
    }
}

actor ComposeUpMenuSessionState {
    private var detached = false
    private var interruptCount = 0
    private var watchEnabled: Bool
    private var watchVersion = 0

    init(watchEnabled: Bool) {
        self.watchEnabled = watchEnabled
    }

    var wasDetached: Bool {
        detached
    }

    var watchIsEnabled: Bool {
        watchEnabled
    }

    var watchChangeVersion: Int {
        watchVersion
    }

    func markDetached() {
        detached = true
    }

    func setWatchEnabled(_ enabled: Bool) {
        watchEnabled = enabled
        watchVersion += 1
    }

    @discardableResult
    func setWatchEnabled(_ enabled: Bool, ifWatchVersion expectedVersion: Int) -> Bool {
        guard watchVersion == expectedVersion else {
            return false
        }
        setWatchEnabled(enabled)
        return true
    }

    func recordInterrupt() -> Int {
        interruptCount += 1
        return interruptCount
    }
}

private final class RawTerminalMode: @unchecked Sendable {
    private let fileDescriptor: Int32
    private var original: termios?
    private let lock = NSLock()

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func enable() throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard original == nil else {
            return
        }

        var current = termios()
        guard tcgetattr(fileDescriptor, &current) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        original = current

        var raw = current
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        raw.c_iflag &= ~tcflag_t(ICRNL | IXON)
        guard tcsetattr(fileDescriptor, TCSANOW, &raw) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            original = nil
            throw error
        }
    }

    func restore() {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard var original else {
            return
        }
        _ = tcsetattr(fileDescriptor, TCSANOW, &original)
        self.original = nil
    }
}
