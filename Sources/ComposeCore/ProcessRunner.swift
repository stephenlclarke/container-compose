import Foundation

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

public protocol CommandRunning: Sendable {
    func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data?
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
            input: input
        )
    }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(
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

            process.terminationHandler = { process in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: out, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self)
                ))
            }

            do {
                try process.run()
                if let input {
                    try stdin.fileHandleForWriting.write(contentsOf: input)
                    try stdin.fileHandleForWriting.close()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public struct RecordedCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL?
}

public final class RecordingRunner: CommandRunning, @unchecked Sendable {
    public private(set) var commands: [RecordedCommand] = []
    public var responses: [CommandResult]

    public init(responses: [CommandResult] = []) {
        self.responses = responses
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data?
    ) async throws -> CommandResult {
        commands.append(RecordedCommand(executable: executable, arguments: arguments, workingDirectory: workingDirectory))
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}
