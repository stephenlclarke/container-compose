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
import Foundation

/// Docker Compose v2-compatible CLI help text.
enum ComposeCLIHelp {
    /// Prints Docker Compose compatible help when the invocation asks for it.
    static func renderIfRequested(arguments: [String]) -> Bool {
        let rewritten = ComposeArgumentRewriter.rewrite(arguments)
        guard isHelpRequested(arguments: rewritten) else {
            return false
        }

        let command = commandPath(in: rewritten)
        let useANSI = shouldUseANSI(arguments: rewritten)
        if command == ["bridge"] {
            print(renderedHelp(bridgeHelp, commandPath: command, useANSI: useANSI))
            return true
        }
        if let help = nestedCommandHelp(for: command) {
            print(renderedHelp(help, commandPath: command, useANSI: useANSI))
            return true
        }
        if command.count == 1, let help = commandHelp[command[0]] {
            print(renderedHelp(help, commandPath: command, useANSI: useANSI))
            return true
        }

        print(renderedHelp(rootHelp, commandPath: [], useANSI: useANSI))
        return true
    }

    /// Prints Docker Compose compatible root help for invocations that include
    /// only global options and no subcommand.
    static func renderRootIfNoCommand(arguments: [String]) -> Bool {
        let rewritten = ComposeArgumentRewriter.rewrite(arguments)
        guard isMissingCommandInvocation(arguments: rewritten) else {
            return false
        }

        print(rootHelpText(arguments: rewritten))
        return true
    }

    static func rootHelpText(arguments: [String]) -> String {
        renderedHelp(rootHelp, commandPath: [], useANSI: shouldUseANSI(arguments: arguments))
    }

    static func commandHelpText(command: String, arguments: [String] = []) -> String? {
        commandHelp[command].map { renderedHelp($0, commandPath: [command], useANSI: shouldUseANSI(arguments: arguments)) }
    }

    struct CommandSupportSnapshot: Equatable {
        var commandPath: [String]
        var support: String
        var color: String
        var detail: String?
    }

    struct OptionSupportSnapshot: Equatable {
        var commandPath: [String]
        var option: String
        var support: String
        var color: String
    }

    static var commandSupportSnapshots: [CommandSupportSnapshot] {
        supportByCommand
            .map { key, support in
                CommandSupportSnapshot(
                    commandPath: commandPath(from: key),
                    support: support.label,
                    color: support.color,
                    detail: supportDetailByCommand[key]
                )
            }
            .sorted { $0.commandPath.lexicographicallyPrecedes($1.commandPath) }
    }

    static var optionSupportSnapshots: [OptionSupportSnapshot] {
        supportByOption
            .flatMap { key, options in
                options.map { option, support in
                    OptionSupportSnapshot(commandPath: commandPath(from: key), option: option, support: support.label, color: support.color)
                }
            }
            .sorted { left, right in
                if left.commandPath == right.commandPath {
                    return left.option < right.option
                }
                return left.commandPath.lexicographicallyPrecedes(right.commandPath)
            }
    }

    static var documentedHelpCommandPaths: [[String]] {
        (
            [[]]
                + commandHelp.keys.map { [$0] }
                + bridgeCommandHelp.keys.map(commandPath(from:))
                + alphaCommandHelp.keys.map(commandPath(from:))
        )
            .sorted { $0.lexicographicallyPrecedes($1) }
    }

    static func helpText(commandPath: [String], arguments: [String] = []) -> String? {
        let useANSI = shouldUseANSI(arguments: arguments)
        if commandPath.isEmpty {
            return renderedHelp(rootHelp, commandPath: [], useANSI: useANSI)
        }
        if commandPath == ["bridge"] {
            return renderedHelp(bridgeHelp, commandPath: commandPath, useANSI: useANSI)
        }
        if let help = bridgeCommandHelp[commandPath.joined(separator: " ")]
            ?? alphaCommandHelp[commandPath.joined(separator: " ")] {
            return renderedHelp(help, commandPath: commandPath, useANSI: useANSI)
        }
        if commandPath.count == 1, let help = commandHelp[commandPath[0]] {
            return renderedHelp(help, commandPath: commandPath, useANSI: useANSI)
        }
        return nil
    }

    private static func isHelpRequested(arguments: [String]) -> Bool {
        if arguments.contains("--help") || arguments.contains("-h") {
            return true
        }
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "help" {
                return true
            }
            if commandNames.contains(argument) {
                if argument == "bridge" {
                    return bridgePathContainsHelp(in: arguments, startingAt: index + 1)
                }
                if argument == "alpha" {
                    return nestedPathContainsHelp(in: arguments, startingAt: index + 1)
                }
                return commandPathContainsHelp(in: arguments, startingAt: index + 1)
            }
            index = nextGlobalArgumentIndex(arguments: arguments, currentIndex: index)
        }
        return false
    }

    private static func nextGlobalArgumentIndex(arguments: [String], currentIndex: Int) -> Int {
        let argument = arguments[currentIndex]
        if consumesGlobalValue(argument), !argument.contains("="), arguments.indices.contains(currentIndex + 1) {
            return currentIndex + 2
        }
        return currentIndex + 1
    }

    private static func commandPathContainsHelp(in arguments: [String], startingAt startIndex: Int) -> Bool {
        var index = startIndex
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "help" {
                return true
            }
            if isGlobalFlag(argument) {
                index += 1
                continue
            }
            if consumesGlobalValue(argument), !argument.contains("="), arguments.indices.contains(index + 1) {
                index += 2
                continue
            }
            if consumesGlobalValue(argument) {
                index += 1
                continue
            }
            return false
        }
        return false
    }

    private static func bridgePathContainsHelp(in arguments: [String], startingAt startIndex: Int) -> Bool {
        nestedPathContainsHelp(
            in: arguments,
            startingAt: startIndex,
            consumesNestedValue: { consumesBridgeValue($0) }
        )
    }

    private static func nestedPathContainsHelp(
        in arguments: [String],
        startingAt startIndex: Int,
        consumesNestedValue: (String) -> Bool = { _ in false }
    ) -> Bool {
        var index = startIndex
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "help" {
                return true
            }
            if isGlobalFlag(argument) {
                index += 1
                continue
            }
            if consumesGlobalValue(argument), !argument.contains("="), arguments.indices.contains(index + 1) {
                index += 2
                continue
            }
            if consumesGlobalValue(argument) {
                index += 1
                continue
            }
            if consumesNestedValue(argument), !argument.contains("="), arguments.indices.contains(index + 1) {
                index += 2
            } else if consumesNestedValue(argument) {
                index += 1
            } else {
                index += 1
            }
        }
        return false
    }

    private static func isMissingCommandInvocation(arguments: [String]) -> Bool {
        guard !arguments.isEmpty else {
            return true
        }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if commandNames.contains(argument) || argument == "help" || argument == "--help" || argument == "-h" {
                return false
            }
            if consumesGlobalValue(argument), !argument.contains("="), arguments.indices.contains(index + 1) {
                index += 2
                continue
            }
            if isGlobalFlag(argument) {
                index += 1
                continue
            }
            if consumesGlobalValue(argument) || argument.hasPrefix("--ansi=") {
                index += 1
                continue
            }
            return false
        }
        return true
    }

    private enum SupportLevel {
        case supported
        case partiallySupported
        case notSupported

        var label: String {
            switch self {
            case .supported:
                "supported"
            case .partiallySupported:
                "partially supported"
            case .notSupported:
                "not supported"
            }
        }

        var color: String {
            switch self {
            case .supported:
                "\u{001B}[32m"
            case .partiallySupported:
                "\u{001B}[38;5;208m"
            case .notSupported:
                "\u{001B}[31m"
            }
        }
    }

    private static let resetColor = "\u{001B}[0m"

    private static let supportByCommand: [String: SupportLevel] = [
        "alpha": .supported,
        "alpha dry-run": .supported,
        "alpha scale": .supported,
        "alpha watch": .supported,
        "attach": .partiallySupported,
        "bridge": .supported,
        "bridge convert": .supported,
        "bridge transformations": .supported,
        "bridge transformations create": .supported,
        "bridge transformations list": .supported,
        "bridge transformations ls": .supported,
        "build": .supported,
        "commit": .partiallySupported,
        "config": .supported,
        "convert": .supported,
        "cp": .supported,
        "create": .supported,
        "down": .supported,
        "events": .supported,
        "exec": .supported,
        "export": .supported,
        "help": .supported,
        "images": .supported,
        "kill": .supported,
        "logs": .supported,
        "ls": .supported,
        "pause": .supported,
        "port": .supported,
        "ps": .supported,
        "publish": .supported,
        "pull": .supported,
        "push": .supported,
        "restart": .supported,
        "rm": .supported,
        "run": .supported,
        "scale": .supported,
        "start": .supported,
        "stats": .supported,
        "stop": .supported,
        "top": .supported,
        "unpause": .supported,
        "up": .supported,
        "version": .supported,
        "volumes": .supported,
        "wait": .supported,
        "watch": .supported,
    ]

    private static let supportDetailByCommand: [String: String] = [
        "attach": "Output-only attach is supported; interactive stream reattachment and detach-key handling require additional runtime support.",
        "commit": "Stopped containers and running containers with default --pause=true can be committed; the running path uses a brief filesystem freeze. --pause=false remains unavailable because a writable filesystem cannot be exported safely without that freeze.",
    ]

    private static let supportByOption: [String: [String: SupportLevel]] = [
        "": [
            "--all-resources": .supported,
            "--ansi": .supported,
            "--compatibility": .supported,
            "--dry-run": .supported,
            "--env-file": .supported,
            "--file": .supported,
            "--parallel": .partiallySupported,
            "--profile": .supported,
            "--progress": .supported,
            "--project-directory": .supported,
            "--project-name": .supported,
            "--verbose": .supported,
        ],
        "alpha": [
            "--dry-run": .supported,
        ],
        "alpha dry-run": [
            "--dry-run": .supported,
        ],
        "alpha scale": [
            "--dry-run": .supported,
            "--no-deps": .supported,
        ],
        "alpha watch": [
            "--dry-run": .supported,
            "--no-up": .supported,
            "--quiet": .supported,
        ],
        "attach": [
            "--detach-keys": .partiallySupported,
            "--dry-run": .supported,
            "--index": .supported,
            "--no-stdin": .supported,
            "--sig-proxy": .supported,
        ],
        "bridge": [
            "--dry-run": .supported,
        ],
        "bridge convert": [
            "--dry-run": .supported,
            "--output": .supported,
            "--templates": .supported,
            "--transformation": .supported,
        ],
        "bridge transformations": [
            "--dry-run": .supported,
        ],
        "bridge transformations create": [
            "--dry-run": .supported,
            "--from": .supported,
        ],
        "bridge transformations list": [
            "--dry-run": .supported,
            "--format": .supported,
            "--quiet": .supported,
        ],
        "bridge transformations ls": [
            "--dry-run": .supported,
            "--format": .supported,
            "--quiet": .supported,
        ],
        "build": [
            "--build-arg": .supported,
            "--builder": .supported,
            "--check": .supported,
            "--dry-run": .supported,
            "--memory": .supported,
            "--no-cache": .supported,
            "--print": .supported,
            "--provenance": .supported,
            "--pull": .supported,
            "--push": .supported,
            "--quiet": .supported,
            "--sbom": .supported,
            "--ssh": .supported,
            "--with-dependencies": .supported,
        ],
        "commit": [
            "--author": .supported,
            "--change": .supported,
            "--dry-run": .supported,
            "--index": .supported,
            "--message": .supported,
            "--pause": .partiallySupported,
        ],
        "config": [
            "--dry-run": .supported,
            "--environment": .supported,
            "--format": .supported,
            "--hash": .supported,
            "--images": .supported,
            "--lock-image-digests": .supported,
            "--models": .supported,
            "--networks": .supported,
            "--no-consistency": .supported,
            "--no-env-resolution": .supported,
            "--no-interpolate": .supported,
            "--no-normalize": .supported,
            "--no-path-resolution": .supported,
            "--output": .supported,
            "--profiles": .supported,
            "--quiet": .supported,
            "--resolve-image-digests": .supported,
            "--services": .supported,
            "--variables": .supported,
            "--volumes": .supported,
        ],
        "convert": [
            "--dry-run": .supported,
            "--format": .supported,
            "--hash": .supported,
            "--images": .supported,
            "--no-consistency": .supported,
            "--no-interpolate": .supported,
            "--no-normalize": .supported,
            "--output": .supported,
            "--profiles": .supported,
            "--quiet": .supported,
            "--resolve-image-digests": .supported,
            "--services": .supported,
            "--volumes": .supported,
        ],
        "cp": [
            "--all": .supported,
            "--archive": .supported,
            "--dry-run": .supported,
            "--follow-link": .supported,
            "--index": .supported,
        ],
        "create": [
            "--build": .supported,
            "--dry-run": .supported,
            "--force-recreate": .supported,
            "--no-build": .supported,
            "--no-recreate": .supported,
            "--pull": .supported,
            "--quiet-pull": .supported,
            "--remove-orphans": .supported,
            "--scale": .supported,
            "--yes": .supported,
        ],
        "down": [
            "--dry-run": .supported,
            "--remove-orphans": .supported,
            "--rmi": .supported,
            "--timeout": .supported,
            "--volumes": .supported,
        ],
        "events": [
            "--dry-run": .supported,
            "--json": .supported,
            "--since": .supported,
            "--until": .supported,
        ],
        "exec": [
            "--detach": .supported,
            "--dry-run": .supported,
            "--env": .supported,
            "--index": .supported,
            "--no-tty": .supported,
            "--privileged": .supported,
            "--user": .supported,
            "--workdir": .supported,
        ],
        "export": [
            "--dry-run": .supported,
            "--index": .supported,
            "--output": .supported,
        ],
        "images": [
            "--dry-run": .supported,
            "--format": .supported,
            "--quiet": .supported,
        ],
        "kill": [
            "--dry-run": .supported,
            "--remove-orphans": .supported,
            "--signal": .supported,
        ],
        "logs": [
            "--dry-run": .supported,
            "--follow": .supported,
            "--index": .supported,
            "--no-color": .supported,
            "--no-log-prefix": .supported,
            "--since": .supported,
            "--tail": .supported,
            "--timestamps": .supported,
            "--until": .supported,
        ],
        "ls": [
            "--all": .supported,
            "--dry-run": .supported,
            "--filter": .supported,
            "--format": .supported,
            "--quiet": .supported,
        ],
        "pause": [
            "--dry-run": .supported,
        ],
        "port": [
            "--dry-run": .supported,
            "--index": .supported,
            "--protocol": .supported,
        ],
        "ps": [
            "--all": .supported,
            "--dry-run": .supported,
            "--filter": .supported,
            "--format": .supported,
            "--no-trunc": .supported,
            "--orphans": .supported,
            "--quiet": .supported,
            "--services": .supported,
            "--status": .supported,
        ],
        "publish": [
            "--app": .supported,
            "--dry-run": .supported,
            "--oci-version": .supported,
            "--resolve-image-digests": .supported,
            "--with-env": .supported,
            "--yes": .supported,
        ],
        "pull": [
            "--dry-run": .supported,
            "--ignore-buildable": .supported,
            "--ignore-pull-failures": .supported,
            "--include-deps": .supported,
            "--policy": .supported,
            "--quiet": .supported,
        ],
        "push": [
            "--dry-run": .supported,
            "--ignore-push-failures": .supported,
            "--include-deps": .supported,
            "--quiet": .supported,
        ],
        "restart": [
            "--dry-run": .supported,
            "--no-deps": .supported,
            "--timeout": .supported,
        ],
        "rm": [
            "--dry-run": .supported,
            "--force": .supported,
            "--stop": .supported,
            "--volumes": .supported,
        ],
        "run": [
            "--build": .supported,
            "--cap-add": .supported,
            "--cap-drop": .supported,
            "--detach": .supported,
            "--dry-run": .supported,
            "--entrypoint": .supported,
            "--env": .supported,
            "--env-from-file": .supported,
            "--interactive": .supported,
            "--label": .supported,
            "--name": .supported,
            "--no-tty": .supported,
            "--no-deps": .supported,
            "--publish": .supported,
            "--pull": .supported,
            "--quiet": .supported,
            "--quiet-build": .supported,
            "--quiet-pull": .supported,
            "--remove-orphans": .supported,
            "--rm": .supported,
            "--service-ports": .supported,
            "--use-aliases": .partiallySupported,
            "--user": .supported,
            "--volume": .supported,
            "--workdir": .supported,
        ],
        "scale": [
            "--dry-run": .supported,
            "--no-deps": .supported,
        ],
        "start": [
            "--dry-run": .supported,
            "--wait": .supported,
            "--wait-timeout": .supported,
        ],
        "stats": [
            "--all": .supported,
            "--dry-run": .supported,
            "--format": .supported,
            "--no-stream": .supported,
            "--no-trunc": .supported,
        ],
        "stop": [
            "--dry-run": .supported,
            "--timeout": .supported,
        ],
        "top": [
            "--dry-run": .supported,
        ],
        "unpause": [
            "--dry-run": .supported,
        ],
        "up": [
            "--abort-on-container-exit": .supported,
            "--abort-on-container-failure": .supported,
            "--always-recreate-deps": .supported,
            "--attach": .supported,
            "--attach-dependencies": .supported,
            "--build": .supported,
            "--detach": .supported,
            "--dry-run": .supported,
            "--exit-code-from": .supported,
            "--force-recreate": .supported,
            "--menu": .supported,
            "--no-attach": .supported,
            "--no-build": .supported,
            "--no-color": .supported,
            "--no-deps": .supported,
            "--no-log-prefix": .supported,
            "--no-recreate": .supported,
            "--no-start": .supported,
            "--pull": .supported,
            "--quiet-build": .supported,
            "--quiet-pull": .supported,
            "--remove-orphans": .supported,
            "--renew-anon-volumes": .supported,
            "--scale": .supported,
            "--timeout": .supported,
            "--timestamps": .supported,
            "--wait": .supported,
            "--wait-timeout": .supported,
            "--watch": .supported,
            "--yes": .supported,
        ],
        "version": [
            "--dry-run": .supported,
            "--format": .supported,
            "--short": .supported,
        ],
        "volumes": [
            "--dry-run": .supported,
            "--format": .supported,
            "--quiet": .supported,
        ],
        "wait": [
            "--down-project": .supported,
            "--dry-run": .supported,
        ],
        "watch": [
            "--dry-run": .supported,
            "--no-up": .supported,
            "--prune": .supported,
            "--quiet": .supported,
        ],
    ]

    private static func shouldUseANSI(arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--ansi", arguments.indices.contains(index + 1) {
                return arguments[index + 1] != "never"
            }
            if argument.hasPrefix("--ansi=") {
                return argument != "--ansi=never"
            }
            index += 1
        }
        return true
    }

    private static func renderedHelp(_ help: String, commandPath: [String], useANSI: Bool) -> String {
        var rendered = colorizeCommandListings(in: help, commandPath: commandPath, useANSI: useANSI)
        rendered = colorizeOptionListings(in: rendered, commandPath: commandPath, useANSI: useANSI)
        if commandPath.isEmpty || commandPath == ["bridge"] || commandPath == ["bridge", "transformations"] {
            rendered = insertSupportLegend(into: rendered, useANSI: useANSI)
        } else if let support = supportLevel(for: commandPath) {
            rendered = insertSupportLine(
                into: rendered,
                support: support,
                detail: supportDetailByCommand[commandPath.joined(separator: " ")],
                useANSI: useANSI
            )
        }
        return rendered
    }

    private static func colorizeCommandListings(in help: String, commandPath: [String], useANSI: Bool) -> String {
        help
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let line = String(line)
                guard let commandName = listedCommandName(in: line) else {
                    return line
                }
                let path = listedCommandPath(commandName, commandPath: commandPath)
                guard let support = supportLevel(for: path) else {
                    return line
                }
                return line.replacingOccurrences(
                    of: commandName,
                    with: styled(commandName, support: support, useANSI: useANSI),
                    options: [],
                    range: line.range(of: commandName)
                )
            }
            .joined(separator: "\n")
    }

    private static func listedCommandName(in line: String) -> String? {
        guard line.hasPrefix("  ") else {
            return nil
        }
        let trimmed = line.dropFirst(2)
        guard let token = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return nil
        }
        return String(token)
    }

    private static func listedCommandPath(_ commandName: String, commandPath: [String]) -> [String] {
        if commandPath == ["bridge"] {
            return ["bridge", commandName]
        }
        if commandPath == ["bridge", "transformations"] {
            return ["bridge", "transformations", commandName]
        }
        if commandPath == ["alpha"] {
            return ["alpha", commandName]
        }
        return [commandName]
    }

    private static func colorizeOptionListings(in help: String, commandPath: [String], useANSI: Bool) -> String {
        help
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                colorizeOptionLine(String(line), commandPath: commandPath, useANSI: useANSI)
            }
            .joined(separator: "\n")
    }

    private static func colorizeOptionLine(_ line: String, commandPath: [String], useANSI: Bool) -> String {
        let options = optionNames(in: line)
        guard !options.isEmpty else {
            return line
        }
        let support = supportLevel(forOptions: options, commandPath: commandPath)
        return replaceOptionNames(options, in: line, support: support, useANSI: useANSI)
    }

    private static func optionNames(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("-") else {
            return []
        }
        var options: [String] = []
        for word in trimmed.split(separator: " ") {
            let option = word.trimmingCharacters(in: CharacterSet(charactersIn: ","))
            if option.hasPrefix("-") {
                options.append(option)
            } else if !options.isEmpty {
                break
            }
        }
        return options
    }

    private static func replaceOptionNames(
        _ options: [String],
        in line: String,
        support: SupportLevel,
        useANSI: Bool
    ) -> String {
        var rendered = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index].isWhitespace {
                rendered.append(line[index])
                index = line.index(after: index)
                continue
            }

            let wordStart = index
            while index < line.endIndex, !line[index].isWhitespace {
                index = line.index(after: index)
            }

            let word = String(line[wordStart..<index])
            let option = word.trimmingCharacters(in: CharacterSet(charactersIn: ","))
            if options.contains(option) {
                rendered += styled(option, support: support, useANSI: useANSI)
                rendered += String(word.dropFirst(option.count))
            } else {
                rendered += word
            }
        }
        return rendered
    }

    private static func insertSupportLegend(into help: String, useANSI: Bool) -> String {
        let legend = [
            "Support:",
            styled("supported", support: .supported, useANSI: useANSI),
            "|",
            styled("partially supported", support: .partiallySupported, useANSI: useANSI),
            "|",
            styled("not supported", support: .notSupported, useANSI: useANSI),
        ].joined(separator: " ")
        if let range = help.range(of: "\n\nManagement Commands:") ?? help.range(of: "\n\nCommands:") {
            return String(help[..<range.lowerBound]) + "\n\n" + legend + String(help[range.lowerBound...])
        }
        return help + "\n\n" + legend
    }

    private static func insertSupportLine(
        into help: String,
        support: SupportLevel,
        detail: String?,
        useANSI: Bool
    ) -> String {
        var line = "\n\nSupport: \(styled(support.label, support: support, useANSI: useANSI))"
        if let detail {
            line += "\nLimitations: \(detail)"
        }
        if let range = help.range(of: "\n\nOptions:") {
            return String(help[..<range.lowerBound]) + line + String(help[range.lowerBound...])
        }
        return help + line
    }

    private static func supportLevel(for commandPath: [String]) -> SupportLevel? {
        supportByCommand[commandPath.joined(separator: " ")]
    }

    private static func commandPath(from key: String) -> [String] {
        key.isEmpty ? [] : key.split(separator: " ").map(String.init)
    }

    private static func supportLevel(forOptions options: [String], commandPath: [String]) -> SupportLevel {
        let commandKey = commandPath.joined(separator: " ")
        if let commandOptions = supportByOption[commandKey] {
            for option in options {
                if let support = commandOptions[option] {
                    return support
                }
            }
            return .notSupported
        }
        if let rootSupport = supportByOption[""]?.first(where: { key, _ in options.contains(key) })?.value {
            return rootSupport
        }
        return supportLevel(for: commandPath) ?? .partiallySupported
    }

    private static func styled(_ value: String, support: SupportLevel, useANSI: Bool) -> String {
        guard useANSI else {
            return value
        }
        return "\(support.color)\(value)\(resetColor)"
    }

    private static func commandPath(in arguments: [String]) -> [String] {
        var path: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                break
            }
            if commandNames.contains(argument) {
                path.append(argument)
                if argument == "bridge", arguments.indices.contains(index + 1) {
                    path.append(contentsOf: nestedCommandPath(
                        in: arguments,
                        startingAt: index + 1,
                        consumesNestedValue: { consumesBridgeValue($0) }
                    ))
                }
                if argument == "alpha", arguments.indices.contains(index + 1) {
                    path.append(contentsOf: nestedCommandPath(in: arguments, startingAt: index + 1))
                }
                break
            }
            if consumesGlobalValue(argument), !argument.contains("="), arguments.indices.contains(index + 1) {
                index += 2
            } else {
                index += 1
            }
        }
        return path
    }

    private static func nestedCommandPath(
        in arguments: [String],
        startingAt startIndex: Int,
        consumesNestedValue: (String) -> Bool = { _ in false }
    ) -> [String] {
        var path: [String] = []
        var index = startIndex
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" || argument == "help" {
                break
            }
            if isGlobalFlag(argument) {
                index += 1
                continue
            }
            if consumesGlobalValue(argument), !argument.contains("="), arguments.indices.contains(index + 1) {
                index += 2
                continue
            }
            if consumesGlobalValue(argument) {
                index += 1
                continue
            }
            if consumesNestedValue(argument), !argument.contains("="), arguments.indices.contains(index + 1) {
                index += 2
                continue
            }
            if consumesNestedValue(argument) {
                index += 1
                continue
            }
            if !argument.hasPrefix("-") {
                path.append(argument)
            }
            index += 1
        }
        return path
    }

    private static func consumesGlobalValue(_ argument: String) -> Bool {
        let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        return [
            "--ansi",
            "--env-file",
            "--file",
            "--parallel",
            "--profile",
            "--progress",
            "--project-directory",
            "--project-name",
            "-f",
            "-p",
        ].contains(name)
    }

    private static func isGlobalFlag(_ argument: String) -> Bool {
        [
            "--all-resources",
            "--compatibility",
            "--dry-run",
            "--verbose",
        ].contains(argument)
    }

    private static func consumesBridgeValue(_ argument: String) -> Bool {
        let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        return [
            "--format",
            "--from",
            "--output",
            "--templates",
            "--transformation",
            "-f",
            "-o",
            "-t",
        ].contains(name)
    }

    private static func nestedCommandHelp(for path: [String]) -> String? {
        var candidate = path
        while !candidate.isEmpty {
            let key = candidate.joined(separator: " ")
            if let help = bridgeCommandHelp[key] ?? alphaCommandHelp[key] {
                return help
            }
            candidate.removeLast()
        }
        return nil
    }

    private static let commandNames: Set<String> = [
        "alpha",
        "attach",
        "bridge",
        "build",
        "commit",
        "config",
        "convert",
        "cp",
        "create",
        "down",
        "events",
        "exec",
        "export",
        "images",
        "kill",
        "logs",
        "ls",
        "pause",
        "port",
        "ps",
        "publish",
        "pull",
        "push",
        "restart",
        "rm",
        "run",
        "scale",
        "start",
        "stats",
        "stop",
        "top",
        "unpause",
        "up",
        "version",
        "volumes",
        "wait",
        "watch",
    ]

    private static let rootHelp = """
    Usage:  container compose [OPTIONS] COMMAND

    Define and run multi-container applications with Docker

    Options:
          --all-resources              Include all resources, even those not used by services
          --ansi string                Control when to print ANSI control characters ("never"|"always"|"auto") (default "auto")
          --compatibility              Run compose in backward compatibility mode
          --dry-run                    Execute command in dry run mode
          --env-file stringArray       Specify an alternate environment file
      -f, --file stringArray           Compose configuration files
          --parallel int               Control max parallelism for image operations; -1 for unlimited
          --profile stringArray        Specify a profile to enable
          --progress string            Set type of progress output (auto, tty, plain, json, quiet)
          --project-directory string   Specify an alternate working directory
      -p, --project-name string        Project name
          --verbose                    Show more output

    Management Commands:
      alpha                   Experimental commands
      bridge                  Convert compose files into another model

    Commands:
      attach                  Attach local standard input, output, and error streams to a service's running container
      build                   Build or rebuild services
      commit                  Create a new image from a service container's changes
      config                  Parse, resolve and render compose file in canonical format
      convert                 Convert compose files to a normalized Compose model
      cp                      Copy files/folders between a service container and the local filesystem
      create                  Creates containers for a service
      down                    Stop and remove containers, networks
      events                  Receive real time events from containers
      exec                    Execute a command in a running container
      export                  Export a service container's filesystem as a tar archive
      help                    Help about any command
      images                  List images used by the created containers
      kill                    Force stop service containers
      logs                    View output from containers
      ls                      List running compose projects
      pause                   Pause services
      port                    Print the public port for a port binding
      ps                      List containers
      publish                 Publish compose application
      pull                    Pull service images
      push                    Push service images
      restart                 Restart service containers
      rm                      Removes stopped service containers
      run                     Run a one-off command on a service
      scale                   Scale services
      start                   Start services
      stats                   Display a live stream of container(s) resource usage statistics
      stop                    Stop services
      top                     Display the running processes
      unpause                 Unpause services
      up                      Create and start containers
      version                 Show the Docker Compose version information
      volumes                 List volumes
      wait                    Block until containers of all (or specified) services stop.
      watch                   Watch build context for service and rebuild/refresh containers when files are updated

    Run 'container compose COMMAND --help' for more information on a command.
    """

    private static let bridgeHelp = """
    Usage:  container compose bridge [OPTIONS] COMMAND

    Convert compose files into another model

    Options:
          --dry-run   Execute command in dry run mode

    Management Commands:
      transformations Manage transformation images

    Commands:
      convert         Convert compose files to Kubernetes manifests, Helm charts, or another model

    Run 'container compose bridge COMMAND --help' for more information on a command.
    """

    private static let bridgeCommandHelp: [String: String] = [
        "bridge convert": """
        Usage:  container compose bridge convert

        Convert compose files to Kubernetes manifests, Helm charts, or another model

        Options:
              --dry-run                      Execute command in dry run mode
          -o, --output string                The output directory for the
                                             Kubernetes resources (default "out")
              --templates string             Directory containing transformation
                                             templates
          -t, --transformation stringArray   Transformation to apply to compose
                                             model (default:
                                             docker/compose-bridge-kubernetes)
        """,
        "bridge transformations": """
        Usage:  container compose bridge transformations [OPTIONS] COMMAND

        Manage transformation images

        Options:
              --dry-run   Execute command in dry run mode

        Commands:
          create      Create a new transformation
          list        List available transformations

        Run 'container compose bridge transformations COMMAND --help' for more information on a command.
        """,
        "bridge transformations create": """
        Usage:  container compose bridge transformations create [OPTION] PATH

        Create a new transformation

        Options:
              --dry-run       Execute command in dry run mode
          -f, --from string   Existing transformation to copy (default:
                              docker/compose-bridge-kubernetes)
        """,
        "bridge transformations list": """
        Usage:  container compose bridge transformations list

        List available transformations

        Aliases:
          container compose bridge transformations list, container compose bridge transformations ls

        Options:
              --dry-run         Execute command in dry run mode
              --format string   Format the output. Values: [table | json]
                                (default "table")
          -q, --quiet           Only display transformer names
        """,
        "bridge transformations ls": """
        Usage:  container compose bridge transformations list

        List available transformations

        Aliases:
          container compose bridge transformations list, container compose bridge transformations ls

        Options:
              --dry-run         Execute command in dry run mode
              --format string   Format the output. Values: [table | json]
                                (default "table")
          -q, --quiet           Only display transformer names
        """,
    ]

    private static let alphaCommandHelp: [String: String] = [
        "alpha dry-run": """
        Usage:  container compose alpha dry-run [OPTIONS] -- COMMAND [ARGS...]

        Execute a command in dry run mode

        Options:
              --dry-run   Execute command in dry run mode
        """,
        "alpha scale": """
        Usage:  container compose alpha scale [OPTIONS] SERVICE=REPLICAS...

        Scale services

        Options:
              --dry-run   Execute command in dry run mode
              --no-deps   Don't start linked services
        """,
        "alpha watch": """
        Usage:  container compose alpha watch [OPTIONS] [SERVICE...]

        Watch build context and service files

        Options:
              --dry-run   Execute command in dry run mode
              --no-up     Do not build and start services before watching
              --quiet     Hide build output
        """,
    ]

    private static let commandHelp: [String: String] = [
        "alpha": """
        Usage:  container compose alpha [OPTIONS] COMMAND

        Experimental commands

        Options:
              --dry-run   Execute command in dry run mode

        Commands:
          dry-run     Execute a command in dry run mode
          scale       Scale services
          watch       Watch build context and service files

        Run 'container compose alpha COMMAND --help' for more information on a command.
        """,
        "attach": """
        Usage:  container compose attach [OPTIONS] SERVICE

        Attach local standard input, output, and error streams to a service's running container

        Options:
              --detach-keys string   Override the key sequence for detaching from a container. Ignored with --no-stdin output-only attach.
              --dry-run              Execute command in dry run mode
              --index int            index of the container if service has multiple replicas.
              --no-stdin             Do not attach STDIN
              --sig-proxy            Proxy all received signals to the process (default true)
        """,
        "build": """
        Usage:  container compose build [OPTIONS] [SERVICE...]

        Build or rebuild services

        Options:
              --build-arg stringArray   Set build-time variables for services
              --builder string          Set builder to use
              --check                   Check build configuration
              --dry-run                 Execute command in dry run mode
          -m, --memory bytes            Set memory limit for the build container. Not supported by BuildKit.
              --no-cache                Do not use cache when building the image
              --print                   Print equivalent bake file
              --provenance string       Add a provenance attestation. Use --provenance=false to explicitly disable.
              --pull                    Always attempt to pull a newer version of the image
              --push                    Push service images
          -q, --quiet                   Suppress the build output
              --sbom string             Add a SBOM attestation. Use --sbom=false to explicitly disable.
              --ssh string              Set SSH authentications used when building service images. (use 'default' for using your default SSH Agent)
              --with-dependencies       Also build dependencies (transitively)
        """,
        "commit": """
        Usage:  container compose commit [OPTIONS] SERVICE [REPOSITORY[:TAG]]

        Create a new image from a service container's changes

        Options:
          -a, --author string    Author
          -c, --change list      Apply Dockerfile instruction to the created image
              --dry-run          Execute command in dry run mode
              --index int        index of the container if service has multiple replicas.
          -m, --message string   Commit message
          -p, --pause            Use a filesystem-consistent snapshot for a running container (default true). This briefly freezes its filesystem; --pause=false is unavailable.
        """,
        "config": """
        Usage:  container compose config [OPTIONS] [SERVICE...]

        Parse, resolve and render compose file in canonical format

        Options:
              --dry-run                 Execute command in dry run mode
              --environment             Print environment used for interpolation.
              --format string           Format the output. Values: [yaml | json]
              --hash string             Print the service config hash, one per line.
              --images                  Print the image names, one per line.
              --lock-image-digests      Produces an override file with image digests
              --models                  Print the model names, one per line.
              --networks                Print the network names, one per line.
              --no-consistency          Don't check model consistency
              --no-env-resolution       Don't resolve service env files
              --no-interpolate          Don't interpolate environment variables
              --no-normalize            Don't normalize compose model
              --no-path-resolution      Don't resolve file paths
          -o, --output string           Save to file
              --profiles                Print the profile names, one per line.
          -q, --quiet                   Only validate the configuration
              --resolve-image-digests   Pin image tags to digests
              --services                Print the service names, one per line.
              --variables               Print model variables and default values.
              --volumes                 Print the volume names, one per line.
        """,
        "convert": """
        Usage:  container compose convert [OPTIONS] [SERVICE...]

        Convert compose files to a normalized Compose model

        Options:
              --dry-run                 Execute command in dry run mode
              --format string           Format the output. Values: [yaml | json]
              --hash string             Print the service config hash, one per line.
              --images                  Print the image names, one per line.
              --no-consistency          Don't check model consistency
              --no-interpolate          Don't interpolate environment variables
              --no-normalize            Don't normalize compose model
          -o, --output string           Save to file
              --profiles                Print the profile names, one per line.
          -q, --quiet                   Only validate the configuration
              --resolve-image-digests   Pin image tags to digests
              --services                Print the service names, one per line.
              --volumes                 Print the volume names, one per line.
        """,
        "cp": """
        Usage:  container compose cp [OPTIONS] SERVICE:SRC_PATH DEST_PATH
                container compose cp [OPTIONS] SRC_PATH SERVICE:DEST_PATH

        Copy files/folders between a service container and the local filesystem

        Options:
              --all           Include containers created by the run command
          -a, --archive       Archive mode (copy all uid/gid information)
              --dry-run       Execute command in dry run mode
          -L, --follow-link   Always follow symbol link in SRC_PATH
              --index int     Index of the container if service has multiple replicas
        """,
        "create": """
        Usage:  container compose create [OPTIONS] [SERVICE...]

        Creates containers for a service

        Options:
              --build            Build images before starting containers
              --dry-run          Execute command in dry run mode
              --force-recreate   Recreate containers even if their configuration and image haven't changed
              --no-build         Don't build an image, even if it's policy
              --no-recreate      If containers already exist, don't recreate them. Incompatible with --force-recreate.
              --pull string      Pull image before running ("always"|"missing"|"never"|"build") (default "policy")
              --quiet-pull       Pull without printing progress information
              --remove-orphans   Remove containers for services not defined in the Compose file
              --scale scale      Scale SERVICE to NUM instances. Overrides the scale setting in the Compose file if present.
          -y, --yes              Assume "yes" as answer to all prompts and run non-interactively
        """,
        "down": """
        Usage:  container compose down [OPTIONS] [SERVICES]

        Stop and remove containers, networks

        Options:
              --dry-run          Execute command in dry run mode
              --remove-orphans   Remove containers for services not defined in the Compose file
              --rmi string       Remove images used by services. ("local"|"all")
          -t, --timeout int      Specify a shutdown timeout in seconds
          -v, --volumes          Remove named volumes declared in the "volumes" section of the Compose file and anonymous volumes attached to containers
        """,
        "events": """
        Usage:  container compose events [OPTIONS] [SERVICE...]

        Receive real time events from containers

        Options:
              --dry-run        Execute command in dry run mode
              --json           Output events as a stream of json objects
              --since string   Show all events created since timestamp
              --until string   Stream events until this timestamp
        """,
        "exec": """
        Usage:  container compose exec [OPTIONS] SERVICE COMMAND [ARGS...]

        Execute a command in a running container

        Options:
          -d, --detach            Detached mode: Run command in the background
              --dry-run           Execute command in dry run mode
          -e, --env stringArray   Set environment variables
              --index int         Index of the container if service has multiple replicas
          -T, --no-tty            Disable pseudo-TTY allocation
              --privileged        Give extended privileges to the process
          -u, --user string       Run the command as this user
          -w, --workdir string    Path to workdir directory for this command
        """,
        "export": """
        Usage:  container compose export [OPTIONS] SERVICE

        Export a service container's filesystem as a tar archive

        Options:
              --dry-run         Execute command in dry run mode
              --index int       index of the container if service has multiple replicas.
          -o, --output string   Write to a file, instead of STDOUT
        """,
        "images": """
        Usage:  container compose images [OPTIONS] [SERVICE...]

        List images used by the created containers

        Options:
              --dry-run         Execute command in dry run mode
              --format string   Format the output. Values: [table | json] (default "table")
          -q, --quiet           Only display IDs
        """,
        "kill": """
        Usage:  container compose kill [OPTIONS] [SERVICE...]

        Force stop service containers

        Options:
              --dry-run          Execute command in dry run mode
              --remove-orphans   Remove containers for services not defined in the Compose file
          -s, --signal string    SIGNAL to send to the container (default "SIGKILL")
        """,
        "logs": """
        Usage:  container compose logs [OPTIONS] [SERVICE...]

        View output from containers

        Options:
              --dry-run         Execute command in dry run mode
          -f, --follow          Follow log output
              --index int       index of the container if service has multiple replicas
              --no-color        Produce monochrome output
              --no-log-prefix   Don't print prefix in logs
              --since string    Show logs since timestamp or relative duration
          -n, --tail string     Number of lines to show from the end of the logs for each container (default "all")
          -t, --timestamps      Show timestamps
              --until string    Show logs before a timestamp or relative duration
        """,
        "ls": """
        Usage:  container compose ls [OPTIONS]

        List running compose projects

        Options:
          -a, --all             Show all stopped Compose projects
              --dry-run         Execute command in dry run mode
              --filter filter   Filter output based on conditions provided
              --format string   Format the output. Values: [table | json] (default "table")
          -q, --quiet           Only display project names
        """,
        "pause": """
        Usage:  container compose pause [SERVICE...]

        Pause services

        Options:
              --dry-run   Execute command in dry run mode
        """,
        "port": """
        Usage:  container compose port [OPTIONS] SERVICE PRIVATE_PORT

        Print the public port for a port binding

        Options:
              --dry-run           Execute command in dry run mode
              --index int         Index of the container if service has multiple replicas
              --protocol string   tcp or udp (default "tcp")
        """,
        "ps": """
        Usage:  container compose ps [OPTIONS] [SERVICE...]

        List containers

        Options:
          -a, --all                  Show all stopped containers
              --dry-run              Execute command in dry run mode
              --filter string        Filter services by a property (supported filters: status)
              --format string        Format output using a custom template (default "table")
              --no-trunc             Don't truncate output
              --orphans              Include orphaned services (default true)
          -q, --quiet                Only display IDs
              --services             Display services
              --status stringArray   Filter services by status
        """,
        "publish": """
        Usage:  container compose publish [OPTIONS] REPOSITORY[:TAG]

        Publish compose application

        Options:
              --app                     Published compose application
              --dry-run                 Execute command in dry run mode
              --oci-version string      OCI image/artifact specification version
              --resolve-image-digests   Pin image tags to digests
              --with-env                Include environment variables in the published OCI artifact
          -y, --yes                     Assume "yes" as answer to all prompts
        """,
        "pull": """
        Usage:  container compose pull [OPTIONS] [SERVICE...]

        Pull service images

        Options:
              --dry-run                Execute command in dry run mode
              --ignore-buildable       Ignore images that can be built
              --ignore-pull-failures   Pull what it can and ignores images with pull failures
              --include-deps           Also pull services declared as dependencies
              --policy string          Apply pull policy ("missing"|"always")
          -q, --quiet                  Pull without printing progress information
        """,
        "push": """
        Usage:  container compose push [OPTIONS] [SERVICE...]

        Push service images

        Options:
              --dry-run                Execute command in dry run mode
              --ignore-push-failures   Push what it can and ignores images with push failures
              --include-deps           Also push images of services declared as dependencies
          -q, --quiet                  Push without printing progress information
        """,
        "restart": """
        Usage:  container compose restart [OPTIONS] [SERVICE...]

        Restart service containers

        Options:
              --dry-run       Execute command in dry run mode
              --no-deps       Don't restart dependent services
          -t, --timeout int   Specify a shutdown timeout in seconds
        """,
        "rm": """
        Usage:  container compose rm [OPTIONS] [SERVICE...]

        Removes stopped service containers

        Options:
              --dry-run   Execute command in dry run mode
          -f, --force     Don't ask to confirm removal
          -s, --stop      Stop the containers, if required, before removing
          -v, --volumes   Remove any anonymous volumes attached to containers
        """,
        "run": """
        Usage:  container compose run [OPTIONS] SERVICE [COMMAND] [ARGS...]

        Run a one-off command on a service

        Options:
              --build                       Build image before starting container
              --cap-add list                Add Linux capabilities
              --cap-drop list               Drop Linux capabilities
          -d, --detach                      Run container in background and print container ID
              --dry-run                     Execute command in dry run mode
              --entrypoint string           Override the entrypoint of the image
          -e, --env stringArray             Set environment variables
              --env-from-file stringArray   Set environment variables from file
          -i, --interactive                 Keep STDIN open even if not attached (default true)
          -l, --label stringArray           Add or override a label
              --name string                 Assign a name to the container
          -T, --no-tty                      Disable pseudo-TTY allocation (default true)
              --no-deps                     Don't start linked services
          -p, --publish stringArray         Publish a container's port(s) to the host
              --pull string                 Pull image before running ("always"|"missing"|"never") (default "policy")
          -q, --quiet                       Don't print anything to STDOUT
              --quiet-build                 Suppress progress output from the build process
              --quiet-pull                  Pull without printing progress information
              --remove-orphans              Remove containers for services not defined in the Compose file
              --rm                          Automatically remove the container when it exits
          -P, --service-ports               Run command with all service's ports enabled and mapped to the host
              --use-aliases                 Use the service's network aliases (requires container-facing DNS)
          -u, --user string                 Run as specified username or uid
          -v, --volume stringArray          Bind mount a volume
          -w, --workdir string              Working directory inside the container
        """,
        "scale": """
        Usage:  container compose scale [SERVICE=REPLICAS...]

        Scale services

        Options:
              --dry-run   Execute command in dry run mode
              --no-deps   Don't start linked services
        """,
        "start": """
        Usage:  container compose start [SERVICE...]

        Start services

        Options:
              --dry-run            Execute command in dry run mode
              --wait               Wait for services to be running|healthy. Implies detached mode.
              --wait-timeout int   Maximum duration in seconds to wait for the project to be running|healthy
        """,
        "stats": """
        Usage:  container compose stats [OPTIONS] [SERVICE]

        Display a live stream of container(s) resource usage statistics

        Options:
          -a, --all             Show all containers (default shows just running)
              --dry-run         Execute command in dry run mode
              --format string   Format output using a custom template
              --no-stream       Disable streaming stats and only pull the first result
              --no-trunc        Do not truncate output
        """,
        "stop": """
        Usage:  container compose stop [OPTIONS] [SERVICE...]

        Stop services

        Options:
              --dry-run       Execute command in dry run mode
          -t, --timeout int   Specify a shutdown timeout in seconds
        """,
        "top": """
        Usage:  container compose top [SERVICES...]

        Display the running processes

        Options:
              --dry-run   Execute command in dry run mode
        """,
        "unpause": """
        Usage:  container compose unpause [SERVICE...]

        Unpause services

        Options:
              --dry-run   Execute command in dry run mode
        """,
        "up": """
        Usage:  container compose up [OPTIONS] [SERVICE...]

        Create and start containers

        Options:
              --abort-on-container-exit      Stops all containers if any container was stopped. Incompatible with -d
              --abort-on-container-failure   Stops all containers if any container exited with failure. Incompatible with -d
              --always-recreate-deps         Recreate dependent containers. Incompatible with --no-recreate.
              --attach stringArray           Restrict attaching to the specified services
              --attach-dependencies          Automatically attach to log output of dependent services
              --build                        Build images before starting containers
          -d, --detach                       Detached mode: Run containers in the background
              --dry-run                      Execute command in dry run mode
              --exit-code-from string        Return the exit code of the selected service container
              --force-recreate               Recreate containers even if their configuration and image haven't changed
              --menu                         Enable interactive shortcuts when running attached. Use --menu=false to explicitly disable the helper menu.
              --no-attach stringArray        Do not attach to the specified services
              --no-build                     Don't build an image, even if it's policy
              --no-color                     Produce monochrome output
              --no-deps                      Don't start linked services
              --no-log-prefix                Don't print prefix in logs
              --no-recreate                  If containers already exist, don't recreate them
              --no-start                     Don't start the services after creating them
              --pull string                  Pull image before running ("always"|"missing"|"never") (default "policy")
              --quiet-build                  Suppress the build output
              --quiet-pull                   Pull without printing progress information
              --remove-orphans               Remove containers for services not defined in the Compose file
          -V, --renew-anon-volumes           Recreate anonymous volumes instead of retrieving data from previous containers
              --scale scale                  Scale SERVICE to NUM instances
          -t, --timeout int                  Use this timeout in seconds for container shutdown
              --timestamps                   Show timestamps
              --wait                         Wait for services to be running|healthy. Implies detached mode.
              --wait-timeout int             Maximum duration in seconds to wait for the project to be running|healthy
          -w, --watch                        Watch source code and rebuild/refresh containers when files are updated
          -y, --yes                          Assume "yes" as answer to all prompts and run non-interactively
        """,
        "version": """
        Usage:  container compose version [OPTIONS]

        Show the Docker Compose version information

        Options:
              --dry-run         Execute command in dry run mode
          -f, --format string   Format the output. Values: [pretty | json]. (Default: pretty)
              --short           Shows only Compose's version number
        """,
        "volumes": """
        Usage:  container compose volumes [OPTIONS] [SERVICE...]

        List volumes

        Options:
              --dry-run         Execute command in dry run mode
              --format string   Format output using a custom template (default "table")
          -q, --quiet           Only display volume names
        """,
        "wait": """
        Usage:  container compose wait SERVICE [SERVICE...] [OPTIONS]

        Block until containers of all (or specified) services stop.

        Options:
              --down-project   Drops project when the first container stops
              --dry-run        Execute command in dry run mode
        """,
        "watch": """
        Usage:  container compose watch [SERVICE...]

        Watch build context for service and rebuild/refresh containers when files are updated

        Options:
              --dry-run   Execute command in dry run mode
              --no-up     Do not build & start services before watching
              --prune     Prune dangling images on rebuild (default true)
              --quiet     hide build output
        """,
    ]
}
