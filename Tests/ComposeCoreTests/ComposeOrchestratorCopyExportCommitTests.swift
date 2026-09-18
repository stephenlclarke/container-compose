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
    @Test("cp stages stdin archives for path-only runtime providers")
    func cpStagesStdinArchivesForPathOnlyRuntimeProviders() async throws {
        let runner = RecordingRunner()
        let copier = PathOnlyRecordingContainerCopier()
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

        let requests = await copier.requests
        #expect(requests.count == 1)
        guard case let .into(id, source, destination) = requests.first else {
            Issue.record("Expected staged stdin copy")
            return
        }
        #expect(id == "demo-api-1")
        #expect((source as NSString).lastPathComponent == "payload.txt")
        #expect(destination == "/tmp")
    }

    @Test("cp staging is private in shared TMPDIR and cleans up after failure")
    func cpStagingIsPrivateInSharedTemporaryDirectoryAndCleansUpAfterFailure() async throws {
        let sharedRoot = try temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: sharedRoot.path)
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let fixtureRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let archive = try archiveWithFile(named: "payload.txt", contents: "from stdin\n", in: fixtureRoot)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let copier = TemporaryPathSnapshottingContainerCopier(root: sharedRoot)
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
            discoveredServiceContainer(id: "demo-api-2", serviceName: "api", status: "running"),
        ])
        var executionOptions = ComposeExecutionOptions(runtimeHooks: .init(copyInputArchive: { input }))
        executionOptions.temporaryDirectory = sharedRoot
        let orchestrator = ComposeOrchestrator(
            options: executionOptions,
            dependencies: orchestratorDependencies {
                $0.copier = copier
                $0.discoveryManager = discoveryManager
            },
        )

        await #expect(throws: ComposeError.self) {
            try await orchestrator.copy(
                project: ComposeProject(
                    name: "demo",
                    services: ["api": ComposeService(name: "api", image: "example/api")],
                ),
                options: ComposeCopyOptions {
                    $0.arguments = ["-", "api:/tmp"]
                    $0.all = true
                },
            )
        }

        let snapshots = await copier.snapshots
        let directories = snapshots.filter {
            guard $0.isDirectory else {
                return false
            }
            let components = $0.path.split(separator: "/")
            return components.count == 1 || components.last == "root"
        }
        let archives = snapshots.filter { !$0.isDirectory && $0.path.hasSuffix(".tar") }
        #expect(directories.count >= 4)
        #expect(directories.allSatisfy { $0.permissions == 0o700 })
        #expect(archives.count >= 2)
        #expect(archives.allSatisfy { $0.permissions == 0o600 })
        #expect(try FileManager.default.contentsOfDirectory(atPath: sharedRoot.path).isEmpty)
    }

    @Test("cp stages stdout archives for path-only runtime providers")
    func cpStagesStdoutArchivesForPathOnlyRuntimeProviders() async throws {
        let runner = RecordingRunner()
        let copier = PathOnlyRecordingContainerCopier()
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

        let extracted = tempDirectory.appendingPathComponent("extracted", isDirectory: true)
        let reader = try ArchiveReader(file: archive)
        _ = try reader.extractContents(to: extracted)
        #expect(await copier.requests.count == 1)
        #expect(
            try String(contentsOf: extracted.appendingPathComponent("report.txt"), encoding: .utf8)
                == "from container\n"
        )
    }

    @Test("container copier streams service-to-service copies directly")
    func containerCopierStreamsServiceToServiceCopiesDirectly() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination, options in
                try await operations.copyInto(id: id, source: source, destination: destination, options: options)
            },
            copyFrom: { id, source, destination, options in
                try await operations.copyFrom(id: id, source: source, destination: destination, options: options)
            },
            copyArchiveInto: { id, archive, destination, options in
                try await operations.copyArchiveInto(
                    id: id,
                    archive: archive,
                    destination: destination,
                    options: options,
                )
            },
            copyArchiveFrom: { id, source, archive, copyContents, options in
                try await operations.copyArchiveFrom(
                    id: id,
                    source: source,
                    archive: archive,
                    copyContents: copyContents,
                    options: options,
                )
            }
        )

        try await copier.copyBetweenContainers(
            sourceID: "demo-api-1",
            source: "/tmp/report.txt",
            destinationID: "demo-worker-1",
            destination: "/var/lib/report.txt"
        )

        #expect(await operations.requests == [
            .archiveFrom(id: "demo-api-1", source: "/tmp/report.txt", copyContents: false),
            .archiveInto(
                id: "demo-worker-1",
                destination: "/var/lib/report.txt",
                data: Data("streamed".utf8),
            ),
        ])
    }

    @Test("container copier follows source link only when streaming service-to-service copies")
    func containerCopierFollowsSourceLinkOnlyWhenStreamingServiceToServiceCopies() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination, options in
                try await operations.copyInto(id: id, source: source, destination: destination, options: options)
            },
            copyFrom: { id, source, destination, options in
                try await operations.copyFrom(id: id, source: source, destination: destination, options: options)
            },
            copyArchiveInto: { id, archive, destination, options in
                try await operations.copyArchiveInto(
                    id: id,
                    archive: archive,
                    destination: destination,
                    options: options,
                )
            },
            copyArchiveFrom: { id, source, archive, copyContents, options in
                try await operations.copyArchiveFrom(
                    id: id,
                    source: source,
                    archive: archive,
                    copyContents: copyContents,
                    options: options,
                )
            }
        )

        try await copier.copyBetweenContainers(
            sourceID: "demo-api-1",
            source: "/tmp/report-link",
            destinationID: "demo-worker-1",
            destination: "/var/lib/report.txt",
            options: ContainerCopyTransferOptions(followSymlink: true)
        )

        #expect(await operations.options == [
            ContainerCopyTransferOptions(followSymlink: true),
            ContainerCopyTransferOptions(),
        ])
    }

    @Test("container copier requests ownership preservation when streaming service-to-service copies")
    func containerCopierRequestsOwnershipPreservationWhenStreamingServiceToServiceCopies() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination, options in
                try await operations.copyInto(id: id, source: source, destination: destination, options: options)
            },
            copyFrom: { id, source, destination, options in
                try await operations.copyFrom(id: id, source: source, destination: destination, options: options)
            },
            copyArchiveInto: { id, archive, destination, options in
                try await operations.copyArchiveInto(
                    id: id,
                    archive: archive,
                    destination: destination,
                    options: options,
                )
            },
            copyArchiveFrom: { id, source, archive, copyContents, options in
                try await operations.copyArchiveFrom(
                    id: id,
                    source: source,
                    archive: archive,
                    copyContents: copyContents,
                    options: options,
                )
            }
        )

        try await copier.copyBetweenContainers(
            sourceID: "demo-api-1",
            source: "/tmp/report.txt",
            destinationID: "demo-worker-1",
            destination: "/var/lib/report.txt",
            options: ContainerCopyTransferOptions(followSymlink: true, preserveOwnership: true)
        )

        #expect(await operations.options == [
            ContainerCopyTransferOptions(followSymlink: true, preserveOwnership: true),
            ContainerCopyTransferOptions(preserveOwnership: true),
        ])
    }

    @Test("container copier streams root contents for service-to-service copies")
    func containerCopierStreamsRootContentsForServiceToServiceCopies() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination, options in
                try await operations.copyInto(id: id, source: source, destination: destination, options: options)
            },
            copyFrom: { id, source, destination, options in
                try await operations.copyFrom(id: id, source: source, destination: destination, options: options)
            },
            copyArchiveInto: { id, archive, destination, options in
                try await operations.copyArchiveInto(
                    id: id,
                    archive: archive,
                    destination: destination,
                    options: options,
                )
            },
            copyArchiveFrom: { id, source, archive, copyContents, options in
                try await operations.copyArchiveFrom(
                    id: id,
                    source: source,
                    archive: archive,
                    copyContents: copyContents,
                    options: options,
                )
            }
        )

        try await copier.copyBetweenContainers(
            sourceID: "demo-api-1",
            source: "/.",
            destinationID: "demo-worker-1",
            destination: "/restore"
        )

        #expect(await operations.requests == [
            .archiveFrom(id: "demo-api-1", source: "/", copyContents: true),
            .archiveInto(
                id: "demo-worker-1",
                destination: "/restore",
                data: Data("streamed".utf8),
            ),
        ])
    }

    @Test("container copier unblocks archive input when archive output fails")
    func containerCopierUnblocksArchiveInputWhenArchiveOutputFails() async throws {
        let copier = ContainerClientCopier(
            copyArchiveInto: { _, archive, _, _ in
                while let chunk = try archive.read(upToCount: 4096), !chunk.isEmpty {}
            },
            copyArchiveFrom: { _, _, _, _, _ in
                throw CopyStreamTestError()
            }
        )

        do {
            try await copier.copyBetweenContainers(
                sourceID: "demo-api-1",
                source: "/tmp/report.txt",
                destinationID: "demo-worker-1",
                destination: "/var/lib/report.txt"
            )
            Issue.record("Expected archive output failure")
        } catch is CopyStreamTestError {
            // Expected.
        }
    }

    @Test("container copier unblocks archive output when archive input fails")
    func containerCopierUnblocksArchiveOutputWhenArchiveInputFails() async throws {
        let copier = ContainerClientCopier(
            copyArchiveInto: { _, _, _, _ in
                throw CopyStreamTestError()
            },
            copyArchiveFrom: { _, _, archive, _, _ in
                let chunk = Data(repeating: 0x41, count: 1024 * 1024)
                while true {
                    try archive.write(contentsOf: chunk)
                }
            }
        )

        do {
            try await copier.copyBetweenContainers(
                sourceID: "demo-api-1",
                source: "/tmp/report.txt",
                destinationID: "demo-worker-1",
                destination: "/var/lib/report.txt"
            )
            Issue.record("Expected archive input failure")
        } catch is CopyStreamTestError {
            // Expected.
        }
    }

    @Test("commit exports stopped service container and loads image archive")
    func commitExportsStoppedServiceContainerAndLoadsImageArchive() async throws {
        let emitted = MessageRecorder()
        let exporter = try RecordingContainerExporter(archiveData: rootfsArchiveData())
        let imageManager = RecordingContainerImageManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-2", serviceName: "api", status: "stopped"),
            discoveredServiceContainer(id: "demo-worker-1", serviceName: "worker", status: "stopped"),
            ComposeContainerSummary(
                id: String(repeating: "1", count: 64),
                name: "renamed-api",
                bundleKey: "demo-api-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                ]
            ),
            ComposeContainerSummary(id: "demo-api-run-abc", status: "stopped", labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "true",
            ]),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.environment = ["LOG_LEVEL": "debug"]
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: RecordingRunner(), options: ComposeExecutionOptions(
            emit: { emitted.append($0) }
        ), dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.exporter = exporter
            $0.imageManager = imageManager
        })

        try await orchestrator.commit(
            project: project,
            serviceName: "api",
            options: ComposeCommitOptions {
                $0.reference = "example/api:snapshot"
                $0.changes = ["ENV FEATURE=on"]
            }
        )

        #expect(await discoveryManager.listRequests == [true])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        let exports = await exporter.requests
        #expect(exports.count == 1)
        #expect(exports.first?.id == "demo-api-1")
        #expect(exports.first?.output?.hasSuffix("/rootfs.tar") == true)
        #expect(exports.first?.live == false)
        let imageRequests = await imageManager.requests
        #expect(imageRequests.count == 2)
        #expect(imageRequests.first == .metadata("example/api"))
        if case let .load(path) = imageRequests[1] {
            #expect(path.hasSuffix("/image.tar"))
        } else {
            Issue.record("Expected image load request")
        }
        #expect(emitted.messages == ["loaded:latest"])
    }

    @Test("commit preserves effective healthchecks in the loaded image archive")
    func commitPreservesEffectiveHealthchecksInLoadedImageArchive() async throws {
        let exporter = try RecordingContainerExporter(archiveData: rootfsArchiveData())
        let imageManager = RecordingContainerImageManager(imageMetadata: [
            "example/api": ComposeImageMetadata(reference: "example/api") {
                $0.healthCheck = ComposeImageHealthCheck(
                    test: ["CMD-SHELL", "curl --fail http://localhost/health"],
                    intervalInNanoseconds: 15_000_000_000,
                    timeoutInNanoseconds: 5_000_000_000,
                    startPeriodInNanoseconds: 2_000_000_000,
                    startIntervalInNanoseconds: 1_000_000_000,
                    retries: 4
                )
            },
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.healthcheck = .object([
                        "interval": .string("5s"),
                        "retries": .number(2),
                    ])
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: RecordingRunner(), dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.exporter = exporter
            $0.imageManager = imageManager
        })

        try await orchestrator.commit(project: project, serviceName: "api")

        let archives = await imageManager.loadedArchiveData
        let archiveData = try #require(archives.first)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("image.tar")
        try archiveData.write(to: archive)
        let config = try commitArchiveConfig(from: archive)
        #expect(config.config.healthCheck == .init(
            test: ["CMD-SHELL", "curl --fail http://localhost/health"],
            intervalInNanoseconds: 5_000_000_000,
            timeoutInNanoseconds: 5_000_000_000,
            startPeriodInNanoseconds: 2_000_000_000,
            startIntervalInNanoseconds: 1_000_000_000,
            retries: 2
        ))
    }

    @Test("commit preserves complete metadata from the service platform in one lookup")
    func commitPreservesCompleteServicePlatformMetadataInOneLookup() async throws {
        let exporter = try RecordingContainerExporter(archiveData: rootfsArchiveData())
        let hostHealthCheck = ComposeImageHealthCheck(test: ["CMD-SHELL", "test -f /host-variant"])
        let serviceHealthCheck = ComposeImageHealthCheck(test: ["CMD-SHELL", "test -f /service-variant"])
        let imageManager = RecordingContainerImageManager(
            imageMetadata: [
                "example/api": ComposeImageMetadata(reference: "example/api") {
                    $0.user = "host-user"
                    $0.environment = ["PLATFORM=host"]
                    $0.entrypoint = ["/host-entrypoint"]
                    $0.command = ["host-command"]
                    $0.workingDir = "/host"
                    $0.labels = ["variant": "host"]
                    $0.exposedPorts = ["8080/tcp"]
                    $0.stopSignal = "SIGTERM"
                    $0.healthCheck = hostHealthCheck
                    $0.declaredVolumeTargets = ["/host-data"]
                },
            ],
            platformImageMetadata: [
                ImageMetadataRequestKey(
                    reference: "example/api",
                    platform: "linux/amd64",
                ): ComposeImageMetadata(reference: "example/api@sha256:service") {
                    $0.displayReference = "example/api:service"
                    $0.user = "service-user"
                    $0.environment = ["PLATFORM=service"]
                    $0.entrypoint = ["/service-entrypoint"]
                    $0.command = ["service-command"]
                    $0.workingDir = "/service"
                    $0.labels = ["variant": "service"]
                    $0.exposedPorts = ["8443/tcp"]
                    $0.stopSignal = "SIGUSR1"
                    $0.healthCheck = serviceHealthCheck
                    $0.declaredVolumeTargets = ["/service-data"]
                },
            ]
        )
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.platform = "linux/amd64"
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: RecordingRunner(), dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.exporter = exporter
            $0.imageManager = imageManager
        })

        try await orchestrator.commit(project: project, serviceName: "api")

        let archiveData = try #require((await imageManager.loadedArchiveData).first)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("image.tar")
        try archiveData.write(to: archive)
        let config = try commitArchiveConfig(from: archive)
        #expect(config.config.user == "service-user")
        #expect(config.config.env == ["PLATFORM=service"])
        #expect(config.config.entrypoint == ["/service-entrypoint"])
        #expect(config.config.cmd == ["service-command"])
        #expect(config.config.workingDir == "/service")
        #expect(config.config.labels == ["variant": "service"])
        #expect(config.config.exposedPorts == ["8443/tcp": [:]])
        #expect(config.config.stopSignal == "SIGUSR1")
        #expect(config.config.healthCheck?.test == serviceHealthCheck.test)
        #expect(config.config.volumes == ["/service-data": [:]])
        let requests = await imageManager.requests
        #expect(requests.first == .availableMetadata(reference: "example/api", platform: "linux/amd64"))
        #expect(!requests.contains(.metadata("example/api")))
        #expect(!requests.contains(.healthCheck(reference: "example/api", platform: "linux/amd64")))
        #expect(!requests.contains(.volumeTargets(reference: "example/api", platform: "linux/amd64")))
    }

    @Test("commit retains default image metadata when the service platform is unavailable")
    func commitRetainsDefaultMetadataWhenServicePlatformIsUnavailable() async throws {
        let exporter = try RecordingContainerExporter(archiveData: rootfsArchiveData())
        let unavailableRequest = ImageMetadataRequestKey(reference: "example/api", platform: "linux/amd64")
        let imageManager = RecordingContainerImageManager(
            imageMetadata: [
                "example/api": ComposeImageMetadata(reference: "example/api") {
                    $0.user = "host-user"
                    $0.declaredVolumeTargets = ["/host-data"]
                },
            ],
            unavailablePlatformImageMetadataRequests: [unavailableRequest]
        )
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.platform = "linux/amd64"
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: RecordingRunner(), dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.exporter = exporter
            $0.imageManager = imageManager
        })

        try await orchestrator.commit(project: project, serviceName: "api")

        let archiveData = try #require((await imageManager.loadedArchiveData).first)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("image.tar")
        try archiveData.write(to: archive)
        let config = try commitArchiveConfig(from: archive)
        #expect(config.config.user == "host-user")
        #expect(config.config.volumes == ["/host-data": [:]])
        #expect(Array((await imageManager.requests).prefix(2)) == [
            .availableMetadata(reference: "example/api", platform: "linux/amd64"),
            .metadata("example/api"),
        ])
    }

    @Test("commit clears default metadata when the service platform declares none")
    func commitClearsDefaultMetadataWhenServicePlatformDeclaresNone() async throws {
        let exporter = try RecordingContainerExporter(archiveData: rootfsArchiveData())
        let imageManager = RecordingContainerImageManager(
            imageMetadata: [
                "example/api": ComposeImageMetadata(reference: "example/api") {
                    $0.user = "host-user"
                    $0.healthCheck = ComposeImageHealthCheck(test: ["CMD", "host-check"])
                    $0.declaredVolumeTargets = ["/host-data"]
                },
            ],
            platformImageMetadata: [
                ImageMetadataRequestKey(
                    reference: "example/api",
                    platform: "linux/amd64",
                ): ComposeImageMetadata(reference: "example/api"),
            ]
        )
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.platform = "linux/amd64"
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: RecordingRunner(), dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.exporter = exporter
            $0.imageManager = imageManager
        })

        try await orchestrator.commit(project: project, serviceName: "api")

        let archiveData = try #require((await imageManager.loadedArchiveData).first)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("image.tar")
        try archiveData.write(to: archive)
        let config = try commitArchiveConfig(from: archive)
        #expect(config.config.user == nil)
        #expect(config.config.healthCheck == nil)
        #expect(config.config.volumes == nil)
        let requests = await imageManager.requests
        #expect(requests.first == .availableMetadata(reference: "example/api", platform: "linux/amd64"))
        #expect(!requests.contains(.metadata("example/api")))
    }

    @Test("commit takes a live filesystem snapshot for running service containers")
    func commitTakesLiveFilesystemSnapshotForRunningServiceContainers() async throws {
        let exporter = try RecordingContainerExporter(archiveData: rootfsArchiveData())
        let imageManager = RecordingContainerImageManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
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

        try await orchestrator.commit(project: project, serviceName: "api")

        #expect(await discoveryManager.listRequests == [true])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        let exports = await exporter.requests
        #expect(exports.count == 1)
        #expect(exports.first?.id == "demo-api-1")
        #expect(exports.first?.output?.hasSuffix("/rootfs.tar") == true)
        #expect(exports.first?.live == true)
        #expect(exports.first?.noFreeze == false)
        let imageRequests = await imageManager.requests
        #expect(imageRequests.count == 2)
        #expect(imageRequests.first == .metadata("example/api"))
        if case let .load(path) = imageRequests[1] {
            #expect(path.hasSuffix("/image.tar"))
        } else {
            Issue.record("Expected image load request")
        }
    }

    @Test("commit takes a no-freeze live snapshot when pause is disabled")
    func commitTakesNoFreezeLiveSnapshotWhenPauseIsDisabled() async throws {
        let exporter = try RecordingContainerExporter(archiveData: rootfsArchiveData())
        let imageManager = RecordingContainerImageManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
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

        try await orchestrator.commit(project: project, serviceName: "api", options: ComposeCommitOptions {
            $0.pause = false
        })

        #expect(await discoveryManager.listRequests == [true])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        let exports = await exporter.requests
        #expect(exports.count == 1)
        #expect(exports.first?.id == "demo-api-1")
        #expect(exports.first?.output?.hasSuffix("/rootfs.tar") == true)
        #expect(exports.first?.live == true)
        #expect(exports.first?.noFreeze == true)
        #expect((await imageManager.requests).count == 2)
    }

    @Test("commit image staging cleans up after archive construction failure")
    func commitImageStagingCleansUpAfterArchiveConstructionFailure() throws {
        let sharedRoot = try temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: sharedRoot.path)
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let fixtureRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let rootfs = fixtureRoot.appendingPathComponent("rootfs.tar")
        try rootfsArchiveData().write(to: rootfs)

        #expect(throws: ComposeError.self) {
            try ComposeCommitImageArchive.write(
                rootfsArchive: rootfs,
                output: fixtureRoot.appendingPathComponent("image.tar"),
                service: ComposeService(name: "api", image: "example/api"),
                options: ComposeCommitOptions {
                    $0.changes = ["UNSUPPORTED value"]
                },
                temporaryDirectory: sharedRoot,
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: sharedRoot.path).isEmpty)
    }

    @Test("commit image archive applies Docker change instructions")
    func commitImageArchiveAppliesDockerChangeInstructions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootfs = directory.appendingPathComponent("rootfs.tar")
        try rootfsArchiveData().write(to: rootfs)
        let imageArchive = directory.appendingPathComponent("image.tar")
        let service = composeService(name: "api", image: "example/api") {
            $0.command = ["serve"]
            $0.entrypoint = ["/usr/bin/api"]
            $0.environment = [
                "EMPTY": nil,
                "LOG_LEVEL": "debug",
            ]
            $0.expose = ["8080"]
            $0.labels = ["com.example.base": "true"]
            $0.ports = ["127.0.0.1:8081:81"]
            $0.stopSignal = "SIGTERM"
            $0.user = "1000:1000"
            $0.workingDir = "/srv"
        }

        try ComposeCommitImageArchive.write(
            rootfsArchive: rootfs,
            output: imageArchive,
            service: service,
            options: ComposeCommitOptions {
                $0.reference = "example/api:snapshot"
                $0.author = "Me"
                $0.changes = [
                    "CMD [\"serve\",\"--port\",\"8443\"]",
                    "ENTRYPOINT [\"/usr/bin/env\"]",
                    "ENV LOG_LEVEL=trace FEATURE=on",
                    "ENV MESSAGE hello from commit",
                    "EXPOSE 8443 5353/udp",
                    "LABEL org.example.commit=yes",
                    "ONBUILD RUN echo next",
                    "USER app",
                    "VOLUME [\"/data\",\"/cache\"]",
                    "WORKDIR /srv/app",
                ]
                $0.message = "snapshot"
            },
            metadata: .init(
                baseImage: ComposeImageMetadata(reference: "example/base:latest") {
                    $0.user = "base-user"
                    $0.environment = ["BASE_ONLY=1", "EMPTY=base", "LOG_LEVEL=info"]
                    $0.entrypoint = ["/base-entrypoint"]
                    $0.command = ["base-command"]
                    $0.workingDir = "/base"
                    $0.labels = [
                        "com.example.base": "image",
                        "com.example.image": "true",
                    ]
                    $0.exposedPorts = ["9090/tcp"]
                    $0.stopSignal = "SIGINT"
                    $0.healthCheck = ComposeImageHealthCheck(
                        test: ["CMD-SHELL", "curl --fail http://localhost/health"],
                        intervalInNanoseconds: 15_000_000_000,
                        timeoutInNanoseconds: 5_000_000_000,
                        startPeriodInNanoseconds: 2_000_000_000,
                        startIntervalInNanoseconds: 1_000_000_000,
                        retries: 4
                    )
                },
                createdAt: date("2026-07-12T09:00:00Z")
            )
        )

        let config = try commitArchiveConfig(from: imageArchive)
        #expect(config.author == "Me")
        #expect(config.config.cmd == ["serve", "--port", "8443"])
        #expect(config.config.entrypoint == ["/usr/bin/env"])
        #expect(config.config.env == ["BASE_ONLY=1", "EMPTY", "FEATURE=on", "LOG_LEVEL=trace", "MESSAGE=hello from commit"])
        #expect(config.config.exposedPorts == [
            "81/tcp": [:],
            "8080/tcp": [:],
            "8443/tcp": [:],
            "5353/udp": [:],
            "9090/tcp": [:],
        ])
        #expect(config.config.labels == [
            "com.example.base": "true",
            "com.example.image": "true",
            "org.example.commit": "yes",
        ])
        #expect(config.config.onBuild == ["RUN echo next"])
        #expect(config.config.stopSignal == "SIGTERM")
        #expect(config.config.healthCheck == .init(
            test: ["CMD-SHELL", "curl --fail http://localhost/health"],
            intervalInNanoseconds: 15_000_000_000,
            timeoutInNanoseconds: 5_000_000_000,
            startPeriodInNanoseconds: 2_000_000_000,
            startIntervalInNanoseconds: 1_000_000_000,
            retries: 4
        ))
        #expect(config.config.user == "app")
        #expect(config.config.volumes == [
            "/cache": [:],
            "/data": [:],
        ])
        #expect(config.config.workingDir == "/srv/app")
    }

    @Test("commit image archive preserves inherited Docker volumes")
    func commitImageArchivePreservesInheritedDockerVolumes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootfs = directory.appendingPathComponent("rootfs.tar")
        try rootfsArchiveData().write(to: rootfs)
        let imageArchive = directory.appendingPathComponent("image.tar")

        try ComposeCommitImageArchive.write(
            rootfsArchive: rootfs,
            output: imageArchive,
            service: composeService(name: "api", image: "example/api"),
            options: ComposeCommitOptions(),
            metadata: .init(baseImage: ComposeImageMetadata(reference: "example/base:latest") {
                $0.declaredVolumeTargets = ["/data", "/cache"]
            })
        )

        let config = try commitArchiveConfig(from: imageArchive)
        #expect(config.config.volumes == [
            "/cache": [:],
            "/data": [:],
        ])
    }

    @Test("commit image archive adds repeated Docker volume changes")
    func commitImageArchiveAddsRepeatedDockerVolumeChanges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootfs = directory.appendingPathComponent("rootfs.tar")
        try rootfsArchiveData().write(to: rootfs)
        let imageArchive = directory.appendingPathComponent("image.tar")

        try ComposeCommitImageArchive.write(
            rootfsArchive: rootfs,
            output: imageArchive,
            service: composeService(name: "api", image: "example/api"),
            options: ComposeCommitOptions {
                $0.changes = [
                    "VOLUME /cache /shared",
                    "VOLUME [\"/logs\",\"/cache\"]",
                ]
            },
            metadata: .init(baseImage: ComposeImageMetadata(reference: "example/base:latest") {
                $0.declaredVolumeTargets = ["/inherited"]
            })
        )

        let config = try commitArchiveConfig(from: imageArchive)
        #expect(config.config.volumes == [
            "/cache": [:],
            "/inherited": [:],
            "/logs": [:],
            "/shared": [:],
        ])
    }

    @Test("commit image archive uses the default shell for shell-form changes")
    func commitImageArchiveUsesDefaultShellPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootfs = directory.appendingPathComponent("rootfs.tar")
        try rootfsArchiveData().write(to: rootfs)
        let imageArchive = directory.appendingPathComponent("image.tar")

        try ComposeCommitImageArchive.write(
            rootfsArchive: rootfs,
            output: imageArchive,
            service: composeService(name: "api", image: "example/api"),
            options: ComposeCommitOptions {
                $0.changes = ["CMD echo hello"]
            }
        )

        let config = try commitArchiveConfig(from: imageArchive)
        #expect(config.config.cmd == ["/bin/sh", "-c", "echo hello"])
    }

    @Test("commit image archive uses the configured shell for shell-form changes")
    func commitImageArchiveUsesConfiguredShellPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootfs = directory.appendingPathComponent("rootfs.tar")
        try rootfsArchiveData().write(to: rootfs)
        let imageArchive = directory.appendingPathComponent("image.tar")

        try ComposeCommitImageArchive.write(
            rootfsArchive: rootfs,
            output: imageArchive,
            service: composeService(name: "api", image: "example/api"),
            options: ComposeCommitOptions {
                $0.changes = ["CMD echo hello"]
            },
            metadata: .init(shellPath: "/custom/bin/sh")
        )

        let config = try commitArchiveConfig(from: imageArchive)
        #expect(config.config.cmd == ["/custom/bin/sh", "-c", "echo hello"])
    }
}
