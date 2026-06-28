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

import ArgumentParser
import ComposeCore
@testable import ComposePlugin
import Testing

@Suite("Compose CLI help")
struct ComposeCLIHelpTests {
    @Test("root help rendered for missing subcommand includes support colours")
    func rootHelpRenderedForMissingSubcommandIncludesSupportColours() {
        let help = ComposeCLIHelp.rootHelpText(arguments: ["--file", "Dockerfile"])

        #expect(help.contains("Support:"))
        #expect(help.contains("\u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[38;5;208mpartially supported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[31mnot supported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[38;5;208mattach\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--progress\u{001B}[0m"))
    }

    @Test("root help honours ansi never")
    func rootHelpHonoursANSINever() {
        let help = ComposeCLIHelp.rootHelpText(arguments: ["--ansi", "never", "--file", "Dockerfile"])

        #expect(help.contains("Support: supported | partially supported | not supported"))
        #expect(!help.contains("\u{001B}["))
    }

    @Test("up no-attach is shown as supported")
    func upNoAttachIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--no-attach\u{001B}[0m"))
    }

    @Test("down command is shown as supported")
    func downCommandIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "down"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
    }

    @Test("create command and options are shown as supported")
    func createCommandAndOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "create"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--build\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--scale\u{001B}[0m"))
    }

    @Test("config command and digest options are shown as supported")
    func configCommandAndDigestOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "config"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--lock-image-digests\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--resolve-image-digests\u{001B}[0m"))
    }

    @Test("ps command and options are shown as supported")
    func psCommandAndOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "ps"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--filter\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--format\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--services\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--status\u{001B}[0m"))
    }

    @Test("watch command and options are shown as supported")
    func watchCommandAndOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "watch"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--no-up\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--prune\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--quiet\u{001B}[0m"))
    }

    @Test("run command and options are shown as supported")
    func runCommandAndOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "run"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--build\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--no-deps\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--service-ports\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--use-aliases\u{001B}[0m"))
    }

    @Test("exec command and privileged option are shown as supported")
    func execCommandAndPrivilegedOptionAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "exec"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--privileged\u{001B}[0m"))
    }

    @Test("build print option is shown as supported")
    func buildPrintOptionIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "build"))

        #expect(help.contains("Support: \u{001B}[38;5;208mpartially supported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--print\u{001B}[0m"))
        #expect(help.contains("\u{001B}[38;5;208m--provenance\u{001B}[0m"))
        #expect(help.contains("\u{001B}[38;5;208m--sbom\u{001B}[0m"))
        #expect(help.contains("Use --provenance=false to explicitly disable."))
        #expect(help.contains("Use --sbom=false to explicitly disable."))
    }

    @Test("attach signal proxy option is shown as supported")
    func attachSignalProxyOptionIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "attach"))

        #expect(help.contains("Support: \u{001B}[38;5;208mpartially supported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[38;5;208m--detach-keys\u{001B}[0m"))
        #expect(help.contains("Ignored with --no-stdin output-only attach."))
        #expect(help.contains("\u{001B}[32m--index\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--no-stdin\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--sig-proxy\u{001B}[0m"))
    }

    @Test("up raw attached output flags are shown as supported")
    func upRawAttachedOutputFlagsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--no-color\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--no-log-prefix\u{001B}[0m"))
    }

    @Test("up timestamps is shown as supported")
    func upTimestampsIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--timestamps\u{001B}[0m"))
    }

    @Test("up attach options are shown as supported")
    func upAttachOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--attach\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--attach-dependencies\u{001B}[0m"))
    }

    @Test("up exit-control options are shown as supported")
    func upExitControlOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--abort-on-container-exit\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--abort-on-container-failure\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--exit-code-from\u{001B}[0m"))
    }

    @Test("up menu option shows partial support for explicit disable")
    func upMenuOptionShowsPartialSupportForExplicitDisable() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[38;5;208m--menu\u{001B}[0m"))
        #expect(help.contains("Use --menu=false to explicitly disable the helper menu."))
    }

    @Test("up raw attached output flags parse")
    func upRawAttachedOutputFlagsParse() throws {
        let command = try Up.parse([
            "--abort-on-container-failure",
            "--attach", "api",
            "--attach", "worker",
            "--attach-dependencies",
            "--exit-code-from", "api",
            "--no-color",
            "--no-log-prefix",
            "--timestamps",
            "api",
        ])

        #expect(command.abortOnContainerFailure)
        #expect(command.attach == ["api", "worker"])
        #expect(command.attachDependencies)
        #expect(command.exitCodeFrom == "api")
        #expect(command.noColor)
        #expect(command.noLogPrefix)
        #expect(command.timestamps)
        #expect(command.services == ["api"])
    }

    @Test("up menu false value parses through Docker Compose rewriter")
    func upMenuFalseValueParsesThroughDockerComposeRewriter() throws {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "up",
            "--menu=false",
            "api",
        ])
        let command = try Up.parse(Array(rewritten.dropFirst()))

        #expect(!command.menu)
        #expect(command.services == ["api"])
    }

    @Test("config image digest flags parse")
    func configImageDigestFlagsParse() throws {
        let command = try Config.parse(["--resolve-image-digests", "--lock-image-digests", "api"])

        #expect(command.resolveImageDigests)
        #expect(command.lockImageDigests)
        #expect(command.services == ["api"])
    }

    @Test("build print flag parses")
    func buildPrintFlagParses() throws {
        let command = try Build.parse([
            "--print",
            "--provenance=false",
            "--sbom", "false",
            "--build-arg", "VERSION=2",
            "--with-dependencies",
            "api",
        ])

        #expect(command.printBake)
        #expect(command.provenance == "false")
        #expect(command.sbom == "false")
        #expect(command.buildArgs == ["VERSION=2"])
        #expect(command.withDependencies)
        #expect(command.services == ["api"])
    }

    @Test("attach signal proxy flag parses")
    func attachSignalProxyFlagParses() throws {
        let command = try Attach.parse(["--no-stdin", "--detach-keys", "ctrl-x", "--sig-proxy=false", "--index", "2", "api"])

        #expect(command.noStdin)
        #expect(command.detachKeys == "ctrl-x")
        #expect(command.sigProxy == "false")
        #expect(command.index == 2)
        #expect(command.service == "api")
    }

    @Test("global progress option maps Docker Compose policies")
    func globalProgressOptionMapsDockerComposePolicies() {
        var options = GlobalOptions()

        options.progress = "quiet"
        #expect(options.progressStyle() == .quiet)

        options.progress = "none"
        #expect(options.progressStyle() == .quiet)

        options.progress = "plain"
        #expect(options.progressStyle() == .plain)

        options.progress = "json"
        #expect(options.progressStyle() == .json)

        options.progress = "tty"
        #expect(options.progressStyle() == .tty)
    }

    @Test("global ansi option controls progress colour")
    func globalANSIOptionControlsProgressColour() {
        var options = GlobalOptions()

        options.ansi = "always"
        #expect(options.shouldColorProgress())

        options.ansi = "never"
        #expect(!options.shouldColorProgress())
    }
}
