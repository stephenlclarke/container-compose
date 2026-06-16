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
    @Test("process runner captures stdout stderr status input env and cwd")
    func processRunnerCapturesProcessDetails() async throws {
        let directory = FileManager.default.temporaryDirectory
        let script = "printf \"%s:%s\" \"$PROCESS_RUNNER_VALUE\" \"$(pwd)\"; cat; printf err >&2"
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", script],
            workingDirectory: directory,
            environment: ["PROCESS_RUNNER_VALUE": "ok"],
            input: Data(" input".utf8)
        )

        #expect(result.succeeded)
        #expect(
            result.stdout == "ok:\(directory.path) input"
                || result.stdout == "ok:/private\(directory.path) input"
        )
        #expect(result.stderr == "err")
    }

    @Test("recording runner captures command environment")
    func recordingRunnerCapturesCommandEnvironment() async throws {
        let runner = RecordingRunner()

        _ = try await runner.run("/usr/bin/env", ["true"], environment: ["SAMPLE": "value"])

        let command = try #require(runner.commands.first)
        #expect(command.environment == ["SAMPLE": "value"])
    }

    @Test("recording runner captures command input")
    func recordingRunnerCapturesCommandInput() async throws {
        let runner = RecordingRunner()
        let input = Data("payload".utf8)

        _ = try await runner.run("/usr/bin/env", ["true"], input: input)

        let command = try #require(runner.commands.first)
        #expect(command.input == input)
    }

    @Test("process runner reports status when inheriting terminal IO")
    func processRunnerReportsStatusWhenInheritingTerminalIO() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", "exit 7"],
            workingDirectory: nil,
            environment: nil,
            io: .inherited
        )

        #expect(result.status == 7)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test("process runner drains large stdout and stderr while process runs")
    func processRunnerDrainsLargeOutputWhileProcessRuns() async throws {
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
            ]
        )

        #expect(result.succeeded)
        #expect(result.stdout.count == 262_144)
        #expect(result.stderr.count == 262_144)
    }

    @Test("process runner reports nonzero status")
    func processRunnerReportsNonzeroStatus() async throws {
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "printf nope >&2; exit 9"])

        #expect(!result.succeeded)
        #expect(result.status == 9)
        #expect(result.stderr == "nope")
    }
}
