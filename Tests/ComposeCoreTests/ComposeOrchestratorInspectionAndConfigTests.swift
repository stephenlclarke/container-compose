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
    @Test("images lists selected created container image records")
    func imagesListsSelectedCreatedContainerImageRecords() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
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

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
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
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
                "worker": ComposeService(name: "worker", image: "example/worker:debug"),
            ]
        )

        try await orchestrator.images(project: project, services: [], options: ComposeImagesOptions(quiet: true))

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(emitted.messages == ["aaaaaaaaaaaa\nbbbbbbbbbbbb"])
    }

    @Test("images table prints header for empty projects")
    func imagesTablePrintsHeaderForEmptyProjects() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [])
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        ).images(project: project, services: [], options: ComposeImagesOptions())

        #expect(await discoveryManager.listRequests == [true])
        #expect(emitted.messages == ["CONTAINER  REPOSITORY  TAG  IMAGE ID  PLATFORM"])
    }

    @Test("images json renders created image records")
    func imagesJSONRendersCreatedImageRecords() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
                "worker": ComposeService(name: "worker", image: "example/worker:debug"),
            ]
        )

        try await orchestrator.images(project: project, services: [], options: ComposeImagesOptions(format: "json"))

        let data = try Data(#require(emitted.messages.first).utf8)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(records.map { $0["container"] } == ["demo-api-1", "demo-worker-1"])
        #expect(records.map { $0["repository"] } == ["localhost:5000/example/api", "example/worker"])
        #expect(records.map { $0["tag"] } == ["latest", "debug"])
        #expect(records.map { $0["imageID"] } == ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("images json renders null for empty projects")
    func imagesJSONRendersNullForEmptyProjects() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [])
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        ).images(project: project, services: [], options: ComposeImagesOptions(format: "json"))

        #expect(await discoveryManager.listRequests == [true])
        #expect(emitted.messages == ["null"])
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

    @Test("volumes lists project and declared external volume records")
    func volumesListsProjectAndDeclaredExternalVolumeRecords() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(volumes: [
            ComposeVolumeSummary(
                name: "demo_cache",
                driver: "local",
                source: "/volumes/demo_cache",
                labels: ["com.apple.container.compose.project": "demo"]
            ),
            ComposeVolumeSummary(name: "shared-data", driver: "local", source: "/volumes/shared-data"),
            ComposeVolumeSummary(
                name: "other_cache",
                driver: "local",
                source: "/volumes/other_cache",
                labels: ["com.apple.container.compose.project": "other"]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            resourceManager: resourceManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(type: "volume", source: "cache", target: "/cache"),
                        ComposeMount(type: "volume", source: "shared", target: "/shared"),
                    ]
                },
            ]
        ) {
            $0.volumes = [
                "cache": ComposeVolume(name: "cache"),
                "shared": ComposeVolume(name: "shared-data", external: true),
            ]
        }

        try await orchestrator.volumes(project: project, options: ComposeVolumesOptions())

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests == [.listVolumes])
        let output = try #require(emitted.messages.first)
        #expect(output.contains("DRIVER"))
        #expect(output.contains("VOLUME NAME"))
        #expect(output.contains("demo_cache"))
        #expect(output.contains("shared-data"))
        #expect(!output.contains("other_cache"))
    }

    @Test("volumes table renders headers when no records match")
    func volumesTableRendersHeadersWhenNoRecordsMatch() async throws {
        let emitted = MessageRecorder()
        let resourceManager = RecordingContainerResourceManager(volumes: [])
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            resourceManager: resourceManager
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await orchestrator.volumes(project: project, options: ComposeVolumesOptions())

        #expect(emitted.messages == ["DRIVER  VOLUME NAME"])
        #expect(await resourceManager.requests == [.listVolumes])
    }

    @Test("volumes quiet prints selected service volume names")
    func volumesQuietPrintsSelectedServiceVolumeNames() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(volumes: [
            ComposeVolumeSummary(
                name: "demo_cache",
                labels: ["com.apple.container.compose.project": "demo"]
            ),
            ComposeVolumeSummary(
                name: "demo_worker",
                labels: ["com.apple.container.compose.project": "demo"]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            resourceManager: resourceManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumes = [ComposeMount(type: "volume", source: "worker", target: "/work")]
                },
            ]
        ) {
            $0.volumes = [
                "cache": ComposeVolume(name: "cache"),
                "worker": ComposeVolume(name: "worker"),
            ]
        }

        try await orchestrator.volumes(
            project: project,
            options: ComposeVolumesOptions(services: ["worker"], quiet: true)
        )

        #expect(await resourceManager.requests == [.listVolumes])
        #expect(emitted.messages == ["demo_worker"])
    }

    @Test("volumes json renders project volume records")
    func volumesJSONRendersProjectVolumeRecords() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(volumes: [
            ComposeVolumeSummary(
                name: "demo_cache",
                driver: "local",
                source: "/volumes/demo_cache",
                labels: ["com.apple.container.compose.project": "demo"]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            resourceManager: resourceManager
        )
        let project = composeProject(
            name: "demo",
            services: ["api": composeService(name: "api", image: "example/api")]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await orchestrator.volumes(project: project, options: ComposeVolumesOptions(format: "json"))

        let data = try Data(#require(emitted.messages.first).utf8)
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(record == [
            "Availability": "N/A",
            "Driver": "local",
            "Group": "N/A",
            "Labels": "com.apple.container.compose.project=demo",
            "Links": "N/A",
            "Mountpoint": "/volumes/demo_cache",
            "Name": "demo_cache",
            "Scope": "local",
            "Size": "N/A",
            "Status": "N/A",
        ])
        #expect(await resourceManager.requests == [.listVolumes])
    }

    @Test("volumes json omits output when there are no matching records")
    func volumesJSONOmitsOutputWhenThereAreNoMatchingRecords() async throws {
        let emitted = MessageRecorder()
        let resourceManager = RecordingContainerResourceManager(volumes: [])
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            resourceManager: resourceManager
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await orchestrator.volumes(project: project, options: ComposeVolumesOptions(format: "json"))

        #expect(emitted.messages.isEmpty)
        #expect(await resourceManager.requests == [.listVolumes])
    }

    @Test("volumes format template renders selected fields")
    func volumesFormatTemplateRendersSelectedFields() async throws {
        let emitted = MessageRecorder()
        let resourceManager = RecordingContainerResourceManager(volumes: [
            ComposeVolumeSummary(
                name: "demo_cache",
                driver: "local",
                source: "/volumes/demo_cache",
                labels: ["com.apple.container.compose.project": "demo"]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            resourceManager: resourceManager
        )
        let project = composeProject(
            name: "demo",
            services: ["api": composeService(name: "api", image: "example/api")]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await orchestrator.volumes(
            project: project,
            options: ComposeVolumesOptions(format: #"table {{.Name}}\t{{.Driver}}\t{{.Scope}}\t{{.Mountpoint}}"#)
        )

        #expect(emitted.messages == [
            """
            VOLUME NAME  DRIVER  SCOPE  MOUNTPOINT
            demo_cache   local   local  /volumes/demo_cache
            """,
        ])
        #expect(await resourceManager.requests == [.listVolumes])
    }

    @Test("volumes format template renders control actions and label lookup")
    func volumesFormatTemplateRendersControlActionsAndLabelLookup() async throws {
        let emitted = MessageRecorder()
        let resourceManager = RecordingContainerResourceManager(volumes: [
            ComposeVolumeSummary(
                name: "demo_cache",
                driver: "local",
                source: "/volumes/demo_cache",
                labels: ["oracle.example/key": "value", composeProjectLabel: "demo"]
            ),
        ])
        let project = ComposeProject(name: "demo", services: [:])

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            resourceManager: resourceManager
        )
        .volumes(
            project: project,
            options: ComposeVolumesOptions(
                format: #"{{if .Name}}{{.Name}}={{.Label "oracle.example/key"}}{{else}}missing{{end}}"#
            )
        )

        #expect(emitted.messages == ["demo_cache=value"])
        #expect(await resourceManager.requests == [.listVolumes])
    }

    @Test("volumes format template rejects unknown fields without records")
    func volumesFormatTemplateRejectsUnknownFieldsWithoutRecords() async throws {
        let resourceManager = RecordingContainerResourceManager(volumes: [])
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: RecordingRunner(), resourceManager: resourceManager)
                .volumes(project: project, options: ComposeVolumesOptions(format: "{{.Foo}}"))
            Issue.record("Expected unsupported volumes template field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("volumes --format field '.Foo'; supported fields are Availability, Driver, Group, Labels, Links, Mountpoint, Name, Scope, Size, Status"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("volumes dry run renders the backing direct API command")
    func volumesDryRunRendersBackingDirectAPICommand() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            resourceManager: resourceManager
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await orchestrator.volumes(project: project, options: ComposeVolumesOptions())

        #expect(emitted.messages == ["+ container volume list --format json"])
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("volumes accepts JSON template actions")
    func volumesAcceptsJSONTemplateActions() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let resourceManager = RecordingContainerResourceManager(volumes: [
            ComposeVolumeSummary(
                name: "demo_cache",
                driver: "local",
                source: "/volumes/demo_cache",
                labels: [composeProjectLabel: "demo"]
            ),
        ])
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            resourceManager: resourceManager
        )
        .volumes(project: project, options: ComposeVolumesOptions(format: "{{json .}}"))

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests == [.listVolumes])
        let data = try Data(#require(emitted.messages.first).utf8)
        let row = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(row["Name"] == "demo_cache")
        #expect(row["Driver"] == "local")
    }

    @Test("stats targets project service containers")
    func statsTargetsProjectServiceContainers() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let statsManager = RecordingContainerStatsManager(outputs: ["stats-output"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": composeService(name: "db", image: "postgres") {
                    $0.containerName = "custom-db"
                },
            ]
        )

        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            statsManager: statsManager
        )
        try await orchestrator.stats(project: project, options: ComposeStatsOptions())
        try await orchestrator.stats(
            project: project,
            options: ComposeStatsOptions(services: ["api", "db"], format: "json", noStream: true)
        )
        try await orchestrator.stats(
            project: project,
            options: ComposeStatsOptions(services: ["api"], all: true, noStream: true, noTrunc: true)
        )

        #expect(runner.commands.isEmpty)
        #expect(await statsManager.requests == [
            ContainerStatsRequest(ids: ["demo-api-1", "custom-db"], format: "table", noStream: false, noTrunc: false, includeStopped: false),
            ContainerStatsRequest(ids: ["demo-api-1", "custom-db"], format: "json", noStream: true, noTrunc: false, includeStopped: false),
            ContainerStatsRequest(ids: ["demo-api-1"], format: "table", noStream: true, noTrunc: true, includeStopped: true),
        ])
        #expect(emitted.messages == [
            "stats-output",
            "stats-output",
            "stats-output",
        ])
    }

    @Test("stats forwards exact bytes from capable runtime managers")
    func statsForwardsExactBytesFromCapableRuntimeManagers() async throws {
        let emittedText = MessageRecorder()
        let emittedData = DataRecorder()
        let statsManager = RecordingContainerStatsDataManager(output: Data([0xC3]))
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                runtimeHooks: .init(
                    emit: { emittedText.append($0) },
                    emitData: { emittedData.append($0) }
                )
            ),
            statsManager: statsManager
        ).stats(
            project: project,
            options: ComposeStatsOptions(services: ["api"], noStream: true)
        )

        #expect(emittedText.messages.isEmpty)
        #expect(emittedData.data == [Data([0xC3])])
        #expect(await statsManager.requests == [
            ContainerStatsRequest(
                ids: ["demo-api-1"],
                format: "table",
                noStream: true,
                noTrunc: false,
                includeStopped: false
            ),
        ])
    }

    @Test("stats stops a streaming session on interrupt")
    func statsStopsStreamingSessionOnInterrupt() async throws {
        let signalProxy = RecordingComposeSignalProxy(forwardedSignals: ["SIGINT"])
        let statsManager = InterruptibleStatsManager()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.signalProxy = signalProxy
                $0.statsManager = statsManager
            }
        ).stats(project: project, options: ComposeStatsOptions())

        #expect(await signalProxy.requests == [["SIGINT", "SIGTERM"]])
        #expect(await statsManager.cancelled)
    }

    @Test("stats dry run emits compose runtime operation")
    func statsDryRunEmitsComposeRuntimeOperation() async throws {
        let emitted = MessageRecorder()
        let statsManager = RecordingContainerStatsManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": composeService(name: "db", image: "postgres") {
                    $0.containerName = "custom-db"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            statsManager: statsManager
        ).stats(
            project: project,
            options: ComposeStatsOptions(services: ["api", "db"], all: true, format: "json", noStream: true)
        )

        #expect(emitted.messages == [
            "+ compose-runtime stats --format json --no-stream --all demo-api-1 custom-db",
        ])
        #expect(await statsManager.requests.isEmpty)
    }

    @Test("stats dry run renders no trunc flag")
    func statsDryRunRendersNoTruncFlag() async throws {
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        ).stats(
            project: project,
            options: ComposeStatsOptions(services: ["api"], noStream: true, noTrunc: true)
        )

        #expect(emitted.messages == [
            "+ compose-runtime stats --no-stream --no-trunc demo-api-1",
        ])
    }

    @Test("stats rejects unsupported template fields before runtime commands")
    func statsRejectsUnsupportedTemplateFieldsBeforeRuntimeCommands() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        let runner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: runner).stats(
                project: project,
                options: ComposeStatsOptions(format: "{{.Scope}}")
            )
            Issue.record("Expected unsupported stats template field failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("stats --format field '.Scope'; supported fields are BlockIO, CPUPerc, Container, ID, MemPerc, MemUsage, Name, NetIO, PIDs"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("top targets discovered project service containers")
    func topTargetsDiscoveredProjectServiceContainers() async throws {
        let emitted = MessageRecorder()
        let topManager = RecordingContainerTopManager(outputs: ["top-output"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-2", status: "running", labels: [composeProjectLabel: "demo", composeServiceLabel: "api"]),
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeProjectLabel: "demo", composeServiceLabel: "api"]),
            ComposeContainerSummary(id: "custom-db", status: "running", labels: [composeProjectLabel: "demo", composeServiceLabel: "db"]),
            ComposeContainerSummary(id: "other-api-1", status: "running", labels: [composeProjectLabel: "other", composeServiceLabel: "api"]),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": composeService(name: "db", image: "postgres") {
                    $0.containerName = "custom-db"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager,
            topManager: topManager
        ).top(project: project)

        #expect(await discoveryManager.listRequests == [true])
        #expect(await topManager.requests == [[
            ComposeTopTarget(service: "api", containerID: "demo-api-1"),
            ComposeTopTarget(service: "api", containerID: "demo-api-2"),
            ComposeTopTarget(service: "db", containerID: "custom-db"),
        ]])
        #expect(emitted.messages == ["top-output"])
    }

    @Test("top dry run emits compose runtime operations")
    func topDryRunEmitsComposeRuntimeOperations() async throws {
        let emitted = MessageRecorder()
        let topManager = RecordingContainerTopManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": composeService(name: "db", image: "postgres") {
                    $0.containerName = "custom-db"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            topManager: topManager
        ).top(project: project, options: ComposeTopOptions(services: ["api", "db"]))

        #expect(emitted.messages == [
            "+ compose-runtime top demo-api-1",
            "+ compose-runtime top custom-db",
        ])
        #expect(await topManager.requests.isEmpty)
    }

    @Test("events passes selected services to direct runtime event manager")
    func eventsPassesSelectedServicesToDirectRuntimeEventManager() async throws {
        let emitted = MessageRecorder()
        let eventsManager = RecordingContainerEventsManager(outputs: ["event-output"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    currentDate: { date("2026-06-22T12:00:00Z") },
                    emit: { emitted.append($0) }
                )
            ),
            eventsManager: eventsManager
        ).events(
            project: project,
            options: ComposeEventsOptions(
                services: ["api"],
                json: true,
                since: "2026-06-22T10:00:00Z",
                until: "30m"
            )
        )

        #expect(await eventsManager.requests == [
            ComposeEventsRequest(
                projectName: "demo",
                services: ["api"],
                format: .json,
                since: date("2026-06-22T10:00:00Z"),
                until: date("2026-06-22T11:30:00Z")
            ),
        ])
        #expect(emitted.messages == ["event-output"])
    }

    @Test("events defaults to Docker Compose text output")
    func eventsDefaultsToDockerComposeTextOutput() async throws {
        let emitted = MessageRecorder()
        let eventsManager = RecordingContainerEventsManager(outputs: ["event-output"])
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            eventsManager: eventsManager
        ).events(
            project: project,
            options: ComposeEventsOptions(services: ["api"])
        )

        #expect(await eventsManager.requests == [
            ComposeEventsRequest(projectName: "demo", services: ["api"], format: .text),
        ])
        #expect(emitted.messages == ["event-output"])
    }

    @Test("events rejects invalid time filters")
    func eventsRejectsInvalidTimeFilters() async throws {
        let eventsManager = RecordingContainerEventsManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        do {
            try await ComposeOrchestrator(eventsManager: eventsManager).events(
                project: project,
                options: ComposeEventsOptions(services: ["api"], json: true, since: "soon")
            )
            Issue.record("Expected invalid events time filter failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("events time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await eventsManager.requests.isEmpty)
    }

    @Test("events dry run emits compose runtime event read")
    func eventsDryRunEmitsComposeRuntimeEventRead() async throws {
        let emitted = MessageRecorder()
        let eventsManager = RecordingContainerEventsManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            eventsManager: eventsManager
        ).events(
            project: project,
            options: ComposeEventsOptions(
                services: ["api"],
                json: true,
                since: "2026-06-22T10:00:00Z",
                until: "2026-06-22T10:05:00Z"
            )
        )

        #expect(emitted.messages == [
            "+ compose-runtime events --since 2026-06-22T10:00:00Z --until 2026-06-22T10:05:00Z",
        ])
        #expect(await eventsManager.requests.isEmpty)
    }

    @Test("event manager filters runtime stream to Compose JSON service events")
    func eventManagerFiltersRuntimeStreamToComposeJSONServiceEvents() async throws {
        let emitted = MessageRecorder()
        let events = [
            ContainerEvent(
                time: date("2026-06-22T10:00:00Z"),
                type: "container",
                id: "demo-api-1",
                action: "start",
                attributes: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                    "com.apple.container.compose.config-hash": "hash",
                    "com.docker.compose.project": "demo",
                    "image": "example/api",
                    "status": "running",
                    "custom": "visible",
                ]
            ),
            ContainerEvent(
                time: date("2026-06-22T10:00:01Z"),
                type: "container",
                id: "demo-db-1",
                action: "start",
                attributes: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "db",
                    composeOneOffLabel: "false",
                    "image": "postgres",
                ]
            ),
            ContainerEvent(
                time: date("2026-06-22T10:00:02Z"),
                type: "container",
                id: "demo-api-run-1",
                action: "start",
                attributes: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "true",
                ]
            ),
            ContainerEvent(
                time: date("2026-06-22T10:00:03Z"),
                type: "container",
                id: "other-api-1",
                action: "start",
                attributes: [
                    composeProjectLabel: "other",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                ]
            ),
            ContainerEvent(
                time: date("2026-06-22T10:00:04Z"),
                type: "image",
                id: "example/api",
                action: "pull",
                attributes: [composeProjectLabel: "demo"]
            ),
        ]
        let client = try RecordingContainerEventsAPIClient(data: containerEventData(events, trailingNewline: false))
        let manager = ContainerClientEventsManager(client: client)

        try await manager.events(
            projectName: "demo",
            services: ["api"],
            format: .json,
            since: date("2026-06-22T09:59:00Z"),
            until: date("2026-06-22T10:01:00Z"),
            emit: { emitted.append($0) }
        )

        #expect(await client.options == [
            ContainerEventOptions(
                since: date("2026-06-22T09:59:00Z"),
                until: date("2026-06-22T10:01:00Z")
            ),
        ])
        #expect(emitted.messages.count == 1)
        let output = try #require(emitted.messages.first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ComposeEventRecord.self, from: Data(output.utf8))
        #expect(record == ComposeEventRecord(
            time: date("2026-06-22T10:00:00Z"),
            type: "container",
            service: "api",
            id: "demo-api-1",
            action: "start",
            attributes: [
                "custom": "visible",
                "image": "example/api",
                "status": "running",
            ]
        ))
    }

    @Test("event manager relays Docker terminal actions and hides generic delete")
    func eventManagerRelaysDockerTerminalActionsAndHidesGenericDelete() async throws {
        let emitted = MessageRecorder()
        let events = [
            ContainerEvent(
                time: date("2026-06-22T10:00:00Z"),
                type: "container",
                id: "demo-api-1",
                action: "kill",
                attributes: composeEventAttributes(extra: ["signal": "9"])
            ),
            ContainerEvent(
                time: date("2026-06-22T10:00:01Z"),
                type: "container",
                id: "demo-api-1",
                action: "die",
                attributes: composeEventAttributes(extra: ["exitCode": "137"])
            ),
            ContainerEvent(
                time: date("2026-06-22T10:00:02Z"),
                type: "container",
                id: "demo-api-1",
                action: "delete",
                attributes: composeEventAttributes()
            ),
            ContainerEvent(
                time: date("2026-06-22T10:00:03Z"),
                type: "container",
                id: "demo-api-1",
                action: "destroy",
                attributes: composeEventAttributes()
            ),
        ]
        let client = try RecordingContainerEventsAPIClient(data: containerEventData(events))
        let manager = ContainerClientEventsManager(client: client)

        try await manager.events(
            projectName: "demo",
            services: ["api"],
            format: .json,
            since: nil,
            until: nil,
            emit: { emitted.append($0) }
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try emitted.messages.map {
            try decoder.decode(ComposeEventRecord.self, from: Data($0.utf8))
        }
        #expect(records.map(\.action) == ["kill", "die", "destroy"])
        #expect(records[0].attributes["signal"] == "9")
        #expect(records[1].attributes["exitCode"] == "137")
    }

    @Test("event manager relays Docker exec actions with public exec metadata")
    func eventManagerRelaysDockerExecActions() async throws {
        let emitted = MessageRecorder()
        let events = [
            ContainerEvent(
                time: date("2026-06-22T10:00:00Z"),
                type: "container",
                id: "demo-api-1",
                action: "exec_create: sh -c exit 23",
                attributes: composeEventAttributes(extra: ["execID": "exec-123"])
            ),
            ContainerEvent(
                time: date("2026-06-22T10:00:01Z"),
                type: "container",
                id: "demo-api-1",
                action: "exec_start: sh -c exit 23",
                attributes: composeEventAttributes(extra: ["execID": "exec-123"])
            ),
            ContainerEvent(
                time: date("2026-06-22T10:00:02Z"),
                type: "container",
                id: "demo-api-1",
                action: "exec_die",
                attributes: composeEventAttributes(extra: ["execID": "exec-123", "exitCode": "23"])
            ),
        ]
        let client = try RecordingContainerEventsAPIClient(data: containerEventData(events))
        let manager = ContainerClientEventsManager(client: client)

        try await manager.events(
            projectName: "demo",
            services: ["api"],
            format: .json,
            since: nil,
            until: nil,
            emit: { emitted.append($0) }
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try emitted.messages.map {
            try decoder.decode(ComposeEventRecord.self, from: Data($0.utf8))
        }
        #expect(records.map(\.action) == [
            "exec_create: sh -c exit 23",
            "exec_start: sh -c exit 23",
            "exec_die",
        ])
        #expect(records.allSatisfy { $0.attributes["execID"] == "exec-123" })
        #expect(records[2].attributes["exitCode"] == "23")
        #expect(records.allSatisfy { record in
            record.attributes.keys.allSatisfy { !$0.hasPrefix("com.docker.compose.") }
        })
    }

    @Test("event manager renders Docker Compose text service events by default")
    func eventManagerRendersDockerComposeTextServiceEventsByDefault() async throws {
        let emitted = MessageRecorder()
        let events = [
            ContainerEvent(
                time: date("2026-06-22T10:00:00.123456Z"),
                type: "container",
                id: "demo-api-1",
                action: "die",
                attributes: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                    "custom": "visible",
                    "exitCode": "0",
                    "image": "example/api",
                ]
            ),
        ]
        let client = try RecordingContainerEventsAPIClient(data: containerEventData(events))
        let manager = ContainerClientEventsManager(client: client)

        try await manager.events(
            projectName: "demo",
            services: [],
            format: .text,
            since: nil,
            until: nil,
            emit: { emitted.append($0) }
        )

        #expect(await client.options == [.default])
        #expect(emitted.messages == [
            "\(composeTextEventTimestamp("2026-06-22T10:00:00Z")) container die demo-api-1 (custom=visible, exitCode=0, image=example/api)",
        ])
    }

    @Test("ls lists compose projects with grouped status")
    func lsListsComposeProjectsWithGroupedStatus() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ls(options: ComposeLsOptions(all: true))

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        let output = try #require(emitted.messages.first)
        #expect(output.contains("NAME"))
        #expect(output.contains("STATUS"))
        #expect(output.contains("CONFIG FILES"))
        #expect(output.contains("demo"))
        #expect(output.contains("exited(1), running(1)"))
        #expect(output.contains("/tmp/demo/compose.yml,/tmp/demo/compose.override.yml"))
        #expect(output.contains("other"))
        #expect(output.contains("/tmp/other/compose.yml"))
    }

    @Test("ls defaults to running projects only")
    func lsDefaultsToRunningProjectsOnly() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ls()

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(try #require(emitted.messages.first).contains("demo"))
    }

    @Test("ls quiet prints filtered project names")
    func lsQuietPrintsFilteredProjectNames() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ls(options: ComposeLsOptions(all: true, quiet: true, filters: ["name=^dem"]))

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(emitted.messages == ["demo"])
    }

    @Test("ls json renders compose projects")
    func lsJSONRendersComposeProjects() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ls(options: ComposeLsOptions(all: true, format: "json"))

        let data = try Data(#require(emitted.messages.first).utf8)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(records.map { $0["name"] } == ["demo", "other"])
        #expect(records.map { $0["status"] } == ["exited(1), running(1)", "running(1)"])
        #expect(records.map { $0["configFiles"] } == [
            "/tmp/demo/compose.yml,/tmp/demo/compose.override.yml",
            "/tmp/other/compose.yml",
        ])
        #expect(await discoveryManager.listRequests == [true])
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
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]))

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(try listedContainerIDs(from: #require(emitted.messages.first)) == ["demo-api-1"])
    }

    @Test("ps default discovery uses configured container binary and environment launcher")
    func psDefaultDiscoveryUsesConfiguredContainerBinaryAndEnvironmentLauncher() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: "[]", stderr: ""),
        ])
        let options = ComposeExecutionOptions(
            containerBinary: "custom-container",
            environmentLauncher: "custom-env",
            runtimeHooks: .init(emit: { emitted.append($0) })
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: options,
            dependencies: ComposeContainerRuntime.dependencies(runner: runner, options: options)
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]))

        let command = try #require(runner.commands.first)
        #expect(runner.commands.count == 1)
        #expect(command.executable == "custom-env")
        #expect(command.arguments == ["custom-container", "list", "--format", "json"])
        #expect(command.workingDirectory == nil)
        #expect(command.environment == nil)
        #expect(command.io == .captured(input: nil))
        let output = try #require(emitted.messages.first)
        let rows = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        #expect(rows?.isEmpty == true)
    }

    @Test("ps keeps project scoping when all containers are requested")
    func psKeepsProjectScopingWhenAllContainersAreRequested() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.all = true }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: #require(emitted.messages.first)) == ["demo-api-1", "demo-worker-1"])
    }

    @Test("ps quiet prints project scoped container IDs")
    func psQuietPrintsProjectScopedContainerIDs() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.quiet = true }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(emitted.messages == ["demo-api-1"])
    }

    @Test("ps filters containers by selected services")
    func psFiltersContainersBySelectedServices() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]),
            options: ComposePsOptions {
                $0.all = true
                $0.selectedServices = ["worker"]
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: #require(emitted.messages.first)) == ["demo-worker-1"])
    }

    @Test("ps services prints project scoped service names")
    func psServicesPrintsProjectScopedServiceNames() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.services = true }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(emitted.messages == ["api"])
    }

    @Test("ps services projection honours selected services")
    func psServicesProjectionHonoursSelectedServices() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]),
            options: ComposePsOptions {
                $0.all = true
                $0.services = true
                $0.selectedServices = ["worker"]
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(emitted.messages == ["worker"])
    }

    @Test("ps format table renders project scoped containers")
    func psFormatTableRendersProjectScopedContainers() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ],
                image: .init(reference: "localhost:5000/example/api:latest"),
                resources: .init(publishedPorts: [
                    ComposeContainerPublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, protocolName: "tcp"),
                    ComposeContainerPublishedPort(hostAddress: "127.0.0.1", hostPort: 8081, containerPort: 81, protocolName: "udp", count: 2),
                    ComposeContainerPublishedPort(hostAddress: "::1", hostPort: 8083, containerPort: 83, protocolName: "tcp"),
                ])
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.format = "table"
                $0.noTrunc = true
            }
        )

        let output = try #require(emitted.messages.first)
        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(output.contains("NAME"))
        #expect(output.contains("IMAGE"))
        #expect(output.contains("SERVICE"))
        #expect(output.contains("PORTS"))
        #expect(output.contains("demo-api-1"))
        #expect(output.contains("api"))
        #expect(output.contains("127.0.0.1:8080->80/tcp"))
        #expect(output.contains("127.0.0.1:8081->81/udp"))
        #expect(output.contains("127.0.0.1:8082->82/udp"))
        #expect(output.contains("[::1]:8083->83/tcp"))
    }

    @Test("ps table renders headers when no records match")
    func psTableRendersHeadersWhenNoRecordsMatch() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [])
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.format = "table" }
        )

        #expect(await discoveryManager.listRequests == [false])
        #expect(emitted.messages == ["NAME  IMAGE  SERVICE  STATUS  PORTS"])
    }

    @Test("ps format template renders selected fields")
    func psFormatTemplateRendersSelectedFields() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.all = true
                $0.format = #"table {{.Name}}\t{{.Service}}\t{{.Status}}\t{{.Ports}}"#
                $0.noTrunc = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(emitted.messages == [
            """
            NAME           SERVICE  STATUS   PORTS
            demo-api-1     api      running
            demo-worker-1  worker   exited
            """,
        ])
    }

    @Test("ps format template renders documented Docker functions")
    func psFormatTemplateRendersDocumentedDockerFunctions() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ],
                image: .init(reference: "example/api:latest")
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.format = #"{{upper .Service}}\t{{truncate .Image 7}}\t{{json .Name}}\t{{join (split .Image ":") "/"}}"#
            }
        )

        #expect(emitted.messages == ["API\texample\t\"demo-api-1\"\texample/api/latest"])
    }

    @Test("ps format template renders else-with continuations")
    func psFormatTemplateRendersElseWithContinuations() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.format = "{{with .Health}}healthy{{else with .Status}}{{.}}{{end}}"
            }
        )

        #expect(emitted.messages == ["running"])
        #expect(await discoveryManager.listRequests == [false])
    }

    @Test("ps format template truncates IDs by default")
    func psFormatTemplateTruncatesIDsByDefault() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "0123456789abcdef",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.format = "{{.ID}}" }
        )

        #expect(emitted.messages == ["0123456789ab"])
    }

    @Test("ps format template renders health exit code and publishers")
    func psFormatTemplateRendersHealthExitCodeAndPublishers() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ],
                resources: .init(publishedPorts: [
                    ComposeContainerPublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, protocolName: "tcp"),
                ]),
                state: .init(exitCode: 0, health: "healthy")
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.all = true
                $0.format = #"{{.Health}}\t{{.ExitCode}}\t{{.Publishers}}"#
            }
        )

        #expect(
            emitted.messages == [
                "healthy\t0\t[{127.0.0.1 80 8080 tcp}]",
            ]
        )
    }

    @Test("ps format template defaults an absent exit code to typed zero")
    func psFormatTemplateDefaultsAbsentExitCodeToTypedZero() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.format = #"{{printf "%d" .ExitCode}}\t{{eq .ExitCode 0}}"#
            }
        )

        #expect(emitted.messages == ["0\ttrue"])
    }

    @Test("ps format template emits partial UTF-8 as exact bytes")
    func psFormatTemplateEmitsPartialUTF8AsExactBytes() async throws {
        let emittedText = MessageRecorder()
        let emittedData = DataRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(
                runtimeHooks: .init(
                    emit: { emittedText.append($0) },
                    emitData: { emittedData.append($0) }
                )
            ),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.format = #"{{printf "%s" (truncate "é" 1)}}"# }
        )

        #expect(emittedText.messages.isEmpty)
        #expect(emittedData.data == [Data([0xC3])])
    }

    @Test("ps format template ranges structured publishers and reads labels")
    func psFormatTemplateRangesStructuredPublishersAndReadsLabels() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                    "oracle.example/key": "value",
                ],
                resources: .init(
                    publishedPorts: [
                        ComposeContainerPublishedPort(
                            hostAddress: "127.0.0.1",
                            hostPort: 32_768,
                            containerPort: 8_080,
                            protocolName: "tcp"
                        ),
                    ],
                    mounts: [
                        ComposeMount(type: "external-volume", source: "demo_cache", target: "/cache"),
                    ],
                    networks: [
                        ComposeContainerNetworkAttachment(network: "demo_default", ipv4Address: "192.0.2.2"),
                    ]
                )
            ),
        ])

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        .ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.format =
                    #"{{range $index, $publisher := .Publishers}}{{$index}}={{$publisher.URL}}|{{$publisher.TargetPort}}|{{$publisher.PublishedPort}}|{{$publisher.Protocol}}{{end}}\t{{.Label "oracle.example/key"}}\t{{.LocalVolumes}}\t{{.Mounts}}\t{{.Networks}}"#
            }
        )

        #expect(
            emitted.messages == [
                "0=127.0.0.1|8080|32768|tcp\tvalue\t1\tdemo_cache\tdemo_default",
            ]
        )
    }

    @Test("ps with or pipeline selects publisher context")
    func psWithOrPipelineSelectsPublisherContext() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ],
                resources: .init(
                    publishedPorts: [
                        ComposeContainerPublishedPort(
                            hostAddress: "127.0.0.1",
                            hostPort: 32_768,
                            containerPort: 8_080,
                            protocolName: "tcp"
                        ),
                    ]
                )
            ),
        ])

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        .ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.format =
                    "{{with . | or (index .Publishers 0)}}{{.TargetPort}}{{end}}"
            }
        )

        #expect(emitted.messages == ["8080"])
    }

    @Test("ps can exclude orphaned service containers")
    func psCanExcludeOrphanedServiceContainers() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeOneOffLabel: "false",
            ], health: "healthy"),
            ComposeContainerSummary(id: "demo-old-1", status: "running", labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "old",
                composeOneOffLabel: "false",
            ]),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]),
            options: ComposePsOptions {
                $0.format = "json"
                $0.orphans = false
            }
        )

        let data = try Data(#require(emitted.messages.first).utf8)
        let containers = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(containers.compactMap { $0["id"] as? String } == ["demo-api-1"])
        #expect(containers.compactMap { $0["health"] as? String } == ["healthy"])
    }

    @Test("ps rejects unsupported template fields, including parenthesized root selectors")
    func psRejectsUnsupportedTemplateFields() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [])
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)

        for template in [
            "{{.Command}}",
            "{{($).Command}}",
            "{{((.)).Command}}",
            "{{with or $ .Name}}{{.Command}}{{end}}",
            "{{with .Name | or $}}{{.Command}}{{end}}",
            "{{with $ | and .Name}}{{.Command}}{{end}}",
            "{{with and .Name $}}{{.Command}}{{end}}",
        ] {
            do {
                try await orchestrator.ps(
                    project: ComposeProject(name: "demo", services: [:]),
                    options: ComposePsOptions { $0.format = template }
                )
                Issue.record("Expected unsupported ps template field error for \(template)")
            } catch let error as ComposeError {
                #expect(error == .unsupported("ps --format field '.Command'; supported fields are ExitCode, Health, ID, Image, Labels, LocalVolumes, Mounts, Name, Names, Networks, Ports, Project, Publishers, Service, State, Status"))
            } catch {
                Issue.record("Unexpected error for \(template): \(error)")
            }
        }

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests.isEmpty)
    }

    @Test("ps rejects root collection operations and unsupported functions before discovery")
    func psRejectsRootIndexingAndTableFunction() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [])
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
        let nonBreakingSpace = "\u{00A0}"

        for template in [
            "{{index $ \"Command\"}}",
            "{{len $}}",
            "{{range $}}{{.}}{{end}}",
            "{{range $index, $value := 3}}{{$index}}={{$value}}{{end}}",
            "{{with table $}}{{.Command}}{{end}}",
            "{{\(nonBreakingSpace).Name}}",
            "{{if\(nonBreakingSpace).Name}}{{.Name}}{{end}}",
        ] {
            await #expect(throws: (any Error).self) {
                try await orchestrator.ps(
                    project: ComposeProject(name: "demo", services: [:]),
                    options: ComposePsOptions { $0.format = template }
                )
            }
        }

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests.isEmpty)
    }

    @Test("ps rejects unknown selected services before runtime commands")
    func psRejectsUnknownSelectedServicesBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)

        do {
            try await orchestrator.ps(
                project: ComposeProject(name: "demo", services: [
                    "api": ComposeService(name: "api", image: "example/api"),
                ]),
                options: ComposePsOptions { $0.selectedServices = ["worker"] }
            )
            Issue.record("Expected unknown service error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unknown service 'worker'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests.isEmpty)
    }

    @Test("ps quiet takes precedence over services")
    func psQuietTakesPrecedenceOverServices() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.quiet = true
                $0.services = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(emitted.messages == ["demo-api-1"])
    }

    @Test("ps status filters project scoped containers")
    func psStatusFiltersProjectScopedContainers() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.statuses = ["running"] }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: #require(emitted.messages.first)) == ["demo-api-1"])
    }

    @Test("ps filter status supports exited alias")
    func psFilterStatusSupportsExitedAlias() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.filters = ["status=exited"] }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: #require(emitted.messages.first)) == ["demo-worker-1"])
    }

    @Test("ps status filters created containers distinctly from exited containers")
    func psStatusFiltersCreatedContainers() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-created-1", serviceName: "created", status: "created"),
            discoveredServiceContainer(id: "demo-exited-1", serviceName: "exited", status: "exited"),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.statuses = ["created"] }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: #require(emitted.messages.first)) == ["demo-created-1"])
    }

    @Test("ps status stopped remains a nonmatching legacy filter")
    func psStatusStoppedDoesNotAliasExited() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.quiet = true
                $0.statuses = ["stopped"]
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(emitted.messages.isEmpty)
    }

    @Test("ps status supports paused containers")
    func psStatusSupportsPausedContainers() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: pausedDiscoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.statuses = ["paused"] }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: #require(emitted.messages.first)) == ["demo-paused-1"])
    }

    @Test("ps filter status supports paused containers")
    func psFilterStatusSupportsPausedContainers() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: pausedDiscoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.filters = ["status=paused"] }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: #require(emitted.messages.first)) == ["demo-paused-1"])
    }

    @Test("ps status filters services projection")
    func psStatusFiltersServicesProjection() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: discoveredContainers())
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions {
                $0.services = true
                $0.statuses = ["running"]
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(emitted.messages == ["api"])
    }

    @Test("ps rejects malformed filters before runtime commands")
    func psRejectsMalformedFiltersBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)

        do {
            try await orchestrator.ps(
                project: ComposeProject(name: "demo", services: [:]),
                options: ComposePsOptions { $0.filters = ["status"] }
            )
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
            try await orchestrator.ps(
                project: ComposeProject(name: "demo", services: [:]),
                options: ComposePsOptions { $0.filters = ["source=image"] }
            )
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
            try await orchestrator.ps(
                project: ComposeProject(name: "demo", services: [:]),
                options: ComposePsOptions { $0.statuses = ["restarting"] }
            )
            Issue.record("Expected unsupported status error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("ps status 'restarting'; current macOS Compose exposes created, exited, paused, running, stopping, and unknown"))
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

    @Test("config preserves inspection-only IPAM options")
    func configPreservesInspectionOnlyIPAMOptions() throws {
        var networkOptions = ComposeNetwork.Options()
        networkOptions.ipamOptions = ["com.example.ipam": "enabled"]
        let project = composeProject(
            name: "demo",
            services: ["api": composeService(name: "api", image: "example/api")]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "demo_backend",
                    options: networkOptions
                ),
            ]
        }

        let output = try ComposeOrchestrator().config(project: project)
        let document = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let networks = try #require(document["networks"] as? [String: Any])
        let backend = try #require(networks["backend"] as? [String: Any])

        #expect(backend["ipamOptions"] as? [String: String] == ["com.example.ipam": "enabled"])
        #expect(backend["unsupportedFields"] == nil)
    }

    @Test("config preserves userns_mode using the Compose field spelling")
    func configPreservesPrivateUserNamespaceMode() throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.usernsMode = "private"
                },
            ]
        )

        let output = try ComposeOrchestrator().config(project: project)
        let document = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let services = try #require(document["services"] as? [String: Any])
        let api = try #require(services["api"] as? [String: Any])

        #expect(api["userns_mode"] as? String == "private")
        #expect(api["usernsMode"] == nil)
    }

    @Test("config renders canonical YAML")
    func configRendersCanonicalYAML() throws {
        var project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.environment = ["CONTROL": "\u{001F}", "EMPTY": nil, "MODE": "dev", "ODD": "line\nquote\"tab\tend"]
                    $0.networks = ["front"]
                },
                "worker": composeService(name: "worker", image: "example/worker"),
            ]
        ) {
            $0.networks = ["front": ComposeNetwork(name: "front")]
            $0.extensions = ["x-project": .object([
                "enabled": .bool(true),
                "one": .number(1),
                "zero": .number(0),
            ])]
        }
        project.workingDirectory = "/workspace/demo"

        let yaml = try ComposeOrchestrator().config(
            project: project,
            options: ComposeConfigOptions {
                $0.services = ["api"]
                $0.format = "yaml"
            }
        )

        #expect(yaml.contains(#"name: "demo""#))
        #expect(yaml.contains(#"workingDirectory: "/workspace/demo""#))
        #expect(yaml.contains("services:\n  api:"))
        #expect(yaml.contains(#"    image: "example/api""#))
        #expect(yaml.contains("    environment:\n      CONTROL: \"\\u001F\"\n      EMPTY: null\n      MODE: \"dev\""))
        #expect(yaml.contains(#"      ODD: "line\nquote\"tab\tend""#))
        #expect(yaml.contains("    networks:\n      - \"front\""))
        #expect(yaml.contains("networks:\n  front:\n    name: \"front\""))
        #expect(yaml.contains("extensions:\n  x-project:\n    enabled: true\n    one: 1\n    zero: 0"))
        #expect(!yaml.contains("worker"))
    }

    @Test("config defaults to canonical YAML")
    func configDefaultsToCanonicalYAML() throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api"),
                "worker": composeService(name: "worker", image: "example/worker"),
            ]
        )

        let yaml = try ComposeOrchestrator().config(project: project, options: ComposeConfigOptions())

        #expect(yaml.contains(#"name: "demo""#))
        #expect(yaml.contains("services:\n  api:"))
        #expect(yaml.contains("  worker:"))
        #expect(!yaml.contains(#""services" :"#))
    }

    @Test("bridge convert enriches the transformer input with image metadata")
    func bridgeConvertEnrichesTransformerInputWithImageMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("app.conf")
        try "feature=true\n".write(to: config, atomically: true, encoding: .utf8)
        let secretEnvironment = "COMPOSE_BRIDGE_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(secretEnvironment, "bridge-secret", 1)
        defer { unsetenv(secretEnvironment) }
        let output = directory.appendingPathComponent("out", isDirectory: true)
        let templates = directory.appendingPathComponent("templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        let runner = BridgeInputInspectingRunner()
        let imageManager = RecordingContainerImageManager(imageMetadata: [
            "example/api:1": ComposeImageMetadata(reference: "example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") {
                $0.displayReference = "example/api:1"
                $0.exposedPorts = ["0443/tcp", "8080/tcp", "8443/udp"]
            },
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:1") {
                    $0.expose = ["9000"]
                    $0.ports = ["127.0.0.1:80:8080", "8443-8444:9443-9444/udp"]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.configs = ["app_config": .object(["file": .string("app.conf")])]
            $0.secrets = ["app_secret": .object(["environment": .string(secretEnvironment)])]
        }

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).bridgeConvert(
            project: project,
            model: .object([
                "name": .string("demo"),
                "services": .object([
                    "api": .object(["image": .string("example/api:1")]),
                ]),
                "configs": .object(["app_config": .object([
                    "file": .string("app.conf"),
                    "x-transform": .string("keep"),
                ])]),
                "secrets": .object(["app_secret": .object(["environment": .string(secretEnvironment)])]),
            ]),
            options: ComposeBridgeConvertOptions(
                output: output.path,
                templates: templates.path,
                transformations: ["example/bridge-transformer:latest"]
            )
        )

        #expect(await imageManager.requests == [
            .pullMissing("example/api:1"),
            .metadata("example/api:1"),
            .pullMissing("example/bridge-transformer:latest"),
        ])
        let command = try #require(runner.commands.last?.arguments)
        #expect(command.starts(with: ["container", "run", "--rm"]))
        #expect(command.contains("LICENSE_AGREEMENT=true"))
        #expect(command.contains("\(output.path):/out"))
        #expect(command.contains("\(templates.path):/templates"))
        #expect(command.last == "example/bridge-transformer:latest")
        #expect(runner.commands.last?.io == .inherited)
        let input = try #require(runner.inputComposeFiles.first)
        #expect(input.contains(#"image: "example/api:1""#))
        #expect(input.contains("expose:\n      - \"443\"\n      - \"8080\"\n      - \"8443\"\n      - \"9000\"\n      - \"9443\"\n      - \"9444\""))
        #expect(input.contains(#"content: "feature=true\n""#))
        #expect(input.contains(#"content: "bridge-secret""#))
        #expect(input.contains(#"x-transform: "keep""#))
        #expect(runner.inputDirectoryPermissions == [0o700])
        #expect(runner.inputFilePermissions == [0o600])
        let outputAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((outputAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o744)
    }

    @Test("bridge convert preserves binary config content")
    func bridgeConvertPreservesBinaryConfigContent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("binary.conf")
        try Data([0x80, 0x81, 0x82]).write(to: config)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        let runner = BridgeInputInspectingRunner()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(name: "demo", services: [:])
        var configuredProject = project
        configuredProject.workingDirectory = directory.path
        configuredProject.configs = ["binary": .object(["file": .string("binary.conf")])]

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).bridgeConvert(
            project: configuredProject,
            model: .object([
                "name": .string("demo"),
                "services": .object([:]),
            ]),
            options: ComposeBridgeConvertOptions(
                output: output.path,
                transformations: ["example/bridge-transformer:latest"]
            )
        )

        let input = try #require(runner.inputComposeFiles.first)
        #expect(input.contains("content: !!binary gIGC"))
    }

    @Test("bridge convert rejects invalid image exposed ports")
    func bridgeConvertRejectsInvalidImageExposedPorts() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(imageMetadata: [
            "example/api:1": ComposeImageMetadata(reference: "example/api:1") {
                $0.exposedPorts = ["not-a-port"]
            },
        ])
        let project = ComposeProject(
            name: "demo",
            services: ["api": composeService(name: "api", image: "example/api:1")]
        )

        do {
            try await ComposeOrchestrator(runner: runner, imageManager: imageManager).bridgeConvert(
                project: project,
                options: ComposeBridgeConvertOptions()
            )
            Issue.record("Expected an invalid image exposed port to be rejected")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("image 'example/api:1' exposes invalid port 'not-a-port'"))
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("bridge convert preserves commas in host bind paths")
    func bridgeConvertPreservesCommasInHostBindPaths() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output,two", isDirectory: true)
        let templates = directory.appendingPathComponent("templates,three", isDirectory: true)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        let runner = BridgeInputInspectingRunner()

        try await ComposeOrchestrator(
            runner: runner,
            imageManager: RecordingContainerImageManager()
        ).bridgeConvert(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposeBridgeConvertOptions(
                output: output.path,
                templates: templates.path,
                transformations: ["example/bridge-transformer:latest"]
            )
        )

        let arguments = try #require(runner.commands.last?.arguments)
        #expect(arguments.contains("\(output.path):/out"))
        #expect(arguments.contains("\(templates.path):/templates"))
        #expect(!arguments.contains("--mount"))
    }

    @Test("bridge convert selects amd64 for legacy official transformer versions")
    func bridgeConvertSelectsAMD64ForLegacyOfficialTransformerVersions() async throws {
        let versionedMessages = MessageRecorder()
        let qualifiedMessages = MessageRecorder()
        let latestMessages = MessageRecorder()
        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { versionedMessages.append($0) })
        ).bridgeConvert(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposeBridgeConvertOptions(transformations: ["docker/compose-bridge-kubernetes:v0.0.3"])
        )
        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { qualifiedMessages.append($0) })
        ).bridgeConvert(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposeBridgeConvertOptions(
                transformations: ["docker.io/docker/compose-bridge-helm:v0.0.3"]
            )
        )
        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { latestMessages.append($0) })
        ).bridgeConvert(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposeBridgeConvertOptions(transformations: ["docker/compose-bridge-kubernetes:latest"])
        )

        #if arch(arm64)
            #expect(versionedMessages.messages.first?.contains("--arch amd64") == true)
            #expect(qualifiedMessages.messages.first?.contains("--arch amd64") == true)
            #expect(latestMessages.messages.first?.contains("--arch") == false)
        #else
            #expect(versionedMessages.messages.first?.contains("--arch") == false)
            #expect(qualifiedMessages.messages.first?.contains("--arch") == false)
        #endif
    }

    @Test("bridge convert preserves compose-go public model shapes")
    func bridgeConvertPreservesComposeGoPublicModelShapes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out", isDirectory: true)
        let runner = BridgeInputInspectingRunner()
        let imageManager = RecordingContainerImageManager(imageMetadata: [
            "example/api:1": ComposeImageMetadata(reference: "example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") {
                $0.exposedPorts = ["8080/tcp"]
            },
        ])
        let project = ComposeProject(
            name: "demo",
            services: ["api": composeService(name: "api", image: "example/api:1")]
        )
        let model = ComposeValue.object([
            "name": .string("demo"),
            "services": .object([
                "api": .object([
                    "image": .string("example/api:1"),
                    "ports": .array([
                        .object([
                            "mode": .string("ingress"),
                            "target": .number(8080),
                            "published": .string("80"),
                            "protocol": .string("tcp"),
                        ]),
                    ]),
                ]),
            ]),
        ])

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).bridgeConvert(
            project: project,
            model: model,
            options: ComposeBridgeConvertOptions(
                output: output.path,
                transformations: ["example/bridge-transformer:latest"]
            )
        )

        let input = try #require(runner.inputComposeFiles.first)
        #expect(input.contains("published: \"80\""))
        #expect(input.contains("target: 8080"))
        #expect(input.contains("expose:\n      - \"8080\""))
        #expect(!input.contains("workingDirectory:"))
        #expect(!input.contains("name: \"api\""))
    }

    @Test("bridge convert uses Docker image names for build-only services")
    func bridgeConvertUsesDockerImageNamesForBuildOnlyServices() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = BridgeInputInspectingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api") {
                    $0.build = ComposeBuild(context: ".")
                },
            ]
        )
        let model = ComposeValue.object([
            "name": .string("demo"),
            "services": .object(["api": .object(["build": .object(["context": .string(directory.path)])])]),
        ])
        let imageManager = RecordingContainerImageManager(imageMetadata: [
            "demo_api:latest": ComposeImageMetadata(reference: "demo_api:latest") {
                $0.exposedPorts = ["8080/tcp"]
            },
        ])

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).bridgeConvert(
            project: project,
            model: model,
            options: ComposeBridgeConvertOptions(
                output: directory.appendingPathComponent("out").path,
                transformations: ["example/bridge-transformer:latest"]
            )
        )

        #expect(await imageManager.requests == [
            .pullMissing("demo_api:latest"),
            .metadata("demo_api:latest"),
            .pullMissing("example/bridge-transformer:latest"),
        ])
        let input = try #require(runner.inputComposeFiles.first)
        #expect(input.contains("image: \"demo-api\""))
        #expect(input.contains("expose:\n      - \"8080\""))
        #expect(!input.contains("image: \"demo_api:latest\""))
    }

    @Test("bridge transformations list renders table JSON and quiet modes")
    func bridgeTransformationsListRendersSupportedFormats() async throws {
        let emitted = MessageRecorder()
        let imageManager = RecordingContainerImageManager(transformers: [
            ComposeBridgeTransformer(
                id: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                reference: "docker/compose-bridge-kubernetes:latest",
                details: ComposeBridgeTransformerDetails(
                    createdAtUnix: 1_700_000_000,
                    labels: ["com.docker.compose.bridge": "transformation"],
                    repoDigests: [
                        "docker/compose-bridge-kubernetes@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    ],
                    size: ComposeBridgeTransformerSize(sizeInBytes: 2048)
                )
            ),
            ComposeBridgeTransformer(
                id: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                reference: "docker/compose-bridge-kubernetes@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                details: ComposeBridgeTransformerDetails(
                    createdAtUnix: 1_700_000_000,
                    labels: ["com.docker.compose.bridge": "transformation"],
                    repoDigests: [
                        "docker/compose-bridge-kubernetes@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    ],
                    repoTags: [],
                    size: ComposeBridgeTransformerSize(sizeInBytes: 2048)
                )
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies { $0.imageManager = imageManager }
        )

        try await orchestrator.bridgeTransformationsList(options: ComposeBridgeTransformationsListOptions())
        try await orchestrator.bridgeTransformationsList(options: ComposeBridgeTransformationsListOptions(format: "json"))
        try await orchestrator.bridgeTransformationsList(options: ComposeBridgeTransformationsListOptions(quiet: true))

        #expect(await imageManager.requests == [.bridgeTransformers, .bridgeTransformers, .bridgeTransformers])
        #expect(emitted.messages.count == 3)
        #expect(emitted.messages[0].contains("IMAGE ID"))
        #expect(emitted.messages[0].contains("TAGS"))
        #expect(emitted.messages[0].contains("compose-bridge-kubernetes"))
        #expect(emitted.messages[1].contains(#""Created" : 1700000000"#))
        #expect(emitted.messages[1].contains(#""Id" : "sha256:aaaaaaaa"#))
        #expect(emitted.messages[1].contains(#""RepoTags" : ["#))
        #expect(emitted.messages[1].contains(#""com.docker.compose.bridge" : "transformation""#))
        #expect(emitted.messages[2] == "docker/compose-bridge-kubernetes:latest")
        let summaries = try #require(
            JSONSerialization.jsonObject(with: Data(emitted.messages[1].utf8)) as? [[String: Any]]
        )
        #expect(summaries.count == 1)
        #expect(summaries[0]["RepoTags"] as? [String] == ["docker/compose-bridge-kubernetes:latest"])
    }

    @Test("bridge transformations list preserves digest references")
    func bridgeTransformationsListPreservesDigestReferences() async throws {
        let emitted = MessageRecorder()
        let imageManager = RecordingContainerImageManager(transformers: [
            ComposeBridgeTransformer(
                id: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                reference: "docker/compose-bridge-kubernetes@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                details: ComposeBridgeTransformerDetails(
                    repoTags: [],
                    size: ComposeBridgeTransformerSize(sizeInBytes: 2048)
                )
            ),
        ])

        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            imageManager: imageManager
        )
        try await orchestrator.bridgeTransformationsList(options: ComposeBridgeTransformationsListOptions())
        try await orchestrator.bridgeTransformationsList(
            options: ComposeBridgeTransformationsListOptions(format: "json")
        )
        try await orchestrator.bridgeTransformationsList(
            options: ComposeBridgeTransformationsListOptions(quiet: true)
        )

        let row = try #require(emitted.messages.first?.split(whereSeparator: \.isNewline).last)
        #expect(row.split(whereSeparator: \.isWhitespace).map(String.init) == [
            "bbbbbbbbbbbb",
            "docker/compose-bridge-kubernetes",
            "<none>",
            "2.05kB",
        ])
        let summaries = try #require(
            JSONSerialization.jsonObject(with: Data(emitted.messages[1].utf8)) as? [[String: Any]]
        )
        #expect(summaries.first?["RepoTags"] as? [String] == [
            "docker/compose-bridge-kubernetes@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ])
        #expect(
            emitted.messages[2]
                == "docker/compose-bridge-kubernetes@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
    }

    @Test("bridge transformations create copies templates and writes Dockerfile")
    func bridgeTransformationsCreateCopiesTemplatesAndWritesDockerfile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("custom-transformer", isDirectory: true)
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: "created-transformer\n", stderr: ""),
            .success,
        ])
        let imageManager = RecordingContainerImageManager()
        let exporter = try RecordingContainerExporter(archiveData: bridgeTransformerArchiveData())
        let options = ComposeExecutionOptions(
            runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                oneOffIdentifier: { "abc123" },
                emit: { emitted.append($0) }
            )
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: options,
            dependencies: orchestratorDependencies {
                $0.exporter = exporter
                $0.imageManager = imageManager
            }
        ).bridgeTransformationsCreate(
            options: ComposeBridgeTransformationsCreateOptions(
                destination: destination.path,
                from: "example/bridge-transformer:latest"
            )
        )

        #expect(await imageManager.requests == [.pullMissing("example/bridge-transformer:latest")])
        #expect(runner.commands.map(\.arguments) == [
            ["container", "create", "--name", "compose-bridge-abc123", "example/bridge-transformer:latest"],
            ["container", "rm", "--force", "created-transformer"],
        ])
        #expect((await exporter.requests).map(\.id) == ["created-transformer"])
        #expect(
            try String(contentsOf: destination.appendingPathComponent("templates/service.tmpl"), encoding: .utf8)
                == "service template"
        )
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("etc/ignored").path))
        let dockerfile = try String(
            contentsOf: destination.appendingPathComponent("Dockerfile"),
            encoding: .utf8
        )
        #expect(dockerfile == """
        FROM docker/compose-bridge-transformer
        LABEL com.docker.compose.bridge=transformation
        COPY templates /templates
        """ + "\n")
        #expect(emitted.messages == ["Transformer created in \"\(destination.path)\""])
    }

    @Test("bridge transformations create removes the stopped container after export failure")
    func bridgeTransformationsCreateRemovesContainerAfterExportFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("custom-transformer", isDirectory: true)
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: "created-transformer\n", stderr: ""),
            .success,
        ])
        let exporter = RecordingContainerExporter(
            failure: .commandFailed(command: "container export", status: 1, stderr: "export failed")
        )
        let options = ComposeExecutionOptions(runtimeHooks: .init(oneOffIdentifier: { "abc123" }))

        await #expect(throws: ComposeError.self) {
            try await ComposeOrchestrator(
                runner: runner,
                options: options,
                dependencies: orchestratorDependencies { $0.exporter = exporter }
            ).bridgeTransformationsCreate(
                options: ComposeBridgeTransformationsCreateOptions(
                    destination: destination.path,
                    from: "example/bridge-transformer:latest"
                )
            )
        }

        #expect(runner.commands.map(\.arguments) == [
            ["container", "create", "--name", "compose-bridge-abc123", "example/bridge-transformer:latest"],
            ["container", "rm", "--force", "created-transformer"],
        ])
        #expect((await exporter.requests).map(\.id) == ["created-transformer"])
    }

    @Test("bridge transformations create does not remove a container after create failure")
    func bridgeTransformationsCreateDoesNotRemoveContainerAfterCreateFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("custom-transformer", isDirectory: true)
        let runner = RecordingRunner(responses: [
            CommandResult(status: 1, stdout: "", stderr: "name already exists"),
        ])
        let imageManager = RecordingContainerImageManager()
        let options = ComposeExecutionOptions(runtimeHooks: .init(oneOffIdentifier: { "abc123" }))

        await #expect(throws: ComposeError.self) {
            try await ComposeOrchestrator(
                runner: runner,
                options: options,
                dependencies: orchestratorDependencies { $0.imageManager = imageManager }
            ).bridgeTransformationsCreate(
                options: ComposeBridgeTransformationsCreateOptions(
                    destination: destination.path,
                    from: "example/bridge-transformer:latest"
                )
            )
        }

        #expect(runner.commands.map(\.arguments) == [
            ["container", "create", "--name", "compose-bridge-abc123", "example/bridge-transformer:latest"],
        ])
    }

    @Test("bridge transformations create dry-run describes export extraction")
    func bridgeTransformationsCreateDryRunDescribesExportExtraction() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let options = ComposeExecutionOptions(
            dryRun: true,
            runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                oneOffIdentifier: { "abc123" },
                emit: { emitted.append($0) }
            )
        )

        try await ComposeOrchestrator(runner: runner, options: options).bridgeTransformationsCreate(
            options: ComposeBridgeTransformationsCreateOptions(destination: "/tmp/custom-transformer")
        )

        #expect(runner.commands.isEmpty)
        #expect(emitted.messages.contains("+ container create --name compose-bridge-abc123 docker/compose-bridge-kubernetes"))
        #expect(emitted.messages.contains("+ compose-runtime export-rootfs compose-bridge-abc123 /tmp/compose-bridge-abc123.tar"))
        #expect(emitted.messages.contains("+ compose-runtime extract-archive --include templates /tmp/compose-bridge-abc123.tar /tmp/custom-transformer"))
        #expect(emitted.messages.contains("+ container rm --force compose-bridge-abc123"))
    }

    @Test("bridge convert accepts empty output without deleting the current directory")
    func bridgeConvertAcceptsEmptyOutputWithoutDeletingCurrentDirectory() async throws {
        let runner = BridgeInputInspectingRunner()
        let imageManager = RecordingContainerImageManager()
        let packageManifest = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Package.swift")

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).bridgeConvert(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposeBridgeConvertOptions(output: "", transformations: ["example/transformer"])
        )

        #expect(FileManager.default.fileExists(atPath: packageManifest.path))
        let mountedOutput = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL.path
        #expect(runner.commands.last?.arguments.contains("\(mountedOutput):/out") == true)
    }

    @Test("bridge convert rejects destructive output paths")
    func bridgeConvertRejectsDestructiveOutputPaths() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()

        await #expect(throws: ComposeError.self) {
            try await ComposeOrchestrator(runner: runner, imageManager: imageManager).bridgeConvert(
                project: ComposeProject(name: "demo", services: [:]),
                options: ComposeBridgeConvertOptions(output: "/", transformations: ["example/transformer"])
            )
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("bridge convert ignores an empty templates option")
    func bridgeConvertIgnoresEmptyTemplatesOption() async throws {
        let runner = BridgeInputInspectingRunner()
        let imageManager = RecordingContainerImageManager()

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).bridgeConvert(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposeBridgeConvertOptions(
                templates: "",
                transformations: ["example/transformer"]
            )
        )

        let arguments = try #require(runner.commands.last?.arguments)
        #expect(!arguments.contains(where: { $0.hasSuffix(":/templates") }))
    }

    @Test("bridge convert rejects output symlinks that resolve to the current directory")
    func bridgeConvertRejectsOutputSymlinkToCurrentDirectory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(
            at: output,
            withDestinationURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        )
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()

        await #expect(throws: ComposeError.self) {
            try await ComposeOrchestrator(runner: runner, imageManager: imageManager).bridgeConvert(
                project: ComposeProject(name: "demo", services: [:]),
                options: ComposeBridgeConvertOptions(output: output.path, transformations: ["example/transformer"])
            )
        }

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(runner.commands.isEmpty)
    }

    @Test("config rejects unsupported render formats")
    func configRejectsUnsupportedRenderFormats() throws {
        let project = ComposeProject(name: "demo", services: ["web": ComposeService(name: "web", image: "nginx")])

        do {
            _ = try ComposeOrchestrator().config(
                project: project,
                options: ComposeConfigOptions { $0.format = "toml" }
            )
            Issue.record("expected unsupported config format")
        } catch let error as ComposeError {
            #expect(error == .unsupported("config --format 'toml'; supported formats are yaml and json"))
        }
    }

    @Test("config unsupported format error uses command label")
    func configUnsupportedFormatErrorUsesCommandLabel() throws {
        let project = ComposeProject(name: "demo", services: ["web": ComposeService(name: "web", image: "nginx")])

        do {
            _ = try ComposeOrchestrator().config(
                project: project,
                options: ComposeConfigOptions {
                    $0.commandName = "convert"
                    $0.format = "toml"
                }
            )
            Issue.record("expected unsupported convert format")
        } catch let error as ComposeError {
            #expect(error == .unsupported("convert --format 'toml'; supported formats are yaml and json"))
        }
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
                    $0.deployLabels = ["com.example.service": "web"]
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
        #expect(decoded.services["web"]?.deployLabels == ["com.example.service": "web"])
        #expect(decoded.services["web"]?.extensions?["x-service"] == .object(["owner": .string("platform")]))
    }

    @Test("config renders supported projections")
    func configRendersSupportedProjections() throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.profiles = ["debug", "dev"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    $0.networks = ["front"]
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "./worker")
                },
            ]
        ) {
            $0.environment = ["BETA": "two", "ALPHA": "one"]
            $0.profiles = ["dev", "debug", "dev"]
            $0.networks = ["front": ComposeNetwork(name: "front"), "back": ComposeNetwork(name: "back")]
            $0.volumes = ["cache": ComposeVolume(name: "cache"), "unused": ComposeVolume(name: "unused")]
            $0.models = ["llm": .object(["model": .string("example/local-llm")])]
        }
        let orchestrator = ComposeOrchestrator()

        #expect(try orchestrator.config(project: project).contains("ALPHA") == false)
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions { $0.environment = true }) == "ALPHA=one\nBETA=two")
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions { $0.servicesOnly = true }) == "api\nworker")
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions {
            $0.servicesOnly = true
            $0.services = ["missing"]
        }) == "api\nworker")
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions { $0.images = true }) == "demo_worker:latest\nexample/api")
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions { $0.networks = true }) == "back\nfront")
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions { $0.profiles = true }) == "debug\ndev")
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions {
            $0.variables = [
                ComposeVariable(name: "IMAGE_NAME", defaultValue: "alpine"),
                ComposeVariable(name: "OPTIONAL", alternateValue: "enabled"),
                ComposeVariable(name: "REQUIRED", required: true),
            ]
        }) == """
        NAME        REQUIRED  DEFAULT VALUE  ALTERNATE VALUE
        IMAGE_NAME  false     alpine
        OPTIONAL    false                    enabled
        REQUIRED    true
        """)
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions { $0.volumes = true }) == "cache\nunused")
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions { $0.models = true }) == "llm")
        #expect(try orchestrator.config(project: project, options: ComposeConfigOptions { $0.quiet = true }) == "")
    }

    @Test("config filters selected services")
    func configFiltersSelectedServices() throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    $0.networks = ["front"]
                    $0.configs = [.object(["source": .string("app_config")])]
                    $0.secrets = [.object(["source": .string("app_secret")])]
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.networks = ["back"]
                    $0.configs = [.object(["source": .string("worker_config")])]
                    $0.secrets = [.object(["source": .string("worker_secret")])]
                },
            ]
        ) {
            $0.networks = ["front": ComposeNetwork(name: "front"), "back": ComposeNetwork(name: "back")]
            $0.volumes = ["cache": ComposeVolume(name: "cache"), "unused": ComposeVolume(name: "unused")]
            $0.configs = [
                "app_config": .object(["external": .bool(true)]),
                "worker_config": .object(["external": .bool(true)]),
            ]
            $0.secrets = [
                "app_secret": .object(["external": .bool(true)]),
                "worker_secret": .object(["external": .bool(true)]),
            ]
        }

        let json = try ComposeOrchestrator().config(
            project: project,
            options: ComposeConfigOptions {
                $0.services = ["api"]
                $0.format = "json"
            }
        )
        let decoded = try JSONDecoder().decode(ComposeProject.self, from: Data(json.utf8))

        #expect(decoded.services.keys.sorted() == ["api"])
        #expect(decoded.networks.keys.sorted() == ["front"])
        #expect(decoded.volumes.keys.sorted() == ["cache"])
        #expect(decoded.configs?.keys.sorted() == ["app_config"])
        #expect(decoded.secrets?.keys.sorted() == ["app_secret"])
    }

    @Test("config all resources keeps unselected top level resources")
    func configAllResourcesKeepsUnselectedTopLevelResources() throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    $0.networks = ["front"]
                    $0.configs = [.object(["source": .string("app_config")])]
                    $0.secrets = [.object(["source": .string("app_secret")])]
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.networks = ["back"]
                    $0.volumes = [ComposeMount(type: "volume", source: "unused", target: "/unused")]
                    $0.configs = [.object(["source": .string("worker_config")])]
                    $0.secrets = [.object(["source": .string("worker_secret")])]
                },
            ]
        ) {
            $0.networks = ["front": ComposeNetwork(name: "front"), "back": ComposeNetwork(name: "back")]
            $0.volumes = ["cache": ComposeVolume(name: "cache"), "unused": ComposeVolume(name: "unused")]
            $0.configs = [
                "app_config": .object(["external": .bool(true)]),
                "worker_config": .object(["external": .bool(true)]),
            ]
            $0.secrets = [
                "app_secret": .object(["external": .bool(true)]),
                "worker_secret": .object(["external": .bool(true)]),
            ]
        }

        let json = try ComposeOrchestrator().config(
            project: project,
            options: ComposeConfigOptions {
                $0.services = ["api"]
                $0.allResources = true
                $0.format = "json"
            }
        )
        let decoded = try JSONDecoder().decode(ComposeProject.self, from: Data(json.utf8))

        #expect(decoded.services.keys.sorted() == ["api"])
        #expect(decoded.networks.keys.sorted() == ["back", "front"])
        #expect(decoded.volumes.keys.sorted() == ["cache", "unused"])
        #expect(decoded.configs?.keys.sorted() == ["app_config", "worker_config"])
        #expect(decoded.secrets?.keys.sorted() == ["app_secret", "worker_secret"])
    }

    @Test("config renders service hashes")
    func configRendersServiceHashes() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        let output = try ComposeOrchestrator().config(
            project: project,
            options: ComposeConfigOptions { $0.hash = "*" }
        )
        let lines = output.split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.range(of: #"^(api|worker) [0-9a-f]{64}$"#, options: .regularExpression) != nil })
    }

    @Test("config resolve image digests pins selected service images")
    func configResolveImageDigestsPinsSelectedServiceImages() async throws {
        let imageManager = RecordingContainerImageManager(digests: [
            "example/api:latest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker:2"),
            ]
        )

        let json = try await ComposeOrchestrator(imageManager: imageManager).config(
            project: project,
            resolvingImageDigests: ComposeConfigOptions {
                $0.services = ["api"]
                $0.format = "json"
                $0.resolveImageDigests = true
            }
        )
        let decoded = try JSONDecoder().decode(ComposeProject.self, from: Data(json.utf8))

        #expect(decoded.services.keys.sorted() == ["api"])
        #expect(decoded.services["api"]?.image == "example/api:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(await imageManager.requests == [.digest("example/api:latest")])
    }

    @Test("config lock image digests renders override file")
    func configLockImageDigestsRendersOverrideFile() async throws {
        let imageManager = RecordingContainerImageManager(digests: [
            "example/api:latest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "example/worker:2": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "pinned": ComposeService(name: "pinned", image: "example/pinned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
                "worker": ComposeService(name: "worker", image: "example/worker:2"),
            ]
        )

        let yaml = try await ComposeOrchestrator(imageManager: imageManager).config(
            project: project,
            resolvingImageDigests: ComposeConfigOptions {
                $0.lockImageDigests = true
            }
        )

        #expect(yaml == """
        services:
          api:
            image: "example/api:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          pinned:
            image: "example/pinned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
          worker:
            image: "example/worker:2@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        """)
        #expect(await imageManager.requests == [
            .digest("example/api:latest"),
            .digest("example/worker:2"),
        ])
    }

    @Test("config resolve image digests skips non image projections")
    func configResolveImageDigestsSkipsNonImageProjections() async throws {
        let imageManager = RecordingContainerImageManager()
        var project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )
        project.environment = ["ALPHA": "one"]

        let output = try await ComposeOrchestrator(imageManager: imageManager).config(
            project: project,
            resolvingImageDigests: ComposeConfigOptions {
                $0.environment = true
                $0.resolveImageDigests = true
            }
        )

        #expect(output == "ALPHA=one")
        #expect(await imageManager.requests.isEmpty)
    }

    @Test("service init key maps to initEnabled")
    func serviceInitKeyMapsToInitEnabled() throws {
        let decoded = try JSONDecoder().decode(ComposeService.self, from: Data(#"{"name":"web","init":true}"#.utf8))

        #expect(decoded.initEnabled == true)

        let encoded = try String(decoding: JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(encoded.contains(#""init":true"#))
        #expect(!encoded.contains("initEnabled"))
    }

}
