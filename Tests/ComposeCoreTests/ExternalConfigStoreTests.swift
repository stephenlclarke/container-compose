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

import ComposeContainerRuntime
import ComposeCore
import Foundation
import Testing

@Suite("Compose external stores")
struct ComposeExternalStoreTests {
    @Test
    func `config reader returns bytes from its Compose-owned directory`() async throws {
        let directory = try temporaryExternalConfigDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let contents = Data([0x00, 0xFF, 0x0A])
        try contents.write(to: directory.appendingPathComponent("shared_app_config"))
        let reader = ComposeExternalConfigReader(directory: directory)

        #expect(try await reader.readConfig(name: "shared_app_config") == contents)
    }

    @Test
    func `config reader rejects paths outside its Compose-owned directory`() async {
        let reader = ComposeExternalConfigReader(directory: URL(fileURLWithPath: "/tmp/configs"))

        await #expect(throws: ComposeError.invalidProject(
            "external Compose config name '../outside' escapes its configured store",
        )) {
            try await reader.readConfig(name: "../outside")
        }
    }

    @Test
    func `secret reader delegates to its caller-owned secure store`() async throws {
        let contents = Data([0x00, 0xFF, 0x0A])
        let reader = ComposeExternalSecretReader(service: "tests", lookup: { service, account in
            guard service == "tests", account == "shared_api_secret" else {
                throw ExternalStoreTestError.unexpectedLookup
            }
            return contents
        })

        #expect(try await reader.readSecret(name: "shared_api_secret") == contents)
    }

    @Test
    func `secret reader rejects an empty resource name before lookup`() async {
        let reader = ComposeExternalSecretReader(service: "tests", lookup: { _, _ in
            throw ExternalStoreTestError.unexpectedLookup
        })

        await #expect(throws: ComposeError.invalidProject("external Compose secret name must not be empty")) {
            try await reader.readSecret(name: "")
        }
    }
}

private enum ExternalStoreTestError: Error {
    case unexpectedLookup
}
