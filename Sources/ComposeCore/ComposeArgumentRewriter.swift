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

/// Rewrites Docker Compose style root options into the position expected by
/// Swift Argument Parser subcommands.
public enum ComposeArgumentRewriter {
    /// Whether a known root option consumes a following value.
    private enum OptionKind {
        case flag
        case value
    }

    private static let subcommands: Set<String> = [
        "build",
        "config",
        "cp",
        "create",
        "down",
        "events",
        "exec",
        "images",
        "kill",
        "ls",
        "logs",
        "pause",
        "port",
        "ps",
        "pull",
        "push",
        "restart",
        "rm",
        "run",
        "start",
        "stop",
        "top",
        "unpause",
        "up",
        "version",
        "wait",
    ]

    private static let globalOptions: [String: OptionKind] = [
        "--ansi": .value,
        "--dry-run": .flag,
        "--env-file": .value,
        "--file": .value,
        "--profile": .value,
        "--progress": .value,
        "--project-directory": .value,
        "--project-name": .value,
        "--verbose": .flag,
        "-f": .value,
        "-p": .value,
    ]

    /// Returns arguments with known Compose global options moved immediately
    /// after the subcommand while preserving unknown pre-command arguments.
    public static func rewrite(_ arguments: [String]) -> [String] {
        guard let commandIndex = commandIndex(in: arguments) else {
            return arguments
        }

        let prefix = Array(arguments[..<commandIndex])
        let command = arguments[commandIndex]
        let suffix = rewriteCommandLocalOptions(
            command: command,
            arguments: Array(arguments[arguments.index(after: commandIndex)...])
        )
        let split = splitGlobalOptions(prefix)
        return split.retained + [command] + split.moved + suffix
    }

    /// Locates the first subcommand while skipping values for root options.
    private static func commandIndex(in arguments: [String]) -> Array<String>.Index? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" {
                return nil
            }
            if subcommands.contains(argument) {
                return index
            }

            guard let kind = globalOptionKind(argument) else {
                index = arguments.index(after: index)
                continue
            }

            index = arguments.index(after: index)
            if kind == .value, !argument.contains("="), index < arguments.endIndex {
                index = arguments.index(after: index)
            }
        }
        return nil
    }

    /// Splits root options into parser-retained and subcommand-local groups.
    private static func splitGlobalOptions(_ arguments: [String]) -> (retained: [String], moved: [String]) {
        var retained: [String] = []
        var moved: [String] = []
        var index = 0

        // Docker Compose accepts global options before the subcommand. Argument
        // Parser models them on each subcommand, so known root options move
        // after the subcommand and unknown options stay where the parser can
        // report them accurately.
        while index < arguments.count {
            let argument = arguments[index]
            guard let kind = globalOptionKind(argument) else {
                retained.append(argument)
                index += 1
                continue
            }

            moved.append(argument)
            index += 1

            if kind == .value, !argument.contains("="), index < arguments.count {
                moved.append(arguments[index])
                index += 1
            }
        }

        return (retained, moved)
    }

    /// Looks up a known global option, including `--option=value` forms.
    private static func globalOptionKind(_ argument: String) -> OptionKind? {
        if let kind = globalOptions[argument] {
            return kind
        }
        guard let equalsIndex = argument.firstIndex(of: "=") else {
            return nil
        }
        return globalOptions[String(argument[..<equalsIndex])]
    }

    /// Normalizes command-specific aliases that conflict with global options.
    private static func rewriteCommandLocalOptions(command: String, arguments: [String]) -> [String] {
        switch command {
        case "exec":
            return rewriteExecOptions(arguments)
        case "logs":
            return rewriteLogsOptions(arguments)
        case "rm":
            return rewriteRemoveOptions(arguments)
        case "run":
            return rewriteRunOptions(arguments)
        default:
            return arguments
        }
    }

    /// Normalizes Docker Compose `exec` boolean option value forms.
    private static func rewriteExecOptions(_ arguments: [String]) -> [String] {
        var rewritten: [String] = []
        var shouldRewriteOptions = true
        for argument in arguments {
            if shouldRewriteOptions, argument == "--" {
                shouldRewriteOptions = false
                rewritten.append(argument)
            } else if shouldRewriteOptions, argument == "--interactive=false" {
                rewritten.append("--no-interactive")
            } else if shouldRewriteOptions, argument == "--interactive=true" {
                rewritten.append("--interactive")
            } else if shouldRewriteOptions, argument == "--tty=false" {
                rewritten.append("--no-tty")
            } else if shouldRewriteOptions, argument == "--tty=true" {
                rewritten.append("--tty")
            } else {
                rewritten.append(argument)
            }
        }
        return rewritten
    }

    /// Normalizes Docker Compose `logs` shorthand options.
    private static func rewriteLogsOptions(_ arguments: [String]) -> [String] {
        var rewritten: [String] = []
        var shouldRewriteOptions = true
        for argument in arguments {
            if shouldRewriteOptions, argument == "--" {
                shouldRewriteOptions = false
                rewritten.append(argument)
            } else if shouldRewriteOptions, argument == "-f" {
                // The parser also accepts global `-f/--file`, so normalize the
                // Docker Compose `logs -f` alias before validation sees the
                // command-local option.
                rewritten.append("--follow")
            } else {
                rewritten.append(argument)
            }
        }
        return rewritten
    }

    /// Normalizes Docker Compose `rm` shorthand options.
    private static func rewriteRemoveOptions(_ arguments: [String]) -> [String] {
        var rewritten: [String] = []
        var shouldRewriteOptions = true
        for argument in arguments {
            if shouldRewriteOptions, argument == "--" {
                shouldRewriteOptions = false
                rewritten.append(argument)
            } else if shouldRewriteOptions, argument == "-f" {
                rewritten.append("--force")
            } else if shouldRewriteOptions, argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.contains("f") {
                rewritten.append(contentsOf: rewriteGroupedRemoveShortOptions(argument))
            } else {
                rewritten.append(argument)
            }
        }
        return rewritten
    }

    /// Splits grouped `rm` short flags while rewriting `f` to `--force`.
    private static func rewriteGroupedRemoveShortOptions(_ argument: String) -> [String] {
        let flags = argument.dropFirst()
        guard flags.count > 1 else {
            return [argument]
        }
        return flags.map { flag in
            flag == "f" ? "--force" : "-\(flag)"
        }
    }

    /// Normalizes Docker Compose `run -p` before the service name.
    private static func rewriteRunOptions(_ arguments: [String]) -> [String] {
        var rewritten: [String] = []
        var index = 0
        var shouldRewriteOptions = true
        while index < arguments.count {
            let argument = arguments[index]
            if !shouldRewriteOptions {
                rewritten.append(argument)
                index += 1
            } else if argument == "--" {
                shouldRewriteOptions = false
                rewritten.append(argument)
                index += 1
            } else if argument == "-p" {
                rewritten.append("--publish")
                if arguments.indices.contains(index + 1) {
                    rewritten.append(arguments[index + 1])
                    index += 2
                } else {
                    index += 1
                }
            } else if argument.hasPrefix("-p"), argument.count > 2 {
                rewritten.append("--publish")
                rewritten.append(String(argument.dropFirst(2)))
                index += 1
            } else if optionConsumesFollowingValue(argument), arguments.indices.contains(index + 1) {
                rewritten.append(argument)
                rewritten.append(arguments[index + 1])
                index += 2
            } else {
                if !argument.hasPrefix("-") {
                    shouldRewriteOptions = false
                }
                rewritten.append(argument)
                index += 1
            }
        }
        return rewritten
    }

    /// Returns whether a `run` option consumes the following argument.
    private static func runOptionConsumesValue(_ argument: String) -> Bool {
        [
            "--entrypoint",
            "--env",
            "--env-from-file",
            "--label",
            "--name",
            "--publish",
            "--pull",
            "--user",
            "--volume",
            "--workdir",
            "-e",
            "-l",
            "-u",
            "-v",
            "-w",
        ].contains(argument)
    }

    /// Returns whether any known command-local or global option consumes a value.
    private static func optionConsumesFollowingValue(_ argument: String) -> Bool {
        if runOptionConsumesValue(argument) {
            return true
        }
        guard let kind = globalOptionKind(argument) else {
            return false
        }
        return kind == .value && !argument.contains("=")
    }
}
