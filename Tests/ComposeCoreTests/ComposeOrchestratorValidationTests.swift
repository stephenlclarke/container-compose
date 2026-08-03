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
    @Test("logging request participates canonically in the service config hash")
    func loggingRequestParticipatesCanonicallyInServiceConfigHash() throws {
        func project(driver: String?, options: [String: String]) -> ComposeProject {
            composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        $0.logging = ComposeLogConfiguration(driver: driver, options: options)
                    },
                ]
            )
        }

        let first = project(driver: "example/provider", options: ["alpha": "1", "beta": "2"])
        let reordered = project(driver: "example/provider", options: ["beta": "2", "alpha": "1"])
        let changedDriver = project(driver: "another/provider", options: ["alpha": "1", "beta": "2"])
        let changedOption = project(driver: "example/provider", options: ["alpha": "1", "beta": "3"])
        let omitted = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")],
        )

        let firstHash = try configHash(project: first, service: #require(first.services["api"]))
        #expect(try configHash(project: reordered, service: #require(reordered.services["api"])) == firstHash)
        #expect(try configHash(project: changedDriver, service: #require(changedDriver.services["api"])) != firstHash)
        #expect(try configHash(project: changedOption, service: #require(changedOption.services["api"])) != firstHash)
        #expect(try configHash(project: omitted, service: #require(omitted.services["api"])) != firstHash)
    }

    @Test("up applies labels from service label files")
    func upAppliesLabelsFromServiceLabelFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(
            """
            # comments and blank lines are ignored
            com.example.empty
            com.example.file=base
            com.example.shared=base

            """.utf8
        ).write(to: directory.appendingPathComponent("base.labels"))
        try Data(
            """
            com.example.file=override

            """.utf8
        ).write(to: directory.appendingPathComponent("override.labels"))
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.labelFiles = ["base.labels", "override.labels"]
                    $0.labels = [
                        "com.example.file": "inline",
                        "com.example.inline": "yes",
                    ]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--label", "com.example.empty="]))
        #expect(command.containsSequence(["--label", "com.example.file=inline"]))
        #expect(command.containsSequence(["--label", "com.example.inline=yes"]))
        #expect(command.containsSequence(["--label", "com.example.shared=base"]))
        #expect(!command.containsSequence(["--label", "com.example.file=override"]))
    }

    @Test("up projects service annotations through the OCI annotation channel")
    func upProjectsServiceAnnotationsThroughTheOCIAnnotationChannel() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.annotations = [
                        "example.com/owner": "platform",
                        "example.com/purpose": "local-dev",
                    ]
                    $0.labels = ["com.example.role": "api"]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--label", "com.example.role=api"]))
        #expect(command.containsSequence(["--annotation", "example.com/owner=platform"]))
        #expect(command.containsSequence(["--annotation", "example.com/purpose=local-dev"]))
        #expect(!command.containsSequence(["--label", "example.com/owner=platform"]))
        #expect(!command.containsSequence(["--label", "example.com/purpose=local-dev"]))
    }

    @Test("up projects service expose as metadata without publishing host ports")
    func upProjectsServiceExposeThroughTheRuntimeMetadataChannel() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.expose = ["8080", "8443/udp", "9000-9001/tcp"]
                },
            ]
        )

        let orchestrator = ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        )
        let plan = try await orchestrator.serviceCreatePlan(project: project, serviceName: "api")
        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(plan.exposedPorts == ["8080", "8443/udp", "9000-9001/tcp"])
        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--expose", "8080"]))
        #expect(command.containsSequence(["--expose", "8443/udp"]))
        #expect(command.containsSequence(["--expose", "9000-9001/tcp"]))
        #expect(!command.contains("--publish"))
    }

    @Test("up keeps same-key labels and annotations distinct")
    func upKeepsSameKeyLabelsAndAnnotationsDistinct() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.annotations = ["com.example.role": "metadata"]
                    $0.labels = ["com.example.role": "api"]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--label", "com.example.role=api"]))
        #expect(command.containsSequence(["--annotation", "com.example.role=metadata"]))
        #expect(!command.containsSequence(["--label", "com.example.role=metadata"]))
    }

    @Test("up recreates containers when service label files change")
    func upRecreatesContainersWhenServiceLabelFilesChange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let labelFile = directory.appendingPathComponent("service.labels")
        try Data("com.example.version=one\n".utf8).write(to: labelFile)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.labelFiles = ["service.labels"]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
        }
        let createRunner = RecordingRunner()

        try await ComposeOrchestrator(
            runner: createRunner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let oldRun = try #require(createRunner.commands.last?.arguments)
        let oldHash = try #require(composeConfigHash(in: oldRun))
        try Data("com.example.version=two\n".utf8).write(to: labelFile)
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: oldHash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        let newRun = try #require(runner.commands.first?.arguments)
        #expect(newRun.containsSequence(["--label", "com.example.version=two"]))
        #expect(composeConfigHash(in: newRun) != oldHash)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("up rejects reserved labels from service label files before creating resources")
    func upRejectsReservedLabelsFromServiceLabelFilesBeforeCreatingResources() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("com.apple.container.compose.project=evil\n".utf8)
            .write(to: directory.appendingPathComponent("service.labels"))
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.labelFiles = ["service.labels"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected reserved service label file to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' label_file 'service.labels' cannot set reserved Compose tracking label 'com.apple.container.compose.project'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests == [])
    }

    @Test("up rejects reserved service labels before creating resources")
    func upRejectsReservedServiceLabelsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.labels = ["com.docker.compose.project": "evil"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected reserved service label to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' label cannot set reserved Compose tracking label 'com.docker.compose.project'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests == [])
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

    @Test("run keeps label overrides separate from service annotations")
    func runKeepsLabelOverridesSeparateFromServiceAnnotations() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.annotations = ["com.example.owner": "platform"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"]) {
                $0.labels = ["com.example.owner=override"]
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--label", "com.example.owner=override"]))
        #expect(command.containsSequence(["--annotation", "com.example.owner=platform"]))
    }

    @Test("run applies one-off volume overrides")
    func runAppliesOneOffVolumeOverrides() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultSource = directory.appendingPathComponent("default").path
        let overrideSource = directory.appendingPathComponent("host").path

        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.volumes = [ComposeMount(
                        type: "bind",
                        source: defaultSource,
                        target: "/default",
                        options: .init(bind: .init(createHostPath: true))
                    )]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["ls"]) {
                $0.volumes = ["\(overrideSource):/container:ro", "cache:/cache", "/scratch"]
            }
        )

        let command = try #require(runner.commands.last?.arguments)
        let anonymousVolume = try #require(command.first { $0.hasPrefix("demo_anon-") && $0.hasSuffix(":/scratch") })
        let anonymousVolumeName = String(anonymousVolume.split(separator: ":", maxSplits: 1)[0])
        #expect(await resourceManager.requests == [
            .createVolume(ComposeVolumeCreateRequest(name: "demo_cache", labels: [
                "com.apple.container.compose.project": "demo",
                "com.apple.container.compose.version": "1",
                "com.apple.container.compose.project.working-directory": FileManager.default.currentDirectoryPath,
                "com.apple.container.compose.project.config-files": "",
                "com.apple.container.compose.project.config-files-hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ])),
            .createVolume(ComposeVolumeCreateRequest(name: anonymousVolumeName)),
        ])
        #expect(FileManager.default.fileExists(atPath: defaultSource))
        #expect(FileManager.default.fileExists(atPath: overrideSource))
        #expect(command.containsSequence(["--volume", "\(defaultSource):/default"]))
        #expect(command.containsSequence(["--volume", "\(overrideSource):/container:ro"]))
        #expect(command.containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(command.contains { $0 == anonymousVolume })
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
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running"),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.noRecreate = true
        })

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
    }

    @Test("up reuses existing containers when config hash matches")
    func upReusesExistingContainersWhenConfigHashMatches() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])
        let createDiscovery = RecordingContainerDiscoveryManager()
        let createRunner = RecordingRunner(responses: [.success])

        try await ComposeOrchestrator(runner: createRunner, discoveryManager: createDiscovery).up(project: project, options: ComposeUpOptions())

        let run = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: run))
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: hash]),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
    }

    @Test("up recreates existing containers when deploy metadata changes")
    func upRecreatesExistingContainersWhenDeployMetadataChanges() async throws {
        let initialProject = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deploy = .object([
                        "labels": .object([
                            "com.example.deploy-marker": .string("one"),
                        ]),
                    ])
                },
            ]
        )
        let createDiscovery = RecordingContainerDiscoveryManager()
        let createRunner = RecordingRunner(responses: [.success])

        try await ComposeOrchestrator(
            runner: createRunner,
            discoveryManager: createDiscovery
        ).up(project: initialProject, options: ComposeUpOptions())

        let run = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: run))
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: hash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let projectWithDeployLabels = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deploy = .object([
                        "labels": .object([
                            "com.example.deploy-marker": .string("two"),
                        ]),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(project: projectWithDeployLabels, options: ComposeUpOptions())

        let newRun = try #require(runner.commands.first?.arguments)
        #expect(newRun.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(composeConfigHash(in: newRun) != hash)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("up recreates existing containers when resource runtime names change")
    func upRecreatesExistingContainersWhenResourceRuntimeNamesChange() async throws {
        let oldProject = projectWithRuntimeResources(networkName: "old-net", volumeName: "old-cache")
        let createDiscovery = RecordingContainerDiscoveryManager()
        let createRunner = RecordingRunner(responses: [.success])

        try await ComposeOrchestrator(runner: createRunner, discoveryManager: createDiscovery).up(project: oldProject, options: ComposeUpOptions())

        let oldRun = try #require(createRunner.commands.last?.arguments)
        let oldHash = try #require(composeConfigHash(in: oldRun))
        let newProject = projectWithRuntimeResources(networkName: "new-net", volumeName: "new-cache")
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: oldHash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(project: newProject, options: ComposeUpOptions())

        let newRun = runner.commands[0].arguments
        #expect(newRun.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(newRun.containsSequence(["--network", "new-net"]))
        #expect(newRun.containsSequence(["--volume", "new-cache:/cache"]))
        #expect(composeConfigHash(in: newRun) != oldHash)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("up recreates existing containers when config hash changes")
    func upRecreatesExistingContainersWhenConfigHashChanges() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: "stale"]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(composeConfigHash(in: runner.commands[0].arguments) != "stale")
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("up ignores deploy update delay in local mode")
    func upIgnoresDeployUpdateDelayInLocalMode() async throws {
        let sleeper = DurationRecorder()
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: "stale-1"]),
            ComposeContainerSummary(id: "demo-api-2", status: "running", labels: [composeConfigHashLabel: "stale-2"]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                    $0.deploy = .object([
                        "update_config": .object([
                            "delay": .string("2s"),
                            "order": .string("start-first"),
                            "parallelism": .number(1),
                        ]),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { try await sleeper.sleep($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.map(\.arguments).count == 2)
        #expect(await sleeper.durations.isEmpty)
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
            .stop(id: "demo-api-2", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-2", force: false),
        ])
    }

    @Test("up timeout overrides service stop grace period when recreating")
    func upTimeoutOverridesServiceStopGracePeriodWhenRecreating() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: "stale"]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions {
            $0.timeout = 12
        })

        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 12),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("up force recreates existing containers even when config hash matches")
    func upForceRecreatesExistingContainersWhenConfigHashMatches() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])
        let createDiscovery = RecordingContainerDiscoveryManager()
        let createRunner = RecordingRunner(responses: [.success])

        try await ComposeOrchestrator(runner: createRunner, discoveryManager: createDiscovery).up(project: project, options: ComposeUpOptions())

        let run = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: run))
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: hash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, lifecycleManager: lifecycleManager).up(project: project, options: ComposeUpOptions {
            $0.forceRecreate = true
        })

        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("up always-recreate-deps recreates matching dependency containers")
    func upAlwaysRecreateDepsRecreatesMatchingDependencyContainers() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )
        let baselineRunner = RecordingRunner()
        try await ComposeOrchestrator(runner: baselineRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
            })

        let dbRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        let dbHash = try #require(composeConfigHash(in: dbRun))
        let apiHash = try #require(composeConfigHash(in: apiRun))
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-db-1", status: "running", labels: [composeConfigHashLabel: dbHash]),
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: apiHash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.alwaysRecreateDeps = true
        })

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--name", "demo-db-1"]))
        #expect(commands[0].contains("--detach"))
        #expect(!commands.contains { $0.contains("demo-api-1") })
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-db-1", force: false),
        ])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
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

    @Test("dry run pull quiet disables pull progress")
    func dryRunPullQuietDisablesPullProgress() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "alpine")])

        try await orchestrator.pull(
            project: project,
            options: ComposePullOptions {
                $0.quiet = true
            }
        )

        #expect(emitted.messages == ["+ container image pull --progress none alpine"])
    }

    @Test("dry run up does not treat synthetic inspect success as existing container")
    func dryRunUpDoesNotTreatSyntheticInspectSuccessAsExistingContainer() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "alpine")])

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.noRecreate = true
        })

        let messages = emitted.messages
        #expect(messages.contains("+ container inspect demo-api-1"))
        #expect(messages.contains { $0.hasPrefix("+ container run ") && $0.contains("--detach") })
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

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.pullPolicy = "missing"
        })

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
                options: ComposeUpOptions {
                    $0.pullPolicy = "sometimes"
                }
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

    }

    @Test("command failures are surfaced")
    func commandFailuresAreSurfaced() async throws {
        let expected = ComposeError.commandFailed(command: "container image pull example/api", status: 4, stderr: "")
        let imageManager = RecordingContainerImageManager(failure: expected)
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(imageManager: imageManager).pull(project: project, services: ["api"])
            Issue.record("Expected command failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
