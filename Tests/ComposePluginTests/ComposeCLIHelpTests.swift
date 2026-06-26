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
    }

    @Test("root help honours ansi never")
    func rootHelpHonoursANSINever() {
        let help = ComposeCLIHelp.rootHelpText(arguments: ["--ansi", "never", "--file", "Dockerfile"])

        #expect(help.contains("Support: supported | partially supported | not supported"))
        #expect(!help.contains("\u{001B}["))
    }
}
