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
#if canImport(Darwin)
    import Darwin
#endif
import Foundation
import Testing

@Suite("Compose signal proxy", .serialized)
struct ComposeSignalProxyTests {
    @Test
    func `unknown signal names run the operation without installing handlers`() async throws {
        let events = SignalEventRecorder()

        try await DispatchComposeSignalProxy().withSignalProxy(
            signals: ["NOT_A_SIGNAL"],
            handler: { await events.append($0) },
            operation: { await events.append("operation") },
        )

        #expect(await events.values == ["operation"])
    }

    #if canImport(Darwin)
        @Test
        func `supported signals are forwarded and handlers are restored`() async throws {
            let events = SignalEventRecorder()

            try await DispatchComposeSignalProxy().withSignalProxy(
                signals: ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"],
                handler: { await events.append($0) },
                operation: {
                    guard Darwin.raise(SIGHUP) == 0 else {
                        throw SignalProxyTestError.raiseFailed
                    }
                    for _ in 0 ..< 100 {
                        if await events.contains("SIGHUP") {
                            return
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    throw SignalProxyTestError.timedOut
                },
            )

            #expect(await events.values == ["SIGHUP"])
        }

        @Test
        func `proxy waits for delivered signal handlers before returning`() async throws {
            let gate = SignalHandlerCompletionGate()
            let task = Task {
                try await DispatchComposeSignalProxy().withSignalProxy(
                    signals: ["SIGHUP"],
                    handler: { await gate.handle($0) },
                    operation: {
                        guard Darwin.raise(SIGHUP) == 0 else {
                            throw SignalProxyTestError.raiseFailed
                        }
                        for _ in 0 ..< 100 {
                            if await gate.handlerStarted {
                                return
                            }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        throw SignalProxyTestError.timedOut
                    },
                )
                await gate.recordProxyCompletion()
            }

            for _ in 0 ..< 100 {
                if await gate.handlerStarted {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await gate.handlerStarted)

            for _ in 0 ..< 20 {
                if await gate.proxyCompleted {
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await !gate.proxyCompleted)

            await gate.releaseHandler()
            try await task.value
            #expect(await gate.proxyCompleted)
            #expect(await gate.signals == ["SIGHUP"])
        }
    #endif
}

private enum SignalProxyTestError: Error {
    case raiseFailed
    case timedOut
}

private actor SignalEventRecorder {
    private var events: [String] = []

    var values: [String] {
        events
    }

    func append(_ event: String) {
        events.append(event)
    }

    func contains(_ event: String) -> Bool {
        events.contains(event)
    }
}

private actor SignalHandlerCompletionGate {
    private(set) var handlerStarted = false
    private(set) var proxyCompleted = false
    private(set) var signals: [String] = []
    private var handlerRelease: CheckedContinuation<Void, Never>?
    private var handlerReleased = false

    func handle(_ signal: String) async {
        signals.append(signal)
        handlerStarted = true
        guard !handlerReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            handlerRelease = continuation
        }
    }

    func recordProxyCompletion() {
        proxyCompleted = true
    }

    func releaseHandler() {
        handlerReleased = true
        handlerRelease?.resume()
        handlerRelease = nil
    }
}
