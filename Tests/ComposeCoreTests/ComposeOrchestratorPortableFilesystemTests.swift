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

@testable import ComposeCore
import Foundation
import Testing

/// Runtime-neutral orchestration contracts execute in both dependency profiles.
extension ComposeOrchestratorTests {
    @Test("export maps service containers to runtime export")
    func exportMapsServiceContainersToRuntimeExport() async throws {
        let runner = RecordingRunner()
        let exporter = RecordingContainerExporter()
        let orchestrator = ComposeOrchestrator(runner: runner, exporter: exporter)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": composeService(name: "db", image: "postgres") {
                    $0.containerName = "custom-db"
                },
            ]
        )

        try await orchestrator.export(project: project, serviceName: "api")
        try await orchestrator.export(
            project: project,
            serviceName: "db",
            options: ComposeExportOptions(output: "db.tar")
        )

        #expect(await exporter.requests == [
            ContainerExportRequest(id: "demo-api-1", output: nil, live: true),
            ContainerExportRequest(id: "custom-db", output: "db.tar", live: true),
        ])
        #expect(runner.commands.isEmpty)
    }

    @Test("export dry run emits compose runtime operation")
    func exportDryRunEmitsComposeRuntimeOperation() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let exporter = RecordingContainerExporter()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                dryRun: true,
                emit: { emitted.append($0) }
            ),
            exporter: exporter
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.export(
            project: project,
            serviceName: "api",
            options: ComposeExportOptions(output: "api.tar")
        )

        #expect(emitted.messages == [
            "+ compose-runtime export --output api.tar demo-api-1",
        ])
        #expect(runner.commands.isEmpty)
        #expect(await exporter.requests.isEmpty)
    }

    @Test("export rejects unknown services before runtime export")
    func exportRejectsUnknownServicesBeforeRuntimeExport() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).export(project: project, serviceName: "worker")
            Issue.record("Expected unknown service error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unknown service 'worker'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("export resolves selected service container indexes")
    func exportResolvesSelectedServiceContainerIndexes() async throws {
        let runner = RecordingRunner()
        let exporter = RecordingContainerExporter()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.exporter = exporter
        }).export(
            project: project,
            serviceName: "api",
            options: ComposeExportOptions(output: "api.tar", index: 2)
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await discoveryManager.getRequests == ["demo-api-2"])
        #expect(await exporter.requests == [
            ContainerExportRequest(id: "demo-api-2", output: "api.tar", live: true),
        ])
    }

    @Test("commit dry run emits export archive and image load plan")
    func commitDryRunEmitsExportArchiveAndImageLoadPlan() async throws {
        let emitted = MessageRecorder()
        let exporter = RecordingContainerExporter()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: RecordingRunner(), options: ComposeExecutionOptions(
            dryRun: true,
            emit: { emitted.append($0) }
        ), dependencies: orchestratorDependencies {
            $0.exporter = exporter
            $0.imageManager = imageManager
        })

        try await orchestrator.commit(
            project: project,
            serviceName: "api",
            options: ComposeCommitOptions {
                $0.reference = "example/api:snapshot"
                $0.author = "Me"
                $0.changes = ["CMD true"]
                $0.index = 2
                $0.message = "snapshot"
                $0.pause = false
            }
        )

        let messages = emitted.messages
        #expect(messages.count == 3)
        let exportMessage = try #require(messages.first)
        let archiveMessage = try #require(messages.dropFirst().first)
        let loadMessage = try #require(messages.last)
        #expect(exportMessage == "+ compose-runtime export --output /tmp/demo-api-2-commit-rootfs.tar demo-api-2")
        #expect(archiveMessage.contains("compose-runtime commit-archive"))
        #expect(archiveMessage.contains("--rootfs /tmp/demo-api-2-commit-rootfs.tar"))
        #expect(archiveMessage.contains("--output /tmp/demo-api-2-commit-image.tar"))
        #expect(archiveMessage.contains("--reference example/api:snapshot"))
        #expect(archiveMessage.contains("--author Me"))
        #expect(archiveMessage.contains("--message snapshot"))
        #expect(archiveMessage.contains("--change 'CMD true'"))
        #expect(archiveMessage.contains("--no-pause"))
        #expect(loadMessage == "+ compose-runtime image load --input /tmp/demo-api-2-commit-image.tar")
        #expect(await exporter.requests.isEmpty)
        #expect(await imageManager.requests.isEmpty)
    }

    @Test("commit resolves effective Compose healthchecks for image config")
    func commitResolvesEffectiveHealthchecksForImageConfig() throws {
        let inherited = ComposeImageHealthCheck(
            test: ["CMD-SHELL", "curl --fail http://localhost/health"],
            intervalInNanoseconds: 15_000_000_000,
            timeoutInNanoseconds: 5_000_000_000,
            startPeriodInNanoseconds: 2_000_000_000,
            startIntervalInNanoseconds: 1_000_000_000,
            retries: 4
        )
        let orchestrator = ComposeOrchestrator(runner: RecordingRunner())

        let inheritedResult = try orchestrator.commitImageHealthCheck(
            service: composeService(name: "api", image: "example/api"),
            inherited: inherited
        )
        #expect(inheritedResult == inherited)

        let tunedResult = try orchestrator.commitImageHealthCheck(
            service: composeService(name: "api", image: "example/api") {
                $0.healthcheck = .object([
                    "interval": .string("5s"),
                    "retries": .number(2),
                ])
            },
            inherited: inherited
        )
        #expect(tunedResult == ComposeImageHealthCheck(
            test: ["CMD-SHELL", "curl --fail http://localhost/health"],
            intervalInNanoseconds: 5_000_000_000,
            timeoutInNanoseconds: 5_000_000_000,
            startPeriodInNanoseconds: 2_000_000_000,
            startIntervalInNanoseconds: 1_000_000_000,
            retries: 2
        ))

        let explicitResult = try orchestrator.commitImageHealthCheck(
            service: composeService(name: "api", image: "example/api") {
                $0.healthcheck = .object([
                    "test": .array([.string("CMD"), .string("/usr/local/bin/health")]),
                    "timeout": .string("4s"),
                ])
            },
            inherited: inherited
        )
        #expect(explicitResult == ComposeImageHealthCheck(
            test: ["CMD", "/usr/local/bin/health"],
            intervalInNanoseconds: 30_000_000_000,
            timeoutInNanoseconds: 4_000_000_000,
            startPeriodInNanoseconds: 0,
            startIntervalInNanoseconds: nil,
            retries: 3
        ))

        let disabledResult = try orchestrator.commitImageHealthCheck(
            service: composeService(name: "api", image: "example/api") {
                $0.healthcheck = .object(["disable": .bool(true)])
            },
            inherited: inherited
        )
        #expect(disabledResult == ComposeImageHealthCheck(test: ["NONE"]))
    }

    @Test("commit rejects negative replica indexes")
    func commitRejectsNegativeReplicaIndexes() async throws {
        let exporter = try RecordingContainerExporter(archiveData: rootfsArchiveData())
        let imageManager = RecordingContainerImageManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: RecordingRunner(), dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.exporter = exporter
            $0.imageManager = imageManager
        })

        do {
            try await orchestrator.commit(project: project, serviceName: "api", options: ComposeCommitOptions {
                $0.index = -1
            })
            Issue.record("Expected negative commit index to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container index must not be negative"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await discoveryManager.listRequests.isEmpty)
        #expect(await discoveryManager.getRequests.isEmpty)
        #expect(await exporter.requests.isEmpty)
        #expect(await imageManager.requests.isEmpty)
    }

    @Test("commit staging is private, exporter-owned, and cleans up after export failure")
    func commitStagingIsPrivateExporterOwnedAndCleansUpAfterExportFailure() async throws {
        let sharedRoot = try temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: sharedRoot.path)
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let exporter = TemporaryPathSnapshottingExporter(root: sharedRoot)
        var executionOptions = ComposeExecutionOptions()
        executionOptions.temporaryDirectory = sharedRoot
        let service = ComposeService(name: "api", image: "example/api")
        let orchestrator = ComposeOrchestrator(
            options: executionOptions,
            dependencies: orchestratorDependencies {
                $0.exporter = exporter
            },
        )

        await #expect(throws: ComposeError.self) {
            try await orchestrator.writeCommitImage(
                project: ComposeProject(name: "demo", services: ["api": service]),
                service: service,
                options: ComposeCommitOptions(),
                container: ComposeContainerSummary(id: "demo-api-1", status: "stopped"),
            )
        }

        let snapshots = await exporter.snapshots
        let directory = try #require(snapshots.first { $0.isDirectory })
        #expect(directory.permissions == 0o700)
        #expect(!snapshots.contains { $0.path.hasSuffix("/rootfs.tar") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: sharedRoot.path).isEmpty)
    }

    @Test("port prints runtime published bindings")
    func portPrintsRuntimePublishedBindings() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ],
                publishedPorts: [
                    ComposeContainerPublishedPort(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, protocolName: "tcp"),
                    ComposeContainerPublishedPort(hostAddress: "127.0.0.1", hostPort: 8443, containerPort: 443, protocolName: "tcp"),
                    ComposeContainerPublishedPort(hostAddress: "0.0.0.0", hostPort: 5353, containerPort: 53, protocolName: "udp"),
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
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

        try await orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 1)
        try await orchestrator.port(project: project, serviceName: "api", privatePort: "443", protocolName: "tcp", index: 1)
        try await orchestrator.port(project: project, serviceName: "api", privatePort: "53/udp", protocolName: "udp", index: 1)

        #expect(emitted.messages == [
            "0.0.0.0:8080",
            "127.0.0.1:8443",
            "0.0.0.0:5353",
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-1", "demo-api-1"])
    }

    @Test("port dry run previews dynamically allocated bindings")
    func portDryRunPreviewsDynamicallyAllocatedBindings() async throws {
        let ports = HostPortSource([49160])
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(options: ComposeExecutionOptions(
            dryRun: true,
            hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) },
            emit: { emitted.append($0) }
        ))
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["80"]
                },
            ]
        )

        try await orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 1)

        #expect(emitted.messages == ["0.0.0.0:49160"])
        #expect(ports.requests == [HostPortAllocationRequest(hostAddress: nil, protocolName: "tcp")])
    }

    @Test("port resolves explicit ranges from runtime published ports")
    func portResolvesExplicitRangesFromRuntimePublishedPorts() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ],
                publishedPorts: [
                    ComposeContainerPublishedPort(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, protocolName: "tcp", count: 3),
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["8080-8082:80-82"]
                },
            ]
        )

        try await orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 1)
        try await orchestrator.port(project: project, serviceName: "api", privatePort: "81", protocolName: "tcp", index: 1)
        try await orchestrator.port(project: project, serviceName: "api", privatePort: "82", protocolName: "tcp", index: 1)

        #expect(emitted.messages == ["0.0.0.0:8080", "0.0.0.0:8081", "0.0.0.0:8082"])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-1", "demo-api-1"])
    }

    @Test("port resolves selected service container indexes")
    func portResolvesSelectedServiceContainerIndexes() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                    composeConfigHashLabel: "api-hash",
                ],
                publishedPorts: [
                    ComposeContainerPublishedPort(hostAddress: "127.0.0.1", hostPort: 9080, containerPort: 80, protocolName: "tcp"),
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["8080:80"]
                },
            ]
        )

        try await orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 2)

        #expect(emitted.messages == ["127.0.0.1:9080"])
        #expect(await discoveryManager.listRequests == [true])
        #expect(await discoveryManager.getRequests == ["demo-api-2"])
    }

    @Test("port dry run expands explicit ranges without runtime discovery")
    func portDryRunExpandsExplicitRangesWithoutRuntimeDiscovery() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["127.0.0.1:8080-8082:80-82"]
                },
            ]
        )

        try await orchestrator.port(project: project, serviceName: "api", privatePort: "81", protocolName: "tcp", index: 1)

        #expect(emitted.messages == ["127.0.0.1:8081"])
        #expect(await discoveryManager.getRequests.isEmpty)
    }

    @Test("port dry run resolves scaled published ranges by index")
    func portDryRunResolvesScaledPublishedRangesByIndex() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                    $0.ports = ["127.0.0.1:8080-8081:80"]
                },
            ]
        )

        try await orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 2)

        #expect(emitted.messages == ["127.0.0.1:8081"])
        #expect(await discoveryManager.getRequests.isEmpty)
    }

    @Test("port validates lookup options")
    func portValidatesLookupOptions() async throws {
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ],
                publishedPorts: [
                    ComposeContainerPublishedPort(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, protocolName: "tcp"),
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(discoveryManager: discoveryManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["8080:80"]
                },
            ]
        )

        do {
            try await orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 0)
            Issue.record("Expected invalid index error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container index must be greater than zero"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await orchestrator.port(project: project, serviceName: "api", privatePort: "80/udp", protocolName: "tcp", index: 1)
            Issue.record("Expected protocol conflict")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("port protocol 'udp' conflicts with --protocol tcp"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await orchestrator.port(project: project, serviceName: "api", privatePort: "81", protocolName: "tcp", index: 1)
            Issue.record("Expected missing port error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' does not publish target port 81/tcp"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
