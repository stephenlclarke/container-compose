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

    @Test("up raw attached output flags parse")
    func upRawAttachedOutputFlagsParse() throws {
        let command = try Up.parse(["--no-color", "--no-log-prefix", "--timestamps", "api"])

        #expect(command.noColor)
        #expect(command.noLogPrefix)
        #expect(command.timestamps)
        #expect(command.services == ["api"])
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
