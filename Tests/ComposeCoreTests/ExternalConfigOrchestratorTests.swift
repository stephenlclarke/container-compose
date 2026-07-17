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

@Suite("External config and secret orchestration")
struct ExternalConfigOrchestratorTests {
    @Test
    func `up materializes external configs through a runtime config reader`() async throws {
        let directory = try temporaryExternalConfigDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let reader = ExternalConfigReader(configs: [
            "shared_app_config": Data([0x00, 0xFF, 0x0A]),
        ])
        let runner = RecordingRunner()
        var service = ComposeService(name: "api", image: "example/api")
        service.attach = false
        service.configs = [
            .object([
                "mode": .string("0555"),
                "source": .string("app_config"),
                "target": .string("/etc/app.conf"),
            ]),
        ]
        var project = ComposeProject(name: "demo", services: ["api": service])
        project.configs = [
            "app_config": .object([
                "external": .bool(true),
                "name": .string("shared_app_config"),
            ]),
        ]
        var options = ComposeExecutionOptions()
        options.materializedConfigSecretDirectory = directory.appendingPathComponent(
            "state",
            isDirectory: true,
        )
        var runtime = ComposeOrchestratorRuntimeDependencies()
        runtime.configReader = reader
        runtime.discoveryManager = EmptyContainerDiscovery()
        let dependencies = ComposeOrchestratorDependencies(
            runner: runner,
            options: options,
            runtime: runtime,
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: options,
            dependencies: dependencies,
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        let source = try #require(readOnlyVolumeSource(target: "/etc/app.conf", in: command))
        #expect(try Data(contentsOf: URL(fileURLWithPath: source)) == Data([0x00, 0xFF, 0x0A]))
        #expect(try posixPermissions(at: source) == 0o555)
        #expect(await reader.requests == ["shared_app_config"])
    }

    @Test
    func `up materializes external secrets through a runtime secret reader`() async throws {
        let directory = try temporaryExternalConfigDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let reader = ExternalSecretReader(secrets: [
            "shared_api_secret": Data([0x00, 0xFF, 0x0A]),
        ])
        let runner = RecordingRunner()
        var service = ComposeService(name: "api", image: "example/api")
        service.attach = false
        service.secrets = [
            .object([
                "mode": .string("0440"),
                "source": .string("api_secret"),
                "target": .string("api-token"),
            ]),
        ]
        var project = ComposeProject(name: "demo", services: ["api": service])
        project.secrets = [
            "api_secret": .object([
                "external": .bool(true),
                "name": .string("shared_api_secret"),
            ]),
        ]
        var options = ComposeExecutionOptions()
        options.materializedConfigSecretDirectory = directory.appendingPathComponent(
            "state",
            isDirectory: true,
        )
        var runtime = ComposeOrchestratorRuntimeDependencies()
        runtime.secretReader = reader
        runtime.discoveryManager = EmptyContainerDiscovery()
        let dependencies = ComposeOrchestratorDependencies(
            runner: runner,
            options: options,
            runtime: runtime,
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: options,
            dependencies: dependencies,
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        let source = try #require(readOnlyVolumeSource(target: "/run/secrets/api-token", in: command))
        #expect(try Data(contentsOf: URL(fileURLWithPath: source)) == Data([0x00, 0xFF, 0x0A]))
        #expect(try posixPermissions(at: source) == 0o440)
        #expect(await reader.requests == ["shared_api_secret"])
    }

    @Test
    func `dry run does not read external secrets`() async throws {
        let reader = ExternalSecretReader(secrets: [:])
        let runner = RecordingRunner()
        var service = ComposeService(name: "api", image: "example/api")
        service.secrets = [.object(["source": .string("api_secret")])]
        var project = ComposeProject(name: "demo", services: ["api": service])
        project.secrets = ["api_secret": .object(["external": .bool(true)])]
        var runtime = ComposeOrchestratorRuntimeDependencies()
        runtime.secretReader = reader
        runtime.discoveryManager = EmptyContainerDiscovery()
        let options = ComposeExecutionOptions(dryRun: true)
        let dependencies = ComposeOrchestratorDependencies(
            runner: runner,
            options: options,
            runtime: runtime,
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: options,
            dependencies: dependencies,
        ).up(project: project, options: ComposeUpOptions())

        #expect(await reader.requests.isEmpty)
    }
}

private actor ExternalConfigReader: ComposeRuntimeConfigReading {
    private let configs: [String: Data]
    private var storage: [String] = []

    init(configs: [String: Data]) {
        self.configs = configs
    }

    var requests: [String] {
        storage
    }

    func readConfig(name: String) async throws -> Data {
        storage.append(name)
        guard let contents = configs[name] else {
            throw ComposeError.invalidProject("missing external config fixture '\(name)'")
        }
        return contents
    }
}

private actor ExternalSecretReader: ComposeRuntimeSecretReading {
    private let secrets: [String: Data]
    private var storage: [String] = []

    init(secrets: [String: Data]) {
        self.secrets = secrets
    }

    var requests: [String] {
        storage
    }

    func readSecret(name: String) async throws -> Data {
        storage.append(name)
        guard let contents = secrets[name] else {
            throw ComposeError.invalidProject("missing external secret fixture '\(name)'")
        }
        return contents
    }
}

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

private struct EmptyContainerDiscovery: ContainerDiscoveryManaging {
    func listContainers(all _: Bool) async throws -> [ComposeContainerSummary] {
        []
    }

    func getContainer(id _: String) async throws -> ComposeContainerSummary? {
        nil
    }
}

private func temporaryExternalConfigDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true,
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func readOnlyVolumeSource(target: String, in arguments: [String]) -> String? {
    let suffix = ":\(target):ro"
    for index in arguments.indices where arguments[index] == "--volume" {
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            continue
        }
        let value = arguments[valueIndex]
        if value.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count))
        }
    }
    return nil
}

private func posixPermissions(at path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}
