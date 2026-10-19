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
import ComposeRuntimeSPI
import Foundation

extension EngineServiceEnvironment {
    /// Reuses the cancellation-safe owned-process runner so FIFOs remain supported
    /// without blocking a Swift executor indefinitely. Never relay captured stderr.
    static func capture(
        paths: [String], runner: any CommandRunning, timeout: Duration = .seconds(30),
        maximumBytes: Int = 16 * 1024 * 1024
    ) async throws -> [Data] {
        guard !paths.isEmpty else { return [] }
        guard maximumBytes > 0, timeout > .zero else {
            throw ComposeError.invalidProject("Invalid environment capture bounds")
        }
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: [Data].self) { group in
            group.addTask {
                var contents: [Data] = []
                var remaining = maximumBytes
                for path in paths {
                    try Task.checkCancellation()
                    guard !path.isEmpty else { throw ComposeError.invalidProject("Empty environment file path") }
                    // Absolute operands cannot be interpreted as cat options.
                    let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
                    let result = try await runner.runCapturingOutputPrefix(
                        "/bin/cat", [absolute], input: nil, maximumOutputBytes: remaining
                    )
                    guard result.succeeded else { throw ComposeError.invalidProject("Cannot read environment file") }
                    guard result.stdoutOmittedByteCount == 0 else {
                        throw ComposeError.invalidProject("Environment files exceed their combined size limit")
                    }
                    remaining -= result.stdoutData.count
                    contents.append(result.stdoutData)
                }
                return contents
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ComposeError.invalidProject("Environment file capture exceeded its deadline")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

extension EngineRuntimeProvider {
    func capturedServiceEnvironment(_ plan: ContainerServiceCreatePlan) async throws -> [Data] {
        try await EngineServiceEnvironment.capture(paths: plan.environmentFiles, runner: runner)
    }
}
