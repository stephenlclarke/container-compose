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
    @Test("cp maps service references in both copy directions")
    func cpMapsServiceReferencesInBothCopyDirections() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let orchestrator = ComposeOrchestrator(runner: runner, copier: copier)
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
        try await orchestrator.copy(
            project: project,
            arguments: ["./seed.sql", "db:/docker-entrypoint-initdb.d/seed.sql"]
        )
        try await orchestrator.copy(project: project, arguments: ["api:/tmp/report.txt", "db:/restore/report.txt"])
        try await orchestrator.copy(project: project, arguments: ["./local:file.txt", "db:/restore/local.txt"])
        try await orchestrator.copy(project: project, arguments: ["api:etc/os-release", "./os-release"])
        try await orchestrator.copy(project: project, arguments: ["./seed.sql", "db:tmp/seed.sql"])
        try await orchestrator.copy(project: project, arguments: ["api:.", "db:tmp/root-copy"])

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests == [
            .from(id: "demo-api-1", source: "/tmp/report.txt", destination: "./report.txt"),
            .into(id: "custom-db", source: "./seed.sql", destination: "/docker-entrypoint-initdb.d/seed.sql"),
            .between(
                sourceID: "demo-api-1",
                source: "/tmp/report.txt",
                destinationID: "custom-db",
                destination: "/restore/report.txt"
            ),
            .into(id: "custom-db", source: "./local:file.txt", destination: "/restore/local.txt"),
            .from(id: "demo-api-1", source: "/etc/os-release", destination: "./os-release"),
            .into(id: "custom-db", source: "./seed.sql", destination: "/tmp/seed.sql"),
            .between(sourceID: "demo-api-1", source: "/.", destinationID: "custom-db", destination: "/tmp/root-copy"),
        ])
        #expect(await copier.options == [
            ContainerCopyTransferOptions(),
            ContainerCopyTransferOptions(),
            ContainerCopyTransferOptions(),
            ContainerCopyTransferOptions(),
            ContainerCopyTransferOptions(),
            ContainerCopyTransferOptions(),
            ContainerCopyTransferOptions(),
        ])
    }

    @Test("cp rejects local to local copies")
    func cpRejectsLocalToLocalCopies() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner, copier: copier)
                .copy(project: project, arguments: ["./local:file.txt", "./out:file.txt"])
            Issue.record("Expected local-to-local cp to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unknown copy direction"))
        }

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests.isEmpty)
    }

    @Test("cp rejects empty service paths")
    func cpRejectsEmptyServicePaths() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner, copier: copier)
                .copy(project: project, arguments: ["api:", "./out"])
            Issue.record("Expected empty service path cp to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container copy path for service 'api' cannot be empty"))
        }

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests.isEmpty)
    }

    @Test("cp streams stdin tar archives into service containers")
    func cpStreamsStdinTarArchivesIntoServiceContainers() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )
        let tempDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        let archive = try archiveWithFile(named: "payload.txt", contents: "from stdin\n", in: tempDirectory)
        let input = try FileHandle(forReadingFrom: archive)
        defer {
            try? input.close()
        }

        let options = ComposeExecutionOptions(runtimeHooks: .init(copyInputArchive: { input }))

        try await ComposeOrchestrator(runner: runner, options: options, copier: copier).copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["-", "api:/tmp"]
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests == [
            .archiveInto(
                id: "demo-api-1",
                destination: "/tmp",
                data: try Data(contentsOf: archive),
            ),
        ])
    }

    @Test("cp all replays stdin archive bytes into every selected container")
    func cpAllReplaysStdinArchiveBytesIntoEverySelectedContainer() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: stdinCopyContainers())
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )
        let tempDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        let archive = try archiveWithFile(named: "payload.txt", contents: "from stdin\n", in: tempDirectory)
        let archiveData = try Data(contentsOf: archive)
        let input = try FileHandle(forReadingFrom: archive)
        defer {
            try? input.close()
        }
        let options = ComposeExecutionOptions(runtimeHooks: .init(copyInputArchive: { input }))
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: options,
            dependencies: orchestratorDependencies {
                $0.copier = copier
                $0.discoveryManager = discoveryManager
            }
        )

        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["-", "api:/tmp"]
                $0.all = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests == [
            .archiveInto(id: "demo-api-1", destination: "/tmp", data: archiveData),
            .archiveInto(id: "demo-api-run-first", destination: "/tmp", data: archiveData),
        ])
        #expect(await copier.archiveHandlesAreClosed)
    }

    @Test("cp streams service container paths as stdout tar archives")
    func cpStreamsServiceContainerPathsAsStdoutTarArchives() async throws {
        let runner = RecordingRunner()
        let tempDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        let expectedArchive = try archiveWithFile(
            named: "report.txt",
            contents: "from container\n",
            in: tempDirectory,
        )
        let expectedArchiveData = try Data(contentsOf: expectedArchive)
        let copier = ArchiveProducingContainerCopier(archiveData: expectedArchiveData)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )
        let archive = tempDirectory.appendingPathComponent("stdout.tar")
        try Data().write(to: archive)
        let output = try FileHandle(forWritingTo: archive)

        let options = ComposeExecutionOptions(runtimeHooks: .init(copyOutputArchive: { output }))

        try await ComposeOrchestrator(runner: runner, options: options, copier: copier).copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report.txt", "-"]
            }
        )
        try output.close()

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests == [
            .archiveFrom(id: "demo-api-1", source: "/tmp/report.txt", copyContents: false),
        ])
        #expect(try Data(contentsOf: archive) == expectedArchiveData)
    }

    @Test("cp stdout preserves trailing dot contents semantics")
    func cpStdoutPreservesTrailingDotContentsSemantics() async throws {
        let runner = RecordingRunner()
        let copier = ArchiveProducingContainerCopier(archiveData: Data())
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )
        let output = FileHandle.nullDevice
        let options = ComposeExecutionOptions(runtimeHooks: .init(copyOutputArchive: { output }))

        try await ComposeOrchestrator(runner: runner, options: options, copier: copier).copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/tree/.", "-"]
            }
        )

        #expect(await copier.requests == [
            .archiveFrom(id: "demo-api-1", source: "/tmp/tree", copyContents: true),
        ])
    }

    @Test("cp rejects using stdin and stdout archive streams together")
    func cpRejectsUsingStdinAndStdoutArchiveStreamsTogether() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner, copier: copier).copy(project: project, arguments: ["-", "-"])
            Issue.record("Expected stdin-to-stdout archive cp to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("cp cannot use '-' for both source and destination"))
        }

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests.isEmpty)
    }

    @Test("cp follow link passes source symlink option to direct copy APIs")
    func cpFollowLinkPassesSourceSymlinkOptionToDirectCopyAPIs() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let orchestrator = ComposeOrchestrator(runner: runner, copier: copier)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report-link", "./report.txt"]
                $0.followLink = true
            }
        )
        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["./seed-link", "db:/tmp/seed.sql"]
                $0.followLink = true
            }
        )
        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report-link", "db:/tmp/report.txt"]
                $0.followLink = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests == [
            .from(id: "demo-api-1", source: "/tmp/report-link", destination: "./report.txt"),
            .into(id: "demo-db-1", source: "./seed-link", destination: "/tmp/seed.sql"),
            .between(
                sourceID: "demo-api-1",
                source: "/tmp/report-link",
                destinationID: "demo-db-1",
                destination: "/tmp/report.txt"
            ),
        ])
        #expect(await copier.options == [
            ContainerCopyTransferOptions(followSymlink: true),
            ContainerCopyTransferOptions(followSymlink: true),
            ContainerCopyTransferOptions(followSymlink: true),
        ])
    }

    @Test("cp archive passes ownership preservation option to direct copy APIs")
    func cpArchivePassesOwnershipPreservationOptionToDirectCopyAPIs() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let orchestrator = ComposeOrchestrator(runner: runner, copier: copier)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report.txt", "./report.txt"]
                $0.archive = true
            }
        )
        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["./seed.sql", "db:/tmp/seed.sql"]
                $0.archive = true
            }
        )
        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report.txt", "db:/tmp/report.txt"]
                $0.archive = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests == [
            .from(id: "demo-api-1", source: "/tmp/report.txt", destination: "./report.txt"),
            .into(id: "demo-db-1", source: "./seed.sql", destination: "/tmp/seed.sql"),
            .between(
                sourceID: "demo-api-1",
                source: "/tmp/report.txt",
                destinationID: "demo-db-1",
                destination: "/tmp/report.txt"
            ),
        ])
        #expect(await copier.options == [
            ContainerCopyTransferOptions(preserveOwnership: true),
            ContainerCopyTransferOptions(preserveOwnership: true),
            ContainerCopyTransferOptions(preserveOwnership: true),
        ])
    }

    @Test("cp copies between service containers through direct copy APIs")
    func cpCopiesBetweenServiceContainersThroughDirectAPIs() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, copier: copier).copy(
            project: project,
            arguments: ["api:/tmp/report.txt", "worker:/var/lib/report.txt"]
        )

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests == [
            .between(
                sourceID: "demo-api-1",
                source: "/tmp/report.txt",
                destinationID: "demo-worker-1",
                destination: "/var/lib/report.txt"
            ),
        ])
    }

    @Test("cp accepts default replica index")
    func cpAcceptsDefaultReplicaIndex() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, copier: copier).copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report.txt", "./report.txt"]
                $0.index = 1
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests == [
            .from(id: "demo-api-1", source: "/tmp/report.txt", destination: "./report.txt"),
        ])
    }

    @Test("cp resolves selected service container indexes")
    func cpResolvesSelectedServiceContainerIndexes() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
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
        let orchestrator = ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies {
            $0.copier = copier
            $0.discoveryManager = discoveryManager
        })

        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report.txt", "./report.txt"]
                $0.index = 2
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await copier.requests == [
            .from(id: "demo-api-2", source: "/tmp/report.txt", destination: "./report.txt"),
        ])
    }

    @Test("cp all includes one-off containers when copying into a service")
    func cpAllIncludesOneOffContainersWhenCopyingIntoAService() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: oneOffCopyContainers())
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies {
            $0.copier = copier
            $0.discoveryManager = discoveryManager
        })

        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["./seed.sql", "api:/tmp/seed.sql"]
                $0.all = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await copier.requests == [
            .into(id: "demo-api-1", source: "./seed.sql", destination: "/tmp/seed.sql"),
            .into(id: "demo-api-run-first", source: "./seed.sql", destination: "/tmp/seed.sql"),
        ])
    }

    @Test("cp all copies from the first matching service container")
    func cpAllCopiesFromTheFirstMatchingServiceContainer() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-run-first",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "true",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-1",
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
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )
        let orchestrator = ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies {
            $0.copier = copier
            $0.discoveryManager = discoveryManager
        })

        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report.txt", "./report.txt"]
                $0.all = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await copier.requests == [
            .from(id: "demo-api-1", source: "/tmp/report.txt", destination: "./report.txt"),
        ])
    }

    @Test("cp dry run emits compose runtime operation")
    func cpDryRunEmitsComposeRuntimeOperation() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            copier: copier
        ).copy(
            project: project,
            arguments: ["api:/tmp/report.txt", "./report.txt"]
        )

        #expect(emitted.messages == [
            "+ compose-runtime cp demo-api-1:/tmp/report.txt ./report.txt",
        ])
        #expect(runner.commands.isEmpty)
        #expect(await copier.requests.isEmpty)
    }

    @Test("cp dry run renders follow link flag")
    func cpDryRunRendersFollowLinkFlag() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            copier: copier
        ).copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report-link", "./report.txt"]
                $0.followLink = true
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime cp --follow-link demo-api-1:/tmp/report-link ./report.txt",
        ])
        #expect(runner.commands.isEmpty)
        #expect(await copier.requests.isEmpty)
    }

    @Test("cp dry run renders archive flag")
    func cpDryRunRendersArchiveFlag() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            copier: copier
        ).copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report.txt", "./report.txt"]
                $0.archive = true
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime cp --archive demo-api-1:/tmp/report.txt ./report.txt",
        ])
        #expect(runner.commands.isEmpty)
        #expect(await copier.requests.isEmpty)
    }

    @Test("cp all stages service to service copies into every destination container")
    func cpAllStagesServiceToServiceCopiesIntoEveryDestinationContainer() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: serviceCopyContainers())
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies {
            $0.copier = copier
            $0.discoveryManager = discoveryManager
        })

        try await orchestrator.copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = ["api:/tmp/report.txt", "worker:/tmp/report.txt"]
                $0.all = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true, true])
        #expect(await copier.requests == [
            .between(
                sourceID: "demo-api-1",
                source: "/tmp/report.txt",
                destinationID: "demo-worker-1",
                destination: "/tmp/report.txt"
            ),
            .between(
                sourceID: "demo-api-1",
                source: "/tmp/report.txt",
                destinationID: "demo-worker-run-first",
                destination: "/tmp/report.txt"
            ),
        ])
    }
}

private func stdinCopyContainers() -> [ComposeContainerSummary] {
    [
        ComposeContainerSummary(
            id: "demo-api-1",
            status: "running",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "false",
                composeConfigHashLabel: "api-hash",
            ]
        ),
        ComposeContainerSummary(
            id: "demo-api-run-first",
            status: "stopped",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "true",
                composeConfigHashLabel: "api-hash",
            ]
        ),

    ]
}

private func oneOffCopyContainers() -> [ComposeContainerSummary] {
    [
        ComposeContainerSummary(
            id: String(repeating: "e", count: 64),
            name: "renamed-api-run-first",
            bundleKey: "demo-api-run-first",
            status: "stopped",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "true",
                composeConfigHashLabel: "api-hash",
            ]
        ),
        ComposeContainerSummary(
            id: String(repeating: "f", count: 64),
            name: "renamed-api",
            bundleKey: "demo-api-1",
            status: "running",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "false",
                composeConfigHashLabel: "api-hash",
            ]
        ),
        ComposeContainerSummary(
            id: "demo-worker-run-first",
            status: "stopped",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "worker",
                composeOneOffLabel: "true",
                composeConfigHashLabel: "worker-hash",
            ]
        ),

    ]
}

private func serviceCopyContainers() -> [ComposeContainerSummary] {
    [
        ComposeContainerSummary(
            id: "demo-api-1",
            status: "running",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "false",
                composeConfigHashLabel: "api-hash",
            ]
        ),
        ComposeContainerSummary(
            id: "demo-worker-1",
            status: "running",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "worker",
                composeOneOffLabel: "false",
                composeConfigHashLabel: "worker-hash",
            ]
        ),
        ComposeContainerSummary(
            id: "demo-worker-run-first",
            status: "stopped",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "worker",
                composeOneOffLabel: "true",
                composeConfigHashLabel: "worker-hash",
            ]
        ),

    ]
}
