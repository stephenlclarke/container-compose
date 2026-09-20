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
import Foundation

/// Tests inject delivery without changing the test host's signal dispositions.
final class ForegroundTestSignalProxy: ComposeSignalProxying, @unchecked Sendable {
    private let lock = NSLock()
    private var active: (@Sendable (String) async -> Void)?
    private var names: [String] = []
    private var finished = false
    private var deliveryStarted = false
    private let implementation: (any ComposeSignalProxying)?

    init(implementation: (any ComposeSignalProxying)? = nil) {
        self.implementation = implementation
    }

    var installed: [String] {
        lock.withLock { names }
    }

    var restored: Bool {
        lock.withLock { finished && active == nil }
    }

    func beginDelivery() -> Bool {
        lock.withLock {
            guard !deliveryStarted else { return false }
            deliveryStarted = true
            return true
        }
    }

    func withSignalProxy(
        signals: [String], handler: @escaping @Sendable (String) async -> Void,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        lock.withLock { names = signals; active = handler }
        defer { lock.withLock { active = nil; finished = true } }
        if let implementation {
            try await implementation.withSignalProxy(signals: signals, handler: handler, operation: operation)
        } else {
            try await operation()
        }
    }

    func send(_ signal: String) async {
        let handler = lock.withLock { active }
        await handler?(signal)
    }
}
