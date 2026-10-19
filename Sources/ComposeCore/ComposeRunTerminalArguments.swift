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

/// Preserves flag presence and values before ArgumentParser consumes `run` options.
/// Guest command boundaries and separate option values remain owned by the caller.
enum ComposeRunTerminalArguments {
    struct Normalized {
        let arguments: [String]
        var consumesFollowingValue = false
    }

    private static let names = [
        "--interactive": "--interactive", "--tty": "--tty",
        "--no-tty": "--no-tty", "--no-TTY": "--no-tty",
    ]
    private static let shortBooleans: [Character: String] = [
        "i": "--interactive", "t": "--tty", "T": "--no-tty",
    ]
    private static let shortValues: [Character: String] = [
        "e": "--env", "l": "--label", "u": "--user", "v": "--volume",
        "w": "--workdir", "p": "--publish", "f": "--file",
    ]

    static func normalize(_ argument: String) -> Normalized? {
        let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if let name = names[String(parts[0])] {
            return Normalized(arguments: [name + "=" + boolean(parts.count == 2 ? String(parts[1]) : "true")])
        }
        if argument == "--no-interactive" {
            return Normalized(arguments: ["--interactive=false"])
        }
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1 else {
            return nil
        }
        return normalizeShortOptions(argument.dropFirst())
    }

    private static func normalizeShortOptions(_ options: Substring) -> Normalized? {
        var remaining = options
        var result: [String] = []
        var hasTerminalFlag = false
        while let option = remaining.first {
            remaining = remaining.dropFirst()
            if let name = shortBooleans[option] {
                hasTerminalFlag = true
                if remaining.first == "=" {
                    result.append(name + "=" + boolean(String(remaining.dropFirst())))
                    return Normalized(arguments: result)
                }
                result.append(name + "=true")
            } else if let name = shortValues[option] {
                // Leave unrelated options to the existing rewriter. Attached
                // values are data, even when they look like another option.
                guard hasTerminalFlag else { return nil }
                if remaining.isEmpty {
                    return Normalized(arguments: result + [name], consumesFollowingValue: true)
                }
                let value = remaining.first == "=" ? remaining.dropFirst() : remaining
                return Normalized(arguments: result + [name + "=" + value])
            } else if "dqP".contains(option) {
                result.append("-" + String(option))
                if remaining.first == "=" {
                    guard hasTerminalFlag else { return nil }
                    result[result.count - 1] += remaining
                    return Normalized(arguments: result)
                }
            } else {
                return nil
            }
        }
        return hasTerminalFlag ? Normalized(arguments: result) : nil
    }

    private static func boolean(_ value: String) -> String {
        switch value {
        case "true", "True", "TRUE", "t", "T", "1": "true"
        case "false", "False", "FALSE", "f", "F", "0": "false"
        default: value // Retain malformed input for the parser's error path.
        }
    }
}
