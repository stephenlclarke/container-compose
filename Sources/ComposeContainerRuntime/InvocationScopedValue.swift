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

import ContainerAPIClient
import Synchronization

typealias ContainerClientProvider = @Sendable () -> ContainerClient

/// Lazily creates one shared value for a single Compose invocation.
///
/// Container's XPC client activates its connection during initialization, so
/// the value must remain lazy: parser-only commands must not start the runtime.
/// The mutex also guarantees that concurrent service operations cannot race
/// and create duplicate connections on first use.
final class InvocationScopedValue<Value: Sendable>: Sendable {
    private let value: Mutex<Value?> = Mutex(nil)
    private let create: @Sendable () -> Value

    init(create: @escaping @Sendable () -> Value) {
        self.create = create
    }

    func get() -> Value {
        value.withLock { value in
            if let value {
                return value
            }
            let created = create()
            value = created
            return created
        }
    }
}

/// Separates reusable control-plane calls from connection-owned sessions.
///
/// `ClientProcess.disconnect()` closes its underlying XPC connection, so
/// attach and interactive exec sessions must keep dedicated connections while
/// ordinary discovery, lifecycle, log, stats, and filesystem requests share
/// the invocation-scoped control connection.
final class InvocationScopedClientPool<Value: Sendable>: Sendable {
    private let controlValue: InvocationScopedValue<Value>
    private let create: @Sendable () -> Value

    init(create: @escaping @Sendable () -> Value) {
        controlValue = InvocationScopedValue(create: create)
        self.create = create
    }

    func control() -> Value {
        controlValue.get()
    }

    func session() -> Value {
        create()
    }
}
