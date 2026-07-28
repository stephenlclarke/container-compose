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
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Decodes arbitrary process bytes for display without dropping invalid UTF-8.
private func processOutputString(_ data: Data) -> String {
    // Process streams are arbitrary bytes, so replacement characters are more
    // useful than discarding the complete output when one byte is invalid.
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: data, as: UTF8.self)
}

/// Matches Foundation.Process status semantics for exits and uncaught signals.
private func processTerminationStatus(_ waitStatus: Int32) -> Int32 {
    let signal = waitStatus & 0x7F
    return signal == 0 ? waitStatus >> 8 & 0xFF : signal
}

/// Makes closed pipe writes fail with EPIPE instead of terminating the process.
private func suppressBrokenPipeSignal(for handle: FileHandle) {
    #if canImport(Darwin)
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    #endif
}

/// A command prepared with an isolated process group and terminal ownership.
private struct PreparedProcessCommand {
    var command: ComposeProcessCommand
    let jobControlProcessGroup: pid_t?
}

/// Parent-side pipes and optional bytes for one captured command.
private struct CapturedProcessCommandIO {
    let stdin: Pipe?
    let stdout: Pipe
    let stderr: Pipe
    let input: Data?
}

/// Configuration specific to a captured process invocation.
private struct CapturedProcessOptions {
    let input: Data?
    let maximumOutputBytes: Int?
}

/// A bounded process-stream prefix and the exact number of discarded bytes.
private struct CapturedProcessOutput {
    var data = Data()
    var omittedByteCount = 0
}

private typealias ProcessStartObserver = @Sendable (
    @escaping @Sendable () -> Void,
) -> Void

/// Minimal POSIX process primitive used by the Compose command runner.
private final class ComposeProcessCommand: @unchecked Sendable {
    struct Attributes {
        var setProcessGroup = false
        var setForegroundProcessGroup = false
    }

    let executable: String
    let arguments: [String]
    let environment: [String]
    let directory: String?
    var stdin: FileHandle?
    var stdout: FileHandle?
    var stderr: FileHandle?
    var attributes = Attributes()

    private let lock = NSLock()
    private var processIdentifier: pid_t = -1

    var pid: pid_t {
        lock.withLock { processIdentifier }
    }

    init(
        _ executable: String,
        arguments: [String],
        environment: [String],
        directory: String?,
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    func start() throws {
        guard lock.withLock({ processIdentifier == -1 }) else {
            throw POSIXError(.EBUSY)
        }

        var fileActions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try Self.duplicate(stdin ?? .standardInput, to: STDIN_FILENO, actions: &fileActions)
        try Self.duplicate(stdout ?? .standardOutput, to: STDOUT_FILENO, actions: &fileActions)
        try Self.duplicate(stderr ?? .standardError, to: STDERR_FILENO, actions: &fileActions)
        if let directory {
            #if canImport(Darwin)
                if #available(macOS 26, *) {
                    try Self.check(posix_spawn_file_actions_addchdir(&fileActions, directory))
                } else {
                    try Self.check(posix_spawn_file_actions_addchdir_np(&fileActions, directory))
                }
            #elseif canImport(Glibc)
                try Self.check(posix_spawn_file_actions_addchdir_np(&fileActions, directory))
            #endif
        }

        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        var flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
            flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        if self.attributes.setProcessGroup {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        }
        try Self.check(posix_spawnattr_setflags(&attributes, flags))

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in 1 ..< NSIG where signal != SIGKILL && signal != SIGSTOP {
            sigaddset(&defaultSignals, signal)
        }
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try Self.check(posix_spawnattr_setsigmask(&attributes, &signalMask))

        var cArguments: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer {
            for value in cArguments {
                free(value)
            }
        }
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            for value in cEnvironment {
                free(value)
            }
        }

        var child: pid_t = 0
        let result = cArguments.withUnsafeMutableBufferPointer { argumentBuffer in
            cEnvironment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawnp(
                    &child,
                    executable,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress,
                )
            }
        }
        try Self.check(result)

        lock.withLock {
            processIdentifier = child
        }
        if self.attributes.setForegroundProcessGroup {
            _ = tcsetpgrp(STDIN_FILENO, child)
        }
    }

    private static func duplicate(
        _ handle: FileHandle,
        to destination: Int32,
        actions: inout posix_spawn_file_actions_t?,
    ) throws {
        try check(posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, destination))
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }
}

/// Returns the signal that stopped a child, or nil for a terminal wait status.
func processStoppedSignal(_ waitStatus: Int32) -> Int32? {
    guard waitStatus & 0xFF == 0x7F else {
        return nil
    }
    return waitStatus >> 8 & 0xFF
}

/// Creates a process command whose descendants share one owned process group.
private func prepareProcessCommand(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: URL?,
    environment: [String: String]?,
    inheritsStandardInput: Bool,
) -> PreparedProcessCommand {
    let resolvedEnvironment = ProcessInfo.processInfo.environment
        .merging(environment ?? [:]) { _, new in new }
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
    let command = ComposeProcessCommand(
        executable,
        arguments: arguments,
        environment: resolvedEnvironment,
        directory: workingDirectory?.path,
    )
    command.attributes.setProcessGroup = true

    let foreground = processForegroundConfiguration(
        inheritsStandardInput: inheritsStandardInput,
        standardInputIsTerminal: isatty(STDIN_FILENO) == 1,
        currentForegroundProcessGroup: tcgetpgrp(STDIN_FILENO),
        currentProcessGroup: getpgrp(),
    )
    command.attributes.setForegroundProcessGroup = foreground.makeChildForeground
    return PreparedProcessCommand(
        command: command,
        jobControlProcessGroup: foreground.jobControlProcessGroup,
    )
}

/// Launches one captured command and transfers every pipe to its owner.
private func launchCapturedCommand(
    _ prepared: PreparedProcessCommand,
    io: CapturedProcessCommandIO,
    state: ProcessRunState,
    processDidStart: ProcessStartObserver,
) {
    var didLaunch = false
    do {
        if let stdin = io.stdin {
            suppressBrokenPipeSignal(for: stdin.fileHandleForWriting)
        }
        try prepared.command.start()
        didLaunch = true
        notifyProcessDidStart(processDidStart, state: state)
        state.didLaunch(
            prepared.command,
            jobControlProcessGroup: prepared.jobControlProcessGroup,
        )
        state.waitForExit(prepared.command)
        try? io.stdin?.fileHandleForReading.close()
        try? io.stdout.fileHandleForWriting.close()
        try? io.stderr.fileHandleForWriting.close()
        state.drain(io.stdout.fileHandleForReading, stream: .stdout)
        state.drain(io.stderr.fileHandleForReading, stream: .stderr)
        if let input = io.input, let stdin = io.stdin {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        }
    } catch {
        try? io.stdin?.fileHandleForReading.close()
        try? io.stdin?.fileHandleForWriting.close()
        try? io.stdout.fileHandleForWriting.close()
        try? io.stderr.fileHandleForWriting.close()
        if didLaunch {
            state.failAfterLaunch(error)
        } else {
            try? io.stdout.fileHandleForReading.close()
            try? io.stderr.fileHandleForReading.close()
            state.failBeforeLaunch(error)
        }
    }
}

/// Invokes the launch-race test hook without nesting it inside run continuations.
private func notifyProcessDidStart(
    _ observer: ProcessStartObserver,
    state: ProcessRunState,
) {
    observer {
        state.cancel()
    }
}

/// Captured result from an external command.
public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    package var stdoutData: Data
    package var stderrData: Data
    package var stdoutOmittedByteCount: Int
    package var stderrOmittedByteCount: Int

    public var stdout: String {
        get { processOutputString(stdoutData) }
        set {
            stdoutData = Data(newValue.utf8)
            stdoutOmittedByteCount = 0
        }
    }

    public var stderr: String {
        get { processOutputString(stderrData) }
        set {
            stderrData = Data(newValue.utf8)
            stderrOmittedByteCount = 0
        }
    }

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        stdoutData = Data(stdout.utf8)
        stderrData = Data(stderr.utf8)
        stdoutOmittedByteCount = 0
        stderrOmittedByteCount = 0
    }

    package init(
        status: Int32,
        stdoutData: Data,
        stderrData: Data,
        stdoutOmittedByteCount: Int = 0,
        stderrOmittedByteCount: Int = 0,
    ) {
        self.status = status
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.stdoutOmittedByteCount = stdoutOmittedByteCount
        self.stderrOmittedByteCount = stderrOmittedByteCount
    }

    public static func == (lhs: CommandResult, rhs: CommandResult) -> Bool {
        lhs.status == rhs.status
            && lhs.stdout == rhs.stdout
            && lhs.stderr == rhs.stderr
    }

    public var succeeded: Bool {
        status == 0
    }
}

/// Controls how a command connects to the parent process streams.
public enum CommandIO: Equatable, Sendable {
    case captured(input: Data?)
    case capturedOutputInheritingInputAndError
    case inherited
    case replacingProcess
}

/// Runs external commands for normalizer and container CLI integration.
public protocol CommandRunning: Sendable {
    /// Runs a command with explicit control over captured or inherited streams.
    func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        io: CommandIO,
    ) async throws -> CommandResult
}

public extension CommandRunning {
    /// Runs a command with captured output and optional stdin data.
    func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil,
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            io: .captured(input: input),
        )
    }
}

/// Production command runner backed by POSIX process spawning.
public struct ProcessRunner: CommandRunning {
    private static let isStateless = true
    private let processDidStart: ProcessStartObserver

    public init() {
        processDidStart = { _ in
            // Production runs do not install the launch-race test hook.
        }
        _ = Self.isStateless
    }

    init(
        processDidStart: @escaping @Sendable (
            @escaping @Sendable () -> Void,
        ) -> Void,
    ) {
        self.processDidStart = processDidStart
    }

    /// Executes a command with either captured or inherited process streams.
    public func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        io: CommandIO,
    ) async throws -> CommandResult {
        switch io {
        case let .captured(input):
            try await runCaptured(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                options: CapturedProcessOptions(
                    input: input,
                    maximumOutputBytes: nil,
                ),
            )
        case .capturedOutputInheritingInputAndError:
            try await runCapturedOutputInheritingInputAndError(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
            )
        case .inherited:
            try await runInheritingIO(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
            )
        case .replacingProcess:
            try replaceCurrentProcess(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
            )
        }
    }

    /// Runs a captured command while retaining at most one prefix per output stream.
    package func runCapturingOutputPrefix(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil,
        maximumOutputBytes: Int,
    ) async throws -> CommandResult {
        precondition(maximumOutputBytes >= 0)
        return try await runCaptured(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            options: CapturedProcessOptions(
                input: input,
                maximumOutputBytes: maximumOutputBytes,
            ),
        )
    }

    /// Runs a child process with stdin/stderr attached and stdout captured.
    private func runCapturedOutputInheritingInputAndError(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
    ) async throws -> CommandResult {
        let state = ProcessRunState(capturesStdout: true, capturesStderr: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stdout = Pipe()
                let prepared = prepareProcessCommand(
                    executable,
                    arguments,
                    workingDirectory: workingDirectory,
                    environment: environment,
                    inheritsStandardInput: true,
                )
                prepared.command.stdin = FileHandle.standardInput
                prepared.command.stdout = stdout.fileHandleForWriting
                prepared.command.stderr = FileHandle.standardError

                guard state.prepareForLaunch(continuation: continuation) else {
                    try? stdout.fileHandleForReading.close()
                    try? stdout.fileHandleForWriting.close()
                    return
                }

                do {
                    try prepared.command.start()
                    notifyProcessDidStart(processDidStart, state: state)
                    state.didLaunch(
                        prepared.command,
                        jobControlProcessGroup: prepared.jobControlProcessGroup,
                    )
                    state.waitForExit(prepared.command)
                    try? stdout.fileHandleForWriting.close()
                    state.drain(stdout.fileHandleForReading)
                } catch {
                    try? stdout.fileHandleForReading.close()
                    try? stdout.fileHandleForWriting.close()
                    state.failBeforeLaunch(error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Runs a child process while collecting stdout and stderr independently.
    private func runCaptured(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        options: CapturedProcessOptions,
    ) async throws -> CommandResult {
        let state = ProcessRunState(
            capturesStdout: true,
            capturesStderr: true,
            maximumOutputBytes: options.maximumOutputBytes,
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stdout = Pipe()
                let stderr = Pipe()
                let stdin = options.input == nil ? nil : Pipe()
                let prepared = prepareProcessCommand(
                    executable,
                    arguments,
                    workingDirectory: workingDirectory,
                    environment: environment,
                    inheritsStandardInput: options.input == nil,
                )
                prepared.command.stdin = stdin?.fileHandleForReading ?? FileHandle.standardInput
                prepared.command.stdout = stdout.fileHandleForWriting
                prepared.command.stderr = stderr.fileHandleForWriting

                guard state.prepareForLaunch(continuation: continuation) else {
                    try? stdin?.fileHandleForReading.close()
                    try? stdin?.fileHandleForWriting.close()
                    try? stdout.fileHandleForReading.close()
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForReading.close()
                    try? stderr.fileHandleForWriting.close()
                    return
                }

                launchCapturedCommand(
                    prepared,
                    io: CapturedProcessCommandIO(
                        stdin: stdin,
                        stdout: stdout,
                        stderr: stderr,
                        input: options.input,
                    ),
                    state: state,
                    processDidStart: processDidStart,
                )
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Runs a child process attached to the caller's terminal streams.
    private func runInheritingIO(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
    ) async throws -> CommandResult {
        let state = ProcessRunState(capturesStdout: false, capturesStderr: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let prepared = prepareProcessCommand(
                    executable,
                    arguments,
                    workingDirectory: workingDirectory,
                    environment: environment,
                    inheritsStandardInput: true,
                )
                prepared.command.stdin = FileHandle.standardInput
                prepared.command.stdout = FileHandle.standardOutput
                prepared.command.stderr = FileHandle.standardError

                guard state.prepareForLaunch(continuation: continuation) else {
                    return
                }

                do {
                    try prepared.command.start()
                    notifyProcessDidStart(processDidStart, state: state)
                    state.didLaunch(
                        prepared.command,
                        jobControlProcessGroup: prepared.jobControlProcessGroup,
                    )
                    state.waitForExit(prepared.command)
                } catch {
                    state.failBeforeLaunch(error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Replaces the plugin process with an interactive child command.
    private func replaceCurrentProcess(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
    ) throws -> CommandResult {
        if let workingDirectory, chdir(workingDirectory.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let environment {
            for (key, value) in environment {
                setenv(key, value, 1)
            }
        }

        let processArguments = [executable] + arguments
        var cArguments = processArguments.map { strdup($0) }
        defer {
            for argument in cArguments {
                free(argument)
            }
        }
        cArguments.append(nil)
        _ = cArguments.withUnsafeMutableBufferPointer { buffer in
            execvp(executable, buffer.baseAddress)
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Owns one child process, its captured streams, and exact-once completion.
private final class ProcessRunState: @unchecked Sendable {
    /// Captured output stream whose pipe completed.
    enum Stream {
        case stdout
        case stderr
    }

    private typealias Completion = (
        continuation: CheckedContinuation<CommandResult, Error>,
        result: Result<CommandResult, Error>,
    )

    private static let terminationGracePeriod = DispatchTimeInterval.milliseconds(250)

    private let lock = NSLock()
    private var cancellationRequested = false
    private var completionError: Error?
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var escalation: DispatchWorkItem?
    private var jobControlProcessGroup: pid_t?
    private let maximumOutputBytes: Int?
    private var ownedProcessGroup: pid_t?
    private var stdout = Data()
    private var stdoutOmittedByteCount = 0
    private var stderr = Data()
    private var stderrOmittedByteCount = 0
    private var stdoutFinished: Bool
    private var stderrFinished: Bool
    private var status: Int32?
    private var terminationFinished = false
    private var terminationRequested = false

    init(
        capturesStdout: Bool,
        capturesStderr: Bool,
        maximumOutputBytes: Int? = nil,
    ) {
        self.maximumOutputBytes = maximumOutputBytes
        stdoutFinished = !capturesStdout
        stderrFinished = !capturesStderr
    }

    /// Installs the continuation and atomically reserves permission to launch.
    func prepareForLaunch(continuation: CheckedContinuation<CommandResult, Error>) -> Bool {
        let cancellationError: Error?
        lock.lock()
        if cancellationRequested {
            cancellationError = completionError ?? CancellationError()
        } else {
            self.continuation = continuation
            cancellationError = nil
        }
        lock.unlock()

        if let cancellationError {
            continuation.resume(throwing: cancellationError)
            return false
        }
        return true
    }

    /// Records a successful launch and terminates immediately if cancellation raced it.
    func didLaunch(
        _ command: ComposeProcessCommand,
        jobControlProcessGroup: pid_t?,
    ) {
        let processGroup = command.pid
        let terminationWorkItem: DispatchWorkItem?
        lock.lock()
        ownedProcessGroup = processGroup
        self.jobControlProcessGroup = jobControlProcessGroup
        terminationWorkItem = cancellationRequested
            ? beginTerminationLocked(of: processGroup)
            : nil
        lock.unlock()

        if let terminationWorkItem {
            startTermination(
                of: processGroup,
                escalation: terminationWorkItem,
            )
        }
    }

    /// Reaps the child leader without blocking the caller's async executor.
    func waitForExit(_ command: ComposeProcessCommand) {
        let processIdentifier = command.pid
        DispatchQueue.global(qos: .utility).async {
            while true {
                var waitStatus = Int32()
                let result = waitpid(processIdentifier, &waitStatus, WUNTRACED)
                if result == processIdentifier {
                    if let stopSignal = processStoppedSignal(waitStatus) {
                        self.relayStop(
                            processGroup: processIdentifier,
                            signal: stopSignal,
                        )
                        continue
                    }
                    self.completeProcess(status: processTerminationStatus(waitStatus))
                    return
                }
                if result == -1, errno == EINTR {
                    continue
                }
                self.completeProcess(
                    status: -1,
                    error: POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD),
                )
                return
            }
        }
    }

    /// Starts asynchronous pipe drainage for one captured stream.
    func drain(_ handle: FileHandle, stream: Stream = .stdout) {
        // Drain pipes while the process is running. Waiting until termination
        // can deadlock when a child writes more than the pipe buffer.
        DispatchQueue.global(qos: .utility).async {
            var output = CapturedProcessOutput()
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                guard !chunk.isEmpty else {
                    break
                }
                if let maximumOutputBytes = self.maximumOutputBytes {
                    let retainedByteCount = min(
                        chunk.count,
                        max(0, maximumOutputBytes - output.data.count),
                    )
                    output.data.append(chunk.prefix(retainedByteCount))
                    output.omittedByteCount += chunk.count - retainedByteCount
                } else {
                    output.data.append(chunk)
                }
            }
            self.complete(stream: stream, output: output)
        }
    }
}

private extension ProcessRunState {
    /// Hands a stopped foreground child back through the parent shell job.
    func relayStop(
        processGroup: pid_t,
        signal: Int32,
    ) {
        let parentProcessGroup: pid_t?
        lock.lock()
        if
            ownedProcessGroup == processGroup,
            !terminationRequested
        {
            parentProcessGroup = jobControlProcessGroup
        } else {
            parentProcessGroup = nil
        }
        lock.unlock()

        let error = relayStoppedProcessGroup(
            childProcessGroup: processGroup,
            parentProcessGroup: parentProcessGroup,
            stopSignal: signal,
            actions: liveProcessJobControlActions(),
        )
        if let error {
            failAfterLaunch(error)
        }
    }

    /// Records the child process exit status and completes if streams finished.
    func completeProcess(status: Int32, error: Error? = nil) {
        let childProcessGroup: pid_t?
        let completion: Completion?
        let parentProcessGroup: pid_t?
        lock.lock()
        childProcessGroup = ownedProcessGroup
        parentProcessGroup = jobControlProcessGroup
        jobControlProcessGroup = nil
        lock.unlock()

        let foregroundProcessGroup = terminalForegroundProcessGroupToRestore(
            childProcessGroup: childProcessGroup,
            parentProcessGroup: parentProcessGroup,
            currentForegroundProcessGroup: tcgetpgrp(STDIN_FILENO),
        )
        let foregroundRestorationError = restoreForegroundProcessGroup(foregroundProcessGroup)

        lock.lock()
        if completionError == nil {
            completionError = error ?? foregroundRestorationError
        }
        self.status = status
        completion = completedResultLocked()
        lock.unlock()
        resume(completion)
    }

    /// Makes cancellation terminal and starts bounded child termination.
    func cancel() {
        let completion: Completion?
        let processGroup: pid_t?
        let terminationWorkItem: DispatchWorkItem?
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        completionError = CancellationError()
        processGroup = ownedProcessGroup
        terminationWorkItem = processGroup.flatMap(beginTerminationLocked)
        completion = completedResultLocked()
        lock.unlock()
        resume(completion)

        if let processGroup, let terminationWorkItem {
            startTermination(
                of: processGroup,
                escalation: terminationWorkItem,
            )
        }
    }

    /// Fails immediately when no child process was launched.
    func failBeforeLaunch(_ error: Error) {
        let continuation: CheckedContinuation<CommandResult, Error>?
        let completionError: Error
        lock.lock()
        continuation = self.continuation
        self.continuation = nil
        completionError = self.completionError ?? error
        lock.unlock()
        continuation?.resume(throwing: completionError)
    }

    /// Records an I/O failure and terminates the launched child.
    func failAfterLaunch(_ error: Error) {
        let completion: Completion?
        let processGroup: pid_t?
        let terminationWorkItem: DispatchWorkItem?
        lock.lock()
        if completionError == nil {
            completionError = error
        }
        processGroup = ownedProcessGroup
        terminationWorkItem = processGroup.flatMap(beginTerminationLocked)
        completion = completedResultLocked()
        lock.unlock()
        resume(completion)

        if let processGroup, let terminationWorkItem {
            startTermination(
                of: processGroup,
                escalation: terminationWorkItem,
            )
        }
    }

    /// Records one completed pipe read and completes if the process exited.
    private func complete(stream: Stream, output: CapturedProcessOutput) {
        let completion: Completion?
        lock.lock()
        switch stream {
        case .stdout:
            stdout = output.data
            stdoutOmittedByteCount = output.omittedByteCount
            stdoutFinished = true
        case .stderr:
            stderr = output.data
            stderrOmittedByteCount = output.omittedByteCount
            stderrFinished = true
        }
        completion = completedResultLocked()
        lock.unlock()
        resume(completion)
    }

    /// Latches termination while the caller owns the state lock.
    private func beginTerminationLocked(
        of processGroup: pid_t,
    ) -> DispatchWorkItem? {
        guard
            ownedProcessGroup == processGroup,
            !terminationRequested
        else {
            return nil
        }
        terminationRequested = true
        let item = DispatchWorkItem {
            self.forceTerminate(processGroup)
        }
        escalation = item
        return item
    }

    /// Sends SIGTERM and schedules SIGKILL after termination is latched.
    private func startTermination(
        of processGroup: pid_t,
        escalation: DispatchWorkItem,
    ) {
        _ = kill(-processGroup, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.terminationGracePeriod,
            execute: escalation,
        )
    }

    /// Sends SIGKILL and waits until the owned group no longer exists.
    private func forceTerminate(_ processGroup: pid_t) {
        _ = kill(-processGroup, SIGKILL)
        for _ in 0 ..< 100 {
            errno = 0
            if kill(-processGroup, 0) == -1, errno == ESRCH {
                break
            }
            usleep(10000)
        }

        let completion: Completion?
        lock.lock()
        terminationFinished = true
        escalation = nil
        completion = completedResultLocked()
        lock.unlock()
        resume(completion)
    }

    /// Restores terminal foreground ownership after an inherited child exits.
    private func restoreForegroundProcessGroup(_ processGroup: pid_t?) -> Error? {
        restoreTerminalForegroundProcessGroup(
            processGroup,
            fileDescriptor: STDIN_FILENO,
        )
    }

    /// Resumes a terminal process result outside the state lock.
    private func resume(_ completion: Completion?) {
        if let completion {
            completion.continuation.resume(with: completion.result)
        }
    }

    /// Returns a command result only after process and both output streams end.
    private func completedResultLocked() -> Completion? {
        guard
            let status,
            stdoutFinished,
            stderrFinished,
            !terminationRequested || terminationFinished,
            let continuation
        else {
            return nil
        }
        self.continuation = nil
        ownedProcessGroup = nil
        if let completionError {
            return (continuation, .failure(completionError))
        }
        return (
            continuation,
            .success(CommandResult(
                status: status,
                stdoutData: stdout,
                stderrData: stderr,
                stdoutOmittedByteCount: stdoutOmittedByteCount,
                stderrOmittedByteCount: stderrOmittedByteCount,
            )),
        )
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
