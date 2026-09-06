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

/// Resolves the Docker credentials copied into the generated `#apisocket`
/// config. Implementations return a complete Docker config containing only
/// the resolved `auths` object.
public protocol ComposeAPISocketCredentialResolving: Sendable {
    func resolvedCredentialConfig() async throws -> Data
}

/// Reads Docker CLI credentials and resolves configured native helpers without
/// invoking a shell. Helper processes receive EOF on stdin, a minimal
/// environment, bounded execution time, and no access to Compose output.
public struct DockerAPISocketCredentialResolver:
    ComposeAPISocketCredentialResolving
{
    private static let maximumConfigBytes = 1_048_576
    private static let helperTimeout = Duration.seconds(10)
    private static let tokenUsername = "<token>"

    private let runner: any CommandRunning
    private let environment: [String: String]

    public init(
        runner: any CommandRunning = ProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) {
        self.runner = runner
        self.environment = environment
    }

    public func resolvedCredentialConfig() async throws -> Data {
        let source = try loadConfiguration()
        var credentials = source.credentials

        if let store = nonEmpty(source.credentialStore) {
            credentials = try await credentialsFromDefaultStore(
                store,
                fileCredentials: credentials,
            )
        }
        for (server, helper) in source.credentialHelpers.sorted(by: {
            $0.key < $1.key
        }) {
            do {
                credentials[server] = try await credential(
                    server: server,
                    helper: helper,
                    sourceCredential: source.credentials[server],
                )
            } catch {
                // Docker CLI deliberately keeps the default-store result when
                // one registry-specific helper cannot be read.
                continue
            }
        }

        let output = DockerCredentialOutput(auths: credentials)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(output)
    }

    private func loadConfiguration() throws -> DockerCredentialSource {
        if let environmentConfig = environment["DOCKER_AUTH_CONFIG"] {
            return try decodeConfiguration(Data(environmentConfig.utf8))
        }

        let root: URL
        if let configured = nonEmpty(environment["DOCKER_CONFIG"]) {
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            let home = environment["HOME"] ?? NSHomeDirectory()
            root = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".docker", isDirectory: true)
        }
        let file = root.appendingPathComponent("config.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return DockerCredentialSource()
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumConfigBytes + 1) ?? Data()
        return try decodeConfiguration(data)
    }

    private func decodeConfiguration(_ data: Data) throws
        -> DockerCredentialSource
    {
        guard data.count <= Self.maximumConfigBytes else {
            throw ComposeError.invalidProject(
                "Docker credential config exceeds the 1048576-byte limit",
            )
        }
        do {
            return try JSONDecoder().decode(DockerCredentialSource.self, from: data)
        } catch {
            throw ComposeError.invalidProject(
                "Docker credential config is invalid: \(error.localizedDescription)",
            )
        }
    }

    private func credentialsFromDefaultStore(
        _ helper: String,
        fileCredentials: [String: DockerResolvedCredential],
    ) async throws -> [String: DockerResolvedCredential] {
        let listed = try await runHelper(
            helper,
            operation: "list",
            input: Data("unused".utf8),
        )
        let servers: [String: String]
        do {
            servers = try JSONDecoder().decode([String: String].self, from: listed)
        } catch {
            throw helperError(helper, operation: "list")
        }
        var credentials: [String: DockerResolvedCredential] = [:]
        for server in servers.keys.sorted() {
            credentials[server] = try await credential(
                server: server,
                helper: helper,
                sourceCredential: fileCredentials[server],
            )
        }
        return credentials
    }

    private func credential(
        server: String,
        helper: String,
        sourceCredential: DockerResolvedCredential?,
    ) async throws -> DockerResolvedCredential {
        let data: Data
        do {
            data = try await runHelper(
                helper,
                operation: "get",
                input: Data(server.utf8),
            )
        } catch DockerCredentialHelperError.credentialsNotFound {
            return DockerResolvedCredential(
                registryToken: sourceCredential?.registryToken,
            )
        }
        let value: DockerHelperCredential
        do {
            value = try JSONDecoder().decode(DockerHelperCredential.self, from: data)
        } catch {
            throw helperError(helper, operation: "get")
        }
        if value.username == Self.tokenUsername {
            return DockerResolvedCredential(
                identityToken: value.secret,
                registryToken: sourceCredential?.registryToken,
            )
        }
        return DockerResolvedCredential(
            auth: Data("\(value.username):\(value.secret)".utf8)
                .base64EncodedString(),
            registryToken: sourceCredential?.registryToken,
        )
    }

    private func runHelper(
        _ suffix: String,
        operation: String,
        input: Data,
    ) async throws -> Data {
        let executable = try helperExecutable(suffix)
        let result: CommandResult
        do {
            result = try await executeHelper(
                executable,
                operation: operation,
                input: input,
            )
        } catch let error as ComposeError {
            throw error
        } catch {
            throw helperError(suffix, operation: operation)
        }
        guard result.stdoutOmittedByteCount == 0,
              result.stderrOmittedByteCount == 0
        else {
            throw helperError(suffix, operation: operation)
        }
        guard result.succeeded else {
            if operation == "get",
               String(bytes: result.stdoutData, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines)
               == "credentials not found in native keychain"
            {
                throw DockerCredentialHelperError.credentialsNotFound
            }
            throw helperError(suffix, operation: operation)
        }
        return result.stdoutData
    }

    private func helperExecutable(_ suffix: String) throws -> String {
        guard !suffix.isEmpty,
              suffix.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || ".-_".unicodeScalars.contains($0)
              })
        else {
            throw ComposeError.invalidProject(
                "Docker credential helper name is invalid",
            )
        }
        return "docker-credential-\(suffix)"
    }

    private func executeHelper(
        _ executable: String,
        operation: String,
        input: Data,
    ) async throws -> CommandResult {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        let home = environment["HOME"] ?? NSHomeDirectory()
        let arguments = [
            "-i", "HOME=\(home)", "PATH=\(path)", executable, operation,
        ]
        return try await withThrowingTaskGroup(
            of: CommandResult.self,
        ) { group in
            group.addTask {
                try await runner.runCapturingOutputPrefix(
                    ComposeExecutionOptions.defaultEnvironmentLauncher,
                    arguments,
                    input: input,
                    maximumOutputBytes: Self.maximumConfigBytes,
                )
            }
            group.addTask {
                try await Task.sleep(for: Self.helperTimeout)
                throw ComposeError.invalidProject(
                    "Docker credential helper '\(executable)' timed out",
                )
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func helperError(
        _ helper: String,
        operation: String,
    ) -> ComposeError {
        .invalidProject(
            "Docker credential helper 'docker-credential-\(helper)' failed during \(operation)",
        )
    }
}

private struct DockerCredentialSource: Decodable {
    var credentials: [String: DockerResolvedCredential]
    var credentialStore: String?
    var credentialHelpers: [String: String]

    init() {
        credentials = [:]
        credentialStore = nil
        credentialHelpers = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case credentials = "auths"
        case credentialStore = "credsStore"
        case credentialHelpers = "credHelpers"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credentials =
            try container.decodeIfPresent(
                [String: DockerResolvedCredential].self,
                forKey: .credentials,
            ) ?? [:]
        credentialStore = try container.decodeIfPresent(
            String.self,
            forKey: .credentialStore,
        )
        credentialHelpers =
            try container.decodeIfPresent(
                [String: String].self,
                forKey: .credentialHelpers,
            ) ?? [:]
    }
}

private struct DockerCredentialOutput: Encodable {
    let auths: [String: DockerResolvedCredential]
}

private struct DockerResolvedCredential: Codable {
    var auth: String?
    var identityToken: String?
    var registryToken: String?

    private enum CodingKeys: String, CodingKey {
        case auth
        case password
        case username
        case identityToken = "identitytoken"
        case registryToken = "registrytoken"
    }

    init(
        auth: String? = nil,
        identityToken: String? = nil,
        registryToken: String? = nil,
    ) {
        self.auth = auth
        self.identityToken = identityToken
        self.registryToken = registryToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identityToken = try container.decodeIfPresent(
            String.self,
            forKey: .identityToken,
        )
        registryToken = try container.decodeIfPresent(
            String.self,
            forKey: .registryToken,
        )
        if let encoded = try container.decodeIfPresent(String.self, forKey: .auth),
           !encoded.isEmpty
        {
            guard let decoded = Data(base64Encoded: encoded),
                  decoded.contains(UInt8(ascii: ":"))
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .auth,
                    in: container,
                    debugDescription: "Docker auth is not base64-encoded username:password data",
                )
            }
            auth = decoded.base64EncodedString()
        } else {
            let username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
            let password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
            auth = username.isEmpty && password.isEmpty
                ? nil
                : Data("\(username):\(password)".utf8).base64EncodedString()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(auth, forKey: .auth)
        try container.encodeIfPresent(identityToken, forKey: .identityToken)
        try container.encodeIfPresent(registryToken, forKey: .registryToken)
    }
}

private struct DockerHelperCredential: Decodable {
    let username: String
    let secret: String

    private enum CodingKeys: String, CodingKey {
        case username = "Username"
        case secret = "Secret"
    }
}

private enum DockerCredentialHelperError: Error {
    case credentialsNotFound
}
