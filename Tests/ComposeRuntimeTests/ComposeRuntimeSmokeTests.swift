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
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing

@Suite("Compose runtime smoke tests")
struct ComposeRuntimeSmokeTests {
    @Test("runtime run build emits progress before build output")
    func runtimeRunBuildEmitsProgressBeforeBuildOutput() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let dockerfile = directory.appendingPathComponent("Dockerfile")
        try """
        FROM alpine:3.20
        """.write(to: dockerfile, atomically: true, encoding: .utf8)

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          shell:
            build:
              context: .
              dockerfile: Dockerfile
            pull_policy: build
            command: ["echo", "runtime-progress-ok"]
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let containerBinary = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container"
        _ = try runProcess(containerBinary, ["system", "status"], timeout: 15)
        defer {
            _ = try? runProcess(
                composeBinary,
                [
                    "--ansi", "never",
                    "--project-name", project,
                    "--file", composeFile.path,
                    "down", "--volumes", "--remove-orphans",
                ],
                timeout: 60
            )
        }

        let result = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--progress", "plain",
                "--project-name", project,
                "--file", composeFile.path,
                "run", "--rm", "--no-TTY", "shell",
            ],
            timeout: 240,
            mergeOutputForOrdering: true
        )

        let output = result.combined
        #expect(output.contains("runtime-progress-ok"))
        #expect(output.contains("Loading Compose model"))
        #expect(output.contains("Building shell"))

        try assert(
            "Loading Compose model",
            appearsBefore: "Building shell",
            in: output,
            diagnostic: "Compose model progress should be visible before build progress starts."
        )
        try assert(
            "Building shell",
            appearsBefore: "#1 ",
            in: output,
            diagnostic: "Build progress should be visible before container build output starts."
        )
    }

    @Test("runtime up handles entrypoint plus command")
    func runtimeUpHandlesEntrypointPlusCommand() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          entrypoint-command:
            image: alpine:3.20
            entrypoint: ["/bin/sh", "-c"]
            command: ["printf entrypoint-command-ok"]
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let containerBinary = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container"
        _ = try runProcess(containerBinary, ["system", "status"], timeout: 15)
        defer {
            _ = try? runProcess(
                composeBinary,
                [
                    "--ansi", "never",
                    "--project-name", project,
                    "--file", composeFile.path,
                    "down", "--volumes", "--remove-orphans",
                ],
                timeout: 60
            )
        }

        _ = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "up", "--detach", "entrypoint-command",
            ],
            timeout: 180
        )

        var lastLogs = ""
        for _ in 0..<20 {
            let logs = try runProcess(
                composeBinary,
                [
                    "--ansi", "never",
                    "--project-name", project,
                    "--file", composeFile.path,
                    "logs", "entrypoint-command",
                ],
                timeout: 30
            )
            lastLogs = logs.stdout + logs.stderr
            if lastLogs.contains("entrypoint-command-ok") {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }

        Issue.record("Expected entrypoint-command output in runtime logs. Last logs: \(lastLogs)")
    }

    @Test("runtime ps lists built compose service")
    func runtimePsListsBuiltComposeService() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = try copyRuntimeFixture(named: "ps")
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let containerBinary = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container"
        _ = try runProcess(containerBinary, ["system", "status"], timeout: 15)
        defer {
            _ = try? runProcess(
                composeBinary,
                [
                    "--ansi", "never",
                    "--project-name", project,
                    "--file", composeFile.path,
                    "down", "--volumes", "--remove-orphans",
                ],
                timeout: 60
            )
        }

        _ = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "up", "--detach", "--build", "ps-app",
            ],
            timeout: 240
        )

        let jsonResult = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "ps", "--format", "json", "--filter", "status=running", "ps-app",
            ],
            timeout: 30
        )
        let rows = try composePsJSONRows(jsonResult.stdout)
        let row = try #require(rows.first)
        let configuration = try #require(row["configuration"] as? [String: Any])
        let labels = try #require(configuration["labels"] as? [String: Any])
        let status = try #require(row["status"] as? [String: Any])

        #expect(rows.count == 1)
        #expect(labels["com.apple.container.compose.project"] as? String == project)
        #expect(labels["com.apple.container.compose.service"] as? String == "ps-app")
        #expect(status["state"] as? String == "running")

        let servicesResult = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "ps", "--services", "--filter", "status=running",
            ],
            timeout: 30
        )
        #expect(servicesResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ps-app")
    }

    @Test("runtime dry run up timestamps follows timestamped logs")
    func runtimeDryRunUpTimestampsFollowsTimestampedLogs() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let dockerfile = directory.appendingPathComponent("Dockerfile")
        try """
        FROM alpine:3.20
        """.write(to: dockerfile, atomically: true, encoding: .utf8)

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            build:
              context: .
              dockerfile: Dockerfile
            command: ["echo", "timestamped-up"]
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let result = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "--dry-run", "up", "--timestamps", "api",
            ],
            timeout: 30
        )

        #expect(result.stdout.contains("+ container run --name \(project)-api-1 --detach"))
        #expect(result.stdout.contains("+ compose-runtime logs --follow --timestamps \(project)-api-1"))
    }

    @Test("runtime dry run up attach follows selected logs")
    func runtimeDryRunUpAttachFollowsSelectedLogs() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: alpine:3.20
            depends_on:
              db:
                condition: service_started
          db:
            image: alpine:3.20
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let selected = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "--dry-run", "up", "--attach", "api", "api",
            ],
            timeout: 30
        )
        let withDependencies = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "--dry-run", "up", "--attach", "api", "--attach-dependencies", "api",
            ],
            timeout: 30
        )

        #expect(selected.stdout.contains("+ container run --name \(project)-db-1 --detach"))
        #expect(selected.stdout.contains("+ container run --name \(project)-api-1 --detach"))
        #expect(selected.stdout.contains("+ compose-runtime logs --follow \(project)-api-1"))
        #expect(!selected.stdout.contains("+ compose-runtime logs --follow \(project)-db-1"))
        #expect(withDependencies.stdout.contains("+ compose-runtime logs --follow \(project)-db-1"))
        #expect(withDependencies.stdout.contains("+ compose-runtime logs --follow \(project)-api-1"))
    }

    @Test("runtime dry run up accepts menu false value")
    func runtimeDryRunUpAcceptsMenuFalseValue() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: alpine:3.20
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let result = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "--dry-run", "up", "--menu=false", "--no-start", "api",
            ],
            timeout: 30
        )

        #expect(result.stdout.contains("+ container create --name \(project)-api-1"))

        let enabled = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "--dry-run", "up", "--menu=true", "--no-start", "api",
            ],
            timeout: 30,
            expectedStatus: 1
        )

        #expect(enabled.stderr.contains("unsupported compose feature: up --menu"))
    }

    @Test("runtime dry run attach no-stdin follows logs with default signal proxy")
    func runtimeDryRunAttachNoStdinFollowsLogsWithDefaultSignalProxy() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: alpine:3.20
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let result = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "--dry-run", "attach", "--no-stdin", "api",
            ],
            timeout: 30
        )

        #expect(result.stdout.contains("+ compose-runtime logs --follow \(project)-api-1"))

        let withDetachKeys = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "--dry-run", "attach", "--no-stdin", "--detach-keys=ctrl-x", "api",
            ],
            timeout: 30
        )

        #expect(withDetachKeys.stdout.contains("+ compose-runtime logs --follow \(project)-api-1"))
    }

    @Test("runtime up exit-code-from returns selected status")
    func runtimeUpExitCodeFromReturnsSelectedStatus() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: alpine:3.20
            command: ["sh", "-c", "exit 7"]
            depends_on:
              db:
                condition: service_started
          db:
            image: alpine:3.20
            command: ["sh", "-c", "sleep 60"]
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        defer {
            _ = try? runProcess(
                composeBinary,
                [
                    "--ansi", "never",
                    "--project-name", project,
                    "--file", composeFile.path,
                    "down", "--volumes", "--remove-orphans",
                ],
                timeout: 60
            )
        }

        let dryRun = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "--dry-run", "up", "--exit-code-from", "api", "api",
            ],
            timeout: 30
        )
        #expect(dryRun.stdout.contains("+ container run --name \(project)-db-1 --detach"))
        #expect(dryRun.stdout.contains("+ container run --name \(project)-api-1 --detach"))
        #expect(dryRun.stdout.contains("+ compose-runtime wait \(project)-api-1"))
        #expect(dryRun.stdout.contains("+ container delete \(project)-api-1"))

        let result = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "up", "--exit-code-from", "api", "api",
            ],
            timeout: 120,
            expectedStatus: 7
        )
        #expect(result.status == 7)
    }

    @Test("runtime config resolves image digests")
    func runtimeConfigResolvesImageDigests() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: alpine:3.20
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let resolved = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "config", "--resolve-image-digests", "api",
            ],
            timeout: 60
        )
        let locked = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "config", "--lock-image-digests", "api",
            ],
            timeout: 60
        )

        #expect(resolved.stdout.range(of: #"image: "alpine:3\.20@sha256:[a-f0-9]{64}""#, options: .regularExpression) != nil)
        #expect(locked.stdout.range(of: #"image: "alpine:3\.20@sha256:[a-f0-9]{64}""#, options: .regularExpression) != nil)
        #expect(locked.stdout.contains("services:\n  api:"))
    }

    @Test("runtime dry run exec renders privileged command")
    func runtimeDryRunExecRendersPrivilegedCommand() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let dockerfile = directory.appendingPathComponent("Dockerfile")
        try """
        FROM alpine:3.20
        """.write(to: dockerfile, atomically: true, encoding: .utf8)

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            build:
              context: .
              dockerfile: Dockerfile
            command: ["sleep", "300"]
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = runtimeProjectName()
        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let result = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", project,
                "--file", composeFile.path,
                "--dry-run", "exec", "--privileged", "--no-tty", "api", "id",
            ],
            timeout: 30
        )

        #expect(result.stdout.contains("+ container exec --privileged --interactive \(project)-api-1 id"))
    }

    @Test("runtime build print renders bake file from compose file")
    func runtimeBuildPrintRendersBakeFileFromComposeFile() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        let apiDirectory = directory.appendingPathComponent("api", isDirectory: true)
        try fileManager.createDirectory(at: apiDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        try """
        FROM alpine:3.20
        """.write(to: apiDirectory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: example/api:latest
            build:
              context: ./api
              dockerfile: Dockerfile
              args:
                FILE_ARG: "1"
              tags:
                - example/api:dev
              ssh:
                - default
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let result = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", runtimeProjectName(),
                "--file", composeFile.path,
                "build", "--print", "--provenance=false", "--sbom=false", "--push", "--build-arg", "CLI_ARG=2", "--ssh", "git=/tmp/git.sock", "api",
            ],
            timeout: 30
        )

        let bake = try composeBakeJSON(result.stdout)
        let api = try composeBakeTarget(bake, name: "api")
        #expect((api["context"] as? String)?.hasSuffix("/api") == true)
        #expect((api["dockerfile"] as? String)?.hasSuffix("/api/Dockerfile") == true)
        #expect(api["tags"] as? [String] == ["example/api:dev", "example/api:latest"])
        #expect(api["ssh"] as? [String] == ["default", "git=/tmp/git.sock"])
        #expect(api["output"] as? [String] == ["type=registry"])
        let arguments = try #require(api["args"] as? [String: String])
        #expect(arguments["FILE_ARG"] == "1")
        #expect(arguments["CLI_ARG"] == "2")

        let enabled = try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", runtimeProjectName(),
                "--file", composeFile.path,
                "build", "--print", "--provenance=true", "api",
            ],
            timeout: 30,
            expectedStatus: 1
        )

        #expect(enabled.stderr.contains("unsupported compose feature: build --provenance"))
    }

    @Test("runtime build forwards default SSH from compose file and CLI")
    func runtimeBuildForwardsDefaultSSHFromComposeFileAndCLI() throws {
        guard runtimeTestsEnabled else {
            return
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
        let apiDirectory = directory.appendingPathComponent("api", isDirectory: true)
        try fileManager.createDirectory(at: apiDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        try """
        FROM ghcr.io/linuxcontainers/alpine:3.20
        RUN --mount=type=ssh test -S "$SSH_AUTH_SOCK"
        """.write(to: apiDirectory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

        let imageTag = UUID().uuidString
        let imageName = "registry.local/compose-ssh:\(imageTag)"
        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: \(imageName)
            build:
              context: ./api
              ssh:
                - default
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let socket = try FakeSSHAgentSocket()
        defer {
            socket.close()
        }

        let composeBinary = ProcessInfo.processInfo.environment["COMPOSE_TEST_BINARY"] ?? ".build/debug/compose"
        let containerBinary = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container"
        defer {
            _ = try? runProcess(containerBinary, ["image", "delete", imageName], timeout: 30)
        }

        try runProcess(
            composeBinary,
            [
                "--ansi", "never",
                "--project-name", runtimeProjectName(),
                "--file", composeFile.path,
                "build", "--ssh", "default", "api",
            ],
            timeout: 120,
            environment: ["SSH_AUTH_SOCK": socket.path]
        )

        let inspect = try runProcess(containerBinary, ["image", "inspect", imageName], timeout: 30)
        #expect(inspect.stdout.contains(imageTag))
    }
}

private var runtimeTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_RUN_RUNTIME_TESTS"] == "1"
}

private func runtimeProjectName() -> String {
    "ccrt-\(UUID().uuidString.prefix(8).lowercased())"
}

private func copyRuntimeFixture(named name: String) throws -> URL {
    let fileManager = FileManager.default
    guard let source = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw ComposeError.invalidProject("missing runtime fixture '\(name)'")
    }
    let destination = fileManager.temporaryDirectory
        .appendingPathComponent("container-compose-runtime-\(UUID().uuidString)", isDirectory: true)
    try fileManager.copyItem(at: source, to: destination)
    return destination
}

private func composePsJSONRows(_ output: String) throws -> [[String: Any]] {
    let data = Data(output.utf8)
    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw ComposeError.invalidProject("compose ps emitted malformed JSON")
    }
    return rows
}

private func composeBakeJSON(_ output: String) throws -> [String: Any] {
    let data = Data(output.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ComposeError.invalidProject("compose build --print emitted malformed JSON")
    }
    return object
}

private func composeBakeTarget(_ bake: [String: Any], name: String) throws -> [String: Any] {
    guard let targets = bake["target"] as? [String: Any],
          let target = targets[name] as? [String: Any] else {
        throw ComposeError.invalidProject("compose build --print emitted no target named '\(name)'")
    }
    return target
}

private struct RuntimeProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var combined: String
}

private final class FakeSSHAgentSocket {
    let path: String
    private let descriptor: Int32
    private var acceptThread: Thread?

    init() throws {
        path = "/tmp/cc-ssh-\(UUID().uuidString.prefix(8)).sock"
        try? FileManager.default.removeItem(atPath: path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ComposeError.commandFailed(command: "socket", status: Int32(errno), stderr: "socket() failed")
        }

        var address = sockaddr_un()
#if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
#endif
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.withCString { cString in
                bytes.copyMemory(from: UnsafeRawBufferPointer(start: cString, count: path.utf8.count + 1))
            }
        }
        let bindResult = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            closeFileDescriptor(descriptor)
            throw ComposeError.commandFailed(command: "bind", status: Int32(errno), stderr: "bind() failed")
        }
        guard listen(descriptor, 5) == 0 else {
            closeFileDescriptor(descriptor)
            throw ComposeError.commandFailed(command: "listen", status: Int32(errno), stderr: "listen() failed")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            closeFileDescriptor(descriptor)
            throw ComposeError.commandFailed(command: "bind", status: Int32(ENOENT), stderr: "socket path was not created")
        }

        acceptThread = Thread { [descriptor] in
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0 {
                    break
                }
                closeFileDescriptor(client)
            }
        }
        acceptThread?.start()
    }

    func close() {
        closeFileDescriptor(descriptor)
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func closeFileDescriptor(_ descriptor: Int32) {
#if canImport(Darwin)
    Darwin.close(descriptor)
#elseif canImport(Glibc)
    Glibc.close(descriptor)
#endif
}

private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else {
            return
        }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

@discardableResult
private func runProcess(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval,
    expectedStatus: Int32 = 0,
    mergeOutputForOrdering: Bool = false,
    environment: [String: String] = [:]
) throws -> RuntimeProcessResult {
    let process = Process()
    let command = [executable] + arguments
    if executable.contains("/") {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
    }

    let stdout = Pipe()
    let stderr = mergeOutputForOrdering ? stdout : Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    if !environment.isEmpty {
        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        process.environment = processEnvironment
    }

    let stdoutBuffer = OutputAccumulator()
    let stderrBuffer = OutputAccumulator()
    let combinedBuffer = OutputAccumulator()
    stdout.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        stdoutBuffer.append(data)
        combinedBuffer.append(data)
    }
    if !mergeOutputForOrdering {
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            stderrBuffer.append(data)
            combinedBuffer.append(data)
        }
    }
    defer {
        stdout.fileHandleForReading.readabilityHandler = nil
        if !mergeOutputForOrdering {
            stderr.fileHandleForReading.readabilityHandler = nil
        }
    }

    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        let stderrOutput = stderrBuffer.string()
        let stdoutOutput = stdoutBuffer.string()
        let combinedOutput = combinedBuffer.string()
        let diagnostic = [
            stderrOutput.isEmpty ? nil : "stderr:\n\(stderrOutput)",
            stdoutOutput.isEmpty ? nil : "stdout:\n\(stdoutOutput)",
            combinedOutput.isEmpty ? nil : "combined:\n\(combinedOutput)",
        ].compactMap { $0 }.joined(separator: "\n")
        throw ComposeError.commandFailed(
            command: command.joined(separator: " "),
            status: process.terminationStatus,
            stderr: "timed out after \(Int(timeout))s\(diagnostic.isEmpty ? "" : "\n\(diagnostic)")"
        )
    }

    process.waitUntilExit()
    let stdoutRemainder = stdout.fileHandleForReading.readDataToEndOfFile()
    stdoutBuffer.append(stdoutRemainder)
    combinedBuffer.append(stdoutRemainder)
    if !mergeOutputForOrdering {
        let stderrRemainder = stderr.fileHandleForReading.readDataToEndOfFile()
        stderrBuffer.append(stderrRemainder)
        combinedBuffer.append(stderrRemainder)
    }
    let result = RuntimeProcessResult(
        status: process.terminationStatus,
        stdout: stdoutBuffer.string(),
        stderr: stderrBuffer.string(),
        combined: combinedBuffer.string()
    )
    guard result.status == expectedStatus else {
        throw ComposeError.commandFailed(
            command: command.joined(separator: " "),
            status: result.status,
            stderr: result.stderr
        )
    }
    return result
}

private func assert(
    _ earlier: String,
    appearsBefore later: String,
    in output: String,
    diagnostic: String
) throws {
    guard let earlierRange = output.range(of: earlier) else {
        Issue.record("Expected output to contain '\(earlier)'. Output:\n\(output)")
        return
    }
    guard let laterRange = output.range(of: later) else {
        Issue.record("Expected output to contain '\(later)'. Output:\n\(output)")
        return
    }
    #expect(earlierRange.lowerBound < laterRange.lowerBound, "\(diagnostic)\nOutput:\n\(output)")
}
