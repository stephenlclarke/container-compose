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
import ComposeRuntimeSPI
import Foundation
import Security

/// Filesystem-backed reader for Compose external config resources.
///
/// Files are addressed by their resolved Compose resource name below the
/// configured directory. This keeps local-mode Compose configuration outside
/// the Apple runtime and makes the store straightforward to provision and
/// back up.
public struct ComposeExternalConfigReader: ComposeRuntimeConfigReading {
    /// Environment variable that overrides the external config directory.
    public static let directoryEnvironmentVariable = "CONTAINER_COMPOSE_CONFIG_DIRECTORY"

    private let directory: URL

    public init(directory: URL = Self.defaultDirectory()) {
        self.directory = directory.standardizedFileURL
    }

    /// Returns the per-user default directory for external Compose configs.
    public static func defaultDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment[directoryEnvironmentVariable], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/container-compose/configs", isDirectory: true)
    }

    public func readConfig(name: String) async throws -> Data {
        let file = try resourceURL(name: name)
        do {
            return try Data(contentsOf: file)
        } catch {
            throw ComposeError.invalidProject(
                "external Compose config '\(name)' is unavailable at '\(file.path)': \(error.localizedDescription)",
            )
        }
    }

    private func resourceURL(name: String) throws -> URL {
        let root = directory.standardizedFileURL
        let file = root.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard !name.isEmpty, file.path.hasPrefix(root.path + "/") else {
            throw ComposeError.invalidProject("external Compose config name '\(name)' escapes its configured store")
        }
        return file
    }
}

/// Keychain-backed reader for Compose external secret resources.
public struct ComposeExternalSecretReader: ComposeRuntimeSecretReading {
    /// Stable Keychain service namespace for Compose external secrets.
    public static let defaultService = "com.apple.container-compose"

    public typealias Lookup = @Sendable (_ service: String, _ account: String) throws -> Data

    private let service: String
    private let lookup: Lookup

    public init(service: String = Self.defaultService) {
        self.init(service: service, lookup: Self.keychainData)
    }

    /// Creates a reader with a custom lookup, primarily for tests and alternate secure stores.
    public init(service: String, lookup: @escaping Lookup) {
        self.service = service
        self.lookup = lookup
    }

    public func readSecret(name: String) async throws -> Data {
        guard !name.isEmpty else {
            throw ComposeError.invalidProject("external Compose secret name must not be empty")
        }
        return try lookup(service, name)
    }

    private static func keychainData(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String }
                ?? "Keychain status \(status)"
            throw ComposeError.invalidProject(
                "external Compose secret '\(account)' is unavailable from Keychain service '\(service)': \(message)",
            )
        }
        return data
    }
}
