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
import Foundation
import Testing

private func composeService(
    name: String,
    image: String? = nil,
    configure: (inout ComposeService) -> Void = { _ in }
) -> ComposeService {
    var service = ComposeService(name: name, image: image)
    configure(&service)
    return service
}

private func composeProject(
    name: String,
    services: [String: ComposeService],
    configure: (inout ComposeProject) -> Void = { _ in }
) -> ComposeProject {
    var project = ComposeProject(name: name, services: services)
    configure(&project)
    return project
}

@Suite("Compose orchestrator")
struct ComposeOrchestratorTests {
    @Test("orders selected services after dependencies")
    func ordersSelectedServicesAfterDependencies() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": "service_started"]
                },
                "db": ComposeService(name: "db", image: "postgres:16"),
                "web": composeService(name: "web", image: "nginx:latest") {
                    $0.dependsOn = ["api": "service_started"]
                },
            ]
        )

        let ordered = try ComposeOrchestrator().orderedServices(project: project, selected: ["web"])

        #expect(ordered.map(\.name) == ["db", "api", "web"])
    }

    @Test("detects dependency cycles")
    func detectsDependencyCycles() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["worker": "service_started"]
                },
                "worker": composeService(name: "worker", image: "example/worker:latest") {
                    $0.dependsOn = ["api": "service_started"]
                },
            ]
        )

        do {
            _ = try ComposeOrchestrator().orderedServices(project: project, selected: [])
            Issue.record("Expected dependency cycle error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("dependency cycle involving 'api'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("up creates resources and runs services with compose labels")
    func upCreatesResourcesAndRunsServicesWithComposeLabels() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .failure,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.command = ["serve"]
                    $0.environment = ["LOG_LEVEL": "debug"]
                    $0.ports = ["8080:80"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    $0.networks = ["default"]
                    $0.labels = ["com.example.role": "api"]
                },
            ]
        ) {
            $0.workingDirectory = "/tmp/demo"
            $0.composeFiles = ["/tmp/compose.yml"]
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.allSatisfy { $0.executable == "/usr/bin/env" })
        #expect(runner.commands.allSatisfy { $0.arguments.first == "container" })
        #expect(runner.commands[0].arguments.containsSequence(["network", "create"]))
        #expect(runner.commands[0].arguments.contains("demo_default"))
        #expect(runner.commands[0].arguments.containsSequence(["--label", "com.apple.container.compose.project.working-directory=/tmp/demo"]))
        #expect(runner.commands[0].arguments.containsLabel(withPrefix: "com.apple.container.compose.project.config-files-hash="))
        #expect(runner.commands[1].arguments.containsSequence(["volume", "create"]))
        #expect(runner.commands[1].arguments.contains("demo_cache"))
        #expect(runner.commands[1].arguments.containsSequence(["--label", "com.apple.container.compose.project.working-directory=/tmp/demo"]))
        #expect(runner.commands[1].arguments.containsLabel(withPrefix: "com.apple.container.compose.project.config-files-hash="))
        #expect(runner.commands[2].arguments == ["container", "inspect", "demo-api-1"])

        let run = runner.commands[3].arguments
        #expect(run.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.project.working-directory=/tmp/demo"]))
        #expect(run.containsLabel(withPrefix: "com.apple.container.compose.project.config-files-hash="))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.oneoff=false"]))
        #expect(run.containsSequence(["--label", "com.example.role=api"]))
        #expect(run.containsSequence(["--env", "LOG_LEVEL=debug"]))
        #expect(run.containsSequence(["--publish", "8080:80"]))
        #expect(run.containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(run.containsSequence(["--network", "demo_default"]))
        #expect(Array(run.suffix(2)) == ["example/api:latest", "serve"])
    }

    @Test("up removes orphan containers when requested")
    func upRemovesOrphanContainersWhenRequested() async throws {
        let runner = RecordingRunner(responses: [
            .failure,
            .success,
            containerListResult(),
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions(removeOrphans: true))

        #expect(runner.commands.count == 5)
        #expect(runner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(runner.commands[1].arguments.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(runner.commands[1].arguments.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(runner.commands[1].arguments.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(runner.commands[1].arguments.last == "example/api:latest")
        #expect(runner.commands[2].arguments == ["container", "list", "--format", "json", "--all"])
        #expect(runner.commands[3].arguments == ["container", "stop", "demo-worker-1"])
        #expect(runner.commands[4].arguments == ["container", "delete", "demo-worker-1"])
    }

    @Test("rejects dependency conditions that need runtime gaps")
    func rejectsUnsupportedDependencyConditions() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": "service_completed_successfully"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: RecordingRunner(responses: [.failure]))
                .up(project: project, options: ComposeUpOptions(services: ["api"]))
            Issue.record("Expected unsupported dependency condition")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' depends on 'job' with condition 'service_completed_successfully'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("lists selected service images")
    func listsSelectedServiceImages() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
                "builder": composeService(name: "builder") {
                    $0.build = ComposeBuild(context: ".")
                },
                "web": ComposeService(name: "web", image: "nginx:latest"),
            ]
        )

        let images = try ComposeOrchestrator().images(project: project, services: ["web", "builder", "api"])

        #expect(images == ["example/api:latest", "nginx:latest"])
    }

    @Test("ps filters containers by project label")
    func psFiltersContainersByProjectLabel() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false)

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json"]])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-api-1", "demo-worker-1"])
    }

    @Test("ps keeps project scoping when all containers are requested")
    func psKeepsProjectScopingWhenAllContainersAreRequested() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: true)

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json", "--all"]])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-api-1", "demo-worker-1"])
    }

    @Test("normalizes a compose file through compose-go")
    func normalizesComposeFileThroughComposeGo() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: nginx:latest
            command: ["nginx", "-g", "daemon off;"]
            ports:
              - "8080:80"
            environment:
              LOG_LEVEL: debug
        volumes:
          data: {}
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        #expect(project.name == "sample")
        #expect(project.services["api"]?.image == "nginx:latest")
        #expect(project.services["api"]?.command == ["nginx", "-g", "daemon off;"])
        #expect(project.services["api"]?.environment?["LOG_LEVEL"] == "debug")
        #expect(project.services["api"]?.ports == ["8080:80"])
        #expect(project.volumes["data"] != nil)
    }

    @Test("normalizer infers project directory from the first compose file")
    func normalizerInfersProjectDirectoryFromFirstComposeFile() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          web:
            image: nginx:latest
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(files: [composeFile.path]))

        #expect(project.workingDirectory == directory.path)
        #expect(project.name == directory.lastPathComponent.lowercased())
        #expect(project.services["web"]?.image == "nginx:latest")
    }

    @Test("normalizer preserves healthchecks configs secrets and extensions")
    func normalizerPreservesHealthchecksConfigsSecretsAndExtensions() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        x-project:
          enabled: true
        services:
          api:
            image: alpine
            healthcheck:
              disable: true
            configs:
              - source: app_config
                target: /etc/app.conf
            secrets:
              - source: app_secret
            x-service:
              owner: platform
        configs:
          app_config:
            external: true
        secrets:
          app_secret:
            external: true
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(files: [composeFile.path]))
        let api = try #require(project.services["api"])

        #expect(project.configs?["app_config"] == .object(["external": .bool(true), "name": .string("app_config")]))
        #expect(project.secrets?["app_secret"] == .object(["external": .bool(true), "name": .string("app_secret")]))
        #expect(project.extensions?["x-project"] == .object(["enabled": .bool(true)]))
        #expect(api.healthcheck == .object(["disable": .bool(true)]))
        #expect(api.configs == [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])])
        #expect(api.secrets == [.object(["source": .string("app_secret"), "target": .string("/run/secrets/app_secret")])])
        #expect(api.extensions?["x-service"] == .object(["owner": .string("platform")]))
    }

    @Test("describes compose errors")
    func describesComposeErrors() {
        #expect(ComposeError.commandFailed(command: "container ps", status: 7, stderr: "").description == "container ps failed with exit code 7")
        #expect(ComposeError.commandFailed(command: "container ps", status: 7, stderr: " denied\n").description == "container ps failed with exit code 7: denied")
        #expect(ComposeError.invalidProject("missing service").description == "invalid compose project: missing service")
        #expect(ComposeError.unsupported("profiles").description == "unsupported compose feature: profiles")
        #expect(ComposeError.missingNormalizer("missing helper").description == "compose normalizer unavailable: missing helper")
    }

    @Test("prints sorted config JSON")
    func printsSortedConfigJSON() throws {
        let project = ComposeProject(name: "demo", services: ["web": ComposeService(name: "web", image: "nginx")])

        let json = try ComposeOrchestrator().config(project: project)

        #expect(json.contains(#""name" : "demo""#))
        #expect(json.contains(#""web" : {"#))
    }

    @Test("config preserves normalized compose extension fields")
    func configPreservesNormalizedComposeExtensionFields() throws {
        let project = composeProject(
            name: "demo",
            services: [
                "web": composeService(name: "web", image: "nginx") {
                    $0.healthcheck = .object(["disable": .bool(true)])
                    $0.configs = [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])]
                    $0.secrets = [.object(["source": .string("app_secret")])]
                    $0.extensions = ["x-service": .object(["owner": .string("platform")])]
                },
            ]
        ) {
            $0.configs = ["app_config": .object(["external": .bool(true)])]
            $0.secrets = ["app_secret": .object(["external": .bool(true)])]
            $0.extensions = ["x-project": .object(["enabled": .bool(true), "retries": .number(3)])]
        }

        let json = try ComposeOrchestrator().config(project: project)
        let decoded = try JSONDecoder().decode(ComposeProject.self, from: Data(json.utf8))

        #expect(decoded.configs?["app_config"] == .object(["external": .bool(true)]))
        #expect(decoded.secrets?["app_secret"] == .object(["external": .bool(true)]))
        #expect(decoded.extensions?["x-project"] == .object(["enabled": .bool(true), "retries": .number(3)]))
        #expect(decoded.services["web"]?.healthcheck == .object(["disable": .bool(true)]))
        #expect(decoded.services["web"]?.configs == [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])])
        #expect(decoded.services["web"]?.secrets == [.object(["source": .string("app_secret")])])
        #expect(decoded.services["web"]?.extensions?["x-service"] == .object(["owner": .string("platform")]))
    }

    @Test("service init key maps to initEnabled")
    func serviceInitKeyMapsToInitEnabled() throws {
        let decoded = try JSONDecoder().decode(ComposeService.self, from: Data(#"{"name":"web","init":true}"#.utf8))

        #expect(decoded.initEnabled == true)

        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(encoded.contains(#""init":true"#))
        #expect(!encoded.contains("initEnabled"))
    }

    @Test("normalizer decodes JSON and forwards compose options")
    func normalizerDecodesJSONAndForwardsOptions() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"{"name":"demo","workingDirectory":"/tmp/demo","composeFiles":["compose.yml"],"services":{"web":{"name":"web","image":"nginx"}},"networks":{},"volumes":{}}"#,
                stderr: ""
            ),
        ])

        let project = try await ComposeNormalizer(runner: runner).normalize(options: ComposeOptions(
            files: ["compose.yml"],
            projectName: "demo",
            profiles: ["dev"],
            envFiles: [".env"],
            projectDirectory: "/tmp/demo"
        ))

        #expect(project.name == "demo")
        #expect(project.services["web"]?.image == "nginx")
        let command = try #require(runner.commands.first)
        #expect(command.arguments.containsSequence(["--file", "compose.yml"]))
        #expect(command.arguments.containsSequence(["--profile", "dev"]))
        #expect(command.arguments.containsSequence(["--env-file", ".env"]))
        #expect(command.arguments.containsSequence(["--project-name", "demo"]))
        #expect(command.arguments.containsSequence(["--project-directory", "/tmp/demo"]))
    }

    @Test("normalizer uses configured fallback launcher")
    func normalizerUsesConfiguredFallbackLauncher() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"{"name":"demo","workingDirectory":"/tmp/demo","composeFiles":["compose.yml"],"services":{"web":{"name":"web","image":"nginx"}},"networks":{},"volumes":{}}"#,
                stderr: ""
            ),
        ])

        _ = try await ComposeNormalizer(runner: runner, fallbackLauncher: "custom-env")
            .normalize(options: ComposeOptions(files: ["compose.yml"], projectDirectory: "/tmp/demo"))

        let command = try #require(runner.commands.first)
        #expect(command.executable == "custom-env")
        #expect(command.arguments.starts(with: ["go", "run", "."]))
        #expect(command.arguments.containsSequence(["--project-directory", "/tmp/demo"]))
    }

    @Test("normalizer forwards inferred project directory")
    func normalizerForwardsInferredProjectDirectory() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"{"name":"demo","workingDirectory":"/tmp/demo","composeFiles":["/tmp/demo/compose.yml"],"services":{"web":{"name":"web","image":"nginx"}},"networks":{},"volumes":{}}"#,
                stderr: ""
            ),
        ])

        _ = try await ComposeNormalizer(runner: runner).normalize(options: ComposeOptions(files: ["/tmp/demo/compose.yml"]))

        let command = try #require(runner.commands.first)
        #expect(command.arguments.containsSequence(["--file", "/tmp/demo/compose.yml"]))
        #expect(command.arguments.containsSequence(["--project-directory", "/tmp/demo"]))
    }

    @Test("normalizer defaults project directory to current working directory")
    func normalizerDefaultsProjectDirectoryToCurrentWorkingDirectory() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"{"name":"demo","workingDirectory":"/tmp/demo","composeFiles":["compose.yml"],"services":{"web":{"name":"web","image":"nginx"}},"networks":{},"volumes":{}}"#,
                stderr: ""
            ),
        ])

        _ = try await ComposeNormalizer(runner: runner).normalize(options: ComposeOptions())

        let command = try #require(runner.commands.first)
        #expect(command.arguments.containsSequence(["--project-directory", FileManager.default.currentDirectoryPath]))
    }

    @Test("normalizer surfaces command and decode failures")
    func normalizerSurfacesCommandAndDecodeFailures() async throws {
        do {
            _ = try await ComposeNormalizer(runner: RecordingRunner(responses: [
                CommandResult(status: 23, stdout: "", stderr: "bad compose"),
            ])).normalize(options: ComposeOptions(files: ["compose.yml"]))
            Issue.record("Expected command failure")
        } catch let error as ComposeError {
            #expect(error == .commandFailed(
                command: "/usr/bin/env go run . --file compose.yml --project-directory \(FileManager.default.currentDirectoryPath)",
                status: 23,
                stderr: "bad compose"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try await ComposeNormalizer(runner: RecordingRunner(responses: [
                CommandResult(status: 0, stdout: "not json", stderr: ""),
            ])).normalize(options: ComposeOptions(files: ["compose.yml"]))
            Issue.record("Expected decode failure")
        } catch let error as ComposeError {
            if case .invalidProject(let message) = error {
                #expect(message.contains("failed to decode normalized compose JSON"))
            } else {
                Issue.record("Unexpected compose error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("build pull and push emit image commands")
    func buildPullAndPushEmitImageCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        dockerfile: "Containerfile",
                        args: ["VERSION": "1"],
                        target: "runtime"
                    )
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await orchestrator.build(project: project, services: [], noCache: true)
        try await orchestrator.pull(project: project, services: ["api", "worker"])
        try await orchestrator.push(project: project, services: ["api", "worker"])

        #expect(runner.commands[0].arguments.containsSequence(["container", "build", "--tag", "example/api:latest"]))
        #expect(runner.commands[0].arguments.containsSequence(["--file", "Containerfile"]))
        #expect(runner.commands[0].arguments.containsSequence(["--target", "runtime"]))
        #expect(runner.commands[0].arguments.contains("--no-cache"))
        #expect(runner.commands[0].arguments.containsSequence(["--build-arg", "VERSION=1"]))
        #expect(runner.commands[0].arguments.last == "api")
        #expect(runner.commands[1].arguments.containsSequence(["--tag", "demo_worker:latest"]))
        #expect(runner.commands[2].arguments == ["container", "image", "pull", "example/api:latest"])
        #expect(runner.commands[3].arguments == ["container", "image", "push", "example/api:latest"])
    }

    @Test("orchestrator uses configured environment launcher")
    func orchestratorUsesConfiguredEnvironmentLauncher() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(environmentLauncher: "custom-env")
        )
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api:latest")]
        )

        try await orchestrator.pull(project: project, services: ["api"])

        let command = try #require(runner.commands.first)
        #expect(command.executable == "custom-env")
        #expect(command.arguments == ["container", "image", "pull", "example/api:latest"])
    }

    @Test("down removes project resources in dependency order")
    func downRemovesProjectResourcesInDependencyOrder() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
            emptyContainerListResult(),
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": "service_started"]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await orchestrator.down(project: project, options: ComposeDownOptions(volumes: true))

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stop", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
            ["container", "stop", "demo-db-1"],
            ["container", "delete", "demo-db-1"],
            ["container", "list", "--format", "json", "--all"],
            ["container", "network", "delete", "demo_default"],
            ["container", "volume", "delete", "demo_data"],
        ])
    }

    @Test("down removes remaining project scoped containers")
    func downRemovesRemainingProjectScopedContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            containerListResult(),
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions())

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stop", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
            ["container", "list", "--format", "json", "--all"],
            ["container", "stop", "demo-worker-1"],
            ["container", "delete", "demo-worker-1"],
        ])
    }

    @Test("lifecycle commands target selected service containers")
    func lifecycleCommandsTargetSelectedServiceContainers() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.tty = true
                    $0.stdinOpen = true
                },
                "web": ComposeService(name: "web", image: "nginx"),
            ]
        )

        try await orchestrator.logs(project: project, services: ["api"], follow: true, tail: 10)
        try await orchestrator.exec(project: project, serviceName: "api", command: ["echo", "ok"], interactive: true, tty: true)
        try await orchestrator.start(project: project, services: ["api"])
        try await orchestrator.stop(project: project, services: ["api"])
        try await orchestrator.restart(project: project, services: ["api"])
        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true)
        try await orchestrator.kill(project: project, services: ["api"], signal: "SIGTERM")
        try await orchestrator.copy(arguments: ["demo-api-1:/tmp/file", "."])

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "logs", "--follow", "-n", "10", "demo-api-1"])
        #expect(commands[1] == ["container", "exec", "--interactive", "--tty", "demo-api-1", "echo", "ok"])
        #expect(commands[2] == ["container", "start", "demo-api-1"])
        #expect(commands[3] == ["container", "stop", "demo-api-1"])
        #expect(commands[4] == ["container", "stop", "demo-api-1"])
        #expect(commands[5] == ["container", "start", "demo-api-1"])
        #expect(commands[6] == ["container", "stop", "demo-api-1"])
        #expect(commands[7] == ["container", "delete", "demo-api-1"])
        #expect(commands[8] == ["container", "kill", "--signal", "SIGTERM", "demo-api-1"])
        #expect(commands[9] == ["container", "cp", "demo-api-1:/tmp/file", "."])
    }

    @Test("run supports one-off containers and option flags")
    func runSupportsOneOffContainersAndOptionFlags() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.entrypoint = ["/bin/sh", "-c"]
                    $0.environment = ["A": "B", "EMPTY": nil]
                    $0.envFiles = [".env"]
                    $0.ports = ["8080:80"]
                    $0.volumes = [
                        ComposeMount(type: "bind", source: "/host", target: "/container", readOnly: true),
                        ComposeMount(type: "tmpfs", target: "/tmp"),
                        ComposeMount(type: "volume", target: "/anon"),
                    ]
                    $0.workingDir = "/work"
                    $0.user = "1000"
                    $0.tty = true
                    $0.stdinOpen = true
                    $0.readOnly = true
                    $0.initEnabled = true
                    $0.tmpfs = ["/cache"]
                    $0.dns = ["1.1.1.1"]
                    $0.dnsSearch = ["local"]
                    $0.capAdd = ["NET_ADMIN"]
                    $0.capDrop = ["MKNOD"]
                    $0.memLimit = "1024"
                    $0.cpus = "2"
                },
            ]
        )

        try await orchestrator.run(project: project, serviceName: "job", command: ["echo", "ok"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "run", "--name"]))
        #expect(command.contains("--rm"))
        #expect(command.containsSequence(["--env", "A=B"]))
        #expect(command.containsSequence(["--env", "EMPTY"]))
        #expect(command.containsSequence(["--env-file", ".env"]))
        #expect(command.containsSequence(["--publish", "8080:80"]))
        #expect(command.containsSequence(["--volume", "/host:/container:ro"]))
        #expect(command.containsSequence(["--tmpfs", "/tmp"]))
        #expect(command.containsSequence(["--workdir", "/work"]))
        #expect(command.containsSequence(["--user", "1000"]))
        #expect(command.contains("--tty"))
        #expect(command.contains("--interactive"))
        #expect(command.containsSequence(["--cap-add", "NET_ADMIN"]))
        #expect(command.containsSequence(["--cap-drop", "MKNOD"]))
        #expect(command.containsSequence(["--dns", "1.1.1.1"]))
        #expect(command.containsSequence(["--dns-search", "local"]))
        #expect(command.containsSequence(["--memory", "1024"]))
        #expect(command.containsSequence(["--cpus", "2"]))
        #expect(command.containsSequence(["--entrypoint", "/bin/sh -c"]))
        #expect(command.contains("--read-only"))
        #expect(command.contains("--init"))
        #expect(Array(command.suffix(3)) == ["alpine", "echo", "ok"])
    }

    @Test("up reuses existing containers when no recreate is requested")
    func upReusesExistingContainersWhenNoRecreateIsRequested() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [.success])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await orchestrator.up(project: project, options: ComposeUpOptions(noRecreate: true))

        #expect(runner.commands.map(\.arguments) == [["container", "inspect", "demo-api-1"]])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
    }

    @Test("up reuses existing containers when config hash matches")
    func upReusesExistingContainersWhenConfigHashMatches() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])
        let createRunner = RecordingRunner(responses: [.failure, .success])

        try await ComposeOrchestrator(runner: createRunner).up(project: project, options: ComposeUpOptions())

        let run = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: run))
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [inspectResult(configHash: hash)])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.map(\.arguments) == [["container", "inspect", "demo-api-1"]])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
    }

    @Test("up recreates existing containers when config hash changes")
    func upRecreatesExistingContainersWhenConfigHashChanges() async throws {
        let runner = RecordingRunner(responses: [
            inspectResult(configHash: "stale"),
            .success,
            .success,
            .success,
        ])
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())

        #expect(runner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(runner.commands[1].arguments == ["container", "stop", "demo-api-1"])
        #expect(runner.commands[2].arguments == ["container", "delete", "demo-api-1"])
        #expect(runner.commands[3].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(composeConfigHash(in: runner.commands[3].arguments) != "stale")
    }

    @Test("up force recreates existing containers even when config hash matches")
    func upForceRecreatesExistingContainersWhenConfigHashMatches() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])
        let createRunner = RecordingRunner(responses: [.failure, .success])

        try await ComposeOrchestrator(runner: createRunner).up(project: project, options: ComposeUpOptions())

        let run = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: run))
        let runner = RecordingRunner(responses: [
            inspectResult(configHash: hash),
            .success,
            .success,
            .success,
        ])

        try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions(forceRecreate: true))

        #expect(runner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(runner.commands[1].arguments == ["container", "stop", "demo-api-1"])
        #expect(runner.commands[2].arguments == ["container", "delete", "demo-api-1"])
        #expect(runner.commands[3].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
    }

    @Test("dry run emits quoted commands")
    func dryRunEmitsQuotedCommands() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, containerBinary: "container bin", emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api:latest")])

        try await orchestrator.pull(project: project, services: ["api"])

        #expect(emitted.messages == ["+ 'container bin' image pull example/api:latest"])
    }

    @Test("invalid and unsupported projects fail clearly")
    func invalidAndUnsupportedProjectsFailClearly() async throws {
        do {
            try await ComposeOrchestrator().up(project: ComposeProject(name: "", services: [:]), options: ComposeUpOptions())
            Issue.record("Expected empty project name failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("project name is empty"))
        }

        do {
            try await ComposeOrchestrator().exec(project: ComposeProject(name: "demo", services: [:]), serviceName: "missing", command: ["true"], interactive: false, tty: false)
            Issue.record("Expected unknown service failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unknown service 'missing'"))
        }

        do {
            try await ComposeOrchestrator().exec(
                project: ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")]),
                serviceName: "api",
                command: [],
                interactive: false,
                tty: false
            )
            Issue.record("Expected empty exec command failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("exec requires a command"))
        }

        do {
            try await ComposeOrchestrator().copy(arguments: [])
            Issue.record("Expected cp argument failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("cp requires source and destination"))
        }

        let unsupportedProjects = [
            ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                $0.networks = ["a", "b"]
            }]),
            ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                $0.extraHosts = ["db:127.0.0.1"]
            }]),
            ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                $0.privileged = true
            }]),
        ]

        for project in unsupportedProjects {
            do {
                try await ComposeOrchestrator().up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported runtime feature")
            } catch let error as ComposeError {
                if case .unsupported = error {
                    continue
                } else {
                    Issue.record("Unexpected compose error: \(error)")
                }
            }
        }
    }

    @Test("command failures are surfaced")
    func commandFailuresAreSurfaced() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(status: 4, stdout: "", stderr: ""),
        ])
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).pull(project: project, services: ["api"])
            Issue.record("Expected command failure")
        } catch let error as ComposeError {
            #expect(error == .commandFailed(command: "container image pull example/api", status: 4, stderr: ""))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("process runner captures stdout stderr status input env and cwd")
    func processRunnerCapturesProcessDetails() async throws {
        let directory = FileManager.default.temporaryDirectory
        let script = "printf \"%s:%s\" \"$PROCESS_RUNNER_VALUE\" \"$(pwd)\"; cat; printf err >&2"
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", script],
            workingDirectory: directory,
            environment: ["PROCESS_RUNNER_VALUE": "ok"],
            input: Data(" input".utf8)
        )

        #expect(result.succeeded)
        #expect(
            result.stdout == "ok:\(directory.path) input"
                || result.stdout == "ok:/private\(directory.path) input"
        )
        #expect(result.stderr == "err")
    }

    @Test("recording runner captures command environment")
    func recordingRunnerCapturesCommandEnvironment() async throws {
        let runner = RecordingRunner()

        _ = try await runner.run("/usr/bin/env", ["true"], environment: ["SAMPLE": "value"])

        let command = try #require(runner.commands.first)
        #expect(command.environment == ["SAMPLE": "value"])
    }

    @Test("recording runner captures command input")
    func recordingRunnerCapturesCommandInput() async throws {
        let runner = RecordingRunner()
        let input = Data("payload".utf8)

        _ = try await runner.run("/usr/bin/env", ["true"], input: input)

        let command = try #require(runner.commands.first)
        #expect(command.input == input)
    }

    @Test("process runner drains large stdout and stderr while process runs")
    func processRunnerDrainsLargeOutputWhileProcessRuns() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            [
                "-c",
                """
                python3 - <<'PY'
                import sys
                sys.stdout.write("o" * 262144)
                sys.stdout.flush()
                sys.stderr.write("e" * 262144)
                sys.stderr.flush()
                PY
                """,
            ]
        )

        #expect(result.succeeded)
        #expect(result.stdout.count == 262_144)
        #expect(result.stderr.count == 262_144)
    }

    @Test("process runner reports nonzero status")
    func processRunnerReportsNonzeroStatus() async throws {
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "printf nope >&2; exit 9"])

        #expect(!result.succeeded)
        #expect(result.status == 9)
        #expect(result.stderr == "nope")
    }
}

private extension CommandResult {
    static let success = CommandResult(status: 0, stdout: "", stderr: "")
    static let failure = CommandResult(status: 1, stdout: "", stderr: "")
}

private let composeConfigHashLabel = "com.apple.container.compose.config-hash"
private let composeProjectLabel = "com.apple.container.compose.project"

private func inspectResult(configHash: String) -> CommandResult {
    CommandResult(
        status: 0,
        stdout: """
        [
          {
            "id": "demo-api-1",
            "configuration": {
              "labels": {
                "\(composeConfigHashLabel)": "\(configHash)"
              }
            }
          }
        ]
        """,
        stderr: ""
    )
}

private func composeConfigHash(in arguments: [String]) -> String? {
    for index in arguments.indices where arguments[index] == "--label" {
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            continue
        }
        let label = arguments[valueIndex]
        let prefix = "\(composeConfigHashLabel)="
        if label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
    }
    return nil
}

private func containerListResult() -> CommandResult {
    CommandResult(
        status: 0,
        stdout: """
        [
          {
            "id": "demo-api-1",
            "configuration": {
              "labels": {
                "\(composeProjectLabel)": "demo"
              }
            }
          },
          {
            "id": "other-api-1",
            "configuration": {
              "labels": {
                "\(composeProjectLabel)": "other"
              }
            }
          },
          {
            "id": "demo-worker-1",
            "Config": {
              "Labels": {
                "\(composeProjectLabel)": "demo"
              }
            }
          }
        ]
        """,
        stderr: ""
    )
}

private func emptyContainerListResult() -> CommandResult {
    CommandResult(status: 0, stdout: "[]", stderr: "")
}

private struct ListedContainer: Decodable {
    var id: String
}

private func listedContainerIDs(from output: String) throws -> [String] {
    try JSONDecoder().decode([ListedContainer].self, from: Data(output.utf8)).map(\.id)
}

private final class MessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(message)
    }
}

private extension Array where Element: Equatable {
    func containsSequence(_ sequence: [Element]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else {
            return false
        }
        return indices.contains { index in
            let end = self.index(index, offsetBy: sequence.count, limitedBy: endIndex)
            guard let end else {
                return false
            }
            return Array(self[index..<end]) == sequence
        }
    }
}

private extension Array where Element == String {
    func containsLabel(withPrefix prefix: String) -> Bool {
        indices.contains { index in
            self[index] == "--label"
                && self.index(after: index) < endIndex
                && self[self.index(after: index)].hasPrefix(prefix)
        }
    }
}
