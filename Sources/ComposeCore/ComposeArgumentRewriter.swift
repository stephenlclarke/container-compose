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
    private enum OptionKind {
        case flag
        case value
    }

    private static let subcommands: Set<String> = [
        "build",
        "config",
        "cp",
        "down",
        "events",
        "exec",
        "images",
        "kill",
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
        guard let commandIndex = arguments.firstIndex(where: { subcommands.contains($0) }) else {
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

    private static func globalOptionKind(_ argument: String) -> OptionKind? {
        if let kind = globalOptions[argument] {
            return kind
        }
        guard let equalsIndex = argument.firstIndex(of: "=") else {
            return nil
        }
        return globalOptions[String(argument[..<equalsIndex])]
    }

    private static func rewriteCommandLocalOptions(command: String, arguments: [String]) -> [String] {
        guard command == "logs" else {
            return arguments
        }

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
}
