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
@testable import ComposeCore
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import Testing

extension ComposeOrchestratorTests {
    @Test("run supports one-off containers and option flags")
    func runSupportsOneOffContainersAndOptionFlags() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostSource = directory.appendingPathComponent("host").path

        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let initializer = RecordingContainerImageVolumeInitializer()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.resourceManager = resourceManager
                $0.imageVolumeInitializer = initializer
            },
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.entrypoint = ["/bin/sh", "-c"]
                    $0.environment = ["A": "B", "EMPTY": nil]
                    $0.envFiles = [".env"]
                    $0.ports = ["8080:80"]
                    $0.volumes = [
                        ComposeMount(
                            type: "bind",
                            source: hostSource,
                            target: "/container",
                            options: .init(readOnly: true, bind: .init(createHostPath: true))
                        ),
                        ComposeMount(type: "tmpfs", target: "/tmp"),
                        ComposeMount(type: "volume", target: "/anon"),
                    ]
                    $0.workingDir = "/work"
                    $0.user = "1000"
                    $0.groupAdd = ["1000", "video", "1001", "staff", "1000", "video"]
                    $0.tty = true
                    $0.stdinOpen = true
                    $0.readOnly = true
                    $0.initEnabled = true
                    $0.platform = "linux/arm64"
                    $0.runtime = "container-runtime-linux"
                    $0.tmpfs = ["/cache"]
                    $0.dns = ["1.1.1.1"]
                    $0.dnsSearch = ["local"]
                    $0.dnsOptions = ["use-vc"]
                    $0.hostname = "custom-job"
                    $0.extraHosts = ["db=10.0.0.5"]
                    $0.capAdd = ["NET_ADMIN"]
                    $0.capDrop = ["MKNOD"]
                    $0.privileged = true
                    $0.oomScoreAdj = -250
                    $0.memLimit = "1024"
                    $0.memReservation = "512"
                    $0.memSwapLimit = "2048"
                    $0.cpus = "2"
                    $0.shmSize = "67108864"
                    $0.ulimits = ["nofile=1024:2048", "nproc=512"]
                },
            ]
        )

        try await orchestrator.run(project: project, serviceName: "job", command: ["echo", "ok"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(runner.commands.first?.io == .replacingProcess)
        #expect(command.starts(with: ["container", "run", "--name"]))
        #expect(command.contains("--rm"))
        #expect(command.containsSequence(["--env", "A=B"]))
        #expect(command.containsSequence(["--env", "EMPTY"]))
        #expect(!command.containsSequence(["--env-file", ".env"]))
        #expect(!command.containsSequence(["--publish", "8080:80"]))
        #expect(FileManager.default.fileExists(atPath: hostSource))
        #expect(command.containsSequence(["--volume", "\(hostSource):/container:ro"]))
        #expect(command.containsSequence(["--tmpfs", "/tmp"]))
        #expect(command.containsSequence(["--workdir", "/work"]))
        #expect(command.containsSequence(["--user", "1000"]))
        #expect(command.containsSequence(["--group-add", "1000"]))
        #expect(command.containsSequence(["--group-add", "1001"]))
        #expect(command.containsSequence(["--group-add", "video"]))
        #expect(command.containsSequence(["--group-add", "staff"]))
        #expect(command.filter { $0 == "--group-add" }.count == 4)
        #expect(command.contains("--tty"))
        #expect(command.contains("--interactive"))
        #expect(command.containsSequence(["--platform", "linux/arm64"]))
        #expect(command.containsSequence(["--runtime", "container-runtime-linux"]))
        #expect(command.containsSequence(["--cap-add", "NET_ADMIN"]))
        #expect(command.containsSequence(["--cap-drop", "MKNOD"]))
        #expect(command.contains("--privileged"))
        #expect(command.containsSequence(["--oom-score-adj", "-250"]))
        #expect(command.containsSequence(["--dns", "1.1.1.1"]))
        #expect(command.containsSequence(["--dns-search", "local"]))
        #expect(command.containsSequence(["--dns-option", "use-vc"]))
        #expect(command.containsSequence(["--hostname", "custom-job"]))
        #expect(command.containsSequence(["--add-host", "db:10.0.0.5"]))
        #expect(command.containsSequence(["--memory", "1024"]))
        #expect(command.containsSequence(["--memory-reservation", "512"]))
        #expect(command.containsSequence(["--memory-swap", "2048"]))
        #expect(command.containsSequence(["--cpus", "2"]))
        #expect(command.containsSequence(["--shm-size", "67108864"]))
        #expect(command.containsSequence(["--ulimit", "nofile=1024:2048"]))
        #expect(command.containsSequence(["--ulimit", "nproc=512"]))
        #expect(command.containsSequence(["--entrypoint", "/bin/sh"]))
        #expect(command.contains("--read-only"))
        #expect(command.contains("--init"))
        #expect(Array(command.suffix(4)) == ["alpine", "-c", "echo", "ok"])
    }

    @Test("run rejects malformed supplemental group IDs before invoking container")
    func runRejectsMalformedSupplementalGroupIDsBeforeInvokingContainer() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.groupAdd = ["4294967296"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(
                project: project,
                serviceName: "job",
                command: ["true"],
                remove: false
            )
            Issue.record("Expected group_add validation failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' uses group_add numeric ID '4294967296' outside the UInt32 range"))
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run applies one-off capability overrides")
    func runAppliesOneOffCapabilityOverrides() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.capAdd = ["NET_ADMIN"]
                    $0.capDrop = ["MKNOD"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.capAdd = ["SYS_PTRACE"]
                $0.capDrop = ["NET_RAW"]
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--cap-add", "NET_ADMIN"]))
        #expect(command.containsSequence(["--cap-add", "SYS_PTRACE"]))
        #expect(command.containsSequence(["--cap-drop", "MKNOD"]))
        #expect(command.containsSequence(["--cap-drop", "NET_RAW"]))
        #expect(Array(command.suffix(2)) == ["alpine", "true"])
    }

    @Test("run rejects empty capability overrides")
    func runRejectsEmptyCapabilityOverrides() async throws {
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        do {
            try await ComposeOrchestrator().run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["true"]) {
                    $0.capAdd = [""]
                }
            )
            Issue.record("Expected empty run capability override to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("run --cap-add requires a capability name"))
        }
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

    @Test("run allocates dynamic published ports only when publishing them")
    func runAllocatesDynamicPublishedPortsOnlyWhenPublishingThem() async throws {
        let ports = HostPortSource([49157, 49158, 49159])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.ports = ["80"]
                },
            ]
        )

        let defaultRunner = RecordingRunner()
        try await ComposeOrchestrator(
            runner: defaultRunner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) })
        ).run(
            project: project,
            serviceName: "api",
            options: composeRunOptions(command: ["true"])
        )
        let defaultCommand = try #require(defaultRunner.commands.first?.arguments)
        #expect(!defaultCommand.contains("--publish"))

        let servicePortsRunner = RecordingRunner()
        try await ComposeOrchestrator(
            runner: servicePortsRunner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) })
        ).run(
            project: project,
            serviceName: "api",
            options: composeRunOptions(command: ["true"]) {
                $0.servicePorts = true
            }
        )
        let servicePortsCommand = try #require(servicePortsRunner.commands.first?.arguments)
        #expect(servicePortsCommand.containsSequence(["--publish", "49157:80"]))

        let hostIPRunner = RecordingRunner()
        try await ComposeOrchestrator(
            runner: hostIPRunner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) })
        ).run(
            project: project,
            serviceName: "api",
            options: composeRunOptions(command: ["true"]) {
                $0.publish = ["127.0.0.1::80"]
            }
        )
        let hostIPCommand = try #require(hostIPRunner.commands.first?.arguments)
        #expect(hostIPCommand.containsSequence(["--publish", "127.0.0.1:49158:80"]))

        let publishRunner = RecordingRunner()
        try await ComposeOrchestrator(
            runner: publishRunner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) })
        ).run(
            project: project,
            serviceName: "api",
            options: composeRunOptions(command: ["true"]) {
                $0.publish = ["80/udp"]
            }
        )
        let publishCommand = try #require(publishRunner.commands.first?.arguments)
        #expect(publishCommand.containsSequence(["--publish", "49159:80/udp"]))
        #expect(ports.requests == [
            HostPortAllocationRequest(hostAddress: nil, protocolName: "tcp"),
            HostPortAllocationRequest(hostAddress: "127.0.0.1", protocolName: "tcp"),
            HostPortAllocationRequest(hostAddress: nil, protocolName: "udp"),
        ])
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

    @Test("run no-deps skips dependency metadata validation")
    func runNoDepsSkipsDependencyMetadataValidation() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy", restart: true)]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.noDeps = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(runner.commands.count == 1)
        #expect(command.starts(with: ["container", "run", "--name"]))
        #expect(command[3].hasPrefix("demo-job-run-"))
        #expect(Array(command.suffix(2)) == ["alpine", "true"])
    }

    @Test("run no-deps only creates selected service resources")
    func runNoDepsOnlyCreatesSelectedServiceResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.networks = ["frontend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "jobcache", target: "/cache")]
                },
                "db": composeService(name: "db", image: "postgres") {
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/var/lib/postgresql/data")]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(name: "backend"),
                "frontend": ComposeNetwork(name: "frontend"),
            ]
            $0.volumes = [
                "data": ComposeVolume(name: "data"),
                "jobcache": ComposeVolume(name: "jobcache"),
            ]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.noDeps = true
                $0.remove = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(runner.commands.count == 1)
        #expect(await resourceManager.requests.map(\.name) == ["demo_frontend", "demo_jobcache"])
        #expect(command.containsSequence(["--network", "demo_frontend"]))
        #expect(command.containsSequence(["--volume", "demo_jobcache:/cache"]))
        #expect(!command.contains("demo_backend"))
        #expect(!command.contains("demo_data"))
    }

    @Test("run rejects dependency timing-only healthchecks before creating resources")
    func runRejectsDependencyTimingOnlyHealthchecksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": composeService(name: "db", image: "postgres") {
                    $0.healthcheck = .object(["interval": .string("5s")])
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/var/lib/postgresql/data")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        do {
            try await ComposeOrchestrator(
                runner: runner,
                imageManager: imageManager,
                resourceManager: resourceManager
            ).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported inherited healthcheck error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'db' tunes an image healthcheck, but image 'postgres' does not expose Dockerfile HEALTHCHECK metadata"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await imageManager.requests == [.healthCheck(reference: "postgres", platform: nil)])
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("run initializes image volumes before the one-off container")
    func runInitializesImageVolumesBeforeTheOneOffContainer() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(imageVolumeTargets: [
            "alpine": ["/image-data"],
        ])
        let resourceManager = RecordingContainerResourceManager()
        let initializer = RecordingContainerImageVolumeInitializer()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.imageVolumeInitializer = initializer
                $0.resourceManager = resourceManager
            },
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains { $0.hasPrefix("demo_anon-job-run-") && $0.hasSuffix(":/image-data") })
        #expect(
            await imageManager.requests == [
                .healthCheck(reference: "alpine", platform: nil),
                .volumeTargets(reference: "alpine", platform: nil),
            ]
        )
        #expect(await resourceManager.requests.count == 2)
        let request = try #require((await initializer.requests).first)
        #expect(request.image == "alpine")
        #expect(request.imageSubpath == "/image-data")
        #expect(request.volumeName.hasPrefix("demo_anon-job-run-"))
    }

    @Test("run starts dependencies before one-off container")
    func runStartsDependenciesBeforeOneOffContainer() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"])
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-db-1"]))
        #expect(commands[0].contains("--detach"))
        #expect(commands[0].containsSequence(["--label", "com.apple.container.compose.service=db"]))
        #expect(commands[0].last == "postgres")
        #expect(commands[1].starts(with: ["container", "run", "--name"]))
        #expect(commands[1][3].hasPrefix("demo-job-run-"))
        #expect(Array(commands[1].suffix(2)) == ["alpine", "true"])
        #expect(await discoveryManager.getRequests == ["demo-db-1"])
    }

    @Test("run prepares default-policy dependency pre start images before creation")
    func runPreparesDefaultPolicyDependencyPreStartImagesBeforeCreation() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(
            pullMissingFailures: ["example/db-init"],
        )
        let dependency = composeService(name: "db", image: "postgres") {
            $0.preStart = [
                ComposeServiceHook(
                    command: ["sh", "-c", "prepare"],
                    image: "example/db-init",
                ),
            ]
        }
        let project = ComposeProject(
            name: "demo",
            services: ["db": dependency],
        )

        do {
            _ = try await ComposeOrchestrator(
                runner: runner,
                imageManager: imageManager,
            ).startDependencyServices(
                project: project,
                services: [dependency],
            )
            Issue.record("Expected dependency pre_start image preparation failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("pull failed: example/db-init"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await imageManager.requests == [
            .pullMissing("example/db-init"),
        ])
        #expect(runner.commands.isEmpty)
    }

    @Test("run waits for healthy dependencies before one-off container")
    func runWaitsForHealthyDependenciesBeforeOneOffContainer() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-db-1": [
                nil,
                ComposeContainerSummary(id: "demo-db-1", status: "running", health: "starting"),
                ComposeContainerSummary(id: "demo-db-1", status: "running", health: "healthy"),
            ],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
            }
        ).run(project: project, serviceName: "job", options: composeRunOptions(command: ["true"]))

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-db-1"]))
        #expect(commands[1].starts(with: ["container", "run", "--name"]))
        #expect(commands[1][3].hasPrefix("demo-job-run-"))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-db-1", "demo-db-1"])
    }

    @Test("run starts provider dependencies and injects setenv into one-off service")
    func runStartsProviderDependenciesAndInjectsSetenvIntoOneOffService() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[]}}
            """, stderr: ""),
            CommandResult(status: 0, stdout: """
            {"type":"setenv","message":"URL=https://magic.cloud/database"}
            """, stderr: ""),
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.dependsOn = ["database": ComposeDependency(condition: "service_started")]
                },
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(type: provider.path)
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies { _ in }).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"])
        )

        #expect(runner.commands.map(\.executable) == [
            provider.path,
            provider.path,
            ComposeExecutionOptions.defaultEnvironmentLauncher,
        ])
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
        #expect(runner.commands[1].arguments == [
            "compose",
            "--project-name=demo",
            "up",
            "database",
        ])
        let runArguments = runner.commands[2].arguments
        #expect(runArguments.starts(with: ["container", "run", "--name"]))
        #expect(runArguments[3].hasPrefix("demo-job-run-"))
        #expect(runArguments.containsSequence(["--env", "DATABASE_URL=https://magic.cloud/database"]))
        #expect(Array(runArguments.suffix(2)) == ["alpine", "true"])
    }

    @Test("run creates project resources before one-off containers")
    func runCreatesProjectResourcesBeforeOneOffContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let orchestrator = ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
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
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(commands[0].starts(with: ["container", "run", "--name"]))
        #expect(commands[0].containsSequence(["--network", "demo_backend"]))
        #expect(commands[0].containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(Array(commands[0].suffix(2)) == ["alpine", "true"])
    }

    @Test("run surfaces network create failures before one-off containers")
    func runSurfacesNetworkCreateFailuresBeforeOneOffContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            networkCreateError: ComposeError.invalidProject("network create failed")
        )
        let project = projectWithBackendNetwork(serviceName: "job", image: "alpine")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected network create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("network create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
    }

    @Test("run surfaces volume create failures before one-off containers")
    func runSurfacesVolumeCreateFailuresBeforeOneOffContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            volumeCreateError: ComposeError.invalidProject("volume create failed")
        )
        let project = projectWithCacheVolume(serviceName: "job", image: "alpine")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected volume create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("volume create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_cache"])
    }

    @Test("run maps network mode none to no network attachment")
    func runMapsNetworkModeNoneToNoNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networkMode = "none"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "run", "--name"]))
        #expect(command.containsSequence(["--network", "none"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("run applies service pull policy before creating resources")
    func runAppliesServicePullPolicyBeforeCreatingResources() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let imageManager = RecordingContainerImageManager()
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

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager, resourceManager: resourceManager).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let commands = runner.commands.map(\.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(await imageManager.requests == [
            .pull("alpine"),
            .healthCheck(reference: "alpine", platform: nil),
        ])
        #expect(commands[0].starts(with: ["container", "run", "--name"]))
    }

    @Test("run direct image pull emits progress before one-off container")
    func runDirectImagePullEmitsProgressBeforeOneOffContainer() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let progress = LockedStringRecorder()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "alpine"),
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "always"
            }
        )

        #expect(progress.snapshot.joined() == """
        ⠓ Pulling image alpine
        ✓ Pulling image alpine
        ⠓ Running job
        ✓ Running job

        """)
        #expect(await imageManager.requests == [
            .pull("alpine"),
            .healthCheck(reference: "alpine", platform: nil),
        ])
        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name"]))
    }

    @Test("run quiet-pull suppresses direct image pull progress")
    func runQuietPullSuppressesDirectImagePullProgress() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let progress = LockedStringRecorder()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "alpine"),
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "always"
                $0.quietPull = true
            }
        )

        #expect(progress.snapshot.joined() == "⠓ Running job\n✓ Running job\n")
        #expect(await imageManager.requests == [
            .pull("alpine"),
            .healthCheck(reference: "alpine", platform: nil),
        ])
        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name"]))
    }

    @Test("run applies service build pull policy before one-off container")
    func runAppliesServiceBuildPullPolicyBeforeOneOffContainer() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "example/job") {
                    $0.build = ComposeBuild(context: "job")
                    $0.pullPolicy = "build"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/job"]))
        #expect(commands[0].last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("job").standardizedFileURL.path)
        #expect(commands[1].starts(with: ["container", "run", "--name"]))
        #expect(Array(commands[1].suffix(2)) == ["example/job", "true"])
    }

    @Test("run build option builds service image before one-off container")
    func runBuildOptionBuildsServiceImageBeforeOneOffContainer() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "example/job") {
                    $0.build = ComposeBuild(context: "job")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.build = true
                $0.quietBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/job"]))
        #expect(commands[0].contains("--quiet"))
        #expect(commands[1].starts(with: ["container", "run", "--name"]))
        #expect(Array(commands[1].suffix(2)) == ["example/job", "true"])
    }

    @Test("run quiet pull option suppresses pull progress")
    func runQuietPullOptionSuppressesPullProgress() async throws {
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "alpine"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "always"
                $0.quietPull = true
            }
        )

        #expect(emitted.messages.contains { $0.contains("container image pull --progress none alpine") })
        #expect(emitted.messages.contains { $0.contains("container run --name") })
    }

    @Test("run interactive option keeps stdin open")
    func runInteractiveOptionKeepsStdinOpen() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "alpine"),
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.interactive = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains("--interactive"))
    }

    @Test("run remove orphans scans project containers after one-off command")
    func runRemoveOrphansScansProjectContainersAfterOneOffCommand() async throws {
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "alpine"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.removeOrphans = true
            }
        )

        #expect(emitted.messages.contains { $0.contains("container run --name") })
        #expect(emitted.messages.contains { $0 == "+ container list --format json --all" })
    }

    @Test("interactive run remove orphans cleans before replacing process")
    func interactiveRunRemoveOrphansCleansBeforeReplacingProcess() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-old-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "old",
                    composeConfigHashLabel: "old-hash",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.tty = true
                    $0.stdinOpen = true
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["sh"]) {
                $0.removeOrphans = true
            }
        )

        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-old-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-old-1", force: false),
        ])
        #expect(runner.commands.first?.io == .replacingProcess)
    }

    @Test("run rejects unsupported service pull policies before creating resources")
    func runRejectsUnsupportedServicePullPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pullPolicy = "sometimes"
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
            #expect(error == .unsupported("service 'job' uses pull_policy 'sometimes'; supported values are always, missing, if_not_present, never, build, daily, weekly, and every_<duration>"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run allows external links whose target does not exist yet")
    func runAllowsExternalLinksWhoseTargetDoesNotExistYet() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.externalLinks = ["legacy_db:db"]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "demo_backend,dns-alias=db:legacy_db"]))
        #expect(!command.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(!(await discoveryManager.getRequests).contains("legacy_db"))
    }

    @Test("run maps external links to source-scoped DNS aliases")
    func runMapsExternalLinksToSourceScopedDNSAliases() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy_db",
                status: "running",
                networks: [
                    ComposeContainerNetworkAttachment(network: "demo_backend", ipv4Address: "192.168.64.20"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.externalLinks = ["legacy_db:db"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "demo_backend,dns-alias=db:legacy_db"]))
        #expect(!command.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(!(await discoveryManager.getRequests).contains("legacy_db"))
    }

    @Test("run maps legacy links to source-scoped DNS aliases after starting dependencies")
    func runMapsLegacyLinksToSourceScopedDNSAliasesAfterStartingDependencies() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-db-1": [nil],
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "db": composeService(name: "db", image: "postgres:18") {
                    $0.networks = ["backend"]
                },
                "job": composeService(name: "job", image: "alpine") {
                    $0.links = ["db:database"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let dependencyCommand = try #require(runner.commands.first?.arguments)
        let runCommand = try #require(runner.commands.last?.arguments)
        #expect(dependencyCommand.containsSequence(["--name", "demo-db-1"]))
        #expect(runCommand.containsSequence(["--network", "demo_backend,dns-alias=database:demo-db-1"]))
        #expect(!runCommand.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(await discoveryManager.getRequests == ["demo-db-1"])
    }

    @Test("run maps hostnames to runtime arguments")
    func runMapsHostnamesToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.hostname = "custom-job"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--hostname", "custom-job"]))
    }

    @Test("run maps domain names to runtime arguments")
    func runMapsDomainNamesToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.domainName = "example.test"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--domainname", "example.test"]))
    }

    @Test("run rejects invalid domain names before creating resources")
    func runRejectsInvalidDomainNamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.domainName = "bad_name"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected invalid domain name error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' domainname 'bad_name' is not a valid RFC1123 hostname"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run maps DNS options to runtime arguments")
    func runMapsDNSOptionsToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.dnsOptions = ["use-vc"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--dns-option", "use-vc"]))
    }

    @Test("run maps sysctls to runtime arguments")
    func runMapsSysctlsToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.sysctls = ["net.core.somaxconn": "1024"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--sysctl", "net.core.somaxconn=1024"]))
    }

    @Test("run maps no-new-privileges security_opt to runtime arguments")
    func runMapsNoNewPrivilegesSecurityOptionToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.securityOpt = ["no-new-privileges=true"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            command: ["true"],
            remove: true
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--security-opt", "no-new-privileges=true"]))
    }

    @Test("run maps unconfined systempaths security_opt to the generic runtime argument")
    func runMapsUnconfinedSystemPathsSecurityOptionToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.securityOpt = ["systempaths=unconfined"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            command: ["true"],
            remove: true
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--security-opt", "systempaths=unconfined"]))
    }

    @Test("run consumes standard security_opt no-ops at the Compose boundary")
    func runConsumesStandardSecurityOptionNoOps() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.securityOpt = ["seccomp=unconfined", "apparmor:unconfined", "label=disable"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            command: ["true"],
            remove: true
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--security-opt"))
    }

    @Test("run persists service stop defaults in runtime arguments")
    func runPersistsServiceStopDefaultsInRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            command: ["true"],
            remove: true
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--stop-signal", "SIGUSR1"]))
        #expect(command.containsSequence(["--stop-timeout", "9"]))
    }

    @Test("run rejects invalid sysctl names before runtime commands")
    func runRejectsInvalidSysctlNamesBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.sysctls = ["bad=name": "1"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected invalid sysctl name error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' uses sysctl name 'bad=name'; sysctl names must not contain '='"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run omits network aliases by default for one-off containers")
    func runOmitsNetworkAliasesByDefaultForOneOffContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["job", "job.internal"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let commands = runner.commands.map(\.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend"]))
        #expect(!commands[0].contains("demo_backend,alias=job,alias=job.internal"))
    }

    @Test("run use-aliases maps service and explicit network aliases")
    func runUseAliasesMapsServiceAndExplicitNetworkAliases() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["job", "job.internal"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", options: composeRunOptions(command: ["true"]) {
                $0.remove = true
                $0.useAliases = true
            })

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "demo_backend,alias=job,alias=job.internal"]))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("run maps interface names to runtime network attachments")
    func runMapsInterfaceNamesToRuntimeNetworkAttachments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
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

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "demo_backend,interface=eth0"]))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("run maps link-local IPs to runtime network attachments")
    func runMapsLinkLocalIPsToRuntimeNetworkAttachments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            addressing: .init(linkLocalIPs: ["169.254.1.5", "fe80::5"])
                        ),
                    ]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence([
            "--network", "demo_backend,address=169.254.1.5,address=fe80::5",
        ]))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("run maps static network addresses to runtime network attachments")
    func runMapsStaticNetworkAddressesToRuntimeNetworkAttachments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            addressing: .init(ipv4Address: "172.28.0.10", ipv6Address: "2001:db8:7::10")
                        ),
                    ]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(
                        subnets: .init(
                            ipv4Subnet: "172.28.0.0/16",
                            ipv6Subnet: "2001:db8:7::/64"
                        )
                    )
                ),
            ]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence([
            "--network", "demo_backend,ip=172.28.0.10,ip6=2001:db8:7::10",
        ]))
    }

    @Test("run maps network mode host to runtime host networking")
    func runMapsNetworkModeHostToRuntimeHostNetworking() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networkMode = "host"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "host"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("run maps network mode bridge to the built-in runtime network")
    func runMapsNetworkModeBridgeToBuiltinRuntimeNetwork() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networkMode = "bridge"
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "run", "--name"]))
        #expect(command.containsSequence(["--network", "default"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("run maps pid host to container pid argument")
    func runMapsPIDHostToContainerPIDArgument() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pid = "host"
                    $0.networks = ["default"]
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "demo_default"]))
        #expect(command.containsSequence(["--pid", "host"]))
        #expect(await resourceManager.requests.map(\.name) == ["demo_default"])
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

    @Test("run rejects an unsupported cgroup namespace mode before creating resources")
    func runRejectsUnsupportedCgroupNamespaceModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.cgroup = "container:db"
                },
            ]
        )

        await #expect(throws: ComposeError.unsupported(
            "service 'job' uses cgroup 'container:db'; supported values are host and private"
        )) {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects IPC namespace sharing modes before creating resources")
    func runRejectsIPCNamespaceSharingModesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.ipc = "service:db"
                },
            ]
        )

        await #expect(throws: ComposeError.unsupported(
            "service 'job' uses ipc 'service:db'; supported values are host and private"
        )) {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported UTS namespace modes before creating resources")
    func runRejectsUnsupportedUTSNamespaceModesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.uts = "container:db"
                },
            ]
        )

        await #expect(throws: ComposeError.unsupported(
            "service 'job' uses uts 'container:db'; supported values are host and private"
        )) {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported pid mode before creating resources")
    func runRejectsUnsupportedPIDModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pid = "container:legacy"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported PID mode error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses pid 'container:legacy'; supported values are host and private"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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

    @Test("run maps block IO config to runtime arguments")
    func runMapsBlockIOConfigToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.blkioConfig = ComposeBlkioConfig(
                        weight: 300,
                        weightDevice: [ComposeBlkioWeightDevice(path: "8:0", weight: 700)],
                        deviceReadBps: [ComposeBlkioThrottleDevice(path: "8:0", rate: "1048576")],
                        deviceReadIOps: [ComposeBlkioThrottleDevice(path: "8:0", rate: "1000")],
                        deviceWriteBps: [ComposeBlkioThrottleDevice(path: "8:0", rate: "2097152")],
                        deviceWriteIOps: [ComposeBlkioThrottleDevice(path: "8:0", rate: "2000")]
                    )
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--blkio", "weight=300"]))
        #expect(command.containsSequence(["--blkio", "device=8:0,weight=700"]))
        #expect(command.containsSequence(["--blkio", "device=8:0,read-bps=1048576"]))
        #expect(command.containsSequence(["--blkio", "device=8:0,read-iops=1000"]))
        #expect(command.containsSequence(["--blkio", "device=8:0,write-bps=2097152"]))
        #expect(command.containsSequence(["--blkio", "device=8:0,write-iops=2000"]))
    }

    @Test("run maps pids_limit to runtime arguments")
    func runMapsPidsLimitToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pidsLimit = 256
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--pids-limit", "256"]))
    }

    @Test("run maps cpu_shares to runtime arguments")
    func runMapsCPUSharesToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.cpuShares = 512
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--cpu-shares", "512"]))
    }

    @Test("run maps cgroup_parent to runtime arguments")
    func runMapsCgroupParentToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.cgroupParent = "workloads/build"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--cgroup-parent", "workloads/build"]))
    }

    @Test("run maps mem_reservation to runtime arguments")
    func runMapsMemoryReservationToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.memReservation = "268435456"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--memory-reservation", "268435456"]))
    }

    @Test("run omits default cpu_shares from runtime arguments")
    func runOmitsDefaultCPUSharesFromRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.cpuShares = 0
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--cpu-shares"))
    }

    @Test("run omits non-positive pids_limit from runtime arguments")
    func runOmitsNonPositivePidsLimitFromRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pidsLimit = -2
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--pids-limit"))
    }

    @Test("run maps device cgroup rules to runtime arguments")
    func runMapsDeviceCgroupRulesToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.deviceCgroupRules = [
                        "c 1:3 mr",
                        "a *:* rwm",
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--device-cgroup-rule", "c 1:3 mr"]))
        #expect(command.containsSequence(["--device-cgroup-rule", "a *:* rwm"]))
    }

    @Test("run maps devices to runtime arguments")
    func runMapsDevicesToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.devices = [
                        .object([
                            "source": .string("/dev/null"),
                            "target": .string("/dev/xnull"),
                            "permissions": .string("rw"),
                        ]),
                        .string("/dev/zero"),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--device", "/dev/null:/dev/xnull:rw"]))
        #expect(command.containsSequence(["--device", "/dev/zero"]))
    }

    @Test("run maps service GPU requests to runtime arguments")
    func runMapsServiceGPURequestsToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.gpus = [.string("all")]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--gpus", "all"]))
    }

    @Test("run rejects invalid devices before runtime commands")
    func runRejectsInvalidDevicesBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.devices = [.string("/dev/null:/dev/xnull:z")]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected invalid devices error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' has invalid devices; entries must use HOST[:CONTAINER[:PERMISSIONS]] with absolute paths and r/w/m permissions"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects invalid device cgroup rules before runtime commands")
    func runRejectsInvalidDeviceCgroupRulesBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.deviceCgroupRules = ["x 1:3 rwm"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected invalid device cgroup rule error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' has invalid device_cgroup_rules; entries must use '<type> <major>:<minor> <access>' such as 'c 1:3 mr'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects invalid block IO config before runtime commands")
    func runRejectsInvalidBlockIOConfigBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.blkioConfig = ComposeBlkioConfig(weight: 1)
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected invalid block IO config error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' uses blkio_config.weight 1; block I/O weight must be between 10 and 1000"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run treats develop watch metadata as harmless")
    func runTreatsDevelopWatchMetadataAsHarmless() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "src", action: "sync", target: "/app/src"),
                    ])
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.contains("run"))
        #expect(runner.commands[0].arguments.contains("--rm"))
    }

    @Test("run rejects unmapped build fields before creating resources")
    func runRejectsUnmappedBuildFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.build = ComposeBuild(
                        context: "job",
                        options: ComposeBuild.Options(unsupportedFields: ["secrets"])
                    )
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
            #expect(error == .unsupported("service 'job' uses unsupported build fields secrets; advanced build fields need Docker Compose compatible apple/container build primitives"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run does not inherit deploy restart policy for one-off containers")
    func runDoesNotInheritDeployRestartPolicyForOneOffContainers() async throws {
        let runner = RecordingRunner(responses: [.success])
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "on-failure",
                        maxAttempts: 3
                    )
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            command: ["true"],
            remove: true
        )

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(!runArguments.contains("--restart"))
    }

    @Test("run accepts start-first deploy update metadata")
    func runAcceptsStartFirstDeployUpdateMetadata() async throws {
        let runner = RecordingRunner(responses: [.success])
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.deploy = .object([
                        "update_config": .object([
                            "order": .string("start-first"),
                        ]),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.contains("true"))
    }

    @Test("run rejects unsupported model fields before creating resources")
    func runRejectsUnsupportedModelFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedModelFieldCases() {
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

    @Test("run rejects negative service scale before creating resources")
    func runRejectsNegativeServiceScaleBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.scale = -1
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected invalid scale error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' scale must be a non-negative integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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

    @Test("run uses negotiated typed logging without process arguments")
    func runUsesNegotiatedTypedLoggingWithoutProcessArguments() async throws {
        let runner = RecordingRunner()
        let launchManager = RecordingContainerLaunchManager()
        let options = ComposeExecutionOptions {
            $0.runtimeCapabilities = .init(identifiers: [
                "io.github.stephenlclarke.container.logging-drivers.v1",
            ])
            $0.oneOffIdentifier = { "abc123" }
        }
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.logging = ComposeLogConfiguration(
                        driver: "fluentd",
                        options: [
                            "fluentd-address": "127.0.0.1:24224",
                            "labels": "com.example.private",
                        ],
                    )
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.launchManager = launchManager
        }

        try await ComposeOrchestrator(runner: runner, options: options, dependencies: dependencies)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        #expect(runner.commands.isEmpty)
        let request = try #require(await launchManager.requests.first)
        #expect(request.command == .run)
        #expect(request.logging == ComposeLogConfiguration(
            driver: "fluentd",
            options: [
                "fluentd-address": "127.0.0.1:24224",
                "labels": "com.example.private",
            ],
        ))
        #expect(!request.arguments.contains("--log-driver"))
        #expect(!request.arguments.contains("--log-opt"))
    }

    @Test("run accepts local logging drivers without options")
    func runAcceptsLocalLoggingDriversWithoutOptions() async throws {
        for testCase in supportedLocalServiceLoggingFieldCases() {
            let runner = RecordingRunner(responses: [.success])
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner)
                .run(project: project, serviceName: "job", command: ["true"], remove: true)

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "run", "--name"]))
            #expect(!command.contains("--log-driver"))
            #expect(!command.contains("--log-opt"))
        }
    }

    @Test("run maps local logging options to runtime policy")
    func runMapsLocalLoggingOptionsToRuntimePolicy() async throws {
        for testCase in supportedLocalServiceLoggingOptionCases() {
            let runner = RecordingRunner(responses: [.success])
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner)
                .run(project: project, serviceName: "job", command: ["true"], remove: true)

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "run", "--name"]))
            #expect(!command.contains("--log-driver"))
            for option in testCase.expectedOptions {
                #expect(command.containsSequence(["--log-opt", option]))
            }
        }
    }

    @Test("run maps disabled logging driver to runtime policy")
    func runMapsDisabledLoggingDriverToRuntimePolicy() async throws {
        for testCase in disabledServiceLoggingFieldCases() {
            let runner = RecordingRunner(responses: [.success])
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner)
                .run(project: project, serviceName: "job", command: ["true"], remove: true)

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "run", "--name"]))
            #expect(command.containsSequence(["--log-driver", "none"]))
            #expect(!command.contains("--log-opt"))
        }
    }

    @Test("run inherits declared volumes from dependency services")
    func runInheritsDeclaredVolumesFromDependencyServices() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "base": composeService(name: "base", image: "example/base") {
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/data")]
                },
                "job": composeService(name: "job", image: "example/job") {
                    $0.volumesFrom = ["base:ro"]
                },
            ]
        ) {
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            discoveryManager: RecordingContainerDiscoveryManager()
        ).run(project: project, serviceName: "job", command: ["echo", "hello"], remove: true)

        let commands = runner.commands.map(\.arguments)
        let baseRun = try #require(commands.first { $0.containsSequence(["--name", "demo-base-1"]) })
        let jobRun = try #require(commands.first { $0.containsSequence(["--name", "demo-job-run-abc123"]) })
        let baseIndex = try #require(commands.firstIndex(of: baseRun))
        let jobIndex = try #require(commands.firstIndex(of: jobRun))
        #expect(baseIndex < jobIndex)
        #expect(baseRun.containsSequence(["--volume", "demo_data:/data"]))
        #expect(jobRun.containsSequence(["--volume", "demo_data:/data:ro"]))
        #expect(jobRun.containsSequence(["example/job", "echo", "hello"]))
    }

    @Test("run inherits external container volumes from direct inspect")
    func runInheritsExternalContainerVolumesFromDirectInspect() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy",
                status: "running",
                mounts: [
                    ComposeMount(type: "external-volume", source: "legacy_data", target: "/data", readOnly: true),
                    ComposeMount(type: "bind", source: "/host/seed", target: "/seed"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "example/job") {
                    $0.volumesFrom = ["container:legacy:rw"]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            discoveryManager: discoveryManager
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        #expect(await discoveryManager.getRequests == ["legacy"])
        let jobRun = try #require(runner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-job-run-abc123"]) })
        #expect(jobRun.containsSequence(["--volume", "legacy_data:/data"]))
        #expect(!jobRun.containsSequence(["--volume", "legacy_data:/data:ro"]))
        #expect(jobRun.containsSequence(["--volume", "/host/seed:/seed"]))
        #expect(jobRun.containsSequence(["example/job", "true"]))
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

    @Test("run rejects unsupported service mount fields before creating resources")
    func runRejectsUnsupportedServiceMountFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            source: "cache",
                            target: "/cache",
                            unsupportedFields: ["volume.nocopy", "bind.recursive", "volume.nocopy"]
                        ),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported service mount error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses unsupported volume fields bind.recursive; advanced service volume options need an apple/container mount primitive gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects advanced mount fields as apple/container gap")
    func runRejectsAdvancedMountFieldsAsAppleContainerGap() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.volumes = [
                        ComposeMount(
                            type: "bind",
                            source: "/host",
                            target: "/cache",
                            unsupportedFields: ["consistency", "bind.recursive"]
                        ),
                    ]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported advanced mount option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses unsupported volume fields consistency, bind.recursive; advanced service volume options need an apple/container mount primitive gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run maps bind propagation values to volume options")
    func runMapsBindPropagationValuesToVolumeOptions() async throws {
        let fileManager = FileManager.default
        for propagation in ["private", "rprivate", "shared", "rshared", "slave", "rslave"] {
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                try? fileManager.removeItem(at: directory)
            }

            let runner = RecordingRunner()
            let project = ComposeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        $0.volumes = [
                            ComposeMount(
                                type: "bind",
                                source: directory.path,
                                target: "/host",
                                options: .init(readOnly: true, bind: .init(propagation: propagation))
                            ),
                        ]
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner).run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["true"])
            )

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.containsSequence(["--volume", "\(directory.path):/host:ro,\(propagation)"]))
        }
    }

    @Test("run rejects unsupported bind propagation values before runtime")
    func runRejectsUnsupportedBindPropagationValuesBeforeRuntime() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.volumes = [
                        ComposeMount(
                            type: "bind",
                            source: directory.path,
                            target: "/host",
                            options: .init(bind: .init(propagation: "recursive-shared"))
                        ),
                    ]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["true"])
            )
            Issue.record("Expected unsupported bind propagation error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("bind propagation 'recursive-shared' is not supported; use private, rprivate, shared, rshared, slave, or rslave"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run maps long form tmpfs options to typed mount")
    func runMapsLongFormTmpfsOptionsToTypedMount() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.volumes = [
                        ComposeMount(
                            type: "tmpfs",
                            target: "/scratch",
                            options: .init(readOnly: true, tmpfs: .init(size: "67108864", mode: "1777"))
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"])
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence([
            "--mount",
            "type=tmpfs,destination=/scratch,readonly,size=67108864,mode=1777",
        ]))
        #expect(!command.containsSequence(["--tmpfs", "/scratch"]))
    }

    @Test("run rejects missing bind sources when create host path is disabled")
    func runRejectsMissingBindSourcesWhenCreateHostPathIsDisabled() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("required")
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.volumes = [ComposeMount(
                        type: "bind",
                        source: source.path,
                        target: "/data",
                        options: .init(bind: .init(createHostPath: false))
                    )]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner)
                .run(project: project, serviceName: "job", options: composeRunOptions(command: ["true"]))
            Issue.record("Expected missing bind source error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' bind mount source '\(source.path)' does not exist and bind.create_host_path is false"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!fileManager.fileExists(atPath: source.path))
        #expect(runner.commands.isEmpty)
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
            #expect(error == .unsupported("service 'job' uses use_api_socket; Docker-compatible API socket and credential handoff need an apple/container runtime boundary"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run maps service MAC address to single network attachment")
    func runMapsServiceMACAddressToSingleNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.macAddress = "02:42:ac:11:00:04"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let commands = runner.commands.map(\.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend,mac=02:42:ac:11:00:04"]))
        #expect(Array(commands[0].suffix(2)) == ["alpine", "true"])
    }

    @Test("run maps healthchecks to container flags")
    func runMapsHealthchecksToContainerFlags() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.healthcheck = .object([
                        "interval": .string("5s"),
                        "retries": .number(2),
                        "start_interval": .string("500ms"),
                        "start_period": .string("1m30s"),
                        "test": .array([.string("CMD-SHELL"), .string("test -f /tmp/ready")]),
                        "timeout": .string("250ms"),
                    ])
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(command.containsSequence(["--health-cmd", "test -f /tmp/ready"]))
        #expect(command.containsSequence(["--health-interval", "5s"]))
        #expect(command.containsSequence(["--health-retries", "2"]))
        #expect(command.containsSequence(["--health-start-interval", "500ms"]))
        #expect(command.containsSequence(["--health-start-period", "1m30s"]))
        #expect(command.containsSequence(["--health-timeout", "250ms"]))
    }

    @Test("run maps file-backed configs and secrets to read-only bind mounts")
    func runMapsFileBackedConfigsAndSecretsToReadOnlyBindMounts() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let config = directory.appendingPathComponent("app.conf")
        let secret = directory.appendingPathComponent("token.txt")
        try Data("config\n".utf8).write(to: config)
        try Data("secret\n".utf8).write(to: secret)
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.configs = [.string("app_config")]
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("runtime-token")])]
                },
            ]
        ) {
            $0.configs = ["app_config": .object(["file": .string(config.path)])]
            $0.secrets = ["app_secret": .object(["file": .string(secret.path)])]
        }

        try await ComposeOrchestrator(runner: runner)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--volume", "\(config.path):/app_config:ro"]))
        #expect(command.containsSequence(["--volume", "\(secret.path):/run/secrets/runtime-token:ro"]))
        #expect(Array(command.suffix(2)) == ["alpine", "true"])
    }

    @Test("run materializes environment backed secrets")
    func runMaterializesEnvironmentBackedSecrets() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let secretEnvironment = "RUN_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(secretEnvironment, "run-secret", 1)
        defer {
            unsetenv(secretEnvironment)
        }
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("runtime-token")])]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.secrets = ["app_secret": .object(["environment": .string(secretEnvironment)])]
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(materializedConfigSecretDirectory: directory.appendingPathComponent("state", isDirectory: true))
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        let secret = try #require(orchestratorReadOnlyVolumeSource(target: "/run/secrets/runtime-token", in: command))
        #expect(try String(contentsOfFile: secret, encoding: .utf8) == "run-secret")
        #expect(try orchestratorPosixPermissions(at: secret) == 0o444)
        #expect(Array(command.suffix(2)) == ["alpine", "true"])
    }

    @Test("run rejects unset environment-backed secrets before creating resources")
    func runRejectsUnsetEnvironmentBackedSecretsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let missingEnvironment = "MISSING_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        unsetenv(missingEnvironment)
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
            $0.secrets = ["app_secret": .object(["environment": .string(missingEnvironment)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected environment-backed secret error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' uses environment-backed secret 'app_secret', but host environment variable '\(missingEnvironment)' is not set"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run applies explicit pull policy before one-off container")
    func runAppliesExplicitPullPolicyBeforeOneOffContainer() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pullPolicy = "never"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "always"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(await imageManager.requests == [
            .pull("alpine"),
            .healthCheck(reference: "alpine", platform: nil),
        ])
        #expect(commands[0].starts(with: ["container", "run"]))
        #expect(Array(commands[0].suffix(2)) == ["alpine", "true"])
    }

    @Test("run pull missing only pulls absent images")
    func runPullMissingOnlyPullsAbsentImages() async throws {
        let presentRunner = RecordingRunner()
        let absentRunner = RecordingRunner()
        let presentImages = RecordingContainerImageManager()
        let absentImages = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        try await ComposeOrchestrator(runner: presentRunner, imageManager: presentImages).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "missing"
            }
        )
        try await ComposeOrchestrator(runner: absentRunner, imageManager: absentImages).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "missing"
            }
        )

        let presentCommands = presentRunner.commands.map(\.arguments)
        #expect(await presentImages.requests == [
            .pullMissing("alpine"),
            .healthCheck(reference: "alpine", platform: nil),
        ])
        #expect(presentCommands[0].starts(with: ["container", "run"]))
        let absentCommands = absentRunner.commands.map(\.arguments)
        #expect(await absentImages.requests == [
            .pullMissing("alpine"),
            .healthCheck(reference: "alpine", platform: nil),
        ])
        #expect(absentCommands[0].starts(with: ["container", "run"]))
    }

    @Test("run pull if not present uses the missing-image flow")
    func runPullIfNotPresentUsesMissingImageFlow() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.pullPolicy = "if_not_present"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(await imageManager.requests == [
            .pullMissing("alpine"),
            .healthCheck(reference: "alpine", platform: nil),
        ])
        #expect(commands[0].starts(with: ["container", "run"]))
        #expect(Array(commands[0].suffix(2)) == ["alpine", "true"])
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

    @Test("run does not inherit service restart policies for one-off containers")
    func runDoesNotInheritServiceRestartPoliciesForOneOffContainers() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
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

        try await ComposeOrchestrator(
            runner: runner,
            resourceManager: resourceManager
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let runArguments = try #require(runner.commands.last?.arguments)
        #expect(runArguments.starts(with: ["container", "run"]))
        #expect(!runArguments.contains("--restart"))
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

    @Test("run quiet suppresses inherited terminal IO")
    func runQuietSuppressesInheritedTerminalIO() async throws {
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
                $0.quiet = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(runner.commands.first?.io == .captured(input: nil))
        #expect(command.contains("--tty"))
        #expect(command.contains("--interactive"))
        #expect(Array(command.suffix(2)) == ["alpine", "sh"])
    }

    @Test("interactive run emits progress before terminal handoff")
    func interactiveRunEmitsProgressBeforeTerminalHandoff() async throws {
        let runner = RecordingRunner()
        let progress = LockedStringRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "shell": composeService(name: "shell", image: "alpine") {
                    $0.tty = true
                    $0.stdinOpen = true
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress)
        ).run(
            project: project,
            serviceName: "shell",
            options: composeRunOptions(command: ["sh"])
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(progress.snapshot.joined() == "⠓ Running shell\n")
        #expect(runner.commands.first?.io == .replacingProcess)
        #expect(command.contains("--tty"))
        #expect(command.contains("--interactive"))
        #expect(Array(command.suffix(2)) == ["alpine", "sh"])
    }

    @Test("run detached executes post start hooks on one off containers")
    func runDetachedExecutesPostStartHooksOnOneOffContainers() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.postStart = [
                        ComposeServiceHook(
                            command: ["sh", "-c", "touch /tmp/ready"],
                            user: "1000",
                            workingDir: "/work",
                            environment: ["READY": "1"]
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            execManager: execManager
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["sleep", "60"]) {
                $0.detach = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "run", "--name", "demo-job-run-abc123"]))
        #expect(command.contains("--detach"))
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-job-run-abc123",
                command: ["sh", "-c", "touch /tmp/ready"],
                environment: ["READY=1"],
                user: "1000",
                workingDirectory: "/work",
                terminal: .init(interactive: false, tty: false)
            ),
        ])
    }

    @Test("run detached accepts pre stop hooks for later one off cleanup")
    func runDetachedAcceptsPreStopHooksForLaterOneOffCleanup() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.preStop = [ComposeServiceHook(command: ["sh", "-c", "rm -f /tmp/ready"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            dependencies: orchestratorDependencies {
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
            }
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["sleep", "60"]) {
                $0.detach = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "run", "--name", "demo-job-run-abc123"]))
        #expect(command.contains("--detach"))
        #expect(await execManager.attachedRequests.isEmpty)
        #expect(await lifecycleManager.requests.isEmpty)
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
        #expect(runner.commands.first?.io == .replacingProcess)
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
        #expect(!command.containsSequence(["--env-file", ".env"]))
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

}
