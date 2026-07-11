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

import Foundation

/// Loads Compose files through the compose-go helper and decodes canonical JSON.
public struct ComposeNormalizer: Sendable {
    public static let defaultFallbackLauncher = ["", "usr", "bin", "env"].joined(separator: "/")

    private let runner: CommandRunning
    private let fallbackLauncher: String

    public init(
        runner: CommandRunning = ProcessRunner(),
        fallbackLauncher: String = ComposeNormalizer.defaultFallbackLauncher,
    ) {
        self.runner = runner
        self.fallbackLauncher = fallbackLauncher
    }

    /// Normalizes Compose input options into the Swift orchestration model.
    public func normalize(options: ComposeOptions) async throws -> ComposeProject {
        let invocation = try Self.normalizerInvocation(fallbackLauncher: fallbackLauncher)
        let arguments = Self.normalizerArguments(invocation: invocation, options: options)

        let result = try await runner.run(
            invocation.executable,
            arguments,
            workingDirectory: invocation.workingDirectory,
        )
        guard result.succeeded else {
            throw Self.normalizerFailure(invocation: invocation, arguments: arguments, result: result)
        }

        let data = Data(result.stdout.utf8)
        do {
            return try JSONDecoder().decode(ComposeProject.self, from: data)
        } catch {
            throw ComposeError.invalidProject("failed to decode normalized compose JSON: \(error)")
        }
    }

    /// Loads the runtime projection and compose-go's public Bridge model in one pass.
    public func bridgeProject(options: ComposeOptions) async throws -> ComposeBridgeProject {
        let invocation = try Self.normalizerInvocation(fallbackLauncher: fallbackLauncher)
        let arguments = Self.normalizerArguments(
            invocation: invocation,
            options: options,
            modeArguments: ["--bridge-model"],
        )

        let result = try await runner.run(
            invocation.executable,
            arguments,
            workingDirectory: invocation.workingDirectory,
        )
        guard result.succeeded else {
            throw Self.normalizerFailure(invocation: invocation, arguments: arguments, result: result)
        }

        let data = Data(result.stdout.utf8)
        do {
            return try JSONDecoder().decode(ComposeBridgeProject.self, from: data)
        } catch {
            throw ComposeError.invalidProject("failed to decode Compose Bridge model JSON: \(error)")
        }
    }

    /// Returns the interpolation variables declared by the Compose model.
    public func variables(options: ComposeOptions) async throws -> [ComposeVariable] {
        let invocation = try Self.normalizerInvocation(fallbackLauncher: fallbackLauncher)
        let arguments = Self.normalizerArguments(
            invocation: invocation,
            options: options,
            modeArguments: ["--variables"],
        )

        let result = try await runner.run(
            invocation.executable,
            arguments,
            workingDirectory: invocation.workingDirectory,
        )
        guard result.succeeded else {
            throw Self.normalizerFailure(invocation: invocation, arguments: arguments, result: result)
        }

        let data = Data(result.stdout.utf8)
        do {
            return try JSONDecoder().decode([ComposeVariable].self, from: data)
        } catch {
            throw ComposeError.invalidProject("failed to decode compose variables JSON: \(error)")
        }
    }
}

/// Concrete command used to run the compose-go normalizer helper.
private struct NormalizerInvocation {
    var executable: String
    var prefixArguments: [String]
    var workingDirectory: URL?
}

private extension ComposeNormalizer {
    static func normalizerFailure(
        invocation: NormalizerInvocation,
        arguments: [String],
        result: CommandResult,
    ) -> ComposeError {
        let stderrLines = result.stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if stderrLines.contains("compose-normalizer: no compose file found") {
            return .missingComposeFile
        }
        return .commandFailed(
            command: ([invocation.executable] + arguments).joined(separator: " "),
            status: result.status,
            stderr: result.stderr,
        )
    }

    static func normalizerArguments(
        invocation: NormalizerInvocation,
        options: ComposeOptions,
        modeArguments: [String] = [],
    ) -> [String] {
        let projectDirectory = options.projectDirectory ?? Self.defaultProjectDirectory(files: options.files)
        var arguments = invocation.prefixArguments
        arguments.append(contentsOf: modeArguments)

        for file in options.files {
            arguments.append(contentsOf: ["--file", absoluteInputPath(file)])
        }
        for profile in options.profiles {
            arguments.append(contentsOf: ["--profile", profile])
        }
        for envFile in options.envFiles {
            arguments.append(contentsOf: ["--env-file", absoluteInputPath(envFile)])
        }
        if let projectName = options.projectName {
            arguments.append(contentsOf: ["--project-name", projectName])
        }
        if options.noConsistency {
            arguments.append("--no-consistency")
        }
        if options.noEnvResolution {
            arguments.append("--no-env-resolution")
        }
        if options.noInterpolate {
            arguments.append("--no-interpolate")
        }
        if options.noNormalize {
            arguments.append("--no-normalize")
        }
        if options.noPathResolution {
            arguments.append("--no-path-resolution")
        }
        arguments.append(contentsOf: ["--project-directory", projectDirectory])
        return arguments
    }

    /// Finds the normalizer from an explicit environment override, plugin
    /// resources, or a source checkout fallback.
    static func normalizerInvocation(fallbackLauncher: String) throws -> NormalizerInvocation {
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
            // Source checkouts run the helper through Go so developers do not
            // need a prebuilt normalizer binary while iterating locally.
            return NormalizerInvocation(
                executable: fallbackLauncher,
                prefixArguments: ["go", "run", "."],
                workingDirectory: sourceURL,
            )
        }

        throw ComposeError.missingNormalizer(
            "set CONTAINER_COMPOSE_NORMALIZER or install resources/compose-normalizer next to the plugin",
        )
    }

    /// Returns the helper path expected in an installed plugin package.
    static func installedNormalizerURL() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        return executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("resources")
            .appendingPathComponent("compose-normalizer")
    }

    /// Returns the Swift package root for local source checkout execution.
    static func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Infers the Compose project directory from the first compose file path.
    static func defaultProjectDirectory(files: [String]) -> String {
        guard let firstFile = files.first,
              firstFile != "-",
              !isRemoteResourcePath(firstFile)
        else {
            return FileManager.default.currentDirectoryPath
        }

        // Docker Compose resolves relative paths from the project directory.
        // When the user passes a compose file, infer that directory from the
        // first file path to match compose-go and Docker Compose behavior.
        let expandedPath = (firstFile as NSString).expandingTildeInPath
        let fileURL = if expandedPath.hasPrefix("/") {
            URL(fileURLWithPath: expandedPath)
        } else {
            URL(
                fileURLWithPath: expandedPath,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            )
        }
        return fileURL.standardizedFileURL.deletingLastPathComponent().path
    }

    static func absoluteInputPath(_ path: String) -> String {
        guard path != "-", !isRemoteResourcePath(path) else {
            return path
        }

        let expandedPath = (path as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        }
        return URL(
            fileURLWithPath: expandedPath,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        ).standardizedFileURL.path
    }

    static func isRemoteResourcePath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        if ["git://", "http://", "https://", "ssh://", "oci://"].contains(where: lowercased.hasPrefix) {
            return true
        }
        if lowercased.hasPrefix("github.com/") {
            return true
        }

        guard let atSign = path.firstIndex(of: "@"),
              !path[..<atSign].contains("/"),
              path[path.index(after: atSign)...].contains(":")
        else {
            return false
        }
        return true
    }
}
