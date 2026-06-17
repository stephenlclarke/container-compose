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

private func composeRunOptions(
    command: [String] = [],
    configure: (inout ComposeRunOptions) -> Void = { _ in }
) -> ComposeRunOptions {
    var options = ComposeRunOptions()
    options.command = command
    configure(&options)
    return options
}

private func projectWithRuntimeResources(networkName: String, volumeName: String) -> ComposeProject {
    composeProject(
        name: "demo",
        services: [
            "api": composeService(name: "api", image: "alpine") {
                $0.networks = ["shared"]
                $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
            },
        ]
    ) {
        $0.networks = ["shared": ComposeNetwork(name: networkName, external: true)]
        $0.volumes = ["cache": ComposeVolume(name: volumeName, external: true)]
    }
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
                    $0.platform = "linux/amd64"
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
        #expect(run.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!run.contains("--detach"))
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
        #expect(run.containsSequence(["--platform", "linux/amd64"]))
        #expect(Array(run.suffix(2)) == ["example/api:latest", "serve"])
    }

    @Test("create creates resources and service containers without starting them")
    func createCreatesResourcesAndServiceContainersWithoutStartingThem() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .failure,
            .success,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.command = ["serve"]
                    $0.environment = ["LOG_LEVEL": "debug"]
                    $0.ports = ["8080:80"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    $0.networks = ["default"]
                    $0.platform = "linux/amd64"
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner).create(project: project, options: ComposeCreateOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "network", "create"]))
        #expect(commands[1].containsSequence(["container", "volume", "create"]))
        #expect(commands[2] == ["container", "inspect", "demo-api-1"])

        let create = commands[3]
        #expect(create.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!create.contains("--detach"))
        #expect(create.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(create.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(create.containsSequence(["--label", "com.apple.container.compose.oneoff=false"]))
        #expect(create.containsSequence(["--env", "LOG_LEVEL=debug"]))
        #expect(create.containsSequence(["--publish", "8080:80"]))
        #expect(create.containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(create.containsSequence(["--network", "demo_default"]))
        #expect(create.containsSequence(["--platform", "linux/amd64"]))
        #expect(Array(create.suffix(2)) == ["example/api:latest", "serve"])
    }

    @Test("create applies build pull policy before creating containers")
    func createAppliesBuildPullPolicyBeforeCreatingContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .failure,
            .success,
            .failure,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).create(
            project: project,
            options: ComposeCreateOptions {
                $0.pullPolicy = "build"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/api"]))
        #expect(commands[0].last == "api")
        #expect(commands[1].containsSequence(["container", "build", "--tag", "demo_worker:latest"]))
        #expect(commands[1].last == "worker")
        #expect(commands[2] == ["container", "inspect", "demo-api-1"])
        #expect(commands[3].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[4] == ["container", "inspect", "demo-worker-1"])
        #expect(commands[5].starts(with: ["container", "create", "--name", "demo-worker-1"]))
    }

    @Test("create pull if not present pulls only absent images")
    func createPullIfNotPresentPullsOnlyAbsentImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .failure,
            .success,
            .failure,
            .success,
            .failure,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner).create(
            project: project,
            options: ComposeCreateOptions {
                $0.pullPolicy = "if_not_present"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "inspect", "example/api"])
        #expect(commands[1] == ["container", "image", "inspect", "postgres"])
        #expect(commands[2] == ["container", "image", "pull", "postgres"])
        #expect(commands[3] == ["container", "inspect", "demo-api-1"])
        #expect(commands[4].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[5] == ["container", "inspect", "demo-db-1"])
        #expect(commands[6].starts(with: ["container", "create", "--name", "demo-db-1"]))
    }

    @Test("create auto builds build-only services by default")
    func createAutoBuildsBuildOnlyServicesByDefault() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .failure,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).create(project: project, options: ComposeCreateOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "demo_worker:latest"]))
        #expect(commands[0].last == "worker")
        #expect(commands[1] == ["container", "inspect", "demo-worker-1"])
        #expect(commands[2].starts(with: ["container", "create", "--name", "demo-worker-1"]))
    }

    @Test("create no-build skips auto build for build-only service")
    func createNoBuildSkipsAutoBuildForBuildOnlyService() async throws {
        let runner = RecordingRunner(responses: [
            .failure,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).create(
            project: project,
            options: ComposeCreateOptions {
                $0.noBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(!commands.contains { $0.containsSequence(["container", "build"]) })
        #expect(commands[0] == ["container", "inspect", "demo-worker-1"])
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(commands[1].last == "demo_worker:latest")
    }

    @Test("create reuses or recreates existing containers according to policy")
    func createReusesOrRecreatesExistingContainersAccordingToPolicy() async throws {
        let emitted = MessageRecorder()
        let reuseRunner = RecordingRunner(responses: [.success])
        try await ComposeOrchestrator(
            runner: reuseRunner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )
        .create(
            project: ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")]),
            options: ComposeCreateOptions {
                $0.noRecreate = true
            }
        )

        #expect(reuseRunner.commands.map(\.arguments) == [["container", "inspect", "demo-api-1"]])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])

        let recreateRunner = RecordingRunner(responses: [
            inspectResult(configHash: "stale"),
            .success,
            .success,
            .success,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await ComposeOrchestrator(runner: recreateRunner).create(project: project, options: ComposeCreateOptions())

        #expect(recreateRunner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(recreateRunner.commands[1].arguments == ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"])
        #expect(recreateRunner.commands[2].arguments == ["container", "delete", "demo-api-1"])
        #expect(recreateRunner.commands[3].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
    }

    @Test("create validates incompatible options and unsupported scale before side effects")
    func createValidatesIncompatibleOptionsAndUnsupportedScaleBeforeSideEffects() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        for options in [
            ComposeCreateOptions {
                $0.build = true
                $0.noBuild = true
            },
            ComposeCreateOptions {
                $0.forceRecreate = true
                $0.noRecreate = true
            },
        ] {
            let runner = RecordingRunner()
            do {
                try await ComposeOrchestrator(runner: runner).create(project: project, options: options)
                Issue.record("Expected invalid create option combination")
            } catch let error as ComposeError {
                #expect(error == .invalidProject(options.build ? "--build and --no-build are incompatible" : "--force-recreate and --no-recreate are incompatible"))
            }
            #expect(runner.commands.isEmpty)
        }

        let scaleRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: scaleRunner).create(
                project: project,
                options: ComposeCreateOptions {
                    $0.scales = ["api=2"]
                }
            )
            Issue.record("Expected unsupported create scale failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("create --scale: service replica scaling is not implemented by container-compose yet"))
        }
        #expect(scaleRunner.commands.isEmpty)

        let pullRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: pullRunner).create(
                project: project,
                options: ComposeCreateOptions {
                    $0.pullPolicy = "daily"
                }
            )
            Issue.record("Expected unsupported create pull policy failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unsupported pull policy 'daily'"))
        }
        #expect(pullRunner.commands.isEmpty)
    }

    @Test("up validates incompatible recreate options before side effects")
    func upValidatesIncompatibleRecreateOptionsBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions(forceRecreate: true, noRecreate: true)
            )
            Issue.record("Expected invalid up option combination")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--force-recreate and --no-recreate are incompatible"))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported scale before side effects")
    func upRejectsUnsupportedScaleBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions(scales: ["api=2"])
            )
            Issue.record("Expected unsupported up scale failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("up --scale: service replica scaling is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up uses external resource names without creating project resources")
    func upUsesExternalResourceNamesWithoutCreatingProjectResources() async throws {
        let runner = RecordingRunner(responses: [
            .failure,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networks = ["shared"]
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/data")]
                },
            ]
        ) {
            $0.networks = ["shared": ComposeNetwork(name: "corp-net", external: true)]
            $0.volumes = ["data": ComposeVolume(name: "corp-data", external: true)]
        }

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0] == ["container", "inspect", "demo-api-1"])
        #expect(!commands.contains { $0.containsSequence(["network", "create"]) })
        #expect(!commands.contains { $0.containsSequence(["volume", "create"]) })

        let run = commands[1]
        #expect(run.containsSequence(["--network", "corp-net"]))
        #expect(run.containsSequence(["--volume", "corp-data:/data"]))
        #expect(!run.contains("demo_shared"))
        #expect(!run.contains("demo_data"))
    }

    @Test("orchestrator honors explicit non external resource names")
    func orchestratorHonorsExplicitNonExternalResourceNames() async throws {
        let upRunner = RecordingRunner(responses: [
            .success,
            .success,
            .failure,
            .success,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "team-net")]
            $0.volumes = ["cache": ComposeVolume(name: "team-cache")]
        }

        try await ComposeOrchestrator(runner: upRunner).up(project: project, options: ComposeUpOptions())

        let upCommands = upRunner.commands.map(\.arguments)
        #expect(upCommands[0].containsSequence(["network", "create"]))
        #expect(upCommands[0].last == "team-net")
        #expect(upCommands[1].containsSequence(["volume", "create"]))
        #expect(upCommands[1].last == "team-cache")
        #expect(upCommands[3].containsSequence(["--network", "team-net"]))
        #expect(upCommands[3].containsSequence(["--volume", "team-cache:/cache"]))

        let downRunner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
        ])

        try await ComposeOrchestrator(runner: downRunner).down(project: project, options: ComposeDownOptions(volumes: true))

        #expect(downRunner.commands.map(\.arguments) == [
            ["container", "stop", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
            ["container", "network", "delete", "team-net"],
            ["container", "volume", "delete", "team-cache"],
        ])
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
        #expect(runner.commands[1].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!runner.commands[1].arguments.contains("--detach"))
        #expect(runner.commands[1].arguments.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(runner.commands[1].arguments.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(runner.commands[1].arguments.last == "example/api:latest")
        #expect(runner.commands[2].arguments == ["container", "list", "--format", "json", "--all"])
        #expect(runner.commands[3].arguments == ["container", "stop", "demo-worker-1"])
        #expect(runner.commands[4].arguments == ["container", "delete", "demo-worker-1"])
    }

    @Test("up emits detach flag only when requested")
    func upEmitsDetachFlagOnlyWhenRequested() async throws {
        let runner = RecordingRunner(responses: [
            .failure,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions(detach: true))

        #expect(runner.commands[1].arguments.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(runner.commands[1].arguments.last == "example/api:latest")
    }

    @Test("up build does not rebuild build-only services")
    func upBuildDoesNotRebuildBuildOnlyServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .failure,
            .success,
            .failure,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions(build: true))

        let buildCommands = runner.commands.map(\.arguments).filter { $0.starts(with: ["container", "build"]) }
        #expect(buildCommands.count == 2)
        #expect(buildCommands[0].containsSequence(["--tag", "example/api"]))
        #expect(buildCommands[0].last == "api")
        #expect(buildCommands[1].containsSequence(["--tag", "demo_worker:latest"]))
        #expect(buildCommands[1].last == "worker")
    }

    @Test("up pull missing pulls only absent images")
    func upPullMissingPullsOnlyAbsentImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .failure,
            .success,
            .failure,
            .success,
            .failure,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions(pullPolicy: "missing"))

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "inspect", "example/api"])
        #expect(commands[1] == ["container", "image", "inspect", "postgres"])
        #expect(commands[2] == ["container", "image", "pull", "postgres"])
        #expect(commands[3] == ["container", "inspect", "demo-api-1"])
        #expect(commands[5] == ["container", "inspect", "demo-db-1"])
    }

    @Test("up pull if not present uses the missing-image flow")
    func upPullIfNotPresentUsesMissingImageFlow() async throws {
        let runner = RecordingRunner(responses: [
            .failure,
            .success,
            .failure,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(runner: runner).up(
            project: project,
            options: ComposeUpOptions(pullPolicy: "if_not_present")
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "inspect", "example/api"])
        #expect(commands[1] == ["container", "image", "pull", "example/api"])
        #expect(commands[2] == ["container", "inspect", "demo-api-1"])
        #expect(commands[3].starts(with: ["container", "run", "--name", "demo-api-1"]))
    }

    @Test("up applies service pull policies when no global pull policy is set")
    func upAppliesServicePullPoliciesWhenNoGlobalPullPolicyIsSet() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .failure,
            .success,
            .failure,
            .success,
            .failure,
            .success,
            .failure,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "always"
                },
                "db": composeService(name: "db", image: "postgres") {
                    $0.pullPolicy = "never"
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.pullPolicy = "missing"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "pull", "example/api"])
        #expect(commands[1] == ["container", "image", "inspect", "example/worker"])
        #expect(commands[2] == ["container", "image", "pull", "example/worker"])
        #expect(commands[3] == ["container", "inspect", "demo-api-1"])
        #expect(commands[5] == ["container", "inspect", "demo-db-1"])
        #expect(commands[7] == ["container", "inspect", "demo-worker-1"])
    }

    @Test("up rejects unsupported service pull policies before creating resources")
    func upRejectsUnsupportedServicePullPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "build"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported service pull policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses pull_policy 'build'; supported values are always, missing, if_not_present, and never"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("rejects dependency conditions with runtime gap reasons")
    func rejectsUnsupportedDependencyConditions() async throws {
        let cases = [
            (
                condition: "service_healthy",
                reason: "health status support needs an apple/container runtime gap PR"
            ),
            (
                condition: "service_completed_successfully",
                reason: "exit code and completion time need an apple/container runtime gap PR"
            ),
            (
                condition: "custom_condition",
                reason: "dependency condition support needs an apple/container runtime gap PR"
            ),
        ]

        for testCase in cases {
            let runner = RecordingRunner()
            let project = ComposeProject(
                name: "demo",
                services: [
                    "job": ComposeService(name: "job", image: "example/job:latest"),
                    "api": composeService(name: "api", image: "example/api:latest") {
                        $0.dependsOn = ["job": testCase.condition]
                    },
                ]
            )

            do {
                try await ComposeOrchestrator(runner: runner)
                    .up(project: project, options: ComposeUpOptions(services: ["api"]))
                Issue.record("Expected unsupported dependency condition")
            } catch let error as ComposeError {
                #expect(error == .unsupported("service 'api' depends on 'job' with condition '\(testCase.condition)'; \(testCase.reason)"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported links before creating resources")
    func upRejectsUnsupportedLinksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported links error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses links; legacy link support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported hostnames before creating resources")
    func upRejectsUnsupportedHostnamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.hostname = "custom-api"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported hostname error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses hostname; custom hostname support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported domain names before creating resources")
    func upRejectsUnsupportedDomainNamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.domainName = "example.test"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported domain name error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses domainname; custom domain name support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported DNS options before creating resources")
    func upRejectsUnsupportedDNSOptionsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dnsOptions = ["use-vc"]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported DNS option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses dns_opt; DNS option support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported sysctls before creating resources")
    func upRejectsUnsupportedSysctlsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.sysctls = ["net.core.somaxconn": "1024"]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported sysctls error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses sysctls; sysctl support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported network aliases before creating resources")
    func upRejectsUnsupportedNetworkAliasesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["api.internal"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported network alias error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses network aliases; network alias support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects multiple networks with apple/container runtime gap before creating resources")
    func upRejectsMultipleNetworksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["frontend", "backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = [
                "frontend": ComposeNetwork(name: "frontend"),
                "backend": ComposeNetwork(name: "backend"),
            ]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported multiple network error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' declares multiple networks; apple/container does not expose network connect yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported network options before creating resources")
    func upRejectsUnsupportedNetworkOptionsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(addressing: .init(ipv4Address: "10.10.0.5"), priority: 42),
                    ]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported network option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses network attachment options ipv4_address, priority on network 'backend'; network attachment options need an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("network option addressing maps to normalized fields")
    func networkOptionAddressingMapsToNormalizedFields() {
        let options = ComposeNetworkOptions(
            addressing: .init(
                ipv4Address: "10.10.0.5",
                ipv6Address: "fd00::5",
                linkLocalIPs: ["169.254.1.5"],
                macAddress: "02:42:ac:11:00:05"
            ),
            priority: 42
        )

        #expect(options.ipv4Address == "10.10.0.5")
        #expect(options.ipv6Address == "fd00::5")
        #expect(options.linkLocalIPs == ["169.254.1.5"])
        #expect(options.macAddress == "02:42:ac:11:00:05")
        #expect(options.priority == 42)
    }

    @Test("up rejects unsupported network mode before creating resources")
    func upRejectsUnsupportedNetworkModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networkMode = "service:redis"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported network mode error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses network_mode 'service:redis'; network mode support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported namespace and cgroup fields before creating resources")
    func upRejectsUnsupportedNamespaceAndCgroupFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedRuntimeStringFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported CPU resource fields before creating resources")
    func upRejectsUnsupportedCPUResourceFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedCPUResourceFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported memory and process resource fields before creating resources")
    func upRejectsUnsupportedMemoryAndProcessResourceFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedMemoryAndProcessResourceFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported block IO config before creating resources")
    func upRejectsUnsupportedBlockIOConfigBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.blkioConfig = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported block IO config error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses blkio_config; block I/O controls are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported develop config before creating resources")
    func upRejectsUnsupportedDevelopConfigBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported develop config error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses develop; develop/watch workflows are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported build fields before creating resources")
    func upRejectsUnsupportedBuildFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api", unsupportedFields: ["additional_contexts", "ssh"])
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported build field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses unsupported build fields additional_contexts, ssh; advanced build fields are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported deploy fields before creating resources")
    func upRejectsUnsupportedDeployFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["mode", "resources.limits", "placement"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported deploy field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses unsupported deploy fields mode, resources.limits, placement; Compose Deploy Specification beyond replica count is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported provider model and hook fields before creating resources")
    func upRejectsUnsupportedProviderModelAndHookFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedProviderModelAndHookFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported user and security option fields before creating resources")
    func upRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedUserAndSecurityOptionFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported device access fields before creating resources")
    func upRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedDeviceAccessFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported service scale before creating resources")
    func upRejectsUnsupportedServiceScaleBeforeCreatingResources() async throws {
        for scale in [0, 2] {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        $0.scale = scale
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported scale error")
            } catch let error as ComposeError {
                #expect(error == .unsupported("service 'api' uses scale \(scale); service replica scaling is not implemented by container-compose yet"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported metadata and logging fields before creating resources")
    func upRejectsUnsupportedMetadataAndLoggingFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedServiceMetadataAndLoggingFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported volume shortcut fields before creating resources")
    func upRejectsUnsupportedVolumeShortcutFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedServiceVolumeShortcutFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported API socket mounting before creating resources")
    func upRejectsUnsupportedAPISocketBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.useAPISocket = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported API socket error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses use_api_socket; API socket mounting is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported MAC address before creating resources")
    func upRejectsUnsupportedMACAddressBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.macAddress = "02:42:ac:11:00:03"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported MAC address error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses mac_address '02:42:ac:11:00:03'; MAC address support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported healthchecks before creating resources")
    func upRejectsUnsupportedHealthchecksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.healthcheck = .object(["disable": .bool(true)])
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported healthcheck error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses healthcheck; health status support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported configs before creating resources")
    func upRejectsUnsupportedConfigsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.configs = ["app_config": .object(["external": .bool(true)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported configs error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses configs; config mount support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported secrets before creating resources")
    func upRejectsUnsupportedSecretsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("/run/secrets/app_secret")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.secrets = ["app_secret": .object(["external": .bool(true)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported secrets error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses secrets; secret mount support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported restart policies before creating resources")
    func upRejectsUnsupportedRestartPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.restart = "unless-stopped"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses restart policy 'unless-stopped'; restart policy support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("images lists selected created container image records")
    func imagesListsSelectedCreatedContainerImageRecords() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
                "worker": ComposeService(name: "worker", image: "example/worker:debug"),
                "web": ComposeService(name: "web", image: "nginx:latest"),
            ]
        )

        try await orchestrator.images(project: project, services: ["api"], options: ComposeImagesOptions())

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json", "--all"]])
        let output = try #require(emitted.messages.first)
        #expect(output.contains("CONTAINER"))
        #expect(output.contains("REPOSITORY"))
        #expect(output.contains("demo-api-1"))
        #expect(output.contains("localhost:5000/example/api"))
        #expect(output.contains("latest"))
        #expect(output.contains("aaaaaaaaaaaa"))
        #expect(output.contains("linux/arm64"))
        #expect(!output.contains("demo-worker-1"))
    }

    @Test("images quiet prints created image IDs")
    func imagesQuietPrintsCreatedImageIDs() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
                "worker": ComposeService(name: "worker", image: "example/worker:debug"),
            ]
        )

        try await orchestrator.images(project: project, services: [], options: ComposeImagesOptions(quiet: true))

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json", "--all"]])
        #expect(emitted.messages == ["aaaaaaaaaaaa\nbbbbbbbbbbbb"])
    }

    @Test("images json renders created image records")
    func imagesJSONRendersCreatedImageRecords() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
                "worker": ComposeService(name: "worker", image: "example/worker:debug"),
            ]
        )

        try await orchestrator.images(project: project, services: [], options: ComposeImagesOptions(format: "json"))

        let data = Data(try #require(emitted.messages.first).utf8)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(records.map { $0["container"] } == ["demo-api-1", "demo-worker-1"])
        #expect(records.map { $0["repository"] } == ["localhost:5000/example/api", "example/worker"])
        #expect(records.map { $0["tag"] } == ["latest", "debug"])
        #expect(records.map { $0["imageID"] } == ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
    }

    @Test("images rejects unsupported output formats")
    func imagesRejectsUnsupportedOutputFormats() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).images(project: project, services: [], options: ComposeImagesOptions(format: "yaml"))
            Issue.record("Expected unsupported images format error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("images --format 'yaml'; supported formats are table and json"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("stats targets project service containers")
    func statsTargetsProjectServiceContainers() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": composeService(name: "db", image: "postgres") {
                    $0.containerName = "custom-db"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).stats(project: project, options: ComposeStatsOptions())
        try await ComposeOrchestrator(runner: runner).stats(
            project: project,
            options: ComposeStatsOptions(services: ["db"], format: "json", noStream: true)
        )

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stats", "demo-api-1", "custom-db"],
            ["container", "stats", "--format", "json", "--no-stream", "custom-db"],
        ])
    }

    @Test("stats rejects unsupported options before runtime commands")
    func statsRejectsUnsupportedOptionsBeforeRuntimeCommands() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        let cases: [(ComposeStatsOptions, ComposeError)] = [
            (
                ComposeStatsOptions(services: ["api", "db"]),
                .invalidProject("stats accepts at most one service")
            ),
            (
                ComposeStatsOptions(all: true),
                .unsupported("stats --all: apple/container stats only reports running containers")
            ),
            (
                ComposeStatsOptions(format: "yaml"),
                .unsupported("stats --format 'yaml': apple/container stats supports table and json output")
            ),
            (
                ComposeStatsOptions(noTrunc: true),
                .unsupported("stats --no-trunc: apple/container stats does not expose truncation control")
            ),
        ]

        for (options, expectedError) in cases {
            let runner = RecordingRunner()
            do {
                try await ComposeOrchestrator(runner: runner).stats(project: project, options: options)
                Issue.record("Expected unsupported stats option failure")
            } catch let error as ComposeError {
                #expect(error == expectedError)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(runner.commands.isEmpty)
        }
    }

    @Test("ls lists compose projects with grouped status")
    func lsListsComposeProjectsWithGroupedStatus() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ls(options: ComposeLsOptions(all: true))

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json", "--all"]])
        let output = try #require(emitted.messages.first)
        #expect(output.contains("NAME"))
        #expect(output.contains("STATUS"))
        #expect(output.contains("CONFIG FILES"))
        #expect(output.contains("demo"))
        #expect(output.contains("running(1), stopped(1)"))
        #expect(output.contains("/tmp/demo/compose.yml,/tmp/demo/compose.override.yml"))
        #expect(output.contains("other"))
        #expect(output.contains("/tmp/other/compose.yml"))
    }

    @Test("ls defaults to running projects only")
    func lsDefaultsToRunningProjectsOnly() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ls()

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json"]])
        #expect(try #require(emitted.messages.first).contains("demo"))
    }

    @Test("ls quiet prints filtered project names")
    func lsQuietPrintsFilteredProjectNames() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ls(options: ComposeLsOptions(all: true, quiet: true, filters: ["name=^dem"]))

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json", "--all"]])
        #expect(emitted.messages == ["demo"])
    }

    @Test("ls json renders compose projects")
    func lsJSONRendersComposeProjects() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ls(options: ComposeLsOptions(all: true, format: "json"))

        let data = Data(try #require(emitted.messages.first).utf8)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(records.map { $0["name"] } == ["demo", "other"])
        #expect(records.map { $0["status"] } == ["running(1), stopped(1)", "running(1)"])
        #expect(records.map { $0["configFiles"] } == [
            "/tmp/demo/compose.yml,/tmp/demo/compose.override.yml",
            "/tmp/other/compose.yml",
        ])
    }

    @Test("ls rejects malformed filters before runtime commands")
    func lsRejectsMalformedFiltersBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)

        do {
            try await orchestrator.ls(options: ComposeLsOptions(filters: ["name"]))
            Issue.record("Expected invalid filter error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("ls --filter must be in KEY=VALUE form"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("ls rejects unsupported filter keys before runtime commands")
    func lsRejectsUnsupportedFilterKeysBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)

        do {
            try await orchestrator.ls(options: ComposeLsOptions(filters: ["status=running"]))
            Issue.record("Expected unsupported filter error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("ls --filter status; supported filter is name"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("ls rejects unsupported output formats")
    func lsRejectsUnsupportedOutputFormats() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)

        do {
            try await orchestrator.ls(options: ComposeLsOptions(format: "yaml"))
            Issue.record("Expected unsupported ls format error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("ls --format 'yaml'; supported formats are table and json"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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

    @Test("ps quiet prints project scoped container IDs")
    func psQuietPrintsProjectScopedContainerIDs() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, quiet: true)

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json"]])
        #expect(emitted.messages == ["demo-api-1\ndemo-worker-1"])
    }

    @Test("ps services prints project scoped service names")
    func psServicesPrintsProjectScopedServiceNames() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, services: true)

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json"]])
        #expect(emitted.messages == ["api\nworker"])
    }

    @Test("ps quiet takes precedence over services")
    func psQuietTakesPrecedenceOverServices() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, quiet: true, services: true)

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json"]])
        #expect(emitted.messages == ["demo-api-1\ndemo-worker-1"])
    }

    @Test("ps status filters project scoped containers")
    func psStatusFiltersProjectScopedContainers() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, statuses: ["running"])

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json", "--all"]])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-api-1"])
    }

    @Test("ps filter status supports exited alias")
    func psFilterStatusSupportsExitedAlias() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, filters: ["status=exited"])

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json", "--all"]])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-worker-1"])
    }

    @Test("ps status filters services projection")
    func psStatusFiltersServicesProjection() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, services: true, statuses: ["running"])

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json", "--all"]])
        #expect(emitted.messages == ["api"])
    }

    @Test("ps rejects malformed filters before runtime commands")
    func psRejectsMalformedFiltersBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)

        do {
            try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, filters: ["status"])
            Issue.record("Expected invalid filter error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("ps --filter must be in KEY=VALUE form"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("ps rejects unsupported filter keys before runtime commands")
    func psRejectsUnsupportedFilterKeysBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)

        do {
            try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, filters: ["source=image"])
            Issue.record("Expected unsupported filter error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("ps --filter source; supported filter is status"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("ps rejects unsupported status filters before runtime commands")
    func psRejectsUnsupportedStatusFiltersBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)

        do {
            try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, statuses: ["paused"])
            Issue.record("Expected unsupported status error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("ps status 'paused'; apple/container exposes running, stopped, stopping, and unknown"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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
            $0.models = ["llm": .object(["model": .string("example/local-llm")])]
            $0.extensions = ["x-project": .object(["enabled": .bool(true), "retries": .number(3)])]
        }

        let json = try ComposeOrchestrator().config(project: project)
        let decoded = try JSONDecoder().decode(ComposeProject.self, from: Data(json.utf8))

        #expect(decoded.configs?["app_config"] == .object(["external": .bool(true)]))
        #expect(decoded.secrets?["app_secret"] == .object(["external": .bool(true)]))
        #expect(decoded.models?["llm"] == .object(["model": .string("example/local-llm")]))
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
                        target: "runtime",
                        noCache: true
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

    @Test("build applies Compose file no cache setting")
    func buildAppliesComposeFileNoCacheSetting() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api", noCache: true)
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(project: project, services: ["api"], noCache: false)

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.contains("--no-cache"))
    }

    @Test("build rejects unsupported build fields before emitting commands")
    func buildRejectsUnsupportedBuildFieldsBeforeEmittingCommands() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api", unsupportedFields: ["dockerfile_inline", "secrets"])
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).build(project: project, services: [], noCache: false)
            Issue.record("Expected unsupported build field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses unsupported build fields dockerfile_inline, secrets; advanced build fields are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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
            .success,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": "service_started"]
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await orchestrator.down(project: project, options: ComposeDownOptions(volumes: true))

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
            ["container", "stop", "demo-db-1"],
            ["container", "delete", "demo-db-1"],
            ["container", "network", "delete", "demo_default"],
            ["container", "volume", "delete", "demo_data"],
        ])
    }

    @Test("down leaves orphan containers unless requested")
    func downLeavesOrphanContainersUnlessRequested() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
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

        try await orchestrator.down(project: project, options: ComposeDownOptions(removeOrphans: true))

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stop", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
            ["container", "list", "--format", "json", "--all"],
            ["container", "stop", "demo-worker-1"],
            ["container", "delete", "demo-worker-1"],
        ])
    }

    @Test("down removes all service images when requested")
    func downRemovesAllServiceImagesWhenRequested() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:dev"),
                "web": composeService(name: "web", image: "example/web:dev") {
                    $0.build = ComposeBuild(context: "web")
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions(rmi: "all"))

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stop", "demo-worker-1"],
            ["container", "delete", "demo-worker-1"],
            ["container", "stop", "demo-web-1"],
            ["container", "delete", "demo-web-1"],
            ["container", "stop", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
            ["container", "image", "delete", "--force", "demo_worker:latest"],
            ["container", "image", "delete", "--force", "example/api:dev"],
            ["container", "image", "delete", "--force", "example/web:dev"],
        ])
    }

    @Test("down removes only local build images when requested")
    func downRemovesOnlyLocalBuildImagesWhenRequested() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:dev"),
                "web": composeService(name: "web", image: "example/web:dev") {
                    $0.build = ComposeBuild(context: "web")
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions(rmi: "local"))

        #expect(runner.commands.map(\.arguments).suffix(1) == [
            ["container", "image", "delete", "--force", "demo_worker:latest"],
        ])
    }

    @Test("down rejects unsupported rmi policy before runtime commands")
    func downRejectsUnsupportedRMIPolicyBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await orchestrator.down(project: project, options: ComposeDownOptions(rmi: "sometimes"))
            Issue.record("Expected invalid rmi policy error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("down --rmi must be 'all' or 'local'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
                "web": ComposeService(name: "web", image: "nginx"),
            ]
        )

        try await orchestrator.logs(project: project, services: ["api"], follow: true, tail: "10")
        try await orchestrator.exec(project: project, serviceName: "api", command: ["echo", "ok"])
        try await orchestrator.start(project: project, services: ["api"])
        try await orchestrator.stop(project: project, services: ["api"])
        try await orchestrator.restart(project: project, services: ["api"])
        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true)
        try await orchestrator.kill(project: project, services: ["api"], signal: "SIGTERM")
        try await orchestrator.copy(project: project, arguments: ["api:/tmp/file", "."])

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "logs", "--follow", "-n", "10", "demo-api-1"])
        #expect(commands[1] == ["container", "exec", "--interactive", "--tty", "demo-api-1", "echo", "ok"])
        #expect(runner.commands[1].io == .inherited)
        #expect(commands[2] == ["container", "start", "demo-api-1"])
        #expect(commands[3] == ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"])
        #expect(commands[4] == ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"])
        #expect(commands[5] == ["container", "start", "demo-api-1"])
        #expect(commands[6] == ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"])
        #expect(commands[7] == ["container", "delete", "demo-api-1"])
        #expect(commands[8] == ["container", "kill", "--signal", "SIGTERM", "demo-api-1"])
        #expect(commands[9] == ["container", "cp", "demo-api-1:/tmp/file", "."])
    }

    @Test("rm supports force and anonymous volume removal")
    func rmSupportsForceAndAnonymousVolumeRemoval() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.volumes = [
                        ComposeMount(type: "volume", target: "/scratch"),
                        ComposeMount(type: "volume", source: "cache", target: "/cache"),
                        ComposeMount(type: "bind", source: "/host", target: "/host"),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: false, force: true, volumes: true)

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0] == ["container", "delete", "--force", "demo-api-1"])
        #expect(commands[1].starts(with: ["container", "volume", "delete"]))
        #expect(commands[1].last?.hasPrefix("demo_anon-") == true)
        #expect(!commands.contains { $0.contains("demo_cache") })
    }

    @Test("lifecycle timeout overrides service stop grace period")
    func lifecycleTimeoutOverridesServiceStopGracePeriod() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await orchestrator.stop(project: project, services: ["api"], timeout: 12)
        try await orchestrator.restart(project: project, services: ["api"], timeout: 13)
        try await orchestrator.down(project: project, options: ComposeDownOptions(timeout: 14))

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stop", "--signal", "SIGUSR1", "--time", "12", "demo-api-1"],
            ["container", "stop", "--signal", "SIGUSR1", "--time", "13", "demo-api-1"],
            ["container", "start", "demo-api-1"],
            ["container", "stop", "--signal", "SIGUSR1", "--time", "14", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
        ])
    }

    @Test("lifecycle rejects invalid timeout before runtime commands")
    func lifecycleRejectsInvalidTimeoutBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        do {
            try await orchestrator.stop(project: project, services: ["api"], timeout: -1)
            Issue.record("Expected invalid timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("stop --timeout must be between 0 and 2147483647 seconds"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("exec disables TTY while keeping stdin inherited")
    func execDisablesTTYWhileKeepingStdinInherited() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            command: ["echo", "ok"],
            interactive: true,
            tty: false
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command == ["container", "exec", "--interactive", "demo-api-1", "echo", "ok"])
        #expect(runner.commands.first?.io == .inherited)
    }

    @Test("logs accepts Compose all tail value")
    func logsAcceptsComposeAllTailValue() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(runner: runner).logs(project: project, services: ["api"], follow: false, tail: "all")

        #expect(runner.commands.map(\.arguments) == [
            ["container", "logs", "demo-api-1"],
        ])
    }

    @Test("logs rejects invalid tail values before runtime commands")
    func logsRejectsInvalidTailValuesBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).logs(project: project, services: ["api"], follow: false, tail: "latest")
            Issue.record("Expected invalid tail error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("logs --tail must be 'all' or a non-negative integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("cp maps service references in both copy directions")
    func cpMapsServiceReferencesInBothCopyDirections() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": composeService(name: "db", image: "postgres") {
                    $0.containerName = "custom-db"
                },
            ]
        )

        try await orchestrator.copy(project: project, arguments: ["api:/tmp/report.txt", "./report.txt"])
        try await orchestrator.copy(project: project, arguments: ["./seed.sql", "db:/docker-entrypoint-initdb.d/seed.sql"])
        try await orchestrator.copy(project: project, arguments: ["./local:file.txt", "./out:file.txt"])

        #expect(runner.commands.map(\.arguments) == [
            ["container", "cp", "demo-api-1:/tmp/report.txt", "./report.txt"],
            ["container", "cp", "./seed.sql", "custom-db:/docker-entrypoint-initdb.d/seed.sql"],
            ["container", "cp", "./local:file.txt", "./out:file.txt"],
        ])
    }

    @Test("port prints static published bindings")
    func portPrintsStaticPublishedBindings() throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = [
                        "8080:80",
                        "127.0.0.1:8443:443",
                        "5353:53/udp",
                    ]
                },
            ]
        )

        try orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 1)
        try orchestrator.port(project: project, serviceName: "api", privatePort: "443", protocolName: "tcp", index: 1)
        try orchestrator.port(project: project, serviceName: "api", privatePort: "53/udp", protocolName: "udp", index: 1)

        #expect(emitted.messages == [
            "0.0.0.0:8080",
            "127.0.0.1:8443",
            "0.0.0.0:5353",
        ])
    }

    @Test("port rejects dynamic bindings that need runtime inspect output")
    func portRejectsDynamicBindingsThatNeedRuntimeInspectOutput() throws {
        let orchestrator = ComposeOrchestrator()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["80"]
                },
            ]
        )

        do {
            try orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 1)
            Issue.record("Expected unsupported dynamic port lookup")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' publishes target port 80/tcp dynamically; published port lookup needs richer inspect output"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("port prefers static bindings when dynamic bindings also exist")
    func portPrefersStaticBindingsWhenDynamicBindingsAlsoExist() throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["80", "8080:80"]
                },
            ]
        )

        try orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 1)

        #expect(emitted.messages == ["0.0.0.0:8080"])
    }

    @Test("port rejects dynamic ranges that need runtime inspect output")
    func portRejectsDynamicRangesThatNeedRuntimeInspectOutput() throws {
        let orchestrator = ComposeOrchestrator()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["80-82"]
                },
            ]
        )

        do {
            try orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 1)
            Issue.record("Expected unsupported dynamic port range lookup")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses port range '80-82'; port range lookup needs richer inspect output"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("port validates lookup options")
    func portValidatesLookupOptions() throws {
        let orchestrator = ComposeOrchestrator()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["8080:80"]
                },
            ]
        )

        do {
            try orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 2)
            Issue.record("Expected unsupported index error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("port --index 2: replica-aware published port lookup needs richer inspect output"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try orchestrator.port(project: project, serviceName: "api", privatePort: "80/udp", protocolName: "tcp", index: 1)
            Issue.record("Expected protocol conflict")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("port protocol 'udp' conflicts with --protocol tcp"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try orchestrator.port(project: project, serviceName: "api", privatePort: "81", protocolName: "tcp", index: 1)
            Issue.record("Expected missing port error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' does not publish target port 81/tcp"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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
                    $0.platform = "linux/arm64"
                    $0.runtime = "container-runtime-linux"
                    $0.tmpfs = ["/cache"]
                    $0.dns = ["1.1.1.1"]
                    $0.dnsSearch = ["local"]
                    $0.capAdd = ["NET_ADMIN"]
                    $0.capDrop = ["MKNOD"]
                    $0.memLimit = "1024"
                    $0.cpus = "2"
                    $0.shmSize = "67108864"
                    $0.ulimits = ["nofile=1024:2048", "nproc=512"]
                },
            ]
        )

        try await orchestrator.run(project: project, serviceName: "job", command: ["echo", "ok"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(runner.commands.first?.io == .inherited)
        #expect(command.starts(with: ["container", "run", "--name"]))
        #expect(command.contains("--rm"))
        #expect(command.containsSequence(["--env", "A=B"]))
        #expect(command.containsSequence(["--env", "EMPTY"]))
        #expect(command.containsSequence(["--env-file", ".env"]))
        #expect(!command.containsSequence(["--publish", "8080:80"]))
        #expect(command.containsSequence(["--volume", "/host:/container:ro"]))
        #expect(command.containsSequence(["--tmpfs", "/tmp"]))
        #expect(command.containsSequence(["--workdir", "/work"]))
        #expect(command.containsSequence(["--user", "1000"]))
        #expect(command.contains("--tty"))
        #expect(command.contains("--interactive"))
        #expect(command.containsSequence(["--platform", "linux/arm64"]))
        #expect(command.containsSequence(["--runtime", "container-runtime-linux"]))
        #expect(command.containsSequence(["--cap-add", "NET_ADMIN"]))
        #expect(command.containsSequence(["--cap-drop", "MKNOD"]))
        #expect(command.containsSequence(["--dns", "1.1.1.1"]))
        #expect(command.containsSequence(["--dns-search", "local"]))
        #expect(command.containsSequence(["--memory", "1024"]))
        #expect(command.containsSequence(["--cpus", "2"]))
        #expect(command.containsSequence(["--shm-size", "67108864"]))
        #expect(command.containsSequence(["--ulimit", "nofile=1024:2048"]))
        #expect(command.containsSequence(["--ulimit", "nproc=512"]))
        #expect(command.containsSequence(["--entrypoint", "/bin/sh -c"]))
        #expect(command.contains("--read-only"))
        #expect(command.contains("--init"))
        #expect(Array(command.suffix(3)) == ["alpine", "echo", "ok"])
    }

    @Test("run publishes service ports only when requested")
    func runPublishesServicePortsOnlyWhenRequested() async throws {
        let defaultRunner = RecordingRunner()
        let servicePortsRunner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.ports = ["8080:80"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: defaultRunner).run(
            project: project,
            serviceName: "api",
            options: composeRunOptions(command: ["true"])
        )
        try await ComposeOrchestrator(runner: servicePortsRunner).run(
            project: project,
            serviceName: "api",
            options: composeRunOptions(command: ["true"]) {
                $0.servicePorts = true
            }
        )

        let defaultCommand = try #require(defaultRunner.commands.first?.arguments)
        let servicePortsCommand = try #require(servicePortsRunner.commands.first?.arguments)
        #expect(!defaultCommand.containsSequence(["--publish", "8080:80"]))
        #expect(servicePortsCommand.containsSequence(["--publish", "8080:80"]))
    }

    @Test("run publishes manual ports without service ports")
    func runPublishesManualPortsWithoutServicePorts() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.ports = ["8080:80"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "api",
            options: composeRunOptions(command: ["true"]) {
                $0.publish = ["127.0.0.1:9090:90"]
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--publish", "127.0.0.1:9090:90"]))
        #expect(!command.containsSequence(["--publish", "8080:80"]))
    }

    @Test("run creates project resources before one-off containers")
    func runCreatesProjectResourcesBeforeOneOffContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await orchestrator.run(project: project, serviceName: "job", command: ["true"], remove: true)

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "network", "create"]))
        #expect(commands[0].last == "demo_backend")
        #expect(commands[1].containsSequence(["container", "volume", "create"]))
        #expect(commands[1].last == "demo_cache")
        #expect(commands[2].starts(with: ["container", "run", "--name"]))
        #expect(commands[2].containsSequence(["--network", "demo_backend"]))
        #expect(commands[2].containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(Array(commands[2].suffix(2)) == ["alpine", "true"])
    }

    @Test("run applies service pull policy before creating resources")
    func runAppliesServicePullPolicyBeforeCreatingResources() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pullPolicy = "always"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "pull", "alpine"])
        #expect(commands[1].containsSequence(["container", "network", "create"]))
        #expect(commands[2].containsSequence(["container", "volume", "create"]))
        #expect(commands[3].starts(with: ["container", "run", "--name"]))
    }

    @Test("run rejects unsupported service pull policies before creating resources")
    func runRejectsUnsupportedServicePullPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pullPolicy = "daily"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported service pull policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses pull_policy 'daily'; supported values are always, missing, if_not_present, and never"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported external links before creating resources")
    func runRejectsUnsupportedExternalLinksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.externalLinks = ["legacy_db:db"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported external links error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses external_links; legacy link support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported hostnames before creating resources")
    func runRejectsUnsupportedHostnamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.hostname = "custom-job"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported hostname error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses hostname; custom hostname support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported domain names before creating resources")
    func runRejectsUnsupportedDomainNamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.domainName = "example.test"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported domain name error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses domainname; custom domain name support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported DNS options before creating resources")
    func runRejectsUnsupportedDNSOptionsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.dnsOptions = ["use-vc"]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported DNS option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses dns_opt; DNS option support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported sysctls before creating resources")
    func runRejectsUnsupportedSysctlsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.sysctls = ["net.core.somaxconn": "1024"]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported sysctls error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses sysctls; sysctl support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported network aliases before creating resources")
    func runRejectsUnsupportedNetworkAliasesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["job.internal"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported network alias error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses network aliases; network alias support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported network options before creating resources")
    func runRejectsUnsupportedNetworkOptionsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(interfaceName: "eth0"),
                    ]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported network option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses network attachment options interface_name on network 'backend'; network attachment options need an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported network mode before creating resources")
    func runRejectsUnsupportedNetworkModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networkMode = "host"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported network mode error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses network_mode 'host'; network mode support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported namespace and cgroup fields before creating resources")
    func runRejectsUnsupportedNamespaceAndCgroupFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedRuntimeStringFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported CPU resource fields before creating resources")
    func runRejectsUnsupportedCPUResourceFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedCPUResourceFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported memory and process resource fields before creating resources")
    func runRejectsUnsupportedMemoryAndProcessResourceFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedMemoryAndProcessResourceFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported block IO config before creating resources")
    func runRejectsUnsupportedBlockIOConfigBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.blkioConfig = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported block IO config error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses blkio_config; block I/O controls are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported develop config before creating resources")
    func runRejectsUnsupportedDevelopConfigBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.develop = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported develop config error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses develop; develop/watch workflows are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported build fields before creating resources")
    func runRejectsUnsupportedBuildFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.build = ComposeBuild(context: "job", unsupportedFields: ["cache_from", "platforms"])
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported build field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses unsupported build fields cache_from, platforms; advanced build fields are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported deploy fields before creating resources")
    func runRejectsUnsupportedDeployFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.unsupportedDeployFields = ["labels", "restart_policy", "endpoint_mode"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported deploy field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses unsupported deploy fields labels, restart_policy, endpoint_mode; Compose Deploy Specification beyond replica count is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported provider model and hook fields before creating resources")
    func runRejectsUnsupportedProviderModelAndHookFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedProviderModelAndHookFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported user and security option fields before creating resources")
    func runRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedUserAndSecurityOptionFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported device access fields before creating resources")
    func runRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedDeviceAccessFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported service scale before creating resources")
    func runRejectsUnsupportedServiceScaleBeforeCreatingResources() async throws {
        for scale in [0, 3] {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        $0.scale = scale
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported scale error")
            } catch let error as ComposeError {
                #expect(error == .unsupported("service 'job' uses scale \(scale); service replica scaling is not implemented by container-compose yet"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported metadata and logging fields before creating resources")
    func runRejectsUnsupportedMetadataAndLoggingFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedServiceMetadataAndLoggingFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported volume shortcut fields before creating resources")
    func runRejectsUnsupportedVolumeShortcutFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedServiceVolumeShortcutFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported API socket mounting before creating resources")
    func runRejectsUnsupportedAPISocketBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.useAPISocket = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported API socket error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses use_api_socket; API socket mounting is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported MAC address before creating resources")
    func runRejectsUnsupportedMACAddressBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.macAddress = "02:42:ac:11:00:04"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported MAC address error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses mac_address '02:42:ac:11:00:04'; MAC address support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported healthchecks before creating resources")
    func runRejectsUnsupportedHealthchecksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.healthcheck = .object(["disable": .bool(true)])
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported healthcheck error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses healthcheck; health status support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported configs before creating resources")
    func runRejectsUnsupportedConfigsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.configs = [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.configs = ["app_config": .object(["external": .bool(true)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported configs error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses configs; config mount support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported secrets before creating resources")
    func runRejectsUnsupportedSecretsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("/run/secrets/app_secret")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.secrets = ["app_secret": .object(["external": .bool(true)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported secrets error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses secrets; secret mount support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run applies explicit pull policy before one-off container")
    func runAppliesExplicitPullPolicyBeforeOneOffContainer() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pullPolicy = "never"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "always"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "pull", "alpine"])
        #expect(commands[1].starts(with: ["container", "run"]))
        #expect(Array(commands[1].suffix(2)) == ["alpine", "true"])
    }

    @Test("run pull missing only pulls absent images")
    func runPullMissingOnlyPullsAbsentImages() async throws {
        let presentRunner = RecordingRunner(responses: [.success])
        let absentRunner = RecordingRunner(responses: [.failure, .success])
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        try await ComposeOrchestrator(runner: presentRunner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "missing"
            }
        )
        try await ComposeOrchestrator(runner: absentRunner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "missing"
            }
        )

        let presentCommands = presentRunner.commands.map(\.arguments)
        #expect(presentCommands[0] == ["container", "image", "inspect", "alpine"])
        #expect(presentCommands[1].starts(with: ["container", "run"]))
        let absentCommands = absentRunner.commands.map(\.arguments)
        #expect(absentCommands[0] == ["container", "image", "inspect", "alpine"])
        #expect(absentCommands[1] == ["container", "image", "pull", "alpine"])
        #expect(absentCommands[2].starts(with: ["container", "run"]))
    }

    @Test("run pull if not present uses the missing-image flow")
    func runPullIfNotPresentUsesMissingImageFlow() async throws {
        let runner = RecordingRunner(responses: [.failure, .success])
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "if_not_present"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "inspect", "alpine"])
        #expect(commands[1] == ["container", "image", "pull", "alpine"])
        #expect(commands[2].starts(with: ["container", "run"]))
        #expect(Array(commands[2].suffix(2)) == ["alpine", "true"])
    }

    @Test("run rejects unsupported explicit pull policy")
    func runRejectsUnsupportedExplicitPullPolicy() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["true"]) {
                    $0.pullPolicy = "daily"
                }
            )
            Issue.record("Expected unsupported run pull policy to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unsupported pull policy 'daily'"))
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported restart policies before creating resources")
    func runRejectsUnsupportedRestartPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.restart = "on-failure"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses restart policy 'on-failure'; restart policy support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run assigns unique names to one-off containers")
    func runAssignsUniqueNamesToOneOffContainers() async throws {
        let identifiers = OneOffIdentifierSource(["first", "second"])
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { identifiers.next() })
        )
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        try await orchestrator.run(project: project, serviceName: "job", command: ["true"], remove: true)
        try await orchestrator.run(project: project, serviceName: "job", command: ["true"], remove: true)

        let names = runner.commands.compactMap { $0.arguments.value(after: "--name") }
        #expect(names == ["demo-job-run-first", "demo-job-run-second"])
    }

    @Test("run uses explicit one-off container name when provided")
    func runUsesExplicitOneOffContainerNameWhenProvided() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.containerName = "custom-job"
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "run", "--name", "custom-job"]))
        #expect(Array(command.suffix(2)) == ["alpine", "true"])
    }

    @Test("run detaches one-off containers without inheriting terminal IO")
    func runDetachesOneOffContainersWithoutInheritingTerminalIO() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.tty = true
                    $0.stdinOpen = true
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["sleep", "60"]) {
                $0.detach = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(runner.commands.first?.io == .captured(input: nil))
        #expect(command.contains("--detach"))
        #expect(command.contains("--tty"))
        #expect(command.contains("--interactive"))
        #expect(Array(command.suffix(3)) == ["alpine", "sleep", "60"])
    }

    @Test("run disables pseudo tty while preserving interactive stdin")
    func runDisablesPseudoTtyWhilePreservingInteractiveStdin() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.tty = true
                    $0.stdinOpen = true
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["sh"]) {
                $0.noTty = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(runner.commands.first?.io == .inherited)
        #expect(!command.contains("--tty"))
        #expect(command.contains("--interactive"))
        #expect(Array(command.suffix(2)) == ["alpine", "sh"])
    }

    @Test("run overrides service entrypoint for one-off containers")
    func runOverridesServiceEntrypointForOneOffContainers() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.entrypoint = ["/usr/bin/default"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["echo", "ok"]) {
                $0.entrypoint = "/bin/sh -c"
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--entrypoint", "/bin/sh -c"]))
        #expect(!command.containsSequence(["--entrypoint", "/usr/bin/default"]))
        #expect(Array(command.suffix(3)) == ["alpine", "echo", "ok"])
    }

    @Test("run overrides service workdir for one-off containers")
    func runOverridesServiceWorkdirForOneOffContainers() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.workingDir = "/default"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["pwd"]) {
                $0.workingDirectory = "/workspace"
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--workdir", "/workspace"]))
        #expect(!command.containsSequence(["--workdir", "/default"]))
        #expect(Array(command.suffix(2)) == ["alpine", "pwd"])
    }

    @Test("run overrides service user for one-off containers")
    func runOverridesServiceUserForOneOffContainers() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.user = "1000"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["id"]) {
                $0.user = "2000:2000"
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--user", "2000:2000"]))
        #expect(!command.containsSequence(["--user", "1000"]))
        #expect(Array(command.suffix(2)) == ["alpine", "id"])
    }

    @Test("run applies one-off environment overrides")
    func runAppliesOneOffEnvironmentOverrides() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.environment = ["EMPTY": nil, "KEEP": "yes", "LOG_LEVEL": "info"]
                    $0.envFiles = [".env"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["env"]) {
                $0.environment = ["LOG_LEVEL=debug", "NEW=value", "PASSTHROUGH", "EMPTY="]
                $0.envFiles = [".env.local"]
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--env", "EMPTY="]))
        #expect(command.containsSequence(["--env", "KEEP=yes"]))
        #expect(command.containsSequence(["--env", "LOG_LEVEL=debug"]))
        #expect(command.containsSequence(["--env", "NEW=value"]))
        #expect(command.containsSequence(["--env", "PASSTHROUGH"]))
        #expect(!command.containsSequence(["--env", "LOG_LEVEL=info"]))
        #expect(command.containsSequence(["--env-file", ".env"]))
        #expect(command.containsSequence(["--env-file", ".env.local"]))
        #expect(Array(command.suffix(2)) == ["alpine", "env"])
    }

    @Test("run applies one-off label overrides")
    func runAppliesOneOffLabelOverrides() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.labels = ["com.example.keep": "yes", "com.example.role": "api"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.labels = ["com.example.role=job", "com.example.flag"]
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--label", "com.apple.container.compose.oneoff=true"]))
        #expect(command.containsSequence(["--label", "com.example.keep=yes"]))
        #expect(command.containsSequence(["--label", "com.example.role=job"]))
        #expect(command.containsSequence(["--label", "com.example.flag"]))
        #expect(!command.containsSequence(["--label", "com.example.role=api"]))
        #expect(Array(command.suffix(2)) == ["alpine", "true"])
    }

    @Test("run rejects empty label override")
    func runRejectsEmptyLabelOverride() async throws {
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        do {
            try await ComposeOrchestrator().run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["true"]) {
                    $0.labels = [""]
                }
            )
            Issue.record("Expected empty run label override to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("run --label requires KEY or KEY=VALUE"))
        }
    }

    @Test("run rejects reserved Compose label overrides")
    func runRejectsReservedComposeLabelOverrides() async throws {
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        do {
            try await ComposeOrchestrator().run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["true"]) {
                    $0.labels = ["com.apple.container.compose.project=evil"]
                }
            )
            Issue.record("Expected reserved run label override to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("run --label cannot override reserved Compose tracking label 'com.apple.container.compose.project'"))
        }
    }

    @Test("run applies one-off volume overrides")
    func runAppliesOneOffVolumeOverrides() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.volumes = [ComposeMount(type: "bind", source: "/default", target: "/default")]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["ls"]) {
                $0.volumes = ["/host:/container:ro", "cache:/cache", "/scratch"]
            }
        )

        let volumeCreate = try #require(runner.commands.first?.arguments)
        #expect(volumeCreate.containsSequence(["container", "volume", "create"]))
        #expect(volumeCreate.last == "demo_cache")
        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--volume", "/default:/default"]))
        #expect(command.containsSequence(["--volume", "/host:/container:ro"]))
        #expect(command.containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(command.contains { $0.hasPrefix("demo_anon-") && $0.hasSuffix(":/scratch") })
        #expect(Array(command.suffix(2)) == ["alpine", "ls"])
    }

    @Test("run rejects unsupported one-off volume mode")
    func runRejectsUnsupportedOneOffVolumeMode() async throws {
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        do {
            try await ComposeOrchestrator().run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["ls"]) {
                    $0.volumes = ["/host:/container:delegated"]
                }
            )
            Issue.record("Expected unsupported run volume mode to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("run --volume mode 'delegated' is not supported; use ro or rw"))
        }
    }

    @Test("run rejects empty environment override")
    func runRejectsEmptyEnvironmentOverride() async throws {
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        do {
            try await ComposeOrchestrator().run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["env"]) {
                    $0.environment = [""]
                }
            )
            Issue.record("Expected empty run environment override to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("run --env requires NAME or NAME=VALUE"))
        }
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

    @Test("up recreates existing containers when resource runtime names change")
    func upRecreatesExistingContainersWhenResourceRuntimeNamesChange() async throws {
        let oldProject = projectWithRuntimeResources(networkName: "old-net", volumeName: "old-cache")
        let createRunner = RecordingRunner(responses: [.failure, .success])

        try await ComposeOrchestrator(runner: createRunner).up(project: oldProject, options: ComposeUpOptions())

        let oldRun = try #require(createRunner.commands.last?.arguments)
        let oldHash = try #require(composeConfigHash(in: oldRun))
        let newProject = projectWithRuntimeResources(networkName: "new-net", volumeName: "new-cache")
        let runner = RecordingRunner(responses: [
            inspectResult(configHash: oldHash),
            .success,
            .success,
            .success,
        ])

        try await ComposeOrchestrator(runner: runner).up(project: newProject, options: ComposeUpOptions())

        #expect(runner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(runner.commands[1].arguments == ["container", "stop", "demo-api-1"])
        #expect(runner.commands[2].arguments == ["container", "delete", "demo-api-1"])
        let newRun = runner.commands[3].arguments
        #expect(newRun.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(newRun.containsSequence(["--network", "new-net"]))
        #expect(newRun.containsSequence(["--volume", "new-cache:/cache"]))
        #expect(composeConfigHash(in: newRun) != oldHash)
    }

    @Test("up recreates existing containers when config hash changes")
    func upRecreatesExistingContainersWhenConfigHashChanges() async throws {
        let runner = RecordingRunner(responses: [
            inspectResult(configHash: "stale"),
            .success,
            .success,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())

        #expect(runner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(runner.commands[1].arguments == ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"])
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

    @Test("dry run up does not treat synthetic inspect success as existing container")
    func dryRunUpDoesNotTreatSyntheticInspectSuccessAsExistingContainer() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "alpine")])

        try await orchestrator.up(project: project, options: ComposeUpOptions(noRecreate: true))

        let messages = emitted.messages
        #expect(messages.contains("+ container inspect demo-api-1"))
        #expect(messages.contains { $0.hasPrefix("+ container run ") && !$0.contains("--detach") })
        #expect(!messages.contains("compose: reusing existing container demo-api-1"))
        #expect(!messages.contains { $0.contains("container stop demo-api-1") })
        #expect(!messages.contains { $0.contains("container delete demo-api-1") })
    }

    @Test("dry run pull missing emits inspect and pull plan")
    func dryRunPullMissingEmitsInspectAndPullPlan() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "alpine")])

        try await orchestrator.up(project: project, options: ComposeUpOptions(pullPolicy: "missing"))

        let messages = emitted.messages
        #expect(messages.contains("+ container image inspect alpine"))
        #expect(messages.contains("+ container image pull alpine"))
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

        let invalidPullPolicyRunner = RecordingRunner()
        let invalidPullPolicyProject = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }
        do {
            try await ComposeOrchestrator(runner: invalidPullPolicyRunner).up(
                project: invalidPullPolicyProject,
                options: ComposeUpOptions(pullPolicy: "sometimes")
            )
            Issue.record("Expected unsupported pull policy failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unsupported pull policy 'sometimes'"))
        }
        #expect(invalidPullPolicyRunner.commands.isEmpty)

        do {
            try await ComposeOrchestrator().copy(project: ComposeProject(name: "demo", services: [:]), arguments: [])
            Issue.record("Expected cp argument failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("cp requires exactly source and destination"))
        }

        do {
            try await ComposeOrchestrator().copy(
                project: ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")]),
                arguments: ["api:/tmp/file"]
            )
            Issue.record("Expected cp single-operand failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("cp requires exactly source and destination"))
        }

        do {
            try await ComposeOrchestrator().copy(
                project: ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")]),
                arguments: ["api:/tmp/file", ".", "extra"]
            )
            Issue.record("Expected cp extra-operand failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("cp requires exactly source and destination"))
        }

        do {
            try await ComposeOrchestrator().copy(
                project: ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")]),
                arguments: ["missing:/tmp/file", "."]
            )
            Issue.record("Expected cp unknown service failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unknown service 'missing'"))
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

}

private extension CommandResult {
    static let success = CommandResult(status: 0, stdout: "", stderr: "")
    static let failure = CommandResult(status: 1, stdout: "", stderr: "")
}

private let composeConfigHashLabel = "com.apple.container.compose.config-hash"
private let composeProjectLabel = "com.apple.container.compose.project"
private let composeServiceLabel = "com.apple.container.compose.service"
private let composeProjectConfigFilesLabel = "com.apple.container.compose.project.config-files"

private struct UnsupportedRuntimeStringFieldCase: Sendable {
    let composeName: String
    let value: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; \(reason)"
    }
}

private func unsupportedRuntimeStringFieldCases() -> [UnsupportedRuntimeStringFieldCase] {
    [
        UnsupportedRuntimeStringFieldCase(
            composeName: "cgroup",
            value: "host",
            reason: "cgroup namespace support needs an apple/container runtime gap PR",
            configure: { $0.cgroup = "host" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "cgroup_parent",
            value: "m-executor-abcd",
            reason: "cgroup parent support needs an apple/container runtime gap PR",
            configure: { $0.cgroupParent = "m-executor-abcd" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "ipc",
            value: "host",
            reason: "IPC namespace support needs an apple/container runtime gap PR",
            configure: { $0.ipc = "host" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "isolation",
            value: "default",
            reason: "isolation support needs an apple/container runtime gap PR",
            configure: { $0.isolation = "default" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "pid",
            value: "host",
            reason: "PID namespace support needs an apple/container runtime gap PR",
            configure: { $0.pid = "host" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "userns_mode",
            value: "host",
            reason: "user namespace support needs an apple/container runtime gap PR",
            configure: { $0.usernsMode = "host" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "uts",
            value: "host",
            reason: "UTS namespace support needs an apple/container runtime gap PR",
            configure: { $0.uts = "host" }
        ),
    ]
}

private struct UnsupportedCPUResourceFieldCase: Sendable {
    let composeName: String
    let value: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; advanced CPU resource support needs an apple/container runtime gap PR"
    }
}

private func unsupportedCPUResourceFieldCases() -> [UnsupportedCPUResourceFieldCase] {
    [
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_count",
            value: "2",
            configure: { $0.cpuCount = 2 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_percent",
            value: "12.5",
            configure: { $0.cpuPercent = 12.5 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_period",
            value: "100000",
            configure: { $0.cpuPeriod = 100_000 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_quota",
            value: "50000",
            configure: { $0.cpuQuota = 50_000 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_rt_period",
            value: "950000",
            configure: { $0.cpuRealtimePeriod = 950_000 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_rt_runtime",
            value: "900000",
            configure: { $0.cpuRealtimeRuntime = 900_000 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpuset",
            value: "0-1",
            configure: { $0.cpuset = "0-1" }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_shares",
            value: "512",
            configure: { $0.cpuShares = 512 }
        ),
    ]
}

private struct UnsupportedMemoryAndProcessResourceFieldCase: Sendable {
    let composeName: String
    let value: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; memory, OOM, and process resource support needs an apple/container runtime gap PR"
    }
}

private func unsupportedMemoryAndProcessResourceFieldCases() -> [UnsupportedMemoryAndProcessResourceFieldCase] {
    [
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "mem_reservation",
            value: "134217728",
            configure: { $0.memReservation = "134217728" }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "memswap_limit",
            value: "268435456",
            configure: { $0.memSwapLimit = "268435456" }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "mem_swappiness",
            value: "60",
            configure: { $0.memSwappiness = "60" }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "oom_kill_disable",
            value: "true",
            configure: { $0.oomKillDisable = true }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "oom_score_adj",
            value: "-500",
            configure: { $0.oomScoreAdj = -500 }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "pids_limit",
            value: "128",
            configure: { $0.pidsLimit = 128 }
        ),
    ]
}

private struct UnsupportedUserAndSecurityOptionFieldCase: Sendable {
    let composeName: String
    let value: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; \(reason)"
    }
}

private func unsupportedUserAndSecurityOptionFieldCases() -> [UnsupportedUserAndSecurityOptionFieldCase] {
    [
        UnsupportedUserAndSecurityOptionFieldCase(
            composeName: "group_add",
            value: "video",
            reason: "supplemental group support needs an apple/container runtime gap PR",
            configure: { $0.groupAdd = ["video", "staff"] }
        ),
        UnsupportedUserAndSecurityOptionFieldCase(
            composeName: "security_opt",
            value: "label:disable",
            reason: "security option support needs an apple/container runtime gap PR",
            configure: { $0.securityOpt = ["label:disable"] }
        ),
    ]
}

private struct UnsupportedDeviceAccessFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

private func unsupportedDeviceAccessFieldCases() -> [UnsupportedDeviceAccessFieldCase] {
    [
        UnsupportedDeviceAccessFieldCase(
            composeName: "credential_spec",
            reason: "credential spec support needs an apple/container runtime gap PR",
            configure: { $0.credentialSpec = .object(["file": .string("credential-spec.json")]) }
        ),
        UnsupportedDeviceAccessFieldCase(
            composeName: "device_cgroup_rules",
            reason: "device cgroup rule support needs an apple/container runtime gap PR",
            configure: { $0.deviceCgroupRules = ["c 1:3 mr"] }
        ),
        UnsupportedDeviceAccessFieldCase(
            composeName: "devices",
            reason: "host device access support needs an apple/container runtime gap PR",
            configure: {
                $0.devices = [
                    .object([
                        "source": .string("/dev/fuse"),
                        "target": .string("/dev/fuse"),
                        "permissions": .string("rwm"),
                    ]),
                ]
            }
        ),
        UnsupportedDeviceAccessFieldCase(
            composeName: "gpus",
            reason: "GPU device access support needs an apple/container runtime gap PR",
            configure: {
                $0.gpus = [
                    .object([
                        "driver": .string("nvidia"),
                        "capabilities": .array([.string("gpu")]),
                    ]),
                ]
            }
        ),
        UnsupportedDeviceAccessFieldCase(
            composeName: "privileged",
            reason: "privileged mode support needs an apple/container runtime gap PR",
            configure: { $0.privileged = true }
        ),
    ]
}

private struct UnsupportedProviderModelAndHookFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

private func unsupportedProviderModelAndHookFieldCases() -> [UnsupportedProviderModelAndHookFieldCase] {
    [
        UnsupportedProviderModelAndHookFieldCase(
            composeName: "provider",
            reason: "service providers are not implemented by container-compose yet",
            configure: { $0.provider = true }
        ),
        UnsupportedProviderModelAndHookFieldCase(
            composeName: "models",
            reason: "service model bindings are not implemented by container-compose yet",
            configure: { $0.models = true }
        ),
        UnsupportedProviderModelAndHookFieldCase(
            composeName: "post_start",
            reason: "lifecycle hooks are not implemented by container-compose yet",
            configure: { $0.postStart = true }
        ),
        UnsupportedProviderModelAndHookFieldCase(
            composeName: "pre_stop",
            reason: "lifecycle hooks are not implemented by container-compose yet",
            configure: { $0.preStop = true }
        ),
    ]
}

private struct UnsupportedServiceMetadataAndLoggingFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

private func unsupportedServiceMetadataAndLoggingFieldCases() -> [UnsupportedServiceMetadataAndLoggingFieldCase] {
    [
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "annotations",
            reason: "service annotations are not implemented by container-compose yet",
            configure: { $0.annotations = ["com.example.note": "runtime"] }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "attach",
            reason: "service attach behavior is not implemented by container-compose yet",
            configure: { $0.attach = false }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "label_file",
            reason: "label file support is not implemented by container-compose yet",
            configure: { $0.labelFiles = ["./service.labels"] }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "logging",
            reason: "service logging configuration is not implemented by container-compose yet",
            configure: { $0.logging = .object(["driver": .string("json-file")]) }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "log_driver",
            reason: "service logging configuration is not implemented by container-compose yet",
            configure: { $0.logDriver = "json-file" }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "log_opt",
            reason: "service logging configuration is not implemented by container-compose yet",
            configure: { $0.logOptions = ["max-size": "10m"] }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "storage_opt",
            reason: "service storage options are not implemented by container-compose yet",
            configure: { $0.storageOptions = ["size": "1G"] }
        ),
    ]
}

private struct UnsupportedServiceVolumeShortcutFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

private func unsupportedServiceVolumeShortcutFieldCases() -> [UnsupportedServiceVolumeShortcutFieldCase] {
    [
        UnsupportedServiceVolumeShortcutFieldCase(
            composeName: "volumes_from",
            reason: "volume inheritance is not implemented by container-compose yet",
            configure: { $0.volumesFrom = ["db:ro"] }
        ),
        UnsupportedServiceVolumeShortcutFieldCase(
            composeName: "volume_driver",
            reason: "service-level volume driver support is not implemented by container-compose yet",
            configure: { $0.volumeDriver = "local" }
        ),
    ]
}

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
              "image": {
                "reference": "localhost:5000/example/api:latest",
                "descriptor": {
                  "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                }
              },
              "labels": {
                "\(composeProjectLabel)": "demo",
                "\(composeServiceLabel)": "api",
                "\(composeConfigHashLabel)": "api-hash",
                "\(composeProjectConfigFilesLabel)": "/tmp/demo/compose.yml,/tmp/demo/compose.override.yml"
              },
              "platform": {
                "os": "linux",
                "architecture": "arm64"
              }
            },
            "status": {
              "state": "running"
            }
          },
          {
            "id": "other-api-1",
            "configuration": {
              "image": {
                "reference": "other/api:latest",
                "descriptor": {
                  "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                }
              },
              "labels": {
                "\(composeProjectLabel)": "other",
                "\(composeServiceLabel)": "api",
                "\(composeConfigHashLabel)": "other-hash",
                "\(composeProjectConfigFilesLabel)": "/tmp/other/compose.yml"
              },
              "platform": {
                "os": "linux",
                "architecture": "arm64"
              }
            },
            "status": {
              "state": "running"
            }
          },
          {
            "id": "demo-worker-1",
            "Config": {
              "Image": "example/worker:debug",
              "ImageID": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "Platform": {
                "OS": "linux",
                "Architecture": "amd64"
              },
              "Labels": {
                "\(composeProjectLabel)": "demo",
                "\(composeServiceLabel)": "worker",
                "\(composeConfigHashLabel)": "worker-hash",
                "\(composeProjectConfigFilesLabel)": "/tmp/demo/compose.yml"
              }
            },
            "State": {
              "Status": "stopped"
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

private final class OneOffIdentifierSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? "fallback" : values.removeFirst()
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
    func value(after option: String) -> String? {
        guard let index = firstIndex(of: option) else {
            return nil
        }
        let valueIndex = self.index(after: index)
        guard valueIndex < endIndex else {
            return nil
        }
        return self[valueIndex]
    }

    func containsLabel(withPrefix prefix: String) -> Bool {
        indices.contains { index in
            self[index] == "--label"
                && self.index(after: index) < endIndex
                && self[self.index(after: index)].hasPrefix(prefix)
        }
    }
}
