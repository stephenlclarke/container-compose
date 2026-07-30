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

@Suite("Compose orchestrator")
struct ComposeOrchestratorTests {
    @Test("dependency groups preserve individually configured collaborators")
    func dependencyGroupsPreserveIndividuallyConfiguredCollaborators() {
        let copier = RecordingContainerCopier()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let eventsManager = RecordingContainerEventsManager()
        let execManager = RecordingContainerExecManager()
        let exporter = RecordingContainerExporter()
        let imageManager = RecordingContainerImageManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager()
        let upMenuController = RecordingComposeUpMenuController()
        let resourceManager = RecordingContainerResourceManager()
        let statsManager = RecordingContainerStatsManager()
        let topManager = RecordingContainerTopManager()
        var dependencies = ComposeOrchestratorDependencies(
            commands: ComposeOrchestratorCommandDependencies(
                copier: copier,
                execManager: execManager,
                exporter: exporter,
                logManager: logManager,
                upMenuController: upMenuController
            ),
            runtime: ComposeOrchestratorRuntimeDependencies(
                services: .init(
                    eventsManager: eventsManager,
                    lifecycleManager: lifecycleManager,
                    resourceManager: resourceManager
                ),
                discoveryManager: discoveryManager,
                inspection: .init(
                    statsManager: statsManager,
                    topManager: topManager
                )
            ),
            imageManager: imageManager
        )

        expectSameInstance(dependencies.copier, copier, "copier")
        expectSameInstance(dependencies.discoveryManager, discoveryManager, "discoveryManager")
        expectSameInstance(dependencies.eventsManager, eventsManager, "eventsManager")
        expectSameInstance(dependencies.execManager, execManager, "execManager")
        expectSameInstance(dependencies.exporter, exporter, "exporter")
        expectSameInstance(dependencies.imageManager, imageManager, "imageManager")
        expectSameInstance(dependencies.lifecycleManager, lifecycleManager, "lifecycleManager")
        expectSameInstance(dependencies.logManager, logManager, "logManager")
        expectSameInstance(dependencies.upMenuController, upMenuController, "upMenuController")
        expectSameInstance(dependencies.resourceManager, resourceManager, "resourceManager")
        expectSameInstance(dependencies.statsManager, statsManager, "statsManager")
        expectSameInstance(dependencies.topManager, topManager, "topManager")

        let replacementLogManager = RecordingContainerLogManager()
        dependencies.logManager = replacementLogManager
        expectSameInstance(dependencies.commands.logManager, replacementLogManager, "commands.logManager")
        let replacementUpMenuController = RecordingComposeUpMenuController()
        dependencies.upMenuController = replacementUpMenuController
        expectSameInstance(dependencies.commands.upMenuController, replacementUpMenuController, "commands.upMenuController")
    }

    @Test("orders selected services after dependencies")
    func ordersSelectedServicesAfterDependencies() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres:16"),
                "web": composeService(name: "web", image: "nginx:latest") {
                    $0.dependsOn = ["api": ComposeDependency(condition: "service_started")]
                },
            ]
        )

        let ordered = try ComposeOrchestrator().orderedServices(project: project, selected: ["web"])

        #expect(ordered.map(\.name) == ["db", "api", "web"])
    }

    @Test("orders map-form dependencies before dependents")
    func ordersMapFormDependenciesBeforeDependents() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "web": composeService(name: "web", image: "example/web:latest") {
                    $0.dependsOn = [
                        "api": ComposeDependency(condition: "service_healthy", restart: true),
                        "cache": ComposeDependency(condition: "service_started"),
                    ]
                },
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_completed_successfully")]
                },
                "db": ComposeService(name: "db", image: "postgres:16"),
                "cache": ComposeService(name: "cache", image: "redis:7"),
            ]
        )

        let ordered = try ComposeOrchestrator().orderedServices(project: project, selected: ["web"])

        #expect(ordered.map(\.name) == ["db", "api", "cache", "web"])
    }

    @Test("orders present optional dependencies and skips missing optional dependencies")
    func ordersPresentOptionalDependenciesAndSkipsMissingOptionalDependencies() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = [
                        "cache": ComposeDependency(condition: "service_started", required: false),
                        "metrics": ComposeDependency(condition: "service_started", required: false),
                    ]
                },
                "cache": ComposeService(name: "cache", image: "redis:7"),
            ]
        )

        let ordered = try ComposeOrchestrator().orderedServices(project: project, selected: ["api"])

        #expect(ordered.map(\.name) == ["cache", "api"])
    }

    @Test("detects dependency cycles")
    func detectsDependencyCycles() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["worker": ComposeDependency(condition: "service_started")]
                },
                "worker": composeService(name: "worker", image: "example/worker:latest") {
                    $0.dependsOn = ["api": ComposeDependency(condition: "service_started")]
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

    @Test("compatibility mode uses legacy underscore container names")
    func compatibilityModeUsesLegacyUnderscoreContainerNames() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(options: ComposeExecutionOptions(
            dryRun: true,
            serviceContainerNameSeparator: "_",
            runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                oneOffIdentifier: { "abc123" },
                emit: { emitted.append($0) }
            )
        ))
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.scale = 2
                },
                "job": composeService(name: "job", image: "alpine"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.noStart = true
        })
        try await orchestrator.run(project: project, serviceName: "job", options: ComposeRunOptions {
            $0.command = ["true"]
            $0.noDeps = true
            $0.noTty = true
        })

        let output = emitted.messages.joined(separator: "\n")
        #expect(output.contains("--name demo_api_1"))
        #expect(output.contains("--name demo_api_2"))
        #expect(output.contains("--name demo_job_run_abc123"))
        #expect(!output.contains("--name demo-api-1"))
    }

}
