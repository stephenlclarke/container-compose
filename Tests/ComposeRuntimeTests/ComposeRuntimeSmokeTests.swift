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
import Foundation
import Testing

@Suite("Compose runtime smoke tests")
struct ComposeRuntimeSmokeTests {
    @Test("runtime run build emits progress before build output")
    func runtimeRunBuildEmitsProgressBeforeBuildOutput() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let dockerfile = directory.appendingPathComponent("Dockerfile")
        try """
        FROM alpine:3.20
        """.write(to: dockerfile, atomically: true, encoding: .utf8)

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          shell:
            build:
              context: .
              dockerfile: Dockerfile
            pull_policy: build
            command: ["echo", "runtime-progress-ok"]
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let containerBinary = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container"
        _ = try runProcess(containerBinary, ["system", "status"], timeout: 15)
        defer {
            _ = try? runProcess(
                composeBinary,
                [
                    "--ansi", "never",
                    "--project-name", project,
                    "--file", composeFile.path,
                    "down", "--volumes", "--remove-orphans",
                ],
                timeout: 60
            )
        }

        let result = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--progress", "plain",
                "--project-name", project,
                "--file", composeFile.path,
                "run", "--rm", "--no-TTY", "shell",
            ],
            timeout: 240,
            mergeOutputForOrdering: true
        )

        let output = result.combined
        #expect(output.contains("runtime-progress-ok"))
        #expect(output.contains("Loading Compose model"))
        #expect(output.contains("Building shell"))

        try assert(
            "Loading Compose model",
            appearsBefore: "Building shell",
            in: output,
            diagnostic: "Compose model progress should be visible before build progress starts."
        )
        try assert(
            "Building shell",
            appearsBefore: "#1 ",
            in: output,
            diagnostic: "Build progress should be visible before container build output starts."
        )
    }

    @Test("runtime up handles entrypoint plus command")
    func runtimeUpHandlesEntrypointPlusCommand() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          entrypoint-command:
            image: alpine:3.20
            entrypoint: ["/bin/sh", "-c"]
            command: ["printf entrypoint-command-ok"]
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let containerBinary = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container"
        _ = try runProcess(containerBinary, ["system", "status"], timeout: 15)
        defer {
            _ = try? runProcess(
                composeBinary,
                [
                    "--ansi", "never",
                    "--project-name", project,
                    "--file", composeFile.path,
                    "down", "--volumes", "--remove-orphans",
                ],
                timeout: 60
            )
        }

        _ = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "up", "--detach", "entrypoint-command",
            ],
            timeout: 180
        )

        var lastLogs = ""
        for _ in 0..<20 {
            let logs = try runProcess(
                composeBinary,
                [
                    "--ansi", "never",
                    "--project-name", project,
                    "--file", composeFile.path,
                    "logs", "entrypoint-command",
                ],
                timeout: 30
            )
            lastLogs = logs.stdout + logs.stderr
            if lastLogs.contains("entrypoint-command-ok") {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }

        Issue.record("Expected entrypoint-command output in runtime logs. Last logs: \(lastLogs)")
    }
}

private var runtimeTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_RUN_RUNTIME_TESTS"] == "1"
}

private func runtimeProjectName() -> String {
    "ccrt-\(UUID().uuidString.prefix(8).lowercased())"
}

private struct RuntimeProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var combined: String
}

private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else {
            return
        }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

@discardableResult
private func runProcess(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval,
    mergeOutputForOrdering: Bool = false
) throws -> RuntimeProcessResult {
    let process = Process()
    let command = [executable] + arguments
    if executable.contains("/") {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
    }

    let stdout = Pipe()
    let stderr = mergeOutputForOrdering ? stdout : Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let stdoutBuffer = OutputAccumulator()
    let stderrBuffer = OutputAccumulator()
    let combinedBuffer = OutputAccumulator()
    stdout.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        stdoutBuffer.append(data)
        combinedBuffer.append(data)
    }
    if !mergeOutputForOrdering {
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            stderrBuffer.append(data)
            combinedBuffer.append(data)
        }
    }
    defer {
        stdout.fileHandleForReading.readabilityHandler = nil
        if !mergeOutputForOrdering {
            stderr.fileHandleForReading.readabilityHandler = nil
        }
    }

    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        let stderrOutput = stderrBuffer.string()
        let stdoutOutput = stdoutBuffer.string()
        let combinedOutput = combinedBuffer.string()
        let diagnostic = [
            stderrOutput.isEmpty ? nil : "stderr:\n\(stderrOutput)",
            stdoutOutput.isEmpty ? nil : "stdout:\n\(stdoutOutput)",
            combinedOutput.isEmpty ? nil : "combined:\n\(combinedOutput)",
        ].compactMap { $0 }.joined(separator: "\n")
        throw ComposeError.commandFailed(
            command: command.joined(separator: " "),
            status: process.terminationStatus,
            stderr: "timed out after \(Int(timeout))s\(diagnostic.isEmpty ? "" : "\n\(diagnostic)")"
        )
    }

    process.waitUntilExit()
    let stdoutRemainder = stdout.fileHandleForReading.readDataToEndOfFile()
    stdoutBuffer.append(stdoutRemainder)
    combinedBuffer.append(stdoutRemainder)
    if !mergeOutputForOrdering {
        let stderrRemainder = stderr.fileHandleForReading.readDataToEndOfFile()
        stderrBuffer.append(stderrRemainder)
        combinedBuffer.append(stderrRemainder)
    }
    let result = RuntimeProcessResult(
        status: process.terminationStatus,
        stdout: stdoutBuffer.string(),
        stderr: stderrBuffer.string(),
        combined: combinedBuffer.string()
    )
    guard result.status == 0 else {
        throw ComposeError.commandFailed(
            command: command.joined(separator: " "),
            status: result.status,
            stderr: result.stderr
        )
    }
    return result
}

private func assert(
    _ earlier: String,
    appearsBefore later: String,
    in output: String,
    diagnostic: String
) throws {
    guard let earlierRange = output.range(of: earlier) else {
        Issue.record("Expected output to contain '\(earlier)'. Output:\n\(output)")
        return
    }
    guard let laterRange = output.range(of: later) else {
        Issue.record("Expected output to contain '\(later)'. Output:\n\(output)")
        return
    }
    #expect(earlierRange.lowerBound < laterRange.lowerBound, "\(diagnostic)\nOutput:\n\(output)")
}
