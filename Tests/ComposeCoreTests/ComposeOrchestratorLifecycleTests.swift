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
    @Test("down removes project resources in dependency order")
    func downRemovesProjectResourcesInDependencyOrder() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(runner: runner, lifecycleManager: lifecycleManager, resourceManager: resourceManager)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
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

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
            .delete(id: "demo-api-1", force: false),
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-db-1", force: false),
        ])
        #expect(await resourceManager.requests == [
            .deleteNetwork(id: "demo_default"),
            .listVolumes,
            .deleteVolume(name: "demo_data"),
        ])
    }

    @Test("down volumes removes anonymous service replica volumes")
    func downVolumesRemovesAnonymousServiceReplicaVolumes() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [composeProjectLabel: "demo", composeServiceLabel: "api"]
            ),
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [composeProjectLabel: "demo", composeServiceLabel: "api"]
            ),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(type: "volume", target: "/scratch"),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        ).down(project: project, options: ComposeDownOptions(volumes: true))

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-2", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-2", force: false),
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
        let resources = await resourceManager.requests
        #expect(resources.count == 3)
        #expect(resources.first == .listVolumes)
        #expect(resources.contains { $0.name.hasPrefix("demo_anon-api-1-") })
        #expect(resources.contains { $0.name.hasPrefix("demo_anon-api-2-") })
    }

    @Test("down volumes removes generated image volumes by lifecycle labels")
    func downVolumesRemovesGeneratedImageVolumesByLifecycleLabels() async throws {
        let runtimeVolume = "demo_anon-api-1-9c67416f2a3b"
        let resourceManager = RecordingContainerResourceManager(volumes: [
            ComposeVolumeSummary(
                name: runtimeVolume,
                labels: [
                    composeProjectLabel: "demo",
                    "com.apple.container.compose.image-volume": "true",
                    "com.apple.container.compose.image-volume.container": "demo-api-1",
                    "com.apple.container.compose.image-volume.service": "api",
                ],
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: ["api": composeService(name: "api", image: "example/api")],
        )

        try await ComposeOrchestrator(runner: RecordingRunner(), resourceManager: resourceManager)
            .down(project: project, options: ComposeDownOptions(volumes: true))

        #expect(await resourceManager.requests == [
            .listVolumes,
            .deleteVolume(name: runtimeVolume),
        ])
    }

    @Test("down service selection preserves shared project resources")
    func downServiceSelectionPreservesSharedProjectResources() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.networks = ["default"]
                    $0.volumes = [
                        ComposeMount(type: "volume", target: "/scratch"),
                    ]
                },
                "db": composeService(name: "db", image: "postgres") {
                    $0.networks = ["default"]
                    $0.volumes = [
                        ComposeMount(type: "volume", source: "data", target: "/var/lib/postgresql/data"),
                    ]
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        ).down(project: project, options: ComposeDownOptions(services: ["api"], volumes: true))

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
        let resources = await resourceManager.requests
        #expect(resources.count == 2)
        #expect(resources.first == .listVolumes)
        if case let .deleteVolume(name) = resources[1] {
            #expect(name.hasPrefix("demo_anon-api-1-"))
        } else {
            Issue.record("Expected selected down to remove only the selected service anonymous volume")
        }
    }

    @Test("down skips missing optional dependencies while cleaning resources")
    func downSkipsMissingOptionalDependenciesWhileCleaningResources() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(runner: runner, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["optional": ComposeDependency(condition: "service_started", required: false)]
                },
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions())

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("down leaves orphan containers unless requested")
    func downLeavesOrphanContainersUnlessRequested() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(runner: runner, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions())

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("down ignores service containers that are already removed")
    func downIgnoresServiceContainersThatAreAlreadyRemoved() async throws {
        let missing = ContainerizationError(.notFound, message: "container not found")
        let stopError = ContainerizationError(.internalError, message: "failed to stop container", cause: missing)
        let deleteError = ContainerizationError(.internalError, message: "failed to delete container", cause: missing)
        let lifecycleManager = RecordingContainerLifecycleManager(
            stopErrorsByID: ["demo-api-1": stopError],
            deleteErrorsByID: ["demo-api-1": deleteError]
        )
        let orchestrator = ComposeOrchestrator(runner: RecordingRunner(), lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions())

        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("down removes remaining project scoped containers")
    func downRemovesRemainingProjectScopedContainers() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions(removeOrphans: true))

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true, true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-worker-1", force: false),
        ])
    }

    @Test("down ignores orphan containers that disappear during cleanup")
    func downIgnoresOrphanContainersThatDisappearDuringCleanup() async throws {
        let missing = ContainerizationError(.notFound, message: "container not found")
        let stopError = ContainerizationError(.internalError, message: "failed to stop container", cause: missing)
        let deleteError = ContainerizationError(.internalError, message: "failed to delete container", cause: missing)
        let lifecycleManager = RecordingContainerLifecycleManager(
            stopErrorsByID: ["demo-worker-1": stopError],
            deleteErrorsByID: ["demo-worker-1": deleteError]
        )
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions(removeOrphans: true))

        #expect(await discoveryManager.listRequests == [true, true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-worker-1", force: false),
        ])
    }

    @Test("down removes all service images when requested")
    func downRemovesAllServiceImagesWhenRequested() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let imageManager = RecordingContainerImageManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            imageManager: imageManager,
            lifecycleManager: lifecycleManager
        )
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

        #expect(runner.commands.isEmpty)
        #expect(await imageManager.requests == [
            .delete(reference: "demo_worker:latest", force: true),
            .delete(reference: "example/api:dev", force: true),
            .delete(reference: "example/web:dev", force: true),
        ])
        #expect(emitted.messages == ["demo_worker:latest", "example/api:dev", "example/web:dev"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-worker-1", force: false),
            .stop(id: "demo-web-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-web-1", force: false),
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("down service selection removes only selected service images")
    func downServiceSelectionRemovesOnlySelectedServiceImages() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(runner: runner, imageManager: imageManager, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:dev"),
                "web": ComposeService(name: "web", image: "example/web:dev"),
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions(services: ["api"], rmi: "all"))

        #expect(runner.commands.isEmpty)
        #expect(await imageManager.requests == [
            .delete(reference: "example/api:dev", force: true),
        ])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("down removes only local build images when requested")
    func downRemovesOnlyLocalBuildImagesWhenRequested() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(runner: runner, imageManager: imageManager, lifecycleManager: lifecycleManager)
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

        #expect(runner.commands.isEmpty)
        #expect(await imageManager.requests == [
            .delete(reference: "demo_worker:latest", force: true),
        ])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-worker-1", force: false),
            .stop(id: "demo-web-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-web-1", force: false),
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("down surfaces image removal failures")
    func downSurfacesImageRemovalFailures() async throws {
        let runner = RecordingRunner()
        let expected = ComposeError.invalidProject("image delete failed")
        let imageManager = RecordingContainerImageManager(failure: expected)
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(runner: runner, imageManager: imageManager, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:dev"),
            ]
        )

        do {
            try await orchestrator.down(project: project, options: ComposeDownOptions(rmi: "all"))
            Issue.record("Expected image delete failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("down surfaces service stop failures")
    func downSurfacesServiceStopFailures() async throws {
        let runner = RecordingRunner()
        let expected = ComposeError.invalidProject("stop failed")
        let lifecycleManager = RecordingContainerLifecycleManager(stopError: expected)
        let orchestrator = ComposeOrchestrator(runner: runner, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        do {
            try await orchestrator.down(project: project, options: ComposeDownOptions())
            Issue.record("Expected service stop failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
        ])
    }

    @Test("down surfaces orphan stop failures")
    func downSurfacesOrphanStopFailures() async throws {
        let runner = RecordingRunner()
        let expected = ComposeError.invalidProject("orphan stop failed")
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let lifecycleManager = RecordingContainerLifecycleManager(stopError: expected)
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = ComposeProject(name: "demo", services: [:])

        do {
            try await orchestrator.down(project: project, options: ComposeDownOptions(removeOrphans: true))
            Issue.record("Expected orphan stop failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true, true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
        ])
    }

    @Test("down surfaces service delete failures")
    func downSurfacesServiceDeleteFailures() async throws {
        let runner = RecordingRunner()
        let expected = ComposeError.invalidProject("delete failed")
        let lifecycleManager = RecordingContainerLifecycleManager(deleteError: expected)
        let orchestrator = ComposeOrchestrator(runner: runner, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await orchestrator.down(project: project, options: ComposeDownOptions())
            Issue.record("Expected service delete failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("down surfaces network removal failures")
    func downSurfacesNetworkRemovalFailures() async throws {
        let runner = RecordingRunner()
        let expected = ComposeError.invalidProject("network delete failed")
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager(networkDeleteError: expected)
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        )
        let project = composeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        do {
            try await orchestrator.down(project: project, options: ComposeDownOptions(volumes: true))
            Issue.record("Expected network delete failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
        #expect(await resourceManager.requests == [
            .deleteNetwork(id: "demo_default"),
        ])
    }

    @Test("down surfaces volume removal failures")
    func downSurfacesVolumeRemovalFailures() async throws {
        let runner = RecordingRunner()
        let expected = ComposeError.invalidProject("volume delete failed")
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager(volumeDeleteError: expected)
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        )
        let project = composeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        ) {
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        do {
            try await orchestrator.down(project: project, options: ComposeDownOptions(volumes: true))
            Issue.record("Expected volume delete failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
        #expect(await resourceManager.requests == [
            .listVolumes,
            .deleteVolume(name: "demo_data"),
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
        let copier = RecordingContainerCopier()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
        ])
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.copier = copier
                $0.discoveryManager = discoveryManager
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
            }
        )
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

        try await orchestrator.logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.tail = "10"
            }
        )
        try await orchestrator.exec(project: project, serviceName: "api", command: ["echo", "ok"])
        try await orchestrator.start(project: project, services: ["api"])
        try await orchestrator.stop(project: project, services: ["api"])
        try await orchestrator.restart(project: project, services: ["api"])
        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true, force: true)
        try await orchestrator.kill(project: project, services: ["api"], signal: "SIGTERM")
        try await orchestrator.copy(project: project, arguments: ["api:/tmp/file", "."])

        #expect(runner.commands.isEmpty)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["echo", "ok"],
                terminal: .init(interactive: true, tty: true)
            ),
        ])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: 10, follow: true),
        ])
        #expect(await lifecycleManager.requests == [
            .start(id: "demo-api-1"),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
            .start(id: "demo-api-1"),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
            .delete(id: "demo-api-1", force: true),
            .kill(id: "demo-api-1", signal: "SIGTERM"),
        ])
        #expect(await copier.requests == [
            .from(id: "demo-api-1", source: "/tmp/file", destination: "."),
        ])
    }

    @Test("up foreground runs post start hooks before aggregating logs")
    func upForegroundRunsPostStartHooksBeforeAggregatingLogs() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let logManager = RecordingContainerLogManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.postStart = [
                        ComposeServiceHook(
                            command: ["sh", "-c", "touch /tmp/ready"],
                            user: "1000",
                            privileged: true,
                            workingDir: "/srv",
                            environment: ["A": "1", "B": nil]
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.execManager = execManager
                $0.logManager = logManager
            }
        ).up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.map(\.arguments).first?.contains("--detach") == true)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "touch /tmp/ready"],
                environment: ["A=1", "B"],
                user: "1000",
                workingDirectory: "/srv",
                privileged: true,
                terminal: .init(interactive: false, tty: false)
            ),
        ])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true),
        ])
    }

    @Test("up foreground stops started services through the standard lifecycle on interruption")
    func upForegroundStopsStartedServicesThroughStandardLifecycleOnInterruption() async throws {
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["ready\n"])
        let signalProxy = RecordingComposeSignalProxy(forwardedSignals: ["SIGINT"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.preStop = [ComposeServiceHook(command: ["sh", "-c", "echo stopping"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            dependencies: orchestratorDependencies {
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.signalProxy = signalProxy
            }
        ).up(project: project, options: ComposeUpOptions())

        #expect(await signalProxy.requests == [["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"]])
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "echo stopping"],
                terminal: .init(interactive: false, tty: false)
            ),
        ])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
        ])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true),
        ])
    }

    @Test("up wait runs post start hooks through detached path")
    func upWaitRunsPostStartHooksThroughDetachedPath() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-api-1", status: "running"),
                ],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.postStart = [ComposeServiceHook(command: ["sh", "-c", "touch /tmp/ready"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.execManager = execManager
            }
        ).up(project: project, options: ComposeUpOptions { $0.wait = true })

        #expect(runner.commands.map(\.arguments).first?.contains("--detach") == true)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "touch /tmp/ready"],
                terminal: .init(interactive: false, tty: false)
            ),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("restart runs pre stop and post start hooks around lifecycle calls")
    func restartRunsPreStopAndPostStartHooksAroundLifecycleCalls() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.preStart = [ComposeServiceHook(command: ["sh", "-c", "prepare"])]
                    $0.postStart = [ComposeServiceHook(command: ["sh", "-c", "touch /tmp/ready"])]
                    $0.preStop = [ComposeServiceHook(command: ["sh", "-c", "rm -f /tmp/ready"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
            }
        ).restart(project: project, services: ["api"])

        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "rm -f /tmp/ready"],
                terminal: .init(interactive: false, tty: false)
            ),
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "touch /tmp/ready"],
                terminal: .init(interactive: false, tty: false)
            ),
        ])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .start(id: "demo-api-1"),
        ])
        #expect(runner.commands.isEmpty)
    }

    @Test("restart includes dependencies unless no-deps is set")
    func restartIncludesDependenciesUnlessNoDepsIsSet() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            lifecycleManager: lifecycleManager
        ).restart(project: project, services: ["api"])

        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
            .start(id: "demo-db-1"),
            .start(id: "demo-api-1"),
        ])

        let noDepsLifecycleManager = RecordingContainerLifecycleManager()
        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            lifecycleManager: noDepsLifecycleManager
        ).restart(project: project, options: ComposeRestartOptions {
            $0.services = ["api"]
            $0.noDeps = true
        })

        #expect(await noDepsLifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .start(id: "demo-api-1"),
        ])
    }

    @Test("lifecycle hooks render exec commands in dry run")
    func lifecycleHooksRenderExecCommandsInDryRun() async throws {
        let emitted = MessageRecorder()
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.preStop = [
                        ComposeServiceHook(
                            command: ["sh", "-c", "echo stopping"],
                            user: "app",
                            privileged: true,
                            workingDir: "/srv",
                            environment: ["MODE": "test"]
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
            }
        ).stop(project: project, services: ["api"], timeout: 3)

        #expect(emitted.messages == [
            "+ container exec --env MODE=test --user app --workdir /srv --privileged demo-api-1 sh -c 'echo stopping'",
            "+ container stop --time 3 demo-api-1",
        ])
        #expect(await execManager.attachedRequests.isEmpty)
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("lifecycle hooks reject unsupported forms before side effects")
    func lifecycleHooksRejectUnsupportedFormsBeforeSideEffects() async throws {
        let cases: [(service: ComposeService, options: ComposeUpOptions, error: ComposeError)] = [
            (
                composeService(name: "api", image: "example/api") {
                    $0.preStart = [ComposeServiceHook(command: ["true"], perReplica: true)]
                },
                ComposeUpOptions { $0.detach = true },
                .unsupported("service 'api' pre_start[0] uses per_replica; Docker Compose supports only false")
            ),
            (
                composeService(name: "api", image: "example/api") {
                    $0.postStart = [ComposeServiceHook()]
                },
                ComposeUpOptions { $0.detach = true },
                .invalidProject("service 'api' post_start[0] requires a command")
            ),
        ]

        for testCase in cases {
            let runner = RecordingRunner()
            let project = ComposeProject(name: "demo", services: ["api": testCase.service])

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: testCase.options)
                Issue.record("Expected lifecycle hook validation error")
            } catch let error as ComposeError {
                #expect(error == testCase.error)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("pre start helper projects hook runtime options and target mounts")
    func preStartHelperProjectsHookRuntimeOptionsAndTargetMounts() async throws {
        let runner = RecordingRunner()
        let helperName = "demo-api-pre-start-0-abc123"
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(
                        id: "demo-api-1",
                        status: "created",
                        mounts: [
                            ComposeMount(
                                type: "external-volume",
                                source: "legacy_cache",
                                target: "/cache",
                                readOnly: true
                            ),
                        ]
                    ),
                ],
            ]
        )
        let lifecycleManager = RecordingContainerLifecycleManager(
            waitExitCodes: [helperName: 0]
        )
        let logManager = RecordingContainerLogManager(outputs: ["prepared\n"])
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.environment = ["BASE": "1", "OVERRIDE": "old"]
                    $0.networks = ["backend"]
                    $0.preStart = [
                        ComposeServiceHook(
                            command: ["sh", "-c", "prepare"],
                            image: "example/init:1",
                            user: "1000",
                            privileged: true,
                            workingDir: "/work",
                            environment: ["OVERRIDE": "new", "READY": "1"]
                        ),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "demo_backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
            }
        ).up(
            project: project,
            options: ComposeUpOptions { $0.detach = true }
        )

        let command = try #require(runner.commands.last?.arguments)
        #expect(runner.commands.count == 2)
        #expect(command.starts(with: ["container", "create", "--name", helperName]))
        #expect(command.containsSequence(["--env", "BASE=1"]))
        #expect(command.containsSequence(["--env", "OVERRIDE=new"]))
        #expect(command.containsSequence(["--env", "READY=1"]))
        #expect(!command.contains("OVERRIDE=old"))
        #expect(command.containsSequence(["--user", "1000"]))
        #expect(command.containsSequence(["--workdir", "/work"]))
        #expect(command.contains("--privileged"))
        #expect(command.containsSequence(["--network", "demo_backend"]))
        #expect(command.containsSequence(["--volume", "legacy_cache:/cache:ro"]))
        #expect(Array(command.suffix(4)) == ["example/init:1", "sh", "-c", "prepare"])
        #expect(await discoveryManager.getRequests == [
            "demo-api-1",
            "demo-api-1",
        ])
        let preStartImageRequests = await imageManager.requests
        #expect(preStartImageRequests == [
            .pullMissing("example/init:1"),
            .healthCheck(reference: "example/api", platform: nil),
            .healthCheck(reference: "example/init:1", platform: nil),
        ])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: helperName, tail: nil, follow: true),
        ])
        #expect(await lifecycleManager.requests == [
            .start(id: helperName),
            .wait(id: helperName),
            .delete(id: helperName, force: false),
            .start(id: "demo-api-1"),
        ])
    }

    @Test("pre start helper image planning handles hook-only services")
    func preStartHelperImagePlanningHandlesHookOnlyServices() {
        let orchestrator = ComposeOrchestrator()
        let service = composeService(name: "prepare") {
            $0.preStart = [
                ComposeServiceHook(command: ["first"], image: "example/init:2"),
                ComposeServiceHook(command: ["duplicate"], image: "example/init:2"),
                ComposeServiceHook(command: ["second"], image: "example/init:1"),
            ]
        }

        #expect(orchestrator.serviceRuntimeImages(service) == [
            "example/init:1",
            "example/init:2",
        ])
    }

    @Test("pre start target planning handles empty and unknown state")
    func preStartTargetPlanningHandlesEmptyAndUnknownState() async throws {
        let orchestrator = ComposeOrchestrator()
        let service = composeService(name: "api", image: "example/api")
        let project = ComposeProject(name: "demo", services: ["api": service])

        try await orchestrator.startServiceTargets(
            project: project,
            service: service,
            targets: []
        )
        #expect(!orchestrator.isStartedServiceTarget(
            ServiceContainerTarget(
                service: service,
                index: 1,
                name: "demo-api-1",
                status: nil
            )
        ))
    }

    @Test("pre start helper validates command and image invariants")
    func preStartHelperValidatesCommandAndImageInvariants() async throws {
        let orchestrator = ComposeOrchestrator()
        let targetService = composeService(name: "api")
        let target = ServiceContainerTarget(
            service: targetService,
            index: 1,
            name: "demo-api-1",
            status: "created"
        )
        let cases: [(hook: ComposeServiceHook, expected: ComposeError)] = [
            (
                ComposeServiceHook(command: []),
                .invalidProject("service 'api' pre_start[0] requires a command")
            ),
            (
                ComposeServiceHook(command: ["prepare"]),
                .invalidProject("service 'api' pre_start[0] has no image")
            ),
        ]

        for testCase in cases {
            do {
                try await orchestrator.runPreStartHook(
                    project: ComposeProject(name: "demo", services: ["api": targetService]),
                    service: targetService,
                    target: target,
                    index: 0,
                    hook: testCase.hook
                )
                Issue.record("Expected pre_start invariant failure")
            } catch let error as ComposeError {
                #expect(error == testCase.expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("pre start helper cleanup runs when output streaming fails")
    func preStartHelperCleanupRunsWhenOutputStreamingFails() async throws {
        let expected = ComposeError.invalidProject("log stream failed")
        let helperName = "demo-api-pre-start-0-abc123"
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-api-1",
                    status: "created"
                ),
            ]
        )
        let service = composeService(name: "api", image: "example/api") {
            $0.preStart = [ComposeServiceHook(command: ["prepare"])]
        }
        let project = ComposeProject(name: "demo", services: ["api": service])

        do {
            try await ComposeOrchestrator(
                runner: RecordingRunner(),
                options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
                dependencies: orchestratorDependencies {
                    $0.discoveryManager = discoveryManager
                    $0.lifecycleManager = lifecycleManager
                    $0.logManager = RecordingContainerLogManager(error: expected)
                }
            ).runPreStartHook(
                project: project,
                service: service,
                target: ServiceContainerTarget(
                    service: service,
                    index: 1,
                    name: "demo-api-1",
                    status: "created"
                ),
                index: 0,
                hook: try #require(service.preStart?.first)
            )
            Issue.record("Expected log streaming failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await lifecycleManager.requests == [
            .start(id: helperName),
            .wait(id: helperName),
            .delete(id: helperName, force: true),
        ])
    }

    @Test("pre start helper names fit the Apple container name boundary")
    func preStartHelperNamesFitAppleContainerNameBoundary() async throws {
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "container-compose-lifecycle-long-project",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.preStart = [ComposeServiceHook(command: ["true"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions {
                $0.dryRun = true
                $0.emit = { emitted.append($0) }
                $0.oneOffIdentifier = { "abcdef123456" }
            }
        ).up(
            project: project,
            options: ComposeUpOptions { $0.detach = true }
        )

        let helperCommand = try #require(emitted.messages.first {
            $0.hasPrefix("+ container create --name ")
                && $0.contains("pre-start")
        })
        let arguments = helperCommand.split(separator: " ").map(String.init)
        let nameIndex = try #require(arguments.firstIndex(of: "--name"))
        let helperName = arguments[arguments.index(after: nameIndex)]
        #expect(helperName.count <= 63)
        #expect(helperName.contains("-pre-start-0-"))
    }

    @Test("up creates every replica before one pre start hook and service starts")
    func upCreatesEveryReplicaBeforeOnePreStartHookAndServiceStarts() async throws {
        let runner = RecordingRunner()
        let helperName = "demo-api-pre-start-0-abc123"
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-api-1", status: "created"),
                ],
                "demo-api-2": [nil],
            ]
        )
        let execManager = RecordingContainerExecManager()
        let imageManager = RecordingContainerImageManager()
        let lifecycleManager = RecordingContainerLifecycleManager(
            waitExitCodes: [helperName: 0]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                    $0.preStart = [
                        ComposeServiceHook(
                            command: ["sh", "-c", "prepare"],
                            image: "example/init:1"
                        ),
                    ]
                    $0.postStart = [ComposeServiceHook(command: ["sh", "-c", "ready"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.execManager = execManager
                $0.imageManager = imageManager
                $0.lifecycleManager = lifecycleManager
                $0.logManager = RecordingContainerLogManager()
            }
        ).up(
            project: project,
            options: ComposeUpOptions { $0.detach = true }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 3)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-2"]))
        #expect(commands[2].starts(with: ["container", "create", "--name", helperName]))
        let preStartImageRequests = await imageManager.requests
        #expect(preStartImageRequests == [
            .pullMissing("example/init:1"),
            .healthCheck(reference: "example/api", platform: nil),
            .healthCheck(reference: "example/init:1", platform: nil),
        ])
        #expect(await lifecycleManager.requests == [
            .start(id: helperName),
            .wait(id: helperName),
            .delete(id: helperName, force: false),
            .start(id: "demo-api-1"),
            .start(id: "demo-api-2"),
        ])
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "ready"],
                terminal: .init(interactive: false, tty: false)
            ),
            ContainerAttachedExecRequest(
                id: "demo-api-2",
                command: ["sh", "-c", "ready"],
                terminal: .init(interactive: false, tty: false)
            ),
        ])
    }

    @Test("pre start does not rerun while one service replica remains running")
    func preStartDoesNotRerunWhileOneServiceReplicaRemainsRunning() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let service = composeService(name: "api", image: "example/api") {
            $0.preStart = [ComposeServiceHook(command: ["prepare"])]
        }
        let project = ComposeProject(name: "demo", services: ["api": service])

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = RecordingContainerDiscoveryManager(
                    containers: [
                        ComposeContainerSummary(
                            id: "demo-api-1",
                            status: "running",
                            labels: [
                                composeProjectLabel: "demo",
                                composeServiceLabel: "api",
                                composeOneOffLabel: "false",
                            ]
                        ),
                        ComposeContainerSummary(
                            id: "demo-api-2",
                            status: "stopped",
                            labels: [
                                composeProjectLabel: "demo",
                                composeServiceLabel: "api",
                                composeOneOffLabel: "false",
                            ]
                        ),
                    ]
                )
                $0.lifecycleManager = lifecycleManager
            }
        ).start(
            project: project,
            services: ["api"]
        )

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .start(id: "demo-api-2"),
        ])
    }

    @Test("pre start treats a paused replica as already running")
    func preStartTreatsPausedReplicaAsAlreadyRunning() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let service = composeService(name: "api", image: "example/api") {
            $0.preStart = [ComposeServiceHook(command: ["prepare"])]
        }
        let project = ComposeProject(name: "demo", services: ["api": service])

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = RecordingContainerDiscoveryManager(
                    containers: [
                        ComposeContainerSummary(
                            id: "demo-api-1",
                            status: "paused",
                            labels: [
                                composeProjectLabel: "demo",
                                composeServiceLabel: "api",
                                composeOneOffLabel: "false",
                            ]
                        ),
                        ComposeContainerSummary(
                            id: "demo-api-2",
                            status: "stopped",
                            labels: [
                                composeProjectLabel: "demo",
                                composeServiceLabel: "api",
                                composeOneOffLabel: "false",
                            ]
                        ),
                    ]
                )
                $0.lifecycleManager = lifecycleManager
            }
        ).start(
            project: project,
            services: ["api"]
        )

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .start(id: "demo-api-2"),
        ])
    }

    @Test("pre start failure gates service startup and cleans helper")
    func preStartFailureGatesServiceStartupAndCleansHelper() async throws {
        let runner = RecordingRunner()
        let helperName = "demo-api-pre-start-0-abc123"
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-api-1", status: "created"),
                ],
            ]
        )
        let lifecycleManager = RecordingContainerLifecycleManager(
            waitExitCodes: [helperName: 7]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.preStart = [ComposeServiceHook(command: ["false"])]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: runner,
                options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
                dependencies: orchestratorDependencies {
                    $0.discoveryManager = discoveryManager
                    $0.lifecycleManager = lifecycleManager
                    $0.logManager = RecordingContainerLogManager()
                }
            ).up(
                project: project,
                options: ComposeUpOptions { $0.detach = true }
            )
            Issue.record("Expected pre_start failure")
        } catch let error as ComposeError {
            guard case let .commandFailed(_, status, stderr) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(status == 7)
            #expect(stderr == "pre_start hook failed for service 'api'")
        }

        #expect(runner.commands.map(\.arguments).count == 2)
        #expect(await lifecycleManager.requests == [
            .start(id: helperName),
            .wait(id: helperName),
            .delete(id: helperName, force: false),
        ])
    }

    @Test("pre start images stay out of service image projections and explicit pull")
    func preStartImagesStayOutOfServiceImageProjectionsAndExplicitPull() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:1") {
                    $0.preStart = [
                        ComposeServiceHook(command: ["prepare"], image: "example/init:1"),
                        ComposeServiceHook(command: ["reuse"], image: "example/init:1"),
                    ]
                },
                "worker": composeService(name: "worker", image: "example/worker:1") {
                    $0.pullPolicy = "never"
                    $0.preStart = [
                        ComposeServiceHook(command: ["prepare"], image: "example/skip:1"),
                    ]
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        )

        #expect(try orchestrator.config(
            project: project,
            options: ComposeConfigOptions { $0.images = true }
        ) == """
        example/api:1
        example/worker:1
        """)

        try await orchestrator.pull(
            project: project,
            options: ComposePullOptions()
        )
        let requests = await imageManager.requests
        #expect(requests.count == 2)
        #expect(requests.contains(.pull("example/api:1")))
        #expect(requests.contains(.pull("example/worker:1")))
    }

    @Test("run foreground executes post start hooks before following raw output")
    func runForegroundExecutesPostStartHooksBeforeFollowingRawOutput() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["ready\n"])
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.postStart = [ComposeServiceHook(command: ["sh", "-c", "touch /tmp/ready"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions {
                $0.oneOffIdentifier = { "abc123" }
                $0.emitData = { emitted.append(String(decoding: $0, as: UTF8.self)) }
            },
            dependencies: orchestratorDependencies {
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
            }
        ).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains("--detach"))
        #expect(!command.contains("--rm"))
        #expect(runner.commands.first?.io == .captured(input: nil))
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-job-run-abc123",
                command: ["sh", "-c", "touch /tmp/ready"],
                terminal: .init(interactive: false, tty: false)
            ),
        ])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-job-run-abc123", tail: nil, follow: true),
        ])
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-job-run-abc123"),
            .delete(id: "demo-job-run-abc123", force: false),
        ])
        #expect(emitted.messages == ["ready\n"])
    }

    @Test("run foreground drains logs after the container exits")
    func runForegroundDrainsLogsAfterContainerExit() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["final output\n"], delay: .milliseconds(10))
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.postStart = [ComposeServiceHook(command: ["true"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions {
                $0.oneOffIdentifier = { "abc123" }
                $0.emitData = { emitted.append(String(decoding: $0, as: UTF8.self)) }
            },
            dependencies: orchestratorDependencies {
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
            }
        ).run(project: project, serviceName: "job", command: ["true"], remove: false)

        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-job-run-abc123"),
        ])
        #expect(emitted.messages == ["final output\n"])
    }

    @Test("run foreground preserves a lifecycle-managed container exit status")
    func runForegroundPreservesLifecycleManagedContainerExitStatus() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-job-run-abc123": 7])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.postStart = [ComposeServiceHook(command: ["true"])]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: RecordingRunner(),
                options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
                dependencies: orchestratorDependencies {
                    $0.lifecycleManager = lifecycleManager
                    $0.logManager = RecordingContainerLogManager()
                }
            ).run(project: project, serviceName: "job", command: ["false"], remove: false)
            Issue.record("Expected lifecycle-managed run exit status")
        } catch let error as ComposeRunExitError {
            #expect(error.status == 7)
        }
    }

    @Test("run foreground preserves a direct container exit status")
    func runForegroundPreservesDirectContainerExitStatus() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(status: 7, stdout: "failed\n", stderr: ""),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "alpine"),
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: runner,
                options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" })
            ).run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["false"]) {
                    $0.noTty = true
                }
            )
            Issue.record("Expected direct run exit status")
        } catch let error as ComposeRunExitError {
            #expect(error.status == 7)
        }
    }

    @Test("run foreground removes lifecycle-managed one-off containers after hook failure")
    func runForegroundRemovesLifecycleManagedContainerAfterHookFailure() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager(attachedStatus: 1)
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.postStart = [ComposeServiceHook(command: ["false"])]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: runner,
                options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
                dependencies: orchestratorDependencies {
                    $0.execManager = execManager
                    $0.lifecycleManager = lifecycleManager
                }
            ).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected lifecycle hook failure")
        } catch is ComposeError {}

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains("--detach"))
        #expect(!command.contains("--rm"))
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-job-run-abc123", force: true),
        ])
    }

    @Test("run foreground invokes pre stop hooks on interruption")
    func runForegroundInvokesPreStopHooksOnInterruption() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager()
        let signalProxy = RecordingComposeSignalProxy(forwardedSignals: ["SIGINT"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.preStop = [ComposeServiceHook(command: ["sh", "-c", "echo stopping"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            dependencies: orchestratorDependencies {
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.signalProxy = signalProxy
            }
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["sleep", "60"])
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains("--detach"))
        #expect(await signalProxy.requests == [["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"]])
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-job-run-abc123",
                command: ["sh", "-c", "echo stopping"],
                terminal: .init(interactive: false, tty: false)
            ),
        ])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-job-run-abc123", signal: nil, timeoutInSeconds: nil),
            .wait(id: "demo-job-run-abc123"),
        ])
    }

    @Test("run interruption stops once even when pre stop fails")
    func runInterruptionStopsOnceEvenWhenPreStopFails() async throws {
        let execManager = RecordingContainerExecManager(attachedStatus: 1)
        let lifecycleManager = RecordingContainerLifecycleManager()
        let signalProxy = RecordingComposeSignalProxy(
            forwardedSignals: ["SIGINT", "SIGTERM"]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.preStop = [ComposeServiceHook(command: ["false"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            dependencies: orchestratorDependencies {
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
                $0.logManager = RecordingContainerLogManager()
                $0.signalProxy = signalProxy
            }
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["sleep", "60"])
        )

        #expect(await execManager.attachedRequests.count == 1)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-job-run-abc123", signal: nil, timeoutInSeconds: nil),
            .wait(id: "demo-job-run-abc123"),
        ])
    }

    @Test("run reattaches interactive lifecycle-managed one off containers")
    func runReattachesInteractiveLifecycleManagedOneOffContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            CommandResult(status: 0, stdout: "", stderr: ""),
        ])
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let signalProxy = RecordingComposeSignalProxy(forwardedSignals: ["SIGINT"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.tty = true
                    $0.stdinOpen = true
                    $0.postStart = [ComposeServiceHook(command: ["true"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            dependencies: orchestratorDependencies {
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
                $0.signalProxy = signalProxy
            }
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["sh"])
        )

        #expect(runner.commands.count == 2)
        #expect(runner.commands[0].arguments.contains("--detach"))
        #expect(runner.commands[0].arguments.contains("--tty"))
        #expect(runner.commands[0].arguments.contains("--interactive"))
        #expect(runner.commands[0].io == .captured(input: nil))
        #expect(runner.commands[1].arguments == [
            "container", "attach", "--sig-proxy=false", "demo-job-run-abc123",
        ])
        #expect(runner.commands[1].io == .inherited)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-job-run-abc123",
                command: ["true"],
                terminal: .init(interactive: false, tty: false)
            ),
        ])
        #expect(await signalProxy.requests == [["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"]])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-job-run-abc123", signal: nil, timeoutInSeconds: nil),
        ])
    }

    @Test("interactive lifecycle attachment renders its dry run")
    func interactiveLifecycleAttachmentRendersItsDryRun() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                dryRun: true,
                emit: { emitted.append($0) }
            )
        )

        let result = try await orchestrator.attachForegroundOneOffRun(
            service: ComposeService(name: "job", image: "alpine"),
            containerName: "demo-job-run-abc123"
        )

        #expect(result == .exited(0))
        #expect(emitted.messages == [
            "+ container attach --sig-proxy=false demo-job-run-abc123",
        ])
    }

    @Test("foreground lifecycle guards missing signal proxy operations")
    func foregroundLifecycleGuardsMissingSignalProxyOperations() async throws {
        let signalProxy = RecordingComposeSignalProxy(runsOperation: false)
        let orchestrator = ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.signalProxy = signalProxy
            }
        )
        let service = ComposeService(name: "job", image: "alpine")

        do {
            _ = try await orchestrator.attachForegroundOneOffRun(
                service: service,
                containerName: "demo-job-run-abc123"
            )
            Issue.record("Expected missing interactive exit status")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "interactive foreground compose run did not produce an exit status"
            ))
        }

        do {
            _ = try await orchestrator.followForegroundOneOffRun(
                service: service,
                containerName: "demo-job-run-abc123"
            )
            Issue.record("Expected missing foreground exit status")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "foreground compose run did not produce an exit status"
            ))
        }
    }

    @Test("interactive run detach keys preserve running auto remove containers")
    func interactiveRunDetachKeysPreserveRunningAutoRemoveContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            CommandResult(status: 0, stdout: "", stderr: ""),
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-job-run-abc123",
                    status: "running"
                ),
            ]
        )
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.tty = true
                    $0.stdinOpen = true
                    $0.postStart = [ComposeServiceHook(command: ["true"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { "abc123" }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["sh"]) {
                $0.remove = true
            }
        )

        #expect(runner.commands[0].arguments.contains("--rm"))
        #expect(runner.commands[1].arguments == [
            "container", "attach", "--sig-proxy=false", "demo-job-run-abc123",
        ])
        #expect(await discoveryManager.getRequests == ["demo-job-run-abc123"])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("up remove orphans runs pre stop hooks for detached one off containers")
    func upRemoveOrphansRunsPreStopHooksForDetachedOneOffContainers() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-job-run-abc123",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "job",
                    composeOneOffLabel: "true",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.preStop = [
                        ComposeServiceHook(
                            command: ["sh", "-c", "rm -f /tmp/ready"],
                            user: "1000",
                            workingDir: "/work",
                            environment: ["READY": "0"]
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.execManager = execManager
                $0.lifecycleManager = lifecycleManager
            }
        ).up(project: project, options: ComposeUpOptions {
            $0.removeOrphans = true
            $0.assumeYes = true
            $0.timeout = 4
        })

        #expect(runner.commands.map(\.arguments).contains { $0.starts(with: ["container", "run", "--name", "demo-job-1"]) })
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-job-run-abc123",
                command: ["sh", "-c", "rm -f /tmp/ready"],
                environment: ["READY=0"],
                user: "1000",
                workingDirectory: "/work",
                terminal: .init(interactive: false, tty: false)
            ),
        ])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-job-run-abc123", signal: nil, timeoutInSeconds: 4),
            .delete(id: "demo-job-run-abc123", force: false),
        ])
    }

    @Test("pre stop hook failure prevents lifecycle stop")
    func preStopHookFailurePreventsLifecycleStop() async throws {
        let execManager = RecordingContainerExecManager(attachedStatus: 7)
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.preStop = [ComposeServiceHook(command: ["false"])]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: RecordingRunner(),
                dependencies: orchestratorDependencies {
                    $0.execManager = execManager
                    $0.lifecycleManager = lifecycleManager
                }
            ).stop(project: project, services: ["api"])
            Issue.record("Expected pre_stop failure")
        } catch let error as ComposeError {
            #expect(error == .commandFailed(command: "container exec demo-api-1 false", status: 7, stderr: "pre_stop hook failed for service 'api'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("start uses direct runtime API and dry run preserves command output")
    func startUsesDirectRuntimeAPIAndDryRunPreservesCommandOutput() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.containerName = "custom-worker"
                },
            ]
        )

        let progress = LockedStringRecorder()
        try await ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            lifecycleManager: lifecycleManager
        )
        .start(project: project, services: [])

        #expect(runner.commands.isEmpty)
        #expect(progress.snapshot.joined() == """
        ⠓ Starting api
        ✓ Starting api
        ⠓ Starting worker
        ✓ Starting worker

        """)
        #expect(await lifecycleManager.requests == [
            .start(id: "demo-api-1"),
            .start(id: "custom-worker"),
        ])

        let emitted = MessageRecorder()
        let dryRunLifecycleManager = RecordingContainerLifecycleManager()
        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            lifecycleManager: dryRunLifecycleManager
        ).start(project: project, services: ["worker"])

        #expect(emitted.messages == [
            "+ container start custom-worker",
        ])
        #expect(await dryRunLifecycleManager.requests.isEmpty)
    }

    @Test("start all uses dependency order")
    func startAllUsesDependencyOrder() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            lifecycleManager: lifecycleManager
        ).start(project: project, services: [])

        #expect(await lifecycleManager.requests == [
            .start(id: "demo-db-1"),
            .start(id: "demo-api-1"),
        ])
    }

    @Test("start selected service does not include dependencies")
    func startSelectedServiceDoesNotIncludeDependencies() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            lifecycleManager: lifecycleManager
        ).start(project: project, services: ["api"])

        #expect(await lifecycleManager.requests == [
            .start(id: "demo-api-1"),
        ])
    }

    @Test("start wait polls until selected containers are running")
    func startWaitPollsUntilSelectedContainersAreRunning() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-api-1",
                    status: "created",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "api",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [
                    ComposeContainerSummary(id: "demo-api-1", status: "starting"),
                    ComposeContainerSummary(id: "demo-api-1", status: "running"),
                ],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(sleep: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).start(project: project, options: ComposeStartOptions {
            $0.services = ["api"]
            $0.wait = true
            $0.waitTimeout = 5
        })

        #expect(await lifecycleManager.requests == [
            .start(id: "demo-api-1"),
        ])
        #expect(await discoveryManager.listRequests == [true])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("start wait polls configured healthchecks until healthy")
    func startWaitPollsConfiguredHealthchecksUntilHealthy() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-api-1",
                    status: "created",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "api",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [
                    ComposeContainerSummary(id: "demo-api-1", status: "running", health: "starting"),
                    ComposeContainerSummary(id: "demo-api-1", status: "running", health: "healthy"),
                ],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.healthcheck = .object([
                        "test": .array([.string("CMD"), .string("/bin/true")]),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(sleep: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).start(project: project, options: ComposeStartOptions {
            $0.services = ["api"]
            $0.wait = true
            $0.waitTimeout = 5
        })

        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("start wait dry run emits wait-ready operations")
    func startWaitDryRunEmitsWaitReadyOperations() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            lifecycleManager: lifecycleManager
        ).start(project: project, options: ComposeStartOptions {
            $0.services = ["api"]
            $0.wait = true
            $0.waitTimeout = 3
        })

        #expect(emitted.messages == [
            "+ container start demo-api-1",
            "+ compose-runtime wait-ready --timeout 3 demo-api-1",
        ])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("pause and unpause use direct runtime API")
    func pauseAndUnpauseUseDirectRuntimeAPI() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "false",
            ]),
            ComposeContainerSummary(id: "demo-api-2", status: "running", labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "false",
            ]),
            ComposeContainerSummary(id: "custom-worker", status: "paused", labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "worker",
                composeOneOffLabel: "false",
            ]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.containerName = "custom-worker"
                },
            ]
        )

        try await orchestrator.pause(project: project, services: ["api"])
        try await orchestrator.unpause(project: project, services: ["worker"])

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .pause(id: "demo-api-1"),
            .pause(id: "demo-api-2"),
            .unpause(id: "custom-worker"),
        ])
    }

    @Test("pause and unpause dry run emit compose runtime operations")
    func pauseAndUnpauseDryRunEmitComposeRuntimeOperations() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            lifecycleManager: lifecycleManager
        )

        try await orchestrator.pause(project: project, services: ["api"])
        try await orchestrator.unpause(project: project, services: ["api"])

        #expect(emitted.messages == [
            "+ compose-runtime pause demo-api-1",
            "+ compose-runtime unpause demo-api-1",
        ])
        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("kill uses direct runtime API with default and explicit signals")
    func killUsesDirectRuntimeAPIWithDefaultAndExplicitSignals() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(runner: runner, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.containerName = "custom-worker"
                },
            ]
        )

        try await orchestrator.kill(project: project, services: [], signal: nil)
        try await orchestrator.kill(project: project, services: ["worker"], signal: "SIGTERM")

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .kill(id: "demo-api-1", signal: "KILL"),
            .kill(id: "custom-worker", signal: "KILL"),
            .kill(id: "custom-worker", signal: "SIGTERM"),
        ])
    }

    @Test("kill dry run emits compose runtime operation")
    func killDryRunEmitsComposeRuntimeOperation() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            lifecycleManager: lifecycleManager
        ).kill(project: project, services: ["api"], signal: "SIGUSR1")

        #expect(emitted.messages == [
            "+ compose-runtime kill --signal SIGUSR1 demo-api-1",
        ])
        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("kill remove orphans cleans project containers outside current model")
    func killRemoveOrphansCleansProjectContainersOutsideCurrentModel() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "false",
            ]),
            ComposeContainerSummary(id: "demo-old-1", status: "running", labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "old",
                composeOneOffLabel: "false",
            ]),
            ComposeContainerSummary(id: "demo-job-run-abc123", status: "running", labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "job",
                composeOneOffLabel: "true",
            ]),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).kill(project: project, services: ["api"], signal: "SIGTERM", removeOrphans: true)

        #expect(await lifecycleManager.requests == [
            .kill(id: "demo-api-1", signal: "SIGTERM"),
            .stop(id: "demo-job-run-abc123", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-job-run-abc123", force: false),
            .stop(id: "demo-old-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-old-1", force: false),
        ])
        #expect(await discoveryManager.listRequests == [true, true])
    }

    @Test("wait uses direct runtime API for selected running service containers")
    func waitUsesDirectRuntimeAPIForSelectedRunningServiceContainers() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-api-1": 7])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    "com.apple.container.compose.project": "demo",
                    "com.apple.container.compose.service": "api",
                    "com.apple.container.compose.oneoff": "false",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).wait(project: project, options: ComposeWaitOptions(services: ["api"]))

        #expect(emitted.messages == ["7"])
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-api-1"),
        ])
        #expect(await discoveryManager.listRequests == [true])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("wait includes scaled service containers discovered through compose labels")
    func waitIncludesScaledServiceContainersDiscoveredThroughComposeLabels() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: [
            "demo-api-1": 0,
            "demo-api-2": 3,
        ])
        let labels = [
            "com.apple.container.compose.project": "demo",
            "com.apple.container.compose.service": "api",
            "com.apple.container.compose.oneoff": "false",
        ]
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-2", status: "stopping", labels: labels),
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: labels),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).wait(project: project)

        #expect(emitted.messages == ["0", "3"])
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-api-1"),
            .wait(id: "demo-api-2"),
        ])
    }

    @Test("wait replays stored exit codes for already stopped containers")
    func waitReplaysStoredExitCodesForAlreadyStoppedContainers() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "stopped",
                labels: [
                    "com.apple.container.compose.project": "demo",
                    "com.apple.container.compose.service": "api",
                    "com.apple.container.compose.oneoff": "false",
                ],
                exitCode: 9
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).wait(project: project)

        #expect(emitted.messages == ["9"])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("wait rejects stopped containers without stored exit codes")
    func waitRejectsStoppedContainersWithoutStoredExitCodes() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "stopped",
                labels: [
                    "com.apple.container.compose.project": "demo",
                    "com.apple.container.compose.service": "api",
                    "com.apple.container.compose.oneoff": "false",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(
                dependencies: orchestratorDependencies {
                    $0.discoveryManager = discoveryManager
                    $0.lifecycleManager = lifecycleManager
                }
            ).wait(project: project)
            Issue.record("Expected stopped wait target to be rejected")
        } catch let error as ComposeError {
            #expect(error == .unsupported("wait: service 'api' container 'demo-api-1' is stopped but has no stored exit code"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("wait dry run emits compose runtime wait operations")
    func waitDryRunEmitsComposeRuntimeWaitOperations() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.lifecycleManager = lifecycleManager
            }
        ).wait(project: project)

        #expect(emitted.messages == [
            "+ compose-runtime wait demo-api-1",
            "+ compose-runtime wait demo-api-2",
        ])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("wait down-project tears down project after first selected service exits")
    func waitDownProjectTearsDownProjectAfterFirstSelectedServiceExits() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-api-1": 5])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-db-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "db",
                    composeOneOffLabel: "false",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).wait(project: project, options: ComposeWaitOptions(services: ["api"], downProject: true))

        #expect(emitted.messages == ["5"])
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-api-1"),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
            .delete(id: "demo-api-1", force: false),
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-db-1", force: false),
        ])
        #expect(await discoveryManager.listRequests == [true, true])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("wait down-project dry run emits wait then down plan")
    func waitDownProjectDryRunEmitsWaitThenDownPlan() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.stopGracePeriodSeconds = 7
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.lifecycleManager = lifecycleManager
            }
        ).wait(project: project, options: ComposeWaitOptions(services: ["api"], downProject: true))

        #expect(emitted.messages == [
            "+ compose-runtime wait demo-api-1",
            "+ container stop --time 7 demo-api-1",
            "+ container delete demo-api-1",
            "+ container stop demo-db-1",
            "+ container delete demo-db-1",
        ])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("wait down-project tears down after replaying stopped container exit code")
    func waitDownProjectTearsDownAfterReplayingStoppedContainerExitCode() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                ],
                exitCode: 9
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).wait(project: project, options: ComposeWaitOptions(downProject: true))

        #expect(emitted.messages == ["9"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
        #expect(await discoveryManager.listRequests == [true, true])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("wait down-project rejects already stopped containers before teardown")
    func waitDownProjectRejectsAlreadyStoppedContainersBeforeTeardown() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(
                dependencies: orchestratorDependencies {
                    $0.discoveryManager = discoveryManager
                    $0.lifecycleManager = lifecycleManager
                }
            ).wait(project: project, options: ComposeWaitOptions(downProject: true))
            Issue.record("Expected stopped down-project wait target to be rejected")
        } catch let error as ComposeError {
            #expect(error == .unsupported("wait: service 'api' container 'demo-api-1' is stopped but has no stored exit code"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await lifecycleManager.requests.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("lifecycle manager maps compose lifecycle to direct API client")
    func lifecycleManagerMapsComposeLifecycleToDirectAPIClient() async throws {
        let client = RecordingContainerLifecycleAPIClient(waitExitCodes: ["demo-api-1": 4])
        let manager = ContainerClientLifecycleManager(client: client)

        try await manager.startContainer(id: "demo-api-1")
        try await manager.killContainer(id: "demo-api-1", signal: "SIGTERM")
        try await manager.stopContainer(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 12)
        try await manager.stopContainer(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil)
        try await manager.pauseContainer(id: "demo-api-1")
        try await manager.unpauseContainer(id: "demo-api-1")
        let exitCode = try await manager.waitContainer(id: "demo-api-1")
        try await manager.deleteContainer(id: "demo-api-1", force: true)

        #expect(exitCode == 4)
        #expect(await client.requests == [
            .start(id: "demo-api-1"),
            .kill(id: "demo-api-1", signal: "SIGTERM"),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 12),
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil),
            .pause(id: "demo-api-1"),
            .unpause(id: "demo-api-1"),
            .wait(id: "demo-api-1"),
            .delete(id: "demo-api-1", force: true),
        ])
    }

    @Test("lifecycle manager rejects stop timeouts outside apple/container API range")
    func lifecycleManagerRejectsStopTimeoutsOutsideAppleContainerAPIRange() async throws {
        let client = RecordingContainerLifecycleAPIClient()
        let manager = ContainerClientLifecycleManager(client: client)

        do {
            try await manager.stopContainer(id: "demo-api-1", signal: nil, timeoutInSeconds: -1)
            Issue.record("Expected invalid stop timeout")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("stop timeout must be between 0 and \(Int32.max) seconds"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await manager.stopContainer(id: "demo-api-1", signal: nil, timeoutInSeconds: Int(Int32.max) + 1)
            Issue.record("Expected invalid stop timeout")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("stop timeout must be between 0 and \(Int32.max) seconds"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests.isEmpty)
    }

    @Test("lifecycle API client forwards configured operations")
    func lifecycleAPIClientForwardsConfiguredOperations() async throws {
        let recorder = RecordingContainerLifecycleAPIClient()
        let client = ContainerLifecycleAPIClient(
            control: ContainerLifecycleAPIClient.ControlOperations(
                start: { id in
                    try await recorder.startContainer(id: id)
                },
                kill: { id, signal in
                    try await recorder.killContainer(id: id, signal: signal)
                },
                stop: { id, options in
                    try await recorder.stopContainer(id: id, options: options)
                },
                pause: { id in
                    try await recorder.pauseContainer(id: id)
                },
                unpause: { id in
                    try await recorder.unpauseContainer(id: id)
                }
            ),
            state: ContainerLifecycleAPIClient.StateOperations(
                wait: { id in
                    try await recorder.waitContainer(id: id)
                },
                delete: { id, force in
                    try await recorder.deleteContainer(id: id, force: force)
                }
            )
        )
        let stopOptions = ContainerStopOptions(timeoutInSeconds: 15, signal: "SIGQUIT")

        try await client.startContainer(id: "demo-api-1")
        try await client.killContainer(id: "demo-api-1", signal: "SIGTERM")
        try await client.stopContainer(id: "demo-api-1", options: stopOptions)
        try await client.pauseContainer(id: "demo-api-1")
        try await client.unpauseContainer(id: "demo-api-1")
        _ = try await client.waitContainer(id: "demo-api-1")
        try await client.deleteContainer(id: "demo-api-1", force: false)

        #expect(await recorder.requests == [
            .start(id: "demo-api-1"),
            .kill(id: "demo-api-1", signal: "SIGTERM"),
            .stop(id: "demo-api-1", signal: "SIGQUIT", timeoutInSeconds: 15),
            .pause(id: "demo-api-1"),
            .unpause(id: "demo-api-1"),
            .wait(id: "demo-api-1"),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("lifecycle API client recovers stopped snapshot exit code after sentinel wait")
    func lifecycleAPIClientRecoversStoppedSnapshotExitCodeAfterSentinelWait() async throws {
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .stopped,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64",
            exitCode: 7
        )
        let client = ContainerLifecycleAPIClient(
            state: ContainerLifecycleAPIClient.StateOperations(
                wait: { id in
                    #expect(id == "demo-api-1")
                    return 255
                },
                get: { id in
                    #expect(id == "demo-api-1")
                    return snapshot
                }
            )
        )

        let exitCode = try await client.waitContainer(id: "demo-api-1")

        #expect(exitCode == 7)
    }

    @Test("discovery manager maps container snapshots to compose summaries")
    func discoveryManagerMapsContainerSnapshotsToComposeSummaries() async throws {
        let snapshots = try [
            containerSnapshot(
                id: "demo-api-1",
                status: .running,
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ],
                imageReference: "example/api:latest",
                imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                platform: "linux/arm64",
                publishedPorts: [
                    PublishPort(
                        hostAddress: IPAddress("127.0.0.1"),
                        hostPort: 8080,
                        containerPort: 80,
                        proto: .tcp,
                        count: 2
                    ),
                ],
                mounts: [
                    Filesystem.volume(
                        name: "legacy_data",
                        format: "ext4",
                        source: "/tmp/legacy-data",
                        destination: "/data",
                        options: ["ro"],
                        subpath: "logs/app"
                    ),
                    Filesystem.virtiofs(source: "/tmp/seed", destination: "/seed", options: []),
                    Filesystem.tmpfs(destination: "/scratch", options: ["ro"]),
                ],
                networks: [
                    ContainerResource.Attachment(
                        network: "demo_backend",
                        hostname: "demo-api-1",
                        aliases: ["api"],
                        ipv4Address: CIDRv4("192.168.64.20/24"),
                        ipv4Gateway: IPv4Address("192.168.64.1"),
                        ipv6Address: nil,
                        macAddress: nil
                    ),
                ],
                health: .healthy
            ),
            containerSnapshot(
                id: "demo-worker-1",
                status: .stopped,
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                    composeConfigHashLabel: "worker-hash",
                ],
                imageReference: "example/worker:debug",
                imageDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                platform: "linux/amd64",
                startedDate: Date(timeIntervalSince1970: 1_699_999_000),
                exitCode: 17,
                exitedDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ]
        let client = RecordingContainerDiscoveryAPIClient(listResponse: snapshots, getResponse: snapshots[1])
        let manager = ContainerClientDiscoveryManager(client: client)

        let running = try await manager.listContainers(all: false)
        let all = try await manager.listContainers(all: true)
        let worker = try await manager.getContainer(id: "demo-worker-1")
        let missingClient = RecordingContainerDiscoveryAPIClient()
        let missingManager = ContainerClientDiscoveryManager(client: missingClient)
        let missing = try await missingManager.getContainer(id: "demo-missing-1")
        let createdSnapshot = try containerSnapshot(
            id: "demo-created-1",
            status: .stopped,
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "created",
                composeConfigHashLabel: "created-hash",
            ],
            imageReference: "example/created:latest",
            imageDigest: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            platform: "linux/arm64"
        )
        let createdClient = RecordingContainerDiscoveryAPIClient(
            listResponse: [createdSnapshot],
            getResponse: createdSnapshot
        )
        let createdManager = ContainerClientDiscoveryManager(client: createdClient)
        let created = try await createdManager.getContainer(id: "demo-created-1")

        #expect(running.map(\.id) == ["demo-api-1", "demo-worker-1"])
        #expect(running.first == ComposeContainerSummary(
            id: "demo-api-1",
            status: "running",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeConfigHashLabel: "api-hash",
            ],
            image: .init(
                reference: "example/api:latest",
                digest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                platform: "linux/arm64"
            ),
            resources: ComposeContainerSummary.Resources(
                publishedPorts: [
                    ComposeContainerPublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, protocolName: "tcp", count: 2),
                ],
                mounts: [
                    ComposeMount(
                        type: "external-volume",
                        source: "legacy_data",
                        target: "/data",
                        options: .init(readOnly: true, volume: .init(subpath: "logs/app"))
                    ),
                    ComposeMount(type: "bind", source: "/tmp/seed", target: "/seed"),
                    ComposeMount(type: "tmpfs", target: "/scratch", readOnly: true),
                ],
                networks: [
                    ComposeContainerNetworkAttachment(network: "demo_backend", ipv4Address: "192.168.64.20"),
                ]
            ),
            state: ComposeContainerSummary.State(health: "healthy")
        ))
        #expect(all.map(\.status) == ["running", "exited"])
        #expect(worker?.id == "demo-worker-1")
        #expect(worker?.platform == "linux/amd64")
        #expect(worker?.exitCode == 17)
        #expect(worker?.exitedDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(created?.status == "created")
        #expect(created?.exitCode == nil)
        #expect(missing == nil)

        let filters = await client.listFilters
        #expect(filters.count == 2)
        #expect(filters[0].status == .running)
        #expect(filters[0].labels[ResourceLabelKeys.plugin] == ContainerListFilters.exclude("machine"))
        #expect(filters[1].status == nil)
        #expect(filters[1].labels[ResourceLabelKeys.plugin] == ContainerListFilters.exclude("machine"))
        #expect(await client.getRequests == ["demo-worker-1"])
        #expect(await missingClient.getRequests == ["demo-missing-1"])
    }

    @Test("CLI JSON discovery manager maps container list output to compose summaries")
    func cliJSONDiscoveryManagerMapsContainerListOutputToComposeSummaries() async throws {
        let runningSnapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .running,
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeConfigHashLabel: "api-hash",
            ],
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64",
            publishedPorts: [
                PublishPort(
                    hostAddress: IPAddress("127.0.0.1"),
                    hostPort: 8080,
                    containerPort: 80,
                    proto: .tcp,
                    count: 1
                ),
            ],
            mounts: [
                Filesystem.virtiofs(source: "/tmp/seed", destination: "/seed", options: ["ro"]),
            ],
            networks: [
                ContainerResource.Attachment(
                    network: "demo_default",
                    hostname: "demo-api-1",
                    ipv4Address: CIDRv4("192.168.64.20/24"),
                    ipv4Gateway: IPv4Address("192.168.64.1"),
                    ipv6Address: nil,
                    macAddress: nil
                ),
            ],
            health: .healthy
        )
        let stoppedSnapshot = try containerSnapshot(
            id: "demo-worker-1",
            status: .stopped,
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "worker",
                composeConfigHashLabel: "worker-hash",
            ],
            imageReference: "example/worker:debug",
            imageDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            platform: "linux/amd64",
            startedDate: Date(timeIntervalSince1970: 1_699_999_000),
            exitCode: 17,
            exitedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let createdSnapshot = try containerSnapshot(
            id: "demo-created-1",
            status: .stopped,
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "created",
                composeConfigHashLabel: "created-hash",
            ],
            imageReference: "example/created:latest",
            imageDigest: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            platform: "linux/arm64"
        )
        let runner = try RecordingRunner(responses: [
            CommandResult(status: 0, stdout: managedContainerJSON([runningSnapshot]), stderr: ""),
            CommandResult(status: 0, stdout: managedContainerJSON([runningSnapshot, stoppedSnapshot]), stderr: ""),
            CommandResult(status: 0, stdout: managedContainerJSON([runningSnapshot, stoppedSnapshot, createdSnapshot]), stderr: ""),
        ])
        let manager = ContainerCLIJSONDiscoveryManager(
            runner: runner,
            environmentLauncher: "/usr/bin/env",
            containerBinary: "forked-container"
        )

        let running = try await manager.listContainers(all: false)
        let worker = try await manager.getContainer(id: "demo-worker-1")
        let created = try await manager.getContainer(id: "demo-created-1")

        #expect(running == [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ],
                image: .init(
                    reference: "example/api:latest",
                    digest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    platform: "linux/arm64"
                ),
                resources: .init(
                    publishedPorts: [
                        ComposeContainerPublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, protocolName: "tcp"),
                    ],
                    mounts: [
                        ComposeMount(type: "bind", source: "/tmp/seed", target: "/seed", readOnly: true),
                    ],
                    networks: [
                        ComposeContainerNetworkAttachment(network: "demo_default", ipv4Address: "192.168.64.20"),
                    ]
                ),
                state: .init(health: "healthy")
            ),
        ])
        #expect(worker?.id == "demo-worker-1")
        #expect(worker?.status == "exited")
        #expect(worker?.exitCode == 17)
        #expect(worker?.exitedDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(worker?.health == nil)
        #expect(created?.status == "created")
        #expect(created?.exitCode == nil)
        #expect(runner.commands.map(\.arguments) == [
            ["forked-container", "list", "--format", "json"],
            ["forked-container", "list", "--format", "json", "--all"],
            ["forked-container", "list", "--format", "json", "--all"],
        ])
    }

    @Test("CLI JSON discovery manager surfaces command failures")
    func cliJSONDiscoveryManagerSurfacesCommandFailures() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(status: 42, stdout: "", stderr: "list failed"),
        ])
        let manager = ContainerCLIJSONDiscoveryManager(
            runner: runner,
            environmentLauncher: "/usr/bin/env",
            containerBinary: "forked-container"
        )

        do {
            _ = try await manager.listContainers(all: true)
            Issue.record("Expected container list failure")
        } catch let error as ComposeError {
            #expect(error == .commandFailed(
                command: "forked-container list --format json --all",
                status: 42,
                stderr: "list failed"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("CLI JSON discovery manager rejects malformed JSON")
    func cliJSONDiscoveryManagerRejectsMalformedJSON() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: "not-json", stderr: ""),
        ])
        let manager = ContainerCLIJSONDiscoveryManager(runner: runner)

        do {
            _ = try await manager.listContainers(all: false)
            Issue.record("Expected container list decode failure")
        } catch let error as ComposeError {
            guard case let .invalidProject(message) = error else {
                Issue.record("Unexpected compose error: \(error)")
                return
            }
            #expect(message.contains("failed to decode container list JSON"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("live discovery manager uses CLI list and configured detail")
    func liveDiscoveryManagerUsesCLIListAndConfiguredDetail() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: "[]", stderr: ""),
        ])
        let detailManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-db-1", status: "running", health: "healthy"),
        ])
        let manager = ContainerLiveDiscoveryManager(
            runner: runner,
            environmentLauncher: "custom-env",
            containerBinary: "custom-container",
            detailManager: detailManager
        )

        let listed = try await manager.listContainers(all: false)
        let detail = try await manager.getContainer(id: "demo-db-1")

        let command = try #require(runner.commands.first)
        #expect(listed.isEmpty)
        #expect(detail?.health == "healthy")
        #expect(command.executable == "custom-env")
        #expect(command.arguments == ["custom-container", "list", "--format", "json"])
        #expect(await detailManager.listRequests.isEmpty)
        #expect(await detailManager.getRequests == ["demo-db-1"])
    }

    @Test("live discovery manager uses CLI JSON detail by default")
    func liveDiscoveryManagerUsesCLIJSONDetailByDefault() async throws {
        let snapshot = try containerSnapshot(
            id: "demo-db-1",
            status: .running,
            labels: [composeProjectLabel: "demo", composeServiceLabel: "db"],
            imageReference: "postgres:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64",
            health: .healthy
        )
        let runner = try RecordingRunner(responses: [
            CommandResult(status: 0, stdout: managedContainerJSON([snapshot]), stderr: ""),
        ])
        let manager = ContainerLiveDiscoveryManager(
            runner: runner,
            environmentLauncher: "custom-env",
            containerBinary: "custom-container"
        )

        let detail = try await manager.getContainer(id: "demo-db-1")

        #expect(detail?.health == "healthy")
        #expect(runner.commands.map(\.arguments) == [
            ["custom-container", "list", "--format", "json", "--all"],
        ])
    }

    @Test("discovery API client forwards configured operations")
    func discoveryAPIClientForwardsConfiguredOperations() async throws {
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .running,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        )
        let recorder = RecordingContainerDiscoveryAPIClient(listResponse: [snapshot], getResponse: snapshot)
        let client = ContainerDiscoveryAPIClient(
            list: { filters in
                try await recorder.listContainers(filters: filters)
            },
            get: { id in
                guard let snapshot = try await recorder.getContainer(id: id) else {
                    throw ComposeError.invalidProject("missing test snapshot")
                }
                return snapshot
            }
        )
        let filters = ContainerListFilters(ids: ["demo-api-1"], status: .running)

        let listed = try await client.listContainers(filters: filters)
        let fetched = try await client.getContainer(id: "demo-api-1")

        #expect(listed.map(\.id) == ["demo-api-1"])
        #expect(fetched?.id == "demo-api-1")
        #expect(await recorder.listFilters.map(\.ids) == [["demo-api-1"]])
        #expect(await recorder.getRequests == ["demo-api-1"])
    }

    @Test("discovery API client maps not found and surfaces get failures")
    func discoveryAPIClientMapsNotFoundAndSurfacesGetFailures() async throws {
        let notFoundClient = ContainerDiscoveryAPIClient(
            list: { _ in [] },
            get: { _ in
                throw ContainerizationError(.notFound, message: "container not found")
            }
        )

        let missing = try await notFoundClient.getContainer(id: "demo-missing-1")
        #expect(missing == nil)

        let expected = ComposeError.invalidProject("get failed")
        let failingClient = ContainerDiscoveryAPIClient(
            list: { _ in [] },
            get: { _ in
                throw expected
            }
        )

        do {
            _ = try await failingClient.getContainer(id: "demo-api-1")
            Issue.record("Expected discovery get failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("discovery manager surfaces get failures")
    func discoveryManagerSurfacesGetFailures() async throws {
        let expected = ComposeError.invalidProject("get failed")
        let client = RecordingContainerDiscoveryAPIClient(getError: expected)
        let manager = ContainerClientDiscoveryManager(client: client)

        do {
            _ = try await manager.getContainer(id: "demo-api-1")
            Issue.record("Expected discovery get failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.getRequests == ["demo-api-1"])
    }

}
