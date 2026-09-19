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

import ContainerUnixHTTPClient
import Foundation

/// A response-head acknowledgement means the gateway registered the exact
/// process generation before startup. The separate result survives auto-remove.
final class EngineForegroundExitWait: Sendable {
    private let task: Task<Int32, any Error>

    private init(task: Task<Int32, any Error>) {
        self.task = task
    }

    static func prepare(client: ContainerUnixHTTPClient, path: String) async throws -> EngineForegroundExitWait {
        let readiness = EngineExitWaitReadiness()
        let task = Task {
            do {
                let response = try await client.send(
                    .init(method: .post, target: path + "/wait?condition=next-exit"),
                    maximumBodyBytes: 65536,
                    onResponseHead: { _ in readiness.finish(.success(())) }
                )
                return try decode(response.body)
            } catch {
                readiness.finish(.failure(error))
                throw error
            }
        }
        let wait = EngineForegroundExitWait(task: task)
        return try await withTaskCancellationHandler {
            do {
                try await readiness.wait()
                try Task.checkCancellation()
                return wait
            } catch {
                task.cancel()
                _ = await task.result
                throw error
            }
        } onCancel: {
            readiness.finish(.failure(CancellationError()))
            task.cancel()
        }
    }

    var value: Int32 {
        get async throws { try await task.value }
    }

    func cancel() {
        task.cancel()
    }

    private static func decode(_ data: Data) throws -> Int32 {
        let exit = try JSONDecoder().decode(ForegroundExit.self, from: data)
        if let error = exit.error, !error.message.isEmpty {
            throw ContainerUnixHTTPClientError.invalidResponse(error.message)
        }
        guard (0 ... 255).contains(exit.statusCode) else {
            throw ContainerUnixHTTPClientError.invalidResponse("invalid container exit status")
        }
        return exit.statusCode
    }
}

private final class EngineExitWaitReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completed: Result<Void, any Error>? = lock.withLock {
                if let result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let completed {
                continuation.resume(with: completed)
            }
        }
    }

    func finish(_ result: Result<Void, any Error>) {
        let pending: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

private struct ForegroundExit: Decodable {
    let statusCode: Int32
    let error: ForegroundExitFailure?
    enum CodingKeys: String, CodingKey { case statusCode = "StatusCode", error = "Error" }
}

private struct ForegroundExitFailure: Decodable {
    let message: String
    enum CodingKeys: String, CodingKey { case message = "Message" }
}
