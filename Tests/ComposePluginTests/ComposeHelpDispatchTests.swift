// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
@testable import ComposePlugin
import Testing

@Suite("Compose help dispatch")
struct ComposeHelpDispatchTests {
    @Test("parsed payload retains options owned by the container", arguments: [
        ["echo", "--help"], ["echo", "-h"], ["echo", "--user", "1000"],
        ["echo", "--workdir", "/guest"], ["echo", "--env", "VALUE=child"],
        ["--help"], ["-h"], ["echo", "--", "--help"], ["--", "echo", "--help"],
    ])
    func parsedPayloadIsUnchanged(payload: [String]) throws {
        let global = ["--ansi", "never", "--file", "compose.yaml", "--dry-run"]
        let runArguments = ComposeArgumentRewriter.argumentsForParsing(
            global + ["run", "--name", "outer", "web"] + payload
        )
        let execArguments = ComposeArgumentRewriter.argumentsForParsing(
            global + ["exec", "--index", "2", "web"] + payload
        )
        let run = try #require(ComposePlugin.parseAsRoot(runArguments) as? Run)
        let exec = try #require(ComposePlugin.parseAsRoot(execArguments) as? Exec)
        #expect(run.service == "web")
        #expect(exec.service == "web")
        #expect(run.command == payload)
        #expect(exec.command == payload)
        #expect(run.name == "outer")
        #expect(exec.index == 2)
        #expect(run.user == nil && exec.user == nil)
        #expect(run.workdir == nil && exec.workdir == nil)
        #expect(run.environment.isEmpty && exec.environment.isEmpty)
        #expect(run.global.ansi == "never" && exec.global.ansi == "never")
        #expect(run.global.file == ["compose.yaml"] && exec.global.file == ["compose.yaml"])
        #expect(run.global.dryRun && exec.global.dryRun)
    }

    @Test("explicit option terminators preserve service and guest payload", arguments: ["run", "exec"])
    func explicitTerminator(command: String) throws {
        let arguments = ComposeArgumentRewriter.argumentsForParsing(
            [command, "--dry-run", "--", "web", "echo", "--help"]
        )
        if command == "run" {
            let parsed = try #require(ComposePlugin.parseAsRoot(arguments) as? Run)
            #expect(parsed.service == "web")
            #expect(parsed.command == ["echo", "--help"])
        } else {
            let parsed = try #require(ComposePlugin.parseAsRoot(arguments) as? Exec)
            #expect(parsed.service == "web")
            #expect(parsed.command == ["echo", "--help"])
        }
    }

    @Test("a run without replacement command retains the image command")
    func defaultRunCommand() throws {
        let arguments = ComposeArgumentRewriter.argumentsForParsing(["run", "--name", "probe", "web"])
        let command = try #require(ComposePlugin.parseAsRoot(arguments) as? Run)
        #expect(command.service == "web")
        #expect(command.command.isEmpty)
        #expect(ComposeArgumentRewriter.argumentsForParsing(["up", "api"]) == ["up", "api"])
    }

    @Test("guest options cannot disable the installed runtime check", arguments: [
        ["run", "web", "echo", "--dry-run"],
        ["exec", "web", "echo", "--dry-run"],
        ["run", "--name", "--dry-run", "web"],
        ["run", "web", "alpha", "dry-run"],
        ["exec", "--", "web", "echo", "--dry-run"],
    ])
    func guestOptionsKeepRuntimePreflight(arguments: [String]) {
        #expect(ContainerPackageCompatibility.requiresRuntimeCheck(arguments: arguments))
        let rewritten = ComposeArgumentRewriter.argumentsForParsing(arguments)
        #expect(ContainerPackageCompatibility.requiresRuntimeCheck(arguments: rewritten))
        #expect(!ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["--dry-run"] + arguments))
    }

    @Test("container command help is not intercepted", arguments: [
        ["run", "web", "echo", "--help"],
        ["exec", "web", "echo", "--help"],
        ["run", "--name", "probe", "web", "echo", "-h"],
        ["exec", "--index", "2", "web", "echo", "-h"],
        ["run", "-eVALUE=help", "web", "help"],
        ["exec", "-u1000", "web", "help"],
        ["run", "help"],
        ["exec", "help", "echo", "--help"],
        ["run", "--cap-add", "NET_ADMIN", "web", "echo", "--help"],
        ["run", "--cap-drop", "ALL", "--", "web", "echo", "--help"],
        ["run", "--name", "--help", "web"],
        ["exec", "--env", "-h", "web", "echo"],
        ["--file", "--help", "run", "web"],
        ["exec", "--workdir=--help", "web", "echo"],
        ["--file", "compose.yaml", "run", "--", "web", "echo", "--help"],
        ["--file", "compose.yaml", "exec", "--", "web", "echo", "--help"],
    ])
    func payloadHelpPassesThrough(arguments: [String]) {
        var output: [String] = []
        #expect(!ComposeCLIHelp.renderIfRequested(arguments: arguments, emit: { output.append($0) }))
        #expect(output.isEmpty)
    }

    @Test("documented commands route to exact help", arguments: ComposeCLIHelp.documentedHelpCommandPaths)
    func documentedCommandHelp(path: [String]) throws {
        var output: [String] = []
        let arguments = ["--ansi", "never"] + path + ["--help"]
        #expect(ComposeCLIHelp.renderIfRequested(arguments: arguments, emit: { output.append($0) }))
        let expected = try #require(ComposeCLIHelp.helpText(commandPath: path, arguments: ["--ansi", "never"]))
        #expect(output == [expected])
        #expect(!output.joined().contains("\u{001B}["))
    }

    @Test("run and exec own help before their service", arguments: [
        ["run", "--help"],
        ["exec", "-h"],
        ["run", "--name", "probe", "--help"],
        ["exec", "--index=2", "--help"],
        ["run", "-p8080:80", "--help"],
        ["exec", "-u1000", "--help"],
        ["run", "--cap-add", "NET_ADMIN", "--help"],
        ["run", "--cap-drop", "ALL", "--help"],
    ])
    func commandHelpBeforeService(arguments: [String]) throws {
        var output: [String] = []
        let command = try #require(arguments.first)
        #expect(ComposeCLIHelp.renderIfRequested(arguments: arguments, emit: { output.append($0) }))
        #expect(output == [try #require(ComposeCLIHelp.commandHelpText(command: command))])
    }

    @Test("help command routes through global and nested options", arguments: [
        (["help"], [String]()),
        (["help", "up"], ["up"]),
        (["up", "help"], ["up"]),
        (["--file", "help", "up", "help"], ["up"]),
        (["up", "--profile=dev", "--verbose", "help"], ["up"]),
        (["up", "--file", "compose.yaml", "help"], ["up"]),
        (["help", "bridge"], ["bridge"]),
        (["bridge", "help"], ["bridge"]),
        (["bridge", "--verbose", "convert", "help"], ["bridge", "convert"]),
        (["bridge", "--profile", "dev", "convert", "help"], ["bridge", "convert"]),
        (["bridge", "--profile=dev", "convert", "help"], ["bridge", "convert"]),
        (["bridge", "convert", "--output", "help", "help"], ["bridge", "convert"]),
        (["bridge", "convert", "--output=help", "help"], ["bridge", "convert"]),
        (["bridge", "transformations", "help"], ["bridge", "transformations"]),
        (["help", "bridge", "transformations", "create"], ["bridge", "transformations", "create"]),
        (["bridge", "transformations", "create", "--from", "help", "help"], ["bridge", "transformations", "create"]),
        (["alpha", "help"], ["alpha"]),
        (["alpha", "--dry-run", "scale", "help"], ["alpha", "scale"]),
        (["alpha", "--file", "compose.yaml", "watch", "help"], ["alpha", "watch"]),
        (["unknown", "--help"], [String]()),
    ])
    func helpCommandRouting(arguments: [String], path: [String]) throws {
        var output: [String] = []
        #expect(ComposeCLIHelp.renderIfRequested(arguments: arguments, emit: { output.append($0) }))
        #expect(output == [try #require(ComposeCLIHelp.helpText(commandPath: path))])
    }

    @Test("option values and positional help words do not request help", arguments: [
        [], ["--file", "help"], ["--profile=help"], ["--verbose", "up"],
        ["up", "api", "help"], ["up", "--file", "help"], ["up", "--file=help"],
        ["bridge", "convert", "--output", "help"], ["bridge", "convert", "--output=help"],
        ["alpha", "--file", "help", "watch"], ["alpha", "--file=help", "watch"],
    ])
    func notHelpRequest(arguments: [String]) {
        var output: [String] = []
        #expect(!ComposeCLIHelp.renderIfRequested(arguments: arguments, emit: { output.append($0) }))
        #expect(output.isEmpty)
    }

    @Test("missing command produces root help", arguments: [
        [], ["--ansi=never"], ["--file", "compose.yaml"], ["--all-resources", "--dry-run", "--verbose"],
        ["--profile=dev", "--project-name", "probe", "--parallel", "2"],
    ])
    func missingCommand(arguments: [String]) {
        var output: [String] = []
        #expect(ComposeCLIHelp.renderRootIfNoCommand(arguments: arguments, emit: { output.append($0) }))
        #expect(output == [ComposeCLIHelp.rootHelpText(arguments: arguments)])
    }

    @Test("real or invalid commands are left to the command parser", arguments: [
        ["up"], ["run", "web", "help"], ["unknown"], ["--invalid"], ["--help"], ["help"],
        ["bridge", "convert"], ["alpha", "watch"],
    ])
    func nonMissingCommand(arguments: [String]) {
        var output: [String] = []
        #expect(!ComposeCLIHelp.renderRootIfNoCommand(arguments: arguments, emit: { output.append($0) }))
        #expect(output.isEmpty)
    }
}
