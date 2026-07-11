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

func menuConfiguration(
    watchEnabled: Bool = false,
    watchAvailable: Bool = true,
    statuses: UpMenuStringRecorder,
    actions: ComposeUpMenuActions,
) -> ComposeUpMenuConfiguration {
    ComposeUpMenuConfiguration(
        projectName: "demo",
        watchEnabled: watchEnabled,
        watchAvailable: watchAvailable,
        colorEnabled: false,
        emitStatus: { statuses.append($0) },
        actions: actions,
    )
}

func pendingOperationTask() -> Task<Void, any Error> {
    Task {
        try await Task.sleep(for: .seconds(60))
    }
}

final class UpMenuStringRecorder: @unchecked Sendable {
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
