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

    @Test("normalizes compact root compose options after the subcommand")
    func normalizesCompactRootComposeOptionsAfterSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-f=compose.yml",
            "-p=demo",
            "--dry-run",
            "config",
        ])

        #expect(rewritten == [
            "config",
            "--file",
            "compose.yml",
            "--project-name",
            "demo",
            "--dry-run",
        ])
    }

    @Test("skips compact root option values when locating the subcommand")
    func skipsCompactRootOptionValuesWhenLocatingSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-fup.yml",
            "-plogs",
            "ps",
        ])

        #expect(rewritten == [
            "ps",
            "--file",
            "up.yml",
            "--project-name",
            "logs",
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

    @Test("recognizes ls as a compose subcommand")
    func recognizesLsAsComposeSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--dry-run",
            "ls",
            "--format",
            "json",
        ])

        #expect(rewritten == [
            "ls",
            "--dry-run",
            "--format",
            "json",
        ])
    }

    @Test("recognizes create as a compose subcommand")
    func recognizesCreateAsComposeSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--file",
            "compose.yml",
            "create",
            "--build",
            "api",
        ])

        #expect(rewritten == [
            "create",
            "--file",
            "compose.yml",
            "--build",
            "api",
        ])
    }

    @Test("recognizes stats as a compose subcommand")
    func recognizesStatsAsComposeSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--project-name",
            "demo",
            "stats",
            "--no-stream",
            "api",
        ])

        #expect(rewritten == [
            "stats",
            "--project-name",
            "demo",
            "--no-stream",
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

    @Test("normalizes logs compact tail shorthand after subcommand")
    func normalizesLogsCompactTailShorthandAfterSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "logs",
            "-n5",
            "-n=all",
            "api",
        ])

        #expect(rewritten == [
            "logs",
            "--tail",
            "5",
            "--tail",
            "all",
            "api",
        ])
    }

    @Test("preserves logs display flags after subcommand")
    func preservesLogsDisplayFlagsAfterSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--project-name",
            "demo",
            "logs",
            "--no-color",
            "--no-log-prefix",
            "api",
        ])

        #expect(rewritten == [
            "logs",
            "--project-name",
            "demo",
            "--no-color",
            "--no-log-prefix",
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

    @Test("does not rewrite logs compact tail shorthand after terminator")
    func doesNotRewriteLogsCompactTailShorthandAfterTerminator() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "logs",
            "--",
            "-n5",
        ])

        #expect(rewritten == [
            "logs",
            "--",
            "-n5",
        ])
    }

    @Test("normalizes rm force shorthand after subcommand")
    func normalizesRmForceShorthandAfterSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--file",
            "compose.yml",
            "rm",
            "-f",
            "api",
        ])

        #expect(rewritten == [
            "rm",
            "--file",
            "compose.yml",
            "--force",
            "api",
        ])
    }

    @Test("normalizes grouped rm shorthand flags")
    func normalizesGroupedRmShorthandFlags() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "rm",
            "-sfv",
            "api",
        ])

        #expect(rewritten == [
            "rm",
            "-s",
            "--force",
            "-v",
            "api",
        ])
    }

    @Test("does not rewrite rm force shorthand after terminator")
    func doesNotRewriteRmForceShorthandAfterTerminator() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "rm",
            "--",
            "-f",
        ])

        #expect(rewritten == [
            "rm",
            "--",
            "-f",
        ])
    }

    @Test("normalizes lifecycle compact timeout shorthands")
    func normalizesLifecycleCompactTimeoutShorthands() {
        let down = ComposeArgumentRewriter.rewrite([
            "down",
            "-t11",
        ])
        let stop = ComposeArgumentRewriter.rewrite([
            "stop",
            "-t12",
            "api",
        ])
        let restart = ComposeArgumentRewriter.rewrite([
            "restart",
            "-t=13",
            "api",
        ])
        let up = ComposeArgumentRewriter.rewrite([
            "up",
            "-t14",
            "api",
        ])

        #expect(down == [
            "down",
            "--timeout",
            "11",
        ])
        #expect(stop == [
            "stop",
            "--timeout",
            "12",
            "api",
        ])
        #expect(restart == [
            "restart",
            "--timeout",
            "13",
            "api",
        ])
        #expect(up == [
            "up",
            "--timeout",
            "14",
            "api",
        ])
    }

    @Test("normalizes up menu boolean value forms")
    func normalizesUpMenuBooleanValueForms() {
        let disabled = ComposeArgumentRewriter.rewrite([
            "up",
            "--menu=false",
            "--menu=0",
            "--menu=no",
            "api",
        ])
        let enabled = ComposeArgumentRewriter.rewrite([
            "up",
            "--menu=true",
            "--menu=1",
            "--menu=yes",
            "api",
        ])

        #expect(disabled == [
            "up",
            "--menu-disabled",
            "--menu-disabled",
            "--menu-disabled",
            "api",
        ])
        #expect(enabled == [
            "up",
            "--menu",
            "--menu",
            "--menu",
            "api",
        ])
    }

    @Test("does not rewrite up menu value forms after terminator")
    func doesNotRewriteUpMenuValueFormsAfterTerminator() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "up",
            "--",
            "--menu=false",
        ])

        #expect(rewritten == [
            "up",
            "--",
            "--menu=false",
        ])
    }

    @Test("normalizes kill compact signal shorthand")
    func normalizesKillCompactSignalShorthand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "kill",
            "-sSIGKILL",
            "api",
        ])

        #expect(rewritten == [
            "kill",
            "--signal",
            "SIGKILL",
            "api",
        ])
    }

    @Test("does not rewrite compact command values after terminator")
    func doesNotRewriteCompactCommandValuesAfterTerminator() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "kill",
            "--",
            "-sSIGKILL",
        ])

        #expect(rewritten == [
            "kill",
            "--",
            "-sSIGKILL",
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

    @Test("normalizes exec compact value shorthands before parsing")
    func normalizesExecCompactValueShorthandsBeforeParsing() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "exec",
            "-eFOO=bar",
            "-u1000:1000",
            "-w/app",
            "api",
            "env",
        ])

        #expect(rewritten == [
            "exec",
            "--env",
            "FOO=bar",
            "--user",
            "1000:1000",
            "--workdir",
            "/app",
            "api",
            "env",
        ])
    }

    @Test("normalizes exec compact values after separated option values")
    func normalizesExecCompactValuesAfterSeparatedOptionValues() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "exec",
            "-e",
            "FOO=bar",
            "-u1000:1000",
            "--index",
            "1",
            "-w/app",
            "api",
            "env",
        ])

        #expect(rewritten == [
            "exec",
            "-e",
            "FOO=bar",
            "--user",
            "1000:1000",
            "--index",
            "1",
            "--workdir",
            "/app",
            "api",
            "env",
        ])
    }

    @Test("does not rewrite exec compact values after service name")
    func doesNotRewriteExecCompactValuesAfterServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "exec",
            "api",
            "echo",
            "-u1000",
            "--interactive=false",
        ])

        #expect(rewritten == [
            "exec",
            "api",
            "echo",
            "-u1000",
            "--interactive=false",
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

    @Test("normalizes run compact publish shorthand before service name")
    func normalizesRunCompactPublishShorthandBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "-p8080:80",
            "-p=9090:90",
            "api",
            "echo",
            "ok",
        ])

        #expect(rewritten == [
            "run",
            "--publish",
            "8080:80",
            "--publish",
            "9090:90",
            "api",
            "echo",
            "ok",
        ])
    }

    @Test("normalizes run compact value shorthands before service name")
    func normalizesRunCompactValueShorthandsBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "-eLOG_LEVEL=debug",
            "-lcom.example.role=job",
            "-u1000:1000",
            "-v./host:/container:ro",
            "-w/workspace",
            "api",
            "env",
        ])

        #expect(rewritten == [
            "run",
            "--env",
            "LOG_LEVEL=debug",
            "--label",
            "com.example.role=job",
            "--user",
            "1000:1000",
            "--volume",
            "./host:/container:ro",
            "--workdir",
            "/workspace",
            "api",
            "env",
        ])
    }

    @Test("normalizes run compact equals value shorthands before service name")
    func normalizesRunCompactEqualsValueShorthandsBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "-e=LOG_LEVEL=debug",
            "-l=com.example.role=job",
            "-u=1000:1000",
            "-v=./host:/container:ro",
            "-w=/workspace",
            "api",
            "env",
        ])

        #expect(rewritten == [
            "run",
            "--env",
            "LOG_LEVEL=debug",
            "--label",
            "com.example.role=job",
            "--user",
            "1000:1000",
            "--volume",
            "./host:/container:ro",
            "--workdir",
            "/workspace",
            "api",
            "env",
        ])
    }

    @Test("keeps run no-deps before service name")
    func keepsRunNoDepsBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--project-name",
            "demo",
            "run",
            "--no-deps",
            "api",
            "echo",
            "ok",
        ])

        #expect(rewritten == [
            "run",
            "--project-name",
            "demo",
            "--no-deps",
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

    @Test("does not rewrite run compact value shorthands after service name")
    func doesNotRewriteRunCompactValueShorthandsAfterServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "api",
            "echo",
            "-eLOG_LEVEL=debug",
            "-v./host:/container:ro",
        ])

        #expect(rewritten == [
            "run",
            "api",
            "echo",
            "-eLOG_LEVEL=debug",
            "-v./host:/container:ro",
        ])
    }

    @Test("does not rewrite run compact value shorthands after terminator")
    func doesNotRewriteRunCompactValueShorthandsAfterTerminator() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "--",
            "-eLOG_LEVEL=debug",
            "-v./host:/container:ro",
        ])

        #expect(rewritten == [
            "run",
            "--",
            "-eLOG_LEVEL=debug",
            "-v./host:/container:ro",
        ])
    }

    @Test("keeps run flags before service name while preserving command arguments")
    func keepsRunFlagsBeforeServiceNameWhilePreservingCommandArguments() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "-d",
            "-T",
            "--rm",
            "--service-ports",
            "api",
            "echo",
            "--rm",
        ])

        #expect(rewritten == [
            "run",
            "-d",
            "-T",
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

    @Test("keeps run env shorthand value before service name")
    func keepsRunEnvShorthandValueBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "-e",
            "LOG_LEVEL=debug",
            "--env-from-file",
            ".env.local",
            "api",
            "env",
        ])

        #expect(rewritten == [
            "run",
            "-e",
            "LOG_LEVEL=debug",
            "--env-from-file",
            ".env.local",
            "api",
            "env",
        ])
    }

    @Test("keeps run label shorthand value before service name")
    func keepsRunLabelShorthandValueBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "-l",
            "com.example.role=job",
            "api",
            "true",
        ])

        #expect(rewritten == [
            "run",
            "-l",
            "com.example.role=job",
            "api",
            "true",
        ])
    }

    @Test("keeps run pull policy before service name")
    func keepsRunPullPolicyBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "--pull",
            "missing",
            "api",
            "true",
        ])

        #expect(rewritten == [
            "run",
            "--pull",
            "missing",
            "api",
            "true",
        ])
    }

    @Test("keeps run volume shorthand value before service name")
    func keepsRunVolumeShorthandValueBeforeServiceName() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "run",
            "-v",
            "/host:/container:ro",
            "api",
            "ls",
        ])

        #expect(rewritten == [
            "run",
            "-v",
            "/host:/container:ro",
            "api",
            "ls",
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

    @Test("keeps root compose options before version")
    func keepsRootComposeOptionsBeforeVersion() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--ansi",
            "never",
            "--dry-run",
            "version",
        ])

        #expect(rewritten == [
            "--ansi",
            "never",
            "--dry-run",
            "version",
        ])
    }

    @Test("normalizes compact root compose options before version")
    func normalizesCompactRootComposeOptionsBeforeVersion() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-pcompact",
            "-f=compose.yml",
            "--dry-run",
            "version",
            "--short",
        ])

        #expect(rewritten == [
            "--project-name",
            "compact",
            "--file",
            "compose.yml",
            "--dry-run",
            "version",
            "--short",
        ])
    }

    @Test("keeps version format shorthand local to version")
    func keepsVersionFormatShorthandLocalToVersion() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-f",
            "compose.yml",
            "version",
            "-f",
            "json",
        ])

        #expect(rewritten == [
            "-f",
            "compose.yml",
            "version",
            "-f",
            "json",
        ])
    }

    @Test("normalizes version compact format shorthand after version")
    func normalizesVersionCompactFormatShorthandAfterVersion() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-fcompose.yml",
            "version",
            "-fjson",
        ])

        #expect(rewritten == [
            "--file",
            "compose.yml",
            "version",
            "--format",
            "json",
        ])
    }

    @Test("recognizes explicit compose command surfaces")
    func recognizesExplicitComposeCommandSurfaces() {
        let commands = [
            "attach",
            "bridge",
            "commit",
            "export",
            "publish",
            "scale",
            "volumes",
            "watch",
        ]

        for command in commands {
            let rewritten = ComposeArgumentRewriter.rewrite([
                "--ansi",
                "never",
                command,
            ])

            #expect(rewritten == [
                command,
                "--ansi",
                "never",
            ])
        }
    }

    @Test("returns arguments unchanged when no subcommand is present")
    func returnsArgumentsUnchangedWhenNoSubcommandIsPresent() {
        let arguments = ["--help", "--verbose"]

        #expect(ComposeArgumentRewriter.rewrite(arguments) == arguments)
    }
}
