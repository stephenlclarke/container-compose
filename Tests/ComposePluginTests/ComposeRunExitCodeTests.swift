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

@Suite("Compose run exit codes")
struct ComposeRunExitCodeTests {
    private struct TerminalCase {
        let flags: [String]
        let input: Bool
        let terminals: [Bool]
    }

    @Test
    func `terminal selection preserves omitted and explicit flag values`() throws {
        let hosts = [(false, false), (false, true), (true, false), (true, true)]
        let cases: [TerminalCase] = [
            .init(flags: [], input: true, terminals: [false, false, false, true]),
            .init(flags: ["-i"], input: true, terminals: [false, true, false, true]),
            .init(flags: ["--interactive=false"], input: false, terminals: [false, true, false, true]),
            .init(flags: ["-T"], input: true, terminals: [false, false, false, false]),
            .init(flags: ["--no-TTY=false"], input: true, terminals: [true, true, true, true]),
            .init(flags: ["--tty"], input: true, terminals: [true, true, true, true]),
            .init(flags: ["--tty=false"], input: true, terminals: [false, false, false, false]),
            .init(flags: ["-it"], input: true, terminals: [true, true, true, true]),
            .init(flags: ["-it=false"], input: true, terminals: [false, false, false, false]),
            .init(flags: ["-ti=false"], input: false, terminals: [true, true, true, true]),
            .init(flags: ["--tty=false", "-t"], input: true, terminals: [true, true, true, true]),
            .init(flags: ["-T", "--no-tty=false"], input: true, terminals: [true, true, true, true]),
            .init(flags: ["-i=false", "-i"], input: true, terminals: [false, true, false, true]),
        ]
        for item in cases {
            let arguments = ComposeArgumentRewriter.argumentsForParsing(["run"] + item.flags + ["app"])
            let command = try #require(ComposePlugin.parseAsRoot(arguments) as? Run)
            for (index, host) in hosts.enumerated() {
                let selected = try command.terminalOptions(inputIsTerminal: host.0, outputIsTerminal: host.1)
                #expect(selected.interactive == item.input, "\(item.flags), host \(host)")
                #expect(!selected.noTty == item.terminals[index], "\(item.flags), host \(host)")
            }
        }
    }

    @Test(arguments: [["-t", "-T"], ["--tty=false", "--no-tty=false"],
                      ["--no-TTY=false", "--tty"], ["-itT"]])
    func `distinct terminal options conflict regardless of their values`(_ flags: [String]) {
        let arguments = ComposeArgumentRewriter.argumentsForParsing(["run"] + flags + ["app"])
        #expect(throws: (any Error).self) {
            _ = try ComposePlugin.parseAsRoot(arguments)
        }
    }

    @Test
    func `grouped terminal flags preserve attached values and guest arguments`() throws {
        let arguments = ComposeArgumentRewriter.argumentsForParsing([
            "run", "-ditu1000", "--env=--tty=false", "-ip8080:80", "app", "echo", "-it=false", "--no-tty"
        ])
        let command = try #require(ComposePlugin.parseAsRoot(arguments) as? Run)
        #expect(command.detach)
        #expect(command.interactive == true)
        #expect(command.tty == true)
        #expect(command.user == "1000")
        #expect(command.environment == ["--tty=false"])
        #expect(command.publish == ["8080:80"])
        #expect(command.command == ["echo", "-it=false", "--no-tty"])
    }

    @Test
    func `grouped terminal flags keep flag-shaped attached option values`() throws {
        let arguments = ComposeArgumentRewriter.argumentsForParsing(["run", "-il--user", "app", "-t"])
        let command = try #require(ComposePlugin.parseAsRoot(arguments) as? Run)
        #expect(command.interactive == true)
        #expect(command.tty == nil)
        #expect(command.labels == ["--user"])
        #expect(command.command == ["-t"])
    }

    @Test(arguments: ["true", "True", "TRUE", "t", "T", "1", "false", "False", "FALSE", "f", "F", "0"])
    func `terminal flags accept Docker boolean spellings`(_ value: String) throws {
        let arguments = ComposeArgumentRewriter.argumentsForParsing(["run", "--tty=" + value, "app"])
        let command = try #require(ComposePlugin.parseAsRoot(arguments) as? Run)
        #expect(command.tty == ["true", "True", "TRUE", "t", "T", "1"].contains(value))
    }

    @Test(arguments: ["yes", "no", "tRuE", "", "invalid"])
    func `terminal flags reject malformed boolean values`(_ value: String) {
        let arguments = ComposeArgumentRewriter.argumentsForParsing(["run", "--tty=" + value, "app"])
        #expect(throws: (any Error).self) {
            _ = try ComposePlugin.parseAsRoot(arguments)
        }
    }

    @Test
    func `run help distinguishes quiet progress from guest streams`() throws {
        let help = try #require(ComposeCLIHelp.helpText(commandPath: ["run"], arguments: ["--ansi", "never"]))
        #expect(help.contains("Suppress Compose progress; preserve guest input and output"))
        #expect(!help.contains("Don't print anything to STDOUT"))
    }

    @Test(arguments: [[], ["-i"], ["--interactive"], ["--interactive=true"], ["-i=true"]])
    func `run keeps input open by default and when explicitly enabled`(_ flags: [String]) throws {
        let arguments = ComposeArgumentRewriter.argumentsForParsing(["run"] + flags + ["-T", "app"])
        let command = try #require(ComposePlugin.parseAsRoot(arguments) as? Run)
        #expect(command.interactive == (flags.isEmpty ? nil : true))
        #expect(command.noTty == true)
        #expect(ComposeRunOptions().interactive)
    }

    @Test(arguments: ["--interactive=false", "-i=false", "--no-interactive"])
    func `run can explicitly disable input without rewriting guest arguments`(_ flag: String) throws {
        let arguments = ComposeArgumentRewriter.argumentsForParsing([
            "run", flag, "app", "echo", "--interactive=false"
        ])
        let command = try #require(ComposePlugin.parseAsRoot(arguments) as? Run)
        #expect(command.interactive == false)
        #expect(command.command == ["echo", "--interactive=false"])
    }

    @Test
    func `command failures preserve the one-off process exit status`() throws {
        let error = ComposeRunExitError(status: 7)

        do {
            try throwRunCommandError(error)
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue == 7)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `non-command failures retain their original error`() throws {
        let expected = ComposeError.invalidProject("missing service")

        do {
            try throwRunCommandError(expected)
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
