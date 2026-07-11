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

extension ComposeOrchestrator {
    /// Runs a provider-backed service lifecycle command.
    func runProvider(
        project: ComposeProject,
        service: ComposeService,
        action: ComposeProviderAction,
    ) async throws -> [String: String] {
        guard let provider = service.provider else {
            return [:]
        }
        let executable = options.dryRun
            ? provider.type
            : try providerExecutablePath(provider.type, project: project)

        let metadata = options.dryRun
            ? ComposeProviderMetadata()
            : await providerMetadata(executable: executable, project: project)
        if action == .stop && metadata.commandMetadata(for: .stop) == nil && !options.dryRun {
            return [:]
        }
        if !metadata.isEmpty {
            try validateProviderOptions(provider: provider, metadata: metadata, action: action)
        }

        let arguments = providerArguments(
            project: project,
            service: service,
            provider: provider,
            action: action,
            metadata: metadata,
        )
        if options.dryRun {
            options.emit("+ " + shellQuoted([executable] + arguments))
            return [:]
        }

        let result = try await runner.run(
            executable,
            arguments,
            workingDirectory: URL(fileURLWithPath: project.workingDirectory, isDirectory: true),
            environment: nil,
            io: .captured(input: nil),
        )
        let variables = try parseProviderOutput(result.stdout, service: service, action: action)
        if !result.succeeded {
            throw ComposeError.commandFailed(
                command: shellQuoted([executable] + arguments),
                status: result.status,
                stderr: result.stderr,
            )
        }
        return action == .stop ? [:] : variables
    }

    /// Reads optional provider metadata. Metadata failures intentionally fall
    /// back to the protocol's no-metadata behavior for backward compatibility.
    func providerMetadata(executable: String, project: ComposeProject) async -> ComposeProviderMetadata {
        do {
            let result = try await runner.run(
                executable,
                ["compose", "metadata"],
                workingDirectory: URL(fileURLWithPath: project.workingDirectory, isDirectory: true),
                environment: nil,
                io: .captured(input: nil),
            )
            guard result.succeeded,
                  let data = result.stdout.data(using: .utf8),
                  !data.isEmpty
            else {
                return ComposeProviderMetadata()
            }
            return (try? JSONDecoder().decode(ComposeProviderMetadata.self, from: data)) ?? ComposeProviderMetadata()
        } catch {
            return ComposeProviderMetadata()
        }
    }

    /// Builds the provider command arguments for one lifecycle action.
    func providerArguments(
        project: ComposeProject,
        service: ComposeService,
        provider: ComposeProvider,
        action: ComposeProviderAction,
        metadata: ComposeProviderMetadata,
    ) -> [String] {
        let commandMetadata = metadata.commandMetadata(for: action)
        let hasMetadata = !metadata.isEmpty
        var arguments = ["compose", "--project-name=\(project.name)", action.rawValue]
        for (key, values) in (provider.options ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !hasMetadata || commandMetadata?.parameter(named: key) != nil else {
                continue
            }
            for value in values {
                arguments.append("--\(key)=\(value)")
            }
        }
        arguments.append(service.name)
        return arguments
    }

    /// Validates required provider options declared by metadata.
    func validateProviderOptions(
        provider: ComposeProvider,
        metadata: ComposeProviderMetadata,
        action: ComposeProviderAction,
    ) throws {
        guard let commandMetadata = metadata.commandMetadata(for: action) else {
            return
        }
        for parameter in commandMetadata.parameters ?? [] where parameter.required == true {
            if (provider.options?[parameter.name] ?? []).isEmpty {
                throw ComposeError.invalidProject("required parameter '\(parameter.name)' is missing from provider '\(provider.type)' definition")
            }
        }
    }

    /// Decodes newline-delimited provider JSON messages.
    func parseProviderOutput(
        _ output: String,
        service: ComposeService,
        action: ComposeProviderAction,
    ) throws -> [String: String] {
        var variables: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            guard let data = text.data(using: .utf8),
                  let message = try? JSONDecoder().decode(ComposeProviderMessage.self, from: data)
            else {
                throw ComposeError.invalidProject("invalid response from provider service '\(service.name)': \(text)")
            }
            switch message.type {
            case "info":
                options.emit("compose: provider \(service.name): \(message.message)")
            case "debug":
                continue
            case "error":
                throw ComposeError.invalidProject("provider service '\(service.name)' failed during \(action.rawValue): \(message.message)")
            case "setenv":
                let parts = message.message.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw ComposeError.invalidProject("invalid setenv response from provider service '\(service.name)': \(message.message)")
                }
                variables[String(parts[0])] = String(parts[1])
            default:
                throw ComposeError.invalidProject("invalid response type '\(message.type)' from provider service '\(service.name)'")
            }
        }
        return variables
    }

    /// Injects provider variables into services that directly depend on it.
    func projectByInjectingProviderEnvironment(
        project: ComposeProject,
        providerServiceName: String,
        variables: [String: String],
    ) -> ComposeProject {
        var updatedProject = project
        let prefix = providerServiceName.uppercased() + "_"
        for entry in project.services.sorted(by: { $0.key < $1.key }) {
            let name = entry.key
            var service = entry.value
            guard service.dependsOn?[providerServiceName] != nil else {
                continue
            }
            var environment = service.environment ?? [:]
            for (key, value) in variables.sorted(by: { $0.key < $1.key }) {
                environment[prefix + key] = value
            }
            service.environment = environment
            updatedProject.services[name] = service
        }
        return updatedProject
    }

    /// Resolves the provider executable path using Compose-compatible rules.
    func providerExecutablePath(_ rawType: String, project: ComposeProject) throws -> String {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "compose" {
            throw ComposeError.invalidProject("provider.type 'compose' is reserved")
        }
        if type.contains("/") {
            let url = type.hasPrefix("/")
                ? URL(fileURLWithPath: type)
                : URL(fileURLWithPath: project.workingDirectory, isDirectory: true)
                .appendingPathComponent(type)
                .standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ComposeError.invalidProject("provider executable '\(type)' was not found or is not executable")
            }
            return url.path
        }
        let candidates = type.hasPrefix("docker-") ? [type] : ["docker-\(type)", type]
        for candidate in candidates {
            if let path = findExecutable(named: candidate) {
                return path
            }
        }
        throw ComposeError.invalidProject("provider executable '\(type)' was not found in PATH")
    }

    /// Finds an executable in PATH.
    func findExecutable(named name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directoryPath = directory.isEmpty ? "." : String(directory)
            let candidate = URL(fileURLWithPath: directoryPath, isDirectory: true)
                .appendingPathComponent(name)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
