import ComposeCore
import Foundation
import Testing

@Suite("Compose orchestrator")
struct ComposeOrchestratorTests {
    @Test("orders selected services after dependencies")
    func ordersSelectedServicesAfterDependencies() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest", dependsOn: ["db": "service_started"]),
                "db": ComposeService(name: "db", image: "postgres:16"),
                "web": ComposeService(name: "web", image: "nginx:latest", dependsOn: ["api": "service_started"]),
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
                "api": ComposeService(name: "api", image: "example/api:latest", dependsOn: ["worker": "service_started"]),
                "worker": ComposeService(name: "worker", image: "example/worker:latest", dependsOn: ["api": "service_started"]),
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
        let project = ComposeProject(
            name: "demo",
            composeFiles: ["/tmp/compose.yml"],
            services: [
                "api": ComposeService(
                    name: "api",
                    image: "example/api:latest",
                    command: ["serve"],
                    environment: ["LOG_LEVEL": "debug"],
                    ports: ["8080:80"],
                    volumes: [ComposeMount(type: "volume", source: "cache", target: "/cache")],
                    networks: ["default"],
                    labels: ["com.example.role": "api"]
                ),
            ],
            networks: ["default": ComposeNetwork(name: "default")],
            volumes: ["cache": ComposeVolume(name: "cache")]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.allSatisfy { $0.executable == "/usr/bin/env" })
        #expect(runner.commands.allSatisfy { $0.arguments.first == "container" })
        #expect(runner.commands[0].arguments.containsSequence(["network", "create"]))
        #expect(runner.commands[0].arguments.contains("demo_default"))
        #expect(runner.commands[1].arguments.containsSequence(["volume", "create"]))
        #expect(runner.commands[1].arguments.contains("demo_cache"))
        #expect(runner.commands[2].arguments == ["container", "inspect", "demo-api-1"])

        let run = runner.commands[3].arguments
        #expect(run.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.oneoff=false"]))
        #expect(run.containsSequence(["--label", "com.example.role=api"]))
        #expect(run.containsSequence(["--env", "LOG_LEVEL=debug"]))
        #expect(run.containsSequence(["--publish", "8080:80"]))
        #expect(run.containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(run.containsSequence(["--network", "demo_default"]))
        #expect(Array(run.suffix(2)) == ["example/api:latest", "serve"])
    }

    @Test("rejects dependency conditions that need runtime gaps")
    func rejectsUnsupportedDependencyConditions() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": ComposeService(
                    name: "api",
                    image: "example/api:latest",
                    dependsOn: ["job": "service_completed_successfully"]
                ),
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
                "builder": ComposeService(name: "builder", build: ComposeBuild(context: ".")),
                "web": ComposeService(name: "web", image: "nginx:latest"),
            ]
        )

        let images = try ComposeOrchestrator().images(project: project, services: ["web", "builder", "api"])

        #expect(images == ["example/api:latest", "nginx:latest"])
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
}

private extension CommandResult {
    static let success = CommandResult(status: 0, stdout: "", stderr: "")
    static let failure = CommandResult(status: 1, stdout: "", stderr: "")
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
