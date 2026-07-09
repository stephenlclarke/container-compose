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

import Foundation

extension ComposeOrchestrator {
    /// Runs image operations sequentially by default, or with the Docker
    /// Compose-compatible explicit `--parallel` limit when requested.
    func runImageOperations(
        _ images: [String],
        progressMessage: String,
        quiet: Bool,
        operation: @escaping @Sendable (_ image: String, _ quiet: Bool) async throws -> Void,
    ) async throws {
        guard let limit = try imageOperationParallelLimit(operationCount: images.count) else {
            for image in images {
                try await operation(image, quiet)
            }
            return
        }

        try await progressActivity(progressMessage, quiet: quiet) {
            try await runBoundedImageOperations(images, limit: limit) { image in
                try await operation(image, true)
            }
        }
    }

    /// Returns the effective bounded parallelism for image operations.
    func imageOperationParallelLimit(operationCount: Int) throws -> Int? {
        guard let requested = options.maxParallelism else {
            return nil
        }
        guard requested == -1 || requested > 0 else {
            throw ComposeError.invalidProject("--parallel must be -1 or a positive integer")
        }
        guard !options.dryRun, operationCount > 1 else {
            return nil
        }
        if requested == -1 {
            return operationCount
        }
        return requested > 1 ? min(requested, operationCount) : nil
    }

    private func runBoundedImageOperations(
        _ images: [String],
        limit: Int,
        operation: @escaping @Sendable (String) async throws -> Void,
    ) async throws {
        var iterator = images.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var activeTasks = 0
            for _ in 0 ..< limit {
                guard let image = iterator.next() else {
                    break
                }
                activeTasks += 1
                group.addTask {
                    try await operation(image)
                }
            }

            while activeTasks > 0 {
                try await group.next()
                activeTasks -= 1
                guard let image = iterator.next() else {
                    continue
                }
                activeTasks += 1
                group.addTask {
                    try await operation(image)
                }
            }
        }
    }
}
