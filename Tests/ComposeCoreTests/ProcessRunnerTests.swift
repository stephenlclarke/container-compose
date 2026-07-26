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
import Testing
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

struct ForegroundConfigurationCase: Sendable {
    let inheritsStandardInput: Bool
    let standardInputIsTerminal: Bool
    let currentForegroundProcessGroup: pid_t
    let currentProcessGroup: pid_t
    let expectedForeground: Bool
    let expectedJobControlProcessGroup: pid_t?
}

struct ForegroundRestorationSelectionCase: Sendable {
    let childProcessGroup: pid_t?
    let parentProcessGroup: pid_t?
    let currentForegroundProcessGroup: pid_t
    let expectedProcessGroup: pid_t?
}

struct ForegroundRestorationFailureCase: Sendable {
    let foregroundError: Int32
    let maskRestorationError: Int32
    let expectedError: Int32
}

@Suite("Process runner", .serialized)
struct ProcessRunnerTests {
    @Test
    func `process runner captures stdout stderr status input env and cwd`() async throws {
        let directory = FileManager.default.temporaryDirectory
        let script = "printf \"%s:%s\" \"$PROCESS_RUNNER_VALUE\" \"$(pwd)\"; cat; printf err >&2"
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", script],
            workingDirectory: directory,
            environment: ["PROCESS_RUNNER_VALUE": "ok"],
            input: Data(" input".utf8),
        )

        #expect(result.succeeded)
        #expect(
            result.stdout == "ok:\(directory.path) input"
                || result.stdout == "ok:/private\(directory.path) input",
        )
        #expect(result.stderr == "err")
    }

    @Test
    func `process runner preserves invalid UTF-8 as replacement characters`() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", "printf '\\377'; printf '\\376' >&2"],
        )

        #expect(result.succeeded)
        #expect(result.stdout == "\u{FFFD}")
        #expect(result.stderr == "\u{FFFD}")
    }

    @Test
    func `process runner captures stdout while inheriting prompt streams`() async throws {
        let directory = FileManager.default.temporaryDirectory
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", "printf '%s:%s' \"$PROCESS_RUNNER_VALUE\" \"$(pwd)\""],
            workingDirectory: directory,
            environment: ["PROCESS_RUNNER_VALUE": "json"],
            io: .capturedOutputInheritingInputAndError,
        )

        #expect(result.succeeded)
        #expect(
            result.stdout == "json:\(directory.path)"
                || result.stdout == "json:/private\(directory.path)",
        )
        #expect(result.stderr.isEmpty)
    }

    @Test
    func `recording runner captures command environment`() async throws {
        let runner = RecordingRunner()

        _ = try await runner.run("/usr/bin/env", ["true"], environment: ["SAMPLE": "value"])

        let command = try #require(runner.commands.first)
        #expect(command.environment == ["SAMPLE": "value"])
    }

    @Test
    func `recording runner captures command input`() async throws {
        let runner = RecordingRunner()
        let input = Data("payload".utf8)

        _ = try await runner.run("/usr/bin/env", ["true"], input: input)

        let command = try #require(runner.commands.first)
        #expect(command.input == input)
    }

    @Test
    func `recording runner exposes no input for inherited IO`() async throws {
        let runner = RecordingRunner()

        _ = try await runner.run(
            "/usr/bin/env",
            ["true"],
            workingDirectory: nil,
            environment: nil,
            io: .inherited,
        )

        let command = try #require(runner.commands.first)
        #expect(command.input == nil)
    }

    @Test
    func `process runner reports status when inheriting terminal IO`() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", "exit 7"],
            workingDirectory: nil,
            environment: nil,
            io: .inherited,
        )

        #expect(result.status == 7)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test
    func `process runner applies working directory and environment to inherited IO`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", "test \"$PROCESS_RUNNER_VALUE\" = ok && touch inherited-io-marker"],
            workingDirectory: directory,
            environment: ["PROCESS_RUNNER_VALUE": "ok"],
            io: .inherited,
        )

        #expect(result.succeeded)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("inherited-io-marker").path))
    }

    @Test
    func `process runner reports captured and inherited launch failures`() async {
        let missingExecutable = "/container-compose-tests/missing-executable"
        var failures = 0

        for commandIO in [CommandIO.captured(input: nil), .capturedOutputInheritingInputAndError, .inherited] {
            do {
                _ = try await ProcessRunner().run(
                    missingExecutable,
                    [],
                    workingDirectory: nil,
                    environment: nil,
                    io: commandIO,
                )
                Issue.record("Expected process launch failure for \(commandIO)")
            } catch {
                failures += 1
            }
        }

        #expect(failures == 3)
    }

    @Test
    func `replacing process reports exec and working directory failures`() async {
        let missingExecutable = "/container-compose-tests/missing-executable"
        let environmentKey = "CONTAINER_COMPOSE_REPLACE_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        defer {
            unsetenv(environmentKey)
        }
        var failures = 0

        do {
            _ = try await ProcessRunner().run(
                missingExecutable,
                [],
                workingDirectory: nil,
                environment: [environmentKey: "inherited"],
                io: .replacingProcess,
            )
            Issue.record("Expected exec failure")
        } catch {
            failures += 1
        }
        #expect(ProcessInfo.processInfo.environment[environmentKey] == "inherited")

        do {
            _ = try await ProcessRunner().run(
                missingExecutable,
                [],
                workingDirectory: URL(fileURLWithPath: "/container-compose-tests/missing-directory"),
                environment: nil,
                io: .replacingProcess,
            )
            Issue.record("Expected working directory failure")
        } catch {
            failures += 1
        }

        #expect(failures == 2)
    }

    @Test
    func `process runner drains large stdout and stderr while process runs`() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            [
                "-c",
                """
                python3 - <<'PY'
                import sys
                sys.stdout.write("o" * 262144)
                sys.stdout.flush()
                sys.stderr.write("e" * 262144)
                sys.stderr.flush()
                PY
                """,
            ],
        )

        #expect(result.succeeded)
        #expect(result.stdout.count == 262_144)
        #expect(result.stderr.count == 262_144)
    }

    @Test
    func `process runner reports nonzero status`() async throws {
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "printf nope >&2; exit 9"])

        #expect(!result.succeeded)
        #expect(result.status == 9)
        #expect(result.stderr == "nope")
    }

    @Test
    func `process runner preserves uncaught signal status`() async throws {
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "kill -TERM $$"])

        #expect(!result.succeeded)
        #expect(result.status == SIGTERM)
    }

    @Test
    func `process runner observes a stopped child before its continued exit`() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            [
                "-c",
                "(sleep 0.05; kill -CONT $$) & kill -STOP $$; printf resumed",
            ],
        )

        #expect(result.succeeded)
        #expect(result.stdout == "resumed")
    }

    @Test
    func `captured process cancellation kills a TERM ignoring child`() async throws {
        try await assertCancellationKillsChild(io: .captured(input: nil))
    }

    @Test
    func `captured process with stdin cancellation kills a TERM ignoring child`() async throws {
        try await assertCancellationKillsChild(io: .captured(input: Data("input".utf8)))
    }

    @Test
    func `captured stdout process cancellation kills a TERM ignoring child`() async throws {
        try await assertCancellationKillsChild(io: .capturedOutputInheritingInputAndError)
    }

    @Test
    func `inherited process cancellation kills a TERM ignoring child`() async throws {
        try await assertCancellationKillsChild(io: .inherited)
    }

    @Test
    func `process runner does not launch an already cancelled task`() async throws {
        for io in [CommandIO.captured(input: Data()), .capturedOutputInheritingInputAndError, .inherited] {
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: marker)
            }

            let task = Task {
                withUnsafeCurrentTask { currentTask in
                    currentTask?.cancel()
                }
                return try await ProcessRunner().run(
                    "/usr/bin/touch",
                    [marker.path],
                    workingDirectory: nil,
                    environment: nil,
                    io: io,
                )
            }

            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }
}

extension ProcessRunnerTests {
    @Test
    func `cancellation racing a completed launch latches group termination`() async {
        let runner = ProcessRunner { cancel in
            cancel()
        }

        await #expect(throws: CancellationError.self) {
            try await runner.run(
                "/bin/sh",
                ["-c", "trap '' TERM; while :; do :; done"],
            )
        }
    }

    @Test(
        arguments: [
            ForegroundConfigurationCase(
                inheritsStandardInput: false,
                standardInputIsTerminal: false,
                currentForegroundProcessGroup: -1,
                currentProcessGroup: 42,
                expectedForeground: false,
                expectedJobControlProcessGroup: nil,
            ),
            ForegroundConfigurationCase(
                inheritsStandardInput: true,
                standardInputIsTerminal: false,
                currentForegroundProcessGroup: -1,
                currentProcessGroup: 42,
                expectedForeground: false,
                expectedJobControlProcessGroup: nil,
            ),
            ForegroundConfigurationCase(
                inheritsStandardInput: true,
                standardInputIsTerminal: true,
                currentForegroundProcessGroup: -1,
                currentProcessGroup: 42,
                expectedForeground: false,
                expectedJobControlProcessGroup: nil,
            ),
            ForegroundConfigurationCase(
                inheritsStandardInput: true,
                standardInputIsTerminal: true,
                currentForegroundProcessGroup: 42,
                currentProcessGroup: 41,
                expectedForeground: false,
                expectedJobControlProcessGroup: 41,
            ),
            ForegroundConfigurationCase(
                inheritsStandardInput: true,
                standardInputIsTerminal: true,
                currentForegroundProcessGroup: 42,
                currentProcessGroup: 42,
                expectedForeground: true,
                expectedJobControlProcessGroup: 42,
            ),
        ],
    )
    func `process foreground selection requires owned inherited terminal input`(_ testCase: ForegroundConfigurationCase) {
        let configuration = processForegroundConfiguration(
            inheritsStandardInput: testCase.inheritsStandardInput,
            standardInputIsTerminal: testCase.standardInputIsTerminal,
            currentForegroundProcessGroup: testCase.currentForegroundProcessGroup,
            currentProcessGroup: testCase.currentProcessGroup,
        )

        #expect(configuration.makeChildForeground == testCase.expectedForeground)
        #expect(configuration.jobControlProcessGroup == testCase.expectedJobControlProcessGroup)
    }

    @Test
    func `foreground resume restores a background launched parent job group`() {
        let configuration = processForegroundConfiguration(
            inheritsStandardInput: true,
            standardInputIsTerminal: true,
            currentForegroundProcessGroup: 42,
            currentProcessGroup: 41,
        )

        #expect(configuration.makeChildForeground == false)
        #expect(configuration.jobControlProcessGroup == 41)
        #expect(terminalForegroundProcessGroupToRestore(
            childProcessGroup: 71,
            parentProcessGroup: configuration.jobControlProcessGroup,
            currentForegroundProcessGroup: 71,
        ) == 41)
    }

    @Test
    func `terminal foreground restoration blocks SIGTTOU and restores the signal mask`() {
        var calls: [String] = []
        let success = terminalForegroundRestorationErrorCode(
            processGroup: 42,
            blockSignal: {
                calls.append("block")
                return 0
            },
            setForegroundProcessGroup: { processGroup in
                calls.append("foreground:\(processGroup)")
                return 0
            },
            restoreSignalMask: {
                calls.append("restore")
                return 0
            },
        )
        #expect(success == 0)
        #expect(calls == ["block", "foreground:42", "restore"])
    }

    @Test
    func `terminal foreground restoration skips absent groups and failed signal blocking`() {
        var calls: [String] = []
        let noGroup = terminalForegroundRestorationErrorCode(
            processGroup: nil,
            blockSignal: {
                calls.append("block")
                return 0
            },
            setForegroundProcessGroup: { _ in
                calls.append("foreground")
                return 0
            },
            restoreSignalMask: {
                calls.append("restore")
                return 0
            },
        )
        #expect(noGroup == 0)
        #expect(calls.isEmpty)

        let blockFailure = terminalForegroundRestorationErrorCode(
            processGroup: 42,
            blockSignal: {
                calls.append("block")
                return EINVAL
            },
            setForegroundProcessGroup: { _ in
                calls.append("foreground")
                return 0
            },
            restoreSignalMask: {
                calls.append("restore")
                return 0
            },
        )
        #expect(blockFailure == EINVAL)
        #expect(calls == ["block"])
    }

    @Test(
        arguments: [
            ForegroundRestorationFailureCase(
                foregroundError: ENOTTY,
                maskRestorationError: EINVAL,
                expectedError: ENOTTY,
            ),
            ForegroundRestorationFailureCase(
                foregroundError: 0,
                maskRestorationError: EINVAL,
                expectedError: EINVAL,
            ),
        ],
    )
    func `terminal foreground restoration returns syscall failures`(_ testCase: ForegroundRestorationFailureCase) {
        var calls: [String] = []
        let error = terminalForegroundRestorationErrorCode(
            processGroup: 42,
            blockSignal: {
                calls.append("block")
                return 0
            },
            setForegroundProcessGroup: { _ in
                calls.append("foreground")
                return testCase.foregroundError
            },
            restoreSignalMask: {
                calls.append("restore")
                return testCase.maskRestorationError
            },
        )
        #expect(error == testCase.expectedError)
        #expect(calls == ["block", "foreground", "restore"])
    }

    @Test
    func `terminal foreground restoration reports terminal descriptor failures`() throws {
        #expect(
            restoreTerminalForegroundProcessGroup(
                nil,
                fileDescriptor: -1,
            ) == nil,
        )

        let error = try #require(
            restoreTerminalForegroundProcessGroup(
                getpgrp(),
                fileDescriptor: -1,
            ) as? POSIXError,
        )
        #expect(error.code == .EBADF)
    }

    @Test
    func `wait status identifies stopped children`() {
        #expect(processStoppedSignal(SIGTSTP << 8 | 0x7F) == SIGTSTP)
        #expect(processStoppedSignal(7 << 8) == nil)
        #expect(processStoppedSignal(SIGTERM) == nil)
    }

    @Test(
        arguments: [
            ForegroundRestorationSelectionCase(
                childProcessGroup: 71,
                parentProcessGroup: 42,
                currentForegroundProcessGroup: 71,
                expectedProcessGroup: 42,
            ),
            ForegroundRestorationSelectionCase(
                childProcessGroup: 71,
                parentProcessGroup: 42,
                currentForegroundProcessGroup: 99,
                expectedProcessGroup: nil,
            ),
            ForegroundRestorationSelectionCase(
                childProcessGroup: nil,
                parentProcessGroup: 42,
                currentForegroundProcessGroup: 71,
                expectedProcessGroup: nil,
            ),
            ForegroundRestorationSelectionCase(
                childProcessGroup: 71,
                parentProcessGroup: nil,
                currentForegroundProcessGroup: 71,
                expectedProcessGroup: nil,
            ),
        ],
    )
    func `terminal restoration requires the child to still own the terminal`(
        _ testCase: ForegroundRestorationSelectionCase,
    ) {
        let processGroup = terminalForegroundProcessGroupToRestore(
            childProcessGroup: testCase.childProcessGroup,
            parentProcessGroup: testCase.parentProcessGroup,
            currentForegroundProcessGroup: testCase.currentForegroundProcessGroup,
        )

        #expect(processGroup == testCase.expectedProcessGroup)
    }

    @Test
    func `foreground child stop suspends and resumes the complete shell job`() {
        var foregroundGroups = [pid_t(71), pid_t(42)]
        var calls: [String] = []
        let error = relayStoppedProcessGroup(
            childProcessGroup: 71,
            parentProcessGroup: 42,
            stopSignal: SIGTSTP,
            actions: ProcessJobControlActions(
                currentForegroundProcessGroup: {
                    foregroundGroups.removeFirst()
                },
                setForegroundProcessGroup: { processGroup in
                    calls.append("foreground:\(processGroup)")
                    return nil
                },
                signalProcessGroup: { processGroup, signal in
                    calls.append("signal:\(processGroup):\(signal)")
                    return 0
                },
            ),
        )

        #expect(error == nil)
        #expect(
            calls == [
                "foreground:42",
                "signal:42:\(SIGTSTP)",
                "foreground:71",
                "signal:71:\(SIGCONT)",
            ],
        )
    }

    @Test
    func `background resume does not steal the shell terminal`() {
        var foregroundGroups = [pid_t(71), pid_t(99)]
        var calls: [String] = []
        let error = relayStoppedProcessGroup(
            childProcessGroup: 71,
            parentProcessGroup: 42,
            stopSignal: SIGTTIN,
            actions: ProcessJobControlActions(
                currentForegroundProcessGroup: {
                    foregroundGroups.removeFirst()
                },
                setForegroundProcessGroup: { processGroup in
                    calls.append("foreground:\(processGroup)")
                    return nil
                },
                signalProcessGroup: { processGroup, signal in
                    calls.append("signal:\(processGroup):\(signal)")
                    return 0
                },
            ),
        )

        #expect(error == nil)
        #expect(
            calls == [
                "foreground:42",
                "signal:42:\(SIGTTIN)",
                "signal:71:\(SIGCONT)",
            ],
        )
    }

    @Test
    func `background child stop leaves terminal ownership unchanged`() {
        var calls: [String] = []
        let error = relayStoppedProcessGroup(
            childProcessGroup: 71,
            parentProcessGroup: 42,
            stopSignal: SIGTTOU,
            actions: ProcessJobControlActions(
                currentForegroundProcessGroup: {
                    99
                },
                setForegroundProcessGroup: { processGroup in
                    calls.append("foreground:\(processGroup)")
                    return nil
                },
                signalProcessGroup: { processGroup, signal in
                    calls.append("signal:\(processGroup):\(signal)")
                    return 0
                },
            ),
        )

        #expect(error == nil)
        #expect(
            calls == [
                "signal:42:\(SIGTTOU)",
                "signal:71:\(SIGCONT)",
            ],
        )
    }

    @Test
    func `child stop relay skips processes without foreground handoff`() {
        var calls = 0
        let error = relayStoppedProcessGroup(
            childProcessGroup: 71,
            parentProcessGroup: nil,
            stopSignal: SIGSTOP,
            actions: ProcessJobControlActions(
                currentForegroundProcessGroup: {
                    calls += 1
                    return 71
                },
                setForegroundProcessGroup: { _ in
                    calls += 1
                    return nil
                },
                signalProcessGroup: { _, _ in
                    calls += 1
                    return 0
                },
            ),
        )

        #expect(error == nil)
        #expect(calls == 0)
    }

    @Test
    func `child stop relay returns foreground and signal failures`() throws {
        let restoreError = relayStoppedProcessGroup(
            childProcessGroup: 71,
            parentProcessGroup: 42,
            stopSignal: SIGTSTP,
            actions: ProcessJobControlActions(
                currentForegroundProcessGroup: {
                    71
                },
                setForegroundProcessGroup: { _ in
                    POSIXError(.ENOTTY)
                },
                signalProcessGroup: { _, _ in
                    Issue.record("Unexpected signal after foreground failure")
                    return 0
                },
            ),
        )
        #expect(try #require(restoreError as? POSIXError).code == .ENOTTY)

        let stopError = relayStoppedProcessGroup(
            childProcessGroup: 71,
            parentProcessGroup: 42,
            stopSignal: SIGTSTP,
            actions: ProcessJobControlActions(
                currentForegroundProcessGroup: {
                    99
                },
                setForegroundProcessGroup: { _ in
                    Issue.record("Unexpected foreground handoff")
                    return nil
                },
                signalProcessGroup: { processGroup, signal in
                    processGroup == 42 && signal == SIGTSTP ? EPERM : 0
                },
            ),
        )
        #expect(try #require(stopError as? POSIXError).code == .EPERM)
    }

    @Test
    func `child stop relay returns resume failures`() throws {
        var foregroundGroups = [pid_t(99), pid_t(42)]
        let childForegroundError = relayStoppedProcessGroup(
            childProcessGroup: 71,
            parentProcessGroup: 42,
            stopSignal: SIGTSTP,
            actions: ProcessJobControlActions(
                currentForegroundProcessGroup: {
                    foregroundGroups.removeFirst()
                },
                setForegroundProcessGroup: { _ in
                    POSIXError(.ENOTTY)
                },
                signalProcessGroup: { _, _ in
                    0
                },
            ),
        )
        #expect(try #require(childForegroundError as? POSIXError).code == .ENOTTY)

        let continueError = relayStoppedProcessGroup(
            childProcessGroup: 71,
            parentProcessGroup: 42,
            stopSignal: SIGTSTP,
            actions: ProcessJobControlActions(
                currentForegroundProcessGroup: {
                    99
                },
                setForegroundProcessGroup: { _ in
                    Issue.record("Unexpected foreground handoff")
                    return nil
                },
                signalProcessGroup: { processGroup, signal in
                    processGroup == 71 && signal == SIGCONT ? ESRCH : 0
                },
            ),
        )
        #expect(try #require(continueError as? POSIXError).code == .ESRCH)
    }
}

extension ProcessRunnerTests {
    @Test
    func `stdin write failure terminates and reaps its child`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let pidFile = directory.appendingPathComponent("child.pid")
        let task = Task {
            _ = try await ProcessRunner().run(
                "/bin/sh",
                [
                    "-c",
                    """
                    printf '%s' "$$" > "$1"
                    exec 0<&-
                    trap '' TERM
                    while :; do :; done
                    """,
                    "process-runner-stdin-failure",
                    pidFile.path,
                ],
                input: Data(repeating: 0x61, count: 1_048_576),
            )
        }
        let processIdentifier = try await waitForProcessIdentifier(at: pidFile)

        await #expect(throws: (any Error).self) {
            try await task.value
        }
        errno = 0
        #expect(kill(processIdentifier, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func `recording runner response storage remains synchronized`() async throws {
        let runner = RecordingRunner()
        let response = CommandResult(status: 7, stdout: "out", stderr: "err")

        runner.responses = [response]
        #expect(runner.responses == [response])
        #expect(try await runner.run("/usr/bin/false", []) == response)
        #expect(runner.responses.isEmpty)
    }
}

extension ProcessRunnerTests {
    @Test
    func `normalizer cancellation terminates its Docker Compose YAML child`() async throws {
        let composeFile = try #require(
            Bundle.module.url(
                forResource: "docker-compose",
                withExtension: "yml",
            ),
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let pidFile = directory.appendingPathComponent("normalizer.pid")
        let childPIDFile = directory.appendingPathComponent("normalizer-child.pid")
        let launcher = directory.appendingPathComponent("normalizer")
        try """
        #!/bin/sh
        printf '%s' "$$" > "\(pidFile.path)"
        /bin/sh -c 'printf "%s" "$$" > "$1"; trap "" TERM; while :; do :; done' \
          normalizer-child "\(childPIDFile.path)" &
        trap '' TERM
        wait
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let task = Task {
            _ = try await ComposeNormalizer(fallbackLauncher: launcher.path).normalize(
                options: ComposeOptions(files: [composeFile.path]),
            )
        }
        let processIdentifier = try await waitForProcessIdentifier(at: pidFile)
        let childProcessIdentifier = try await waitForProcessIdentifier(at: childPIDFile)
        #expect(getpgid(processIdentifier) == processIdentifier)
        #expect(getpgid(childProcessIdentifier) == processIdentifier)
        let clock = ContinuousClock()
        let cancellationStarted = clock.now
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(clock.now - cancellationStarted < .seconds(2))
        expectProcessDoesNotExist(processIdentifier)
        expectProcessDoesNotExist(childProcessIdentifier)
    }
}

/// Proves cancellation waits for bounded child termination in one I/O mode.
private func assertCancellationKillsChild(io: CommandIO) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let pidFile = directory.appendingPathComponent("child.pid")
    let descendantPIDFile = directory.appendingPathComponent("descendant.pid")
    let task = Task {
        try await ProcessRunner().run(
            "/bin/sh",
            [
                "-c",
                """
                printf '%s' "$$" > "$1"
                /bin/sh -c 'printf "%s" "$$" > "$1"; trap "" TERM; while :; do :; done' \
                  process-runner-descendant "$2" &
                trap '' TERM
                wait
                """,
                "process-runner-cancellation",
                pidFile.path,
                descendantPIDFile.path,
            ],
            workingDirectory: nil,
            environment: nil,
            io: io,
        )
    }
    let processIdentifier = try await waitForProcessIdentifier(at: pidFile)
    let descendantProcessIdentifier = try await waitForProcessIdentifier(at: descendantPIDFile)
    #expect(getpgid(processIdentifier) == processIdentifier)
    #expect(getpgid(descendantProcessIdentifier) == processIdentifier)
    let clock = ContinuousClock()
    let cancellationStarted = clock.now
    task.cancel()
    task.cancel()

    var observedCancellation = false
    do {
        _ = try await task.value
        Issue.record("Expected cancellation for \(io)")
    } catch is CancellationError {
        observedCancellation = true
    } catch {
        Issue.record("Expected CancellationError for \(io), received \(error)")
    }

    #expect(observedCancellation)
    #expect(clock.now - cancellationStarted < .seconds(2))
    expectProcessDoesNotExist(processIdentifier)
    expectProcessDoesNotExist(descendantProcessIdentifier)
}

/// Requires a previously owned PID to be absent after command completion.
private func expectProcessDoesNotExist(_ processIdentifier: pid_t) {
    errno = 0
    let processProbe = kill(processIdentifier, 0)
    #expect(processProbe == -1)
    #expect(errno == ESRCH)
}

/// Waits for the child to publish its PID before cancellation.
private func waitForProcessIdentifier(at pidFile: URL) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(3)
    while clock.now < deadline {
        if
            let data = FileManager.default.contents(atPath: pidFile.path),
            let value = String(data: data, encoding: .utf8),
            let processIdentifier = pid_t(value)
        {
            return processIdentifier
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ProcessRunnerTestError.pidFileTimedOut
}

private enum ProcessRunnerTestError: Error {
    case pidFileTimedOut
}
