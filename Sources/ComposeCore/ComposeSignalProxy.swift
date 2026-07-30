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
#endif
import Dispatch
import Foundation

/// Runs an async operation while forwarding host signals to a caller-supplied handler.
public protocol ComposeSignalProxying: Sendable {
    /// Installs handlers for `signals`, runs `operation`, then removes the handlers.
    func withSignalProxy(
        signals: [String],
        handler: @escaping @Sendable (String) async -> Void,
        operation: @escaping @Sendable () async throws -> Void,
    ) async throws
}

/// Dispatch-backed signal proxy used by interactive-ish Compose operations.
public struct DispatchComposeSignalProxy: ComposeSignalProxying {
    #if canImport(Darwin)
        private static let processSignalOwnership = ProcessSignalProxyOwnership()
    #endif

    public init() {
        // Public initializer keeps the dispatch-backed proxy constructible outside this module.
    }

    public func withSignalProxy(
        signals: [String],
        handler: @escaping @Sendable (String) async -> Void,
        operation: @escaping @Sendable () async throws -> Void,
    ) async throws {
        #if canImport(Darwin)
            let mappings = signals.compactMap(Self.signalMapping(named:))
            guard !mappings.isEmpty else {
                try await operation()
                return
            }
            await Self.processSignalOwnership.acquire()
            do {
                try Task.checkCancellation()
                try await Self.runWithSignalProxy(
                    mappings: mappings,
                    handler: handler,
                    operation: operation,
                )
                await Self.processSignalOwnership.release()
            } catch {
                await Self.processSignalOwnership.release()
                throw error
            }
        #else
            _ = signals
            _ = handler
            try await operation()
        #endif
    }

    #if canImport(Darwin)
        private static func runWithSignalProxy(
            mappings: [(name: String, number: Int32)],
            handler: @escaping @Sendable (String) async -> Void,
            operation: @escaping @Sendable () async throws -> Void,
        ) async throws {
            let queue = DispatchQueue(label: "container-compose.signal-proxy")
            let cancellationGroup = DispatchGroup()
            let handlerTasks = SignalHandlerTaskTracker()
            var sources: [DispatchSourceSignal] = []
            var previousHandlers: [(Int32, (@convention(c) (Int32) -> Void)?)] = []
            for mapping in mappings {
                previousHandlers.append((mapping.number, Darwin.signal(mapping.number, SIG_IGN)))
                let source = DispatchSource.makeSignalSource(signal: mapping.number, queue: queue)
                source.setEventHandler {
                    handlerTasks.submit {
                        await handler(mapping.name)
                    }
                }
                cancellationGroup.enter()
                source.setCancelHandler {
                    cancellationGroup.leave()
                }
                source.resume()
                sources.append(source)
            }

            let operationResult: Result<Void, Error>
            do {
                try await operation()
                operationResult = .success(())
            } catch {
                operationResult = .failure(error)
            }
            for source in sources {
                source.cancel()
            }
            await withCheckedContinuation { continuation in
                cancellationGroup.notify(queue: queue) {
                    continuation.resume()
                }
            }
            await handlerTasks.waitForAll()
            for (number, previousHandler) in previousHandlers {
                _ = Darwin.signal(number, previousHandler)
            }
            try operationResult.get()
        }

        private static func signalMapping(named name: String) -> (name: String, number: Int32)? {
            switch name {
            case "SIGHUP":
                ("SIGHUP", SIGHUP)
            case "SIGINT":
                ("SIGINT", SIGINT)
            case "SIGQUIT":
                ("SIGQUIT", SIGQUIT)
            case "SIGTERM":
                ("SIGTERM", SIGTERM)
            default:
                nil
            }
        }
    #endif
}

#if canImport(Darwin)
    /// Serializes ownership of process-wide Darwin signal dispositions.
    private actor ProcessSignalProxyOwnership {
        private var isOwned = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard isOwned else {
                isOwned = true
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            guard !waiters.isEmpty else {
                isOwned = false
                return
            }
            waiters.removeFirst().resume()
        }
    }
#endif

private final class SignalHandlerTaskTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightTaskCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func submit(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        inFlightTaskCount += 1
        lock.unlock()

        Task {
            await operation()
            self.completeTask()
        }
    }

    func waitForAll() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard inFlightTaskCount > 0 else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func completeTask() {
        let completedWaiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        inFlightTaskCount -= 1
        if inFlightTaskCount == 0 {
            completedWaiters = waiters
            waiters.removeAll()
        } else {
            completedWaiters = []
        }
        lock.unlock()

        for waiter in completedWaiters {
            waiter.resume()
        }
    }
}
