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

/// Captured result from an external command.
public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool {
        status == 0
    }
}

/// Controls how a command connects to the parent process streams.
public enum CommandIO: Equatable, Sendable {
    case captured(input: Data?)
    case inherited
}

/// Runs external commands for normalizer and container CLI integration.
public protocol CommandRunning: Sendable {
    func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        io: CommandIO
    ) async throws -> CommandResult
}

public extension CommandRunning {
    func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            io: .captured(input: input)
        )
    }
}

/// Production command runner backed by Foundation `Process`.
public struct ProcessRunner: CommandRunning {
    public init() {
        // Stateless runner; public initializer supports dependency injection.
    }

    /// Executes a command with either captured or inherited process streams.
    public func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        io: CommandIO
    ) async throws -> CommandResult {
        switch io {
        case .captured(let input):
            try await runCaptured(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                input: input
            )
        case .inherited:
            try await runInheritingIO(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment
            )
        }
    }

    /// Runs a child process while collecting stdout and stderr independently.
    private func runCaptured(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data?
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            if input != nil {
                process.standardInput = stdin
            }
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            let state = ProcessRunState(continuation: continuation)
            process.terminationHandler = { process in
                state.completeProcess(status: process.terminationStatus)
            }

            do {
                try process.run()
                state.drain(stdout.fileHandleForReading, stream: .stdout)
                state.drain(stderr.fileHandleForReading, stream: .stderr)
                if let input {
                    try stdin.fileHandleForWriting.write(contentsOf: input)
                    try stdin.fileHandleForWriting.close()
                }
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                try? stdin.fileHandleForWriting.close()
                state.fail(error)
            }
        }
    }

    /// Runs a child process attached to the caller's terminal streams.
    private func runInheritingIO(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            let state = InheritedProcessRunState(continuation: continuation)
            process.terminationHandler = { process in
                state.complete(status: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                state.fail(error)
            }
        }
    }
}

/// Completes inherited-IO process continuations exactly once.
private final class InheritedProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, Error>?

    init(continuation: CheckedContinuation<CommandResult, Error>) {
        self.continuation = continuation
    }

    /// Resumes the pending command with the child process exit status.
    func complete(status: Int32) {
        let continuation = takeContinuation()
        continuation?.resume(returning: CommandResult(status: status, stdout: "", stderr: ""))
    }

    /// Resumes the pending command with a process launch error.
    func fail(_ error: Error) {
        let continuation = takeContinuation()
        continuation?.resume(throwing: error)
    }

    /// Removes and returns the continuation while holding the state lock.
    private func takeContinuation() -> CheckedContinuation<CommandResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

/// Coordinates process termination with stdout and stderr pipe drainage.
private final class ProcessRunState: @unchecked Sendable {
    /// Captured output stream whose pipe completed.
    enum Stream {
        case stdout
        case stderr
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutFinished = false
    private var stderrFinished = false
    private var status: Int32?

    init(continuation: CheckedContinuation<CommandResult, Error>) {
        self.continuation = continuation
    }

    /// Starts asynchronous pipe drainage for one captured stream.
    func drain(_ handle: FileHandle, stream: Stream) {
        // Drain pipes while the process is running. Waiting until termination
        // can deadlock when a child writes more than the pipe buffer.
        DispatchQueue.global(qos: .utility).async {
            let data = handle.readDataToEndOfFile()
            self.complete(stream: stream, data: data)
        }
    }

    /// Records the child process exit status and completes if streams finished.
    func completeProcess(status: Int32) {
        finish { state in
            state.status = status
        }
    }

    /// Fails the pending command immediately after a process launch error.
    func fail(_ error: Error) {
        let continuation = takeContinuation()
        continuation?.resume(throwing: error)
    }

    /// Records one completed pipe read and completes if the process exited.
    private func complete(stream: Stream, data: Data) {
        finish { state in
            switch stream {
            case .stdout:
                state.stdout = data
                state.stdoutFinished = true
            case .stderr:
                state.stderr = data
                state.stderrFinished = true
            }
        }
    }

    /// Applies a state update under lock and resumes outside the lock if done.
    private func finish(_ update: (ProcessRunState) -> Void) {
        let completion: (continuation: CheckedContinuation<CommandResult, Error>, result: CommandResult)?
        lock.lock()
        update(self)
        completion = completedResultLocked()
        lock.unlock()
        if let completion {
            completion.continuation.resume(returning: completion.result)
        }
    }

    /// Returns a command result only after process and both output streams end.
    private func completedResultLocked() -> (continuation: CheckedContinuation<CommandResult, Error>, result: CommandResult)? {
        guard let status, stdoutFinished, stderrFinished, let continuation else {
            return nil
        }
        self.continuation = nil
        return (
            continuation,
            CommandResult(
                status: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        )
    }

    /// Removes and returns the continuation while holding the state lock.
    private func takeContinuation() -> CheckedContinuation<CommandResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

/// Command invocation recorded by `RecordingRunner`.
public struct RecordedCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]?
    public var io: CommandIO

    public var input: Data? {
        if case .captured(let input) = io {
            return input
        }
        return nil
    }
}

/// Test runner that records invocations and returns queued responses.
public final class RecordingRunner: CommandRunning, @unchecked Sendable {
    public private(set) var commands: [RecordedCommand] = []
    public var responses: [CommandResult]

    public init(responses: [CommandResult] = []) {
        self.responses = responses
    }

    /// Records a command and returns the next queued response, or success.
    public func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        io: CommandIO
    ) async throws -> CommandResult {
        commands.append(RecordedCommand(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            io: io
        ))
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}
