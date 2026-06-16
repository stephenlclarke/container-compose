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
        "-v": .flag,
    ]

    public static func rewrite(_ arguments: [String]) -> [String] {
        guard let commandIndex = arguments.firstIndex(where: { subcommands.contains($0) }) else {
            return arguments
        }

        let prefix = Array(arguments[..<commandIndex])
        let command = arguments[commandIndex]
        let suffix = Array(arguments[arguments.index(after: commandIndex)...])
        let split = splitGlobalOptions(prefix)
        return split.retained + [command] + split.moved + suffix
    }

    private static func splitGlobalOptions(_ arguments: [String]) -> (retained: [String], moved: [String]) {
        var retained: [String] = []
        var moved: [String] = []
        var index = 0

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
}
