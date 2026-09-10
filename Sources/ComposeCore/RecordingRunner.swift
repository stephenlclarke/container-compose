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

/// Command invocation recorded by `RecordingRunner`.
public struct RecordedCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]?
    public var io: CommandIO

    public var input: Data? {
        if case let .captured(input) = io {
            return input
        }
        return nil
    }
}

/// Test runner that records invocations and returns queued responses.
public final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var commandStorage: [RecordedCommand] = []
    private var responseStorage: [CommandResult]

    public var commands: [RecordedCommand] {
        lock.lock()
        defer { lock.unlock() }
        return commandStorage
    }

    public var responses: [CommandResult] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return responseStorage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            responseStorage = newValue
        }
    }

    public init(responses: [CommandResult] = []) {
        responseStorage = responses
    }

    /// Records a command and returns the next queued response, or success.
    public func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        io: CommandIO,
    ) async throws -> CommandResult {
        lock.withLock {
            commandStorage.append(RecordedCommand(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                io: io,
            ))
            return responseStorage.isEmpty
                ? CommandResult(status: 0, stdout: "", stderr: "")
                : responseStorage.removeFirst()
        }
    }
}
