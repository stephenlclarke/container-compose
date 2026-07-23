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

extension ComposeArgumentRewriterTests {
    @Test
    func `moves root compose options after alpha nested commands`() {
        let scale = ComposeArgumentRewriter.rewrite([
            "-f",
            "compose.yml",
            "--project-name",
            "demo",
            "alpha",
            "scale",
            "--no-deps",
            "api=2",
        ])
        let dryRun = ComposeArgumentRewriter.rewrite([
            "--ansi",
            "never",
            "alpha",
            "dry-run",
            "--",
            "up",
            "api",
        ])

        #expect(scale == [
            "alpha",
            "scale",
            "-f",
            "compose.yml",
            "--project-name",
            "demo",
            "--no-deps",
            "api=2",
        ])
        #expect(dryRun == [
            "alpha",
            "dry-run",
            "--ansi",
            "never",
            "--",
            "up",
            "api",
        ])
    }

    @Test
    func `moves bridge globals to convert`() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-f",
            "compose.yml",
            "--project-name",
            "demo",
            "--dry-run",
            "bridge",
            "convert",
            "--output",
            "out",
        ])

        #expect(rewritten == [
            "bridge",
            "convert",
            "-f",
            "compose.yml",
            "--project-name",
            "demo",
            "--dry-run",
            "--output",
            "out",
        ])
    }

    @Test
    func `moves bridge globals to transformation create`() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-f",
            "compose.yml",
            "--dry-run",
            "bridge",
            "transformations",
            "create",
            "-f",
            "example/transformer:latest",
            "custom",
        ])

        #expect(rewritten == [
            "-f",
            "compose.yml",
            "bridge",
            "transformations",
            "create",
            "--dry-run",
            "--from",
            "example/transformer:latest",
            "custom",
        ])
    }

    @Test
    func `moves bridge globals to transformation list`() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "bridge",
            "--dry-run",
            "transformations",
            "list",
            "--format",
            "json",
        ])

        #expect(rewritten == [
            "bridge",
            "transformations",
            "list",
            "--dry-run",
            "--format",
            "json",
        ])
    }

    @Test
    func `normalizes commit shorthand and optional pause boolean`() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--file",
            "compose.yml",
            "commit",
            "-a=Me",
            "-c=ENV FEATURE=on",
            "-m=snapshot",
            "-p=false",
            "api",
            "example/api:snapshot",
        ])

        #expect(rewritten == [
            "commit",
            "--file",
            "compose.yml",
            "--author",
            "Me",
            "--change",
            "ENV FEATURE=on",
            "--message",
            "snapshot",
            "--no-pause",
            "api",
            "example/api:snapshot",
        ])
    }

    @Test
    func `preserves commit arguments after terminator`() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "commit",
            "--",
            "-p=false",
            "-a=Me",
        ])

        #expect(rewritten == [
            "commit",
            "--",
            "-p=false",
            "-a=Me",
        ])
    }

    @Test
    func `returns arguments unchanged when no subcommand is present`() {
        let arguments = ["--help", "--verbose"]

        #expect(ComposeArgumentRewriter.rewrite(arguments) == arguments)
    }

    @Test
    func `keeps root compose options before version`() {
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

    @Test
    func `normalizes compact root compose options before version`() {
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

    @Test
    func `keeps version format shorthand local to version`() {
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

    @Test
    func `normalizes version compact format shorthand after version`() {
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

    @Test
    func `recognizes explicit compose command surfaces`() {
        let commands = [
            "alpha",
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
}
