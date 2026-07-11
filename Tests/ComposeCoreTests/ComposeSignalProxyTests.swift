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

@Suite("Compose signal proxy")
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
