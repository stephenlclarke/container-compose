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
    /// Runs independent image operations using Docker Compose's effective
    /// parallelism limit.
    func runImageOperations(
        _ images: [String],
        progressMessage: String,
        quiet: Bool,
        operation: @escaping @Sendable (_ image: String, _ quiet: Bool) async throws -> Void,
    ) async throws {
        guard let limit = try engineOperationParallelLimit(operationCount: images.count) else {
            for image in images {
                try await operation(image, quiet)
            }
            return
        }

        try await progressActivity(progressMessage, quiet: quiet) {
            try await runBoundedEngineOperations(images, limit: limit) { image in
                try await operation(image, true)
            }
        }
    }

    /// Returns the effective parallelism for independent engine operations.
    ///
    /// A `nil` return value preserves deterministic handling for dry runs,
    /// single-operation batches, and an explicit limit of one.
    func engineOperationParallelLimit(
        operationCount: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws -> Int? {
        let requested = try ComposeExecutionOptions.effectiveParallelism(
            explicit: options.maxParallelism,
            environment: environment,
        )
        guard !options.dryRun, operationCount > 1 else {
            return nil
        }
        if requested == -1 {
            return operationCount
        }
        return requested > 1 ? min(requested, operationCount) : nil
    }

    /// Executes values with a bounded task group while preserving cancellation.
    func runBoundedEngineOperations<Value>(
        _ values: [Value],
        limit: Int,
        operation: @escaping @Sendable (Value) async throws -> Void,
    ) async throws {
        var iterator = values.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var activeTasks = 0
            for _ in 0 ..< limit {
                guard let value = iterator.next() else {
                    break
                }
                activeTasks += 1
                let concurrentValue = ConcurrentEngineOperationValue(value: value)
                group.addTask {
                    try await operation(concurrentValue.value)
                }
            }

            while activeTasks > 0 {
                try await group.next()
                activeTasks -= 1
                guard let value = iterator.next() else {
                    continue
                }
                activeTasks += 1
                let concurrentValue = ConcurrentEngineOperationValue(value: value)
                group.addTask {
                    try await operation(concurrentValue.value)
                }
            }
        }
    }
}

/// Carries an immutable value into an independent engine-operation task.
///
/// Compose models are copied before scheduling and never mutated while their
/// task group is running. The wrapper confines that audited assumption to the
/// parallel scheduler instead of marking the broad normalized model Sendable.
struct ConcurrentEngineOperationValue<Value>: @unchecked Sendable {
    let value: Value
}
