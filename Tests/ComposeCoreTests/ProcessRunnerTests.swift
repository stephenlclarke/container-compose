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

@Suite("Process runner")
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
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", "printf json"],
            workingDirectory: nil,
            environment: nil,
            io: .capturedOutputInheritingInputAndError,
        )

        #expect(result.succeeded)
        #expect(result.stdout == "json")
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
        var failures = 0

        do {
            _ = try await ProcessRunner().run(
                missingExecutable,
                [],
                workingDirectory: nil,
                environment: nil,
                io: .replacingProcess,
            )
            Issue.record("Expected exec failure")
        } catch {
            failures += 1
        }

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
}
