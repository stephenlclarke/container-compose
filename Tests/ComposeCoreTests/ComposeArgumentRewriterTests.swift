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
import Testing

@Suite("Compose argument rewriter")
struct ComposeArgumentRewriterTests {
    @Test("moves root compose options after the subcommand")
    func movesRootComposeOptionsAfterSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-f",
            "compose.yml",
            "--project-name",
            "demo",
            "--profile=dev",
            "--dry-run",
            "config",
        ])

        #expect(rewritten == [
            "config",
            "-f",
            "compose.yml",
            "--project-name",
            "demo",
            "--profile=dev",
            "--dry-run",
        ])
    }

    @Test("leaves subcommand options and arguments in place")
    func leavesSubcommandOptionsAndArgumentsInPlace() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--ansi",
            "never",
            "up",
            "--detach",
            "api",
        ])

        #expect(rewritten == [
            "up",
            "--ansi",
            "never",
            "--detach",
            "api",
        ])
    }

    @Test("normalizes logs follow shorthand after subcommand")
    func normalizesLogsFollowShorthandAfterSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--file",
            "compose.yml",
            "logs",
            "-f",
            "api",
        ])

        #expect(rewritten == [
            "logs",
            "--file",
            "compose.yml",
            "--follow",
            "api",
        ])
    }

    @Test("does not rewrite logs follow shorthand after terminator")
    func doesNotRewriteLogsFollowShorthandAfterTerminator() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "logs",
            "--",
            "-f",
        ])

        #expect(rewritten == [
            "logs",
            "--",
            "-f",
        ])
    }

    @Test("keeps unknown root options before the subcommand")
    func keepsUnknownRootOptionsBeforeSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--not-a-compose-option",
            "--file",
            "compose.yml",
            "config",
        ])

        #expect(rewritten == [
            "--not-a-compose-option",
            "config",
            "--file",
            "compose.yml",
        ])
    }

    @Test("keeps short v available to subcommands")
    func keepsShortVAvailableToSubcommands() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-v",
            "--verbose",
            "down",
            "-v",
        ])

        #expect(rewritten == [
            "-v",
            "down",
            "--verbose",
            "-v",
        ])
    }

    @Test("moves root compose options for version")
    func movesRootComposeOptionsForVersion() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--ansi",
            "never",
            "--dry-run",
            "version",
        ])

        #expect(rewritten == [
            "version",
            "--ansi",
            "never",
            "--dry-run",
        ])
    }

    @Test("returns arguments unchanged when no subcommand is present")
    func returnsArgumentsUnchangedWhenNoSubcommandIsPresent() {
        let arguments = ["--help", "--verbose"]

        #expect(ComposeArgumentRewriter.rewrite(arguments) == arguments)
    }
}
