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

    @Test("normalizes exec boolean value forms before parsing")
    func normalizesExecBooleanValueFormsBeforeParsing() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "exec",
            "--interactive=false",
            "--tty=false",
            "api",
            "echo",
            "ok",
        ])

        #expect(rewritten == [
            "exec",
            "--no-interactive",
            "--no-tty",
            "api",
            "echo",
            "ok",
        ])
    }

    @Test("does not rewrite exec boolean value forms after terminator")
    func doesNotRewriteExecBooleanValueFormsAfterTerminator() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "exec",
            "api",
            "--",
            "--interactive=false",
        ])

        #expect(rewritten == [
            "exec",
            "api",
            "--",
            "--interactive=false",
        ])
    }

    @Test("normalizes run publish shorthand before service name")
    func normalizesRunPublishShorthandBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--project-name",
            "demo",
            "run",
            "--publish",
            "8080:80",
            "-p",
            "9090:90",
            "api",
            "echo",
            "ok",
        ])

        #expect(rewritten == [
            "run",
            "--project-name",
            "demo",
            "--publish",
            "8080:80",
            "--publish",
            "9090:90",
            "api",
            "echo",
            "ok",
        ])
    }

    @Test("does not rewrite run publish shorthand after service name")
    func doesNotRewriteRunPublishShorthandAfterServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "api",
            "echo",
            "-p",
        ])

        #expect(rewritten == [
            "run",
            "api",
            "echo",
            "-p",
        ])
    }

    @Test("keeps run flags before service name while preserving command arguments")
    func keepsRunFlagsBeforeServiceNameWhilePreservingCommandArguments() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "--rm",
            "--service-ports",
            "api",
            "echo",
            "--rm",
        ])

        #expect(rewritten == [
            "run",
            "--rm",
            "--service-ports",
            "api",
            "echo",
            "--rm",
        ])
    }

    @Test("keeps run name value before service name")
    func keepsRunNameValueBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "--name",
            "one-off-api",
            "-p",
            "9090:90",
            "api",
            "echo",
            "ok",
        ])

        #expect(rewritten == [
            "run",
            "--name",
            "one-off-api",
            "--publish",
            "9090:90",
            "api",
            "echo",
            "ok",
        ])
    }

    @Test("keeps run entrypoint value before service name")
    func keepsRunEntrypointValueBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "--entrypoint",
            "/bin/sh -c",
            "api",
            "echo",
            "ok",
        ])

        #expect(rewritten == [
            "run",
            "--entrypoint",
            "/bin/sh -c",
            "api",
            "echo",
            "ok",
        ])
    }

    @Test("keeps run workdir shorthand value before service name")
    func keepsRunWorkdirShorthandValueBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "-w",
            "/workspace",
            "api",
            "pwd",
        ])

        #expect(rewritten == [
            "run",
            "-w",
            "/workspace",
            "api",
            "pwd",
        ])
    }

    @Test("keeps run user shorthand value before service name")
    func keepsRunUserShorthandValueBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "-u",
            "1000:1000",
            "api",
            "id",
        ])

        #expect(rewritten == [
            "run",
            "-u",
            "1000:1000",
            "api",
            "id",
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

    @Test("skips global option values when locating the subcommand")
    func skipsGlobalOptionValuesWhenLocatingSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-f",
            "up",
            "--project-name",
            "logs",
            "--env-file",
            "down",
            "config",
        ])

        #expect(rewritten == [
            "config",
            "-f",
            "up",
            "--project-name",
            "logs",
            "--env-file",
            "down",
        ])
    }

    @Test("skips equals-form global option values when locating the subcommand")
    func skipsEqualsFormGlobalOptionValuesWhenLocatingSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--file=up",
            "--project-name=logs",
            "ps",
        ])

        #expect(rewritten == [
            "ps",
            "--file=up",
            "--project-name=logs",
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
