import Foundation

public struct ComposeNormalizer: Sendable {
    private let runner: CommandRunning

    public init(runner: CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func normalize(options: ComposeOptions) async throws -> ComposeProject {
        let invocation = try Self.normalizerInvocation()
        var arguments = invocation.prefixArguments

        for file in options.files {
            arguments.append(contentsOf: ["--file", file])
        }
        for profile in options.profiles {
            arguments.append(contentsOf: ["--profile", profile])
        }
        for envFile in options.envFiles {
            arguments.append(contentsOf: ["--env-file", envFile])
        }
        if let projectName = options.projectName {
            arguments.append(contentsOf: ["--project-name", projectName])
        }
        if let projectDirectory = options.projectDirectory {
            arguments.append(contentsOf: ["--project-directory", projectDirectory])
        }

        let result = try await runner.run(
            invocation.executable,
            arguments,
            workingDirectory: invocation.workingDirectory
        )
        guard result.succeeded else {
            throw ComposeError.commandFailed(
                command: ([invocation.executable] + arguments).joined(separator: " "),
                status: result.status,
                stderr: result.stderr
            )
        }

        let data = Data(result.stdout.utf8)
        do {
            return try JSONDecoder().decode(ComposeProject.self, from: data)
        } catch {
            throw ComposeError.invalidProject("failed to decode normalized compose JSON: \(error)")
        }
    }
}

private struct NormalizerInvocation {
    var executable: String
    var prefixArguments: [String]
    var workingDirectory: URL?
}

private extension ComposeNormalizer {
    static func normalizerInvocation() throws -> NormalizerInvocation {
        if let explicit = ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_NORMALIZER"], !explicit.isEmpty {
            return NormalizerInvocation(executable: explicit, prefixArguments: [], workingDirectory: nil)
        }

        if let installed = installedNormalizerURL(), FileManager.default.isExecutableFile(atPath: installed.path) {
            return NormalizerInvocation(executable: installed.path, prefixArguments: [], workingDirectory: nil)
        }

        let sourceURL = packageRootURL()
            .appendingPathComponent("Tools")
            .appendingPathComponent("compose-normalizer")
        if FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent("go.mod").path) {
            return NormalizerInvocation(executable: "/usr/bin/env", prefixArguments: ["go", "run", "."], workingDirectory: sourceURL)
        }

        throw ComposeError.missingNormalizer(
            "set CONTAINER_COMPOSE_NORMALIZER or install resources/compose-normalizer next to the plugin"
        )
    }

    static func installedNormalizerURL() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        return executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("resources")
            .appendingPathComponent("compose-normalizer")
    }

    static func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
