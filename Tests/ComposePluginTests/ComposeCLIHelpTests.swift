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
        #expect(help.contains("\u{001B}[38;5;208mrun\u{001B}[0m"))
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
