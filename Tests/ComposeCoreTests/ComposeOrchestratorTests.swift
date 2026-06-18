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
import ContainerResource
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
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

private func projectWithBackendNetwork(serviceName: String, image: String) -> ComposeProject {
    composeProject(
        name: "demo",
        services: [
            serviceName: composeService(name: serviceName, image: image) {
                $0.networks = ["backend"]
            },
        ]
    ) {
        $0.networks = ["backend": ComposeNetwork(name: "backend")]
    }
}

private func projectWithCacheVolume(serviceName: String, image: String) -> ComposeProject {
    composeProject(
        name: "demo",
        services: [
            serviceName: composeService(name: serviceName, image: image) {
                $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
            },
        ]
    ) {
        $0.volumes = ["cache": ComposeVolume(name: "cache")]
    }
}

private func composeProjectWithInheritedVolume(target: String) -> ComposeProject {
    composeProject(
        name: "demo",
        services: [
            "base": composeService(name: "base", image: "example/base") {
                $0.volumes = [ComposeMount(type: "volume", source: "data", target: target)]
            },
            "worker": composeService(name: "worker", image: "example/worker") {
                $0.volumesFrom = ["base"]
            },
        ]
    ) {
        $0.volumes = ["data": ComposeVolume(name: "data")]
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class InlineDockerfileRunner: CommandRunning, @unchecked Sendable {
    private(set) var commands: [[String]] = []
    private(set) var dockerfileContents: [String] = []

    func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        io: CommandIO
    ) async throws -> CommandResult {
        _ = executable
        _ = workingDirectory
        _ = environment
        _ = io
        commands.append(arguments)
        if let fileIndex = arguments.firstIndex(of: "--file"),
           arguments.indices.contains(fileIndex + 1) {
            let dockerfileURL = URL(fileURLWithPath: arguments[fileIndex + 1])
            if FileManager.default.fileExists(atPath: dockerfileURL.path) {
                dockerfileContents.append(try String(contentsOf: dockerfileURL, encoding: .utf8))
            }
        }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

private func orchestratorDependencies(
    configure: (inout ComposeOrchestratorDependencies) -> Void
) -> ComposeOrchestratorDependencies {
    var dependencies = ComposeOrchestratorDependencies()
    dependencies.copier = RecordingContainerCopier()
    dependencies.discoveryManager = RecordingContainerDiscoveryManager()
    dependencies.execManager = RecordingContainerExecManager()
    dependencies.exporter = RecordingContainerExporter()
    dependencies.imageManager = RecordingContainerImageManager()
    dependencies.lifecycleManager = RecordingContainerLifecycleManager()
    dependencies.logManager = RecordingContainerLogManager()
    dependencies.pullMetadataStore = RecordingPullMetadataStore()
    dependencies.resourceManager = RecordingContainerResourceManager()
    dependencies.statsManager = RecordingContainerStatsManager()
    configure(&dependencies)
    return dependencies
}

private func expectSameInstance<T: AnyObject>(_ actual: Any, _ expected: T, _ name: String) {
    guard let actual = actual as? T else {
        Issue.record("Expected \(name) to use \(T.self)")
        return
    }
    #expect(actual === expected)
}

private extension ComposeOrchestrator {
    convenience init(imageManager: ContainerImageManaging) {
        self.init(dependencies: orchestratorDependencies { $0.imageManager = imageManager })
    }

    convenience init(runner: CommandRunning, copier: ContainerCopying) {
        self.init(runner: runner, dependencies: orchestratorDependencies { $0.copier = copier })
    }

    convenience init(runner: CommandRunning, discoveryManager: ContainerDiscoveryManaging) {
        self.init(runner: runner, dependencies: orchestratorDependencies { $0.discoveryManager = discoveryManager })
    }

    convenience init(runner: CommandRunning, execManager: ContainerExecManaging) {
        self.init(runner: runner, dependencies: orchestratorDependencies { $0.execManager = execManager })
    }

    convenience init(runner: CommandRunning, exporter: ContainerExporting) {
        self.init(runner: runner, dependencies: orchestratorDependencies { $0.exporter = exporter })
    }

    convenience init(runner: CommandRunning, imageManager: ContainerImageManaging) {
        self.init(runner: runner, dependencies: orchestratorDependencies { $0.imageManager = imageManager })
    }

    convenience init(runner: CommandRunning, lifecycleManager: ContainerLifecycleManaging) {
        self.init(runner: runner, dependencies: orchestratorDependencies { $0.lifecycleManager = lifecycleManager })
    }

    convenience init(runner: CommandRunning, resourceManager: ContainerResourceManaging) {
        self.init(runner: runner, dependencies: orchestratorDependencies { $0.resourceManager = resourceManager })
    }

    convenience init(
        runner: CommandRunning,
        discoveryManager: ContainerDiscoveryManaging,
        imageManager: ContainerImageManaging
    ) {
        self.init(runner: runner, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.imageManager = imageManager
        })
    }

    convenience init(
        runner: CommandRunning,
        discoveryManager: ContainerDiscoveryManaging,
        lifecycleManager: ContainerLifecycleManaging
    ) {
        self.init(runner: runner, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.lifecycleManager = lifecycleManager
        })
    }

    convenience init(
        runner: CommandRunning,
        discoveryManager: ContainerDiscoveryManaging,
        resourceManager: ContainerResourceManaging
    ) {
        self.init(runner: runner, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.resourceManager = resourceManager
        })
    }

    convenience init(
        runner: CommandRunning,
        imageManager: ContainerImageManaging,
        lifecycleManager: ContainerLifecycleManaging
    ) {
        self.init(runner: runner, dependencies: orchestratorDependencies {
            $0.imageManager = imageManager
            $0.lifecycleManager = lifecycleManager
        })
    }

    convenience init(
        runner: CommandRunning,
        imageManager: ContainerImageManaging,
        resourceManager: ContainerResourceManaging
    ) {
        self.init(runner: runner, dependencies: orchestratorDependencies {
            $0.imageManager = imageManager
            $0.resourceManager = resourceManager
        })
    }

    convenience init(
        runner: CommandRunning,
        lifecycleManager: ContainerLifecycleManaging,
        resourceManager: ContainerResourceManaging
    ) {
        self.init(runner: runner, dependencies: orchestratorDependencies {
            $0.lifecycleManager = lifecycleManager
            $0.resourceManager = resourceManager
        })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        copier: ContainerCopying
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.copier = copier })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        discoveryManager: ContainerDiscoveryManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.discoveryManager = discoveryManager })
    }

    convenience init(options: ComposeExecutionOptions, discoveryManager: ContainerDiscoveryManaging) {
        self.init(options: options, dependencies: orchestratorDependencies { $0.discoveryManager = discoveryManager })
    }

    convenience init(discoveryManager: ContainerDiscoveryManaging) {
        self.init(dependencies: orchestratorDependencies { $0.discoveryManager = discoveryManager })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        execManager: ContainerExecManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.execManager = execManager })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        exporter: ContainerExporting
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.exporter = exporter })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        imageManager: ContainerImageManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.imageManager = imageManager })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        lifecycleManager: ContainerLifecycleManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.lifecycleManager = lifecycleManager })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        logManager: ContainerLogManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.logManager = logManager })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        resourceManager: ContainerResourceManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.resourceManager = resourceManager })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        statsManager: ContainerStatsManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.statsManager = statsManager })
    }

    convenience init(
        runner: CommandRunning,
        discoveryManager: ContainerDiscoveryManaging,
        lifecycleManager: ContainerLifecycleManaging,
        resourceManager: ContainerResourceManaging
    ) {
        self.init(runner: runner, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.lifecycleManager = lifecycleManager
            $0.resourceManager = resourceManager
        })
    }

    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        imageManager: ContainerImageManaging,
        lifecycleManager: ContainerLifecycleManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies {
            $0.imageManager = imageManager
            $0.lifecycleManager = lifecycleManager
        })
    }

    convenience init(
        runner: CommandRunning,
        copier: ContainerCopying,
        execManager: ContainerExecManaging,
        lifecycleManager: ContainerLifecycleManaging,
        logManager: ContainerLogManaging
    ) {
        self.init(runner: runner, dependencies: orchestratorDependencies {
            $0.copier = copier
            $0.execManager = execManager
            $0.lifecycleManager = lifecycleManager
            $0.logManager = logManager
        })
    }
}

@Suite("Compose orchestrator")
struct ComposeOrchestratorTests {
    @Test("dependency groups preserve individually configured collaborators")
    func dependencyGroupsPreserveIndividuallyConfiguredCollaborators() {
        let copier = RecordingContainerCopier()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let execManager = RecordingContainerExecManager()
        let exporter = RecordingContainerExporter()
        let imageManager = RecordingContainerImageManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager()
        let resourceManager = RecordingContainerResourceManager()
        let statsManager = RecordingContainerStatsManager()
        var dependencies = ComposeOrchestratorDependencies(
            commands: ComposeOrchestratorCommandDependencies(
                copier: copier,
                execManager: execManager,
                exporter: exporter,
                logManager: logManager
            ),
            runtime: ComposeOrchestratorRuntimeDependencies(
                discoveryManager: discoveryManager,
                lifecycleManager: lifecycleManager,
                resourceManager: resourceManager,
                statsManager: statsManager
            ),
            imageManager: imageManager
        )

        expectSameInstance(dependencies.copier, copier, "copier")
        expectSameInstance(dependencies.discoveryManager, discoveryManager, "discoveryManager")
        expectSameInstance(dependencies.execManager, execManager, "execManager")
        expectSameInstance(dependencies.exporter, exporter, "exporter")
        expectSameInstance(dependencies.imageManager, imageManager, "imageManager")
        expectSameInstance(dependencies.lifecycleManager, lifecycleManager, "lifecycleManager")
        expectSameInstance(dependencies.logManager, logManager, "logManager")
        expectSameInstance(dependencies.resourceManager, resourceManager, "resourceManager")
        expectSameInstance(dependencies.statsManager, statsManager, "statsManager")

        let replacementLogManager = RecordingContainerLogManager()
        dependencies.logManager = replacementLogManager
        expectSameInstance(dependencies.commands.logManager, replacementLogManager, "commands.logManager")
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

    @Test("up creates resources and runs services with compose labels")
    func upCreatesResourcesAndRunsServicesWithComposeLabels() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        )
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
                    $0.deployLabels = ["com.example.service": "api"]
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
        #expect(await discoveryManager.getRequests == ["demo-api-1"])

        let resources = await resourceManager.requests
        #expect(resources.count == 2)
        if case .createNetwork(let request) = resources[0] {
            #expect(request.name == "demo_default")
            #expect(request.isInternal == false)
            #expect(request.ipv4Subnet == nil)
            #expect(request.ipv6Subnet == nil)
            #expect(request.labels["com.apple.container.compose.project.working-directory"] == "/tmp/demo")
            #expect(request.labels["com.apple.container.compose.project.config-files-hash"] != nil)
        } else {
            Issue.record("Expected network creation through direct API")
        }
        if case .createVolume(let request) = resources[1] {
            #expect(request.name == "demo_cache")
            #expect(request.driver == nil)
            #expect(request.driverOpts == [:])
            #expect(request.labels["com.apple.container.compose.project.working-directory"] == "/tmp/demo")
            #expect(request.labels["com.apple.container.compose.project.config-files-hash"] != nil)
        } else {
            Issue.record("Expected volume creation through direct API")
        }

        let run = runner.commands[0].arguments
        #expect(run.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!run.contains("--detach"))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.project.working-directory=/tmp/demo"]))
        #expect(run.containsLabel(withPrefix: "com.apple.container.compose.project.config-files-hash="))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.oneoff=false"]))
        #expect(run.containsSequence(["--label", "com.example.role=api"]))
        #expect(!run.containsSequence(["--label", "com.example.service=api"]))
        #expect(run.containsSequence(["--env", "LOG_LEVEL=debug"]))
        #expect(run.containsSequence(["--publish", "8080:80"]))
        #expect(run.containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(run.containsSequence(["--network", "demo_default"]))
        #expect(run.containsSequence(["--platform", "linux/amd64"]))
        #expect(Array(run.suffix(2)) == ["example/api:latest", "serve"])
    }

    @Test("up creates volume driver options through direct API")
    func upCreatesVolumeDriverOptionsThroughDirectAPI() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = [
                "cache": ComposeVolume(
                    name: "cache",
                    driver: "local",
                    driverOpts: [
                        "journal": "ordered",
                        "size": "64m",
                    ],
                    labels: ["com.example.volume": "cache"]
                ),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let requests = await resourceManager.requests
        let request = try #require(requests.compactMap { event -> ComposeVolumeCreateRequest? in
            if case .createVolume(let request) = event {
                return request
            }
            return nil
        }.first)
        #expect(request.name == "demo_cache")
        #expect(request.driver == "local")
        #expect(request.resolvedDriver == "local")
        #expect(request.driverOpts == [
            "journal": "ordered",
            "size": "64m",
        ])
        #expect(request.labels["com.apple.container.compose.project"] == "demo")
        #expect(request.labels["com.apple.container.compose.project.config-files-hash"] != nil)
        #expect(request.labels["com.example.volume"] == "cache")
    }

    @Test("up dry run renders volume driver options")
    func upDryRunRendersVolumeDriverOptions() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = [
                "cache": ComposeVolume(
                    name: "cache",
                    driver: "local",
                    driverOpts: [
                        "journal": "ordered",
                        "size": "64m",
                    ]
                ),
            ]
        }

        try await ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }))
            .up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages.contains { message in
            message.contains("container volume create --opt journal=ordered --opt size=64m")
        })
    }

    @Test("up creates internal IPAM networks through direct API")
    func upCreatesInternalIPAMNetworksThroughDirectAPI() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    isInternal: true,
                    labels: ["com.example.network": "backend"],
                    subnets: ComposeNetwork.Subnets(
                        ipv4Subnet: "10.77.0.0/24",
                        ipv6Subnet: "fd77::/64"
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let resources = await resourceManager.requests
        #expect(resources.count == 1)
        if case .createNetwork(let request) = resources[0] {
            #expect(request.name == "demo_backend")
            #expect(request.isInternal == true)
            #expect(request.ipv4Subnet == "10.77.0.0/24")
            #expect(request.ipv6Subnet == "fd77::/64")
            #expect(request.labels["com.apple.container.compose.project"] == "demo")
            #expect(request.labels["com.apple.container.compose.project.config-files-hash"] != nil)
            #expect(request.labels["com.example.network"] == "backend")
        } else {
            Issue.record("Expected network creation through direct API")
        }
        #expect(runner.commands.map(\.arguments)[0].containsSequence(["--network", "demo_backend"]))
    }

    @Test("up dry run renders internal IPAM network create")
    func upDryRunRendersInternalIPAMNetworkCreate() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    isInternal: true,
                    subnets: ComposeNetwork.Subnets(
                        ipv4Subnet: "10.77.0.0/24",
                        ipv6Subnet: "fd77::/64"
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }))
            .up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages.contains { message in
            message.contains("container network create --internal --subnet 10.77.0.0/24 --subnet-v6 fd77::/64")
        })
    }

    @Test("up rejects unsupported project network IPAM before side effects")
    func upRejectsUnsupportedProjectNetworkIPAMBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    unsupportedFields: ["ipam.config.gateway"]
                ),
            ]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported project network IPAM error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("network 'backend' uses unsupported fields ipam.config.gateway; only internal and one IPv4/IPv6 IPAM subnet are mapped to apple/container networks"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up surfaces network create failures before starting containers")
    func upSurfacesNetworkCreateFailuresBeforeStartingContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            networkCreateError: ComposeError.invalidProject("network create failed")
        )
        let project = projectWithBackendNetwork(serviceName: "api", image: "example/api")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected network create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("network create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
    }

    @Test("up surfaces volume create failures before starting containers")
    func upSurfacesVolumeCreateFailuresBeforeStartingContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            volumeCreateError: ComposeError.invalidProject("volume create failed")
        )
        let project = projectWithCacheVolume(serviceName: "api", image: "example/api")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected volume create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("volume create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_cache"])
    }

    @Test("up maps network mode none to no network attachment")
    func upMapsNetworkModeNoneToNoNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networkMode = "none"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "none"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up starts present optional dependencies in dependency order")
    func upStartsPresentOptionalDependenciesInDependencyOrder() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["optional": ComposeDependency(condition: "service_started", required: false)]
                },
                "optional": ComposeService(name: "optional", image: "example/optional:latest"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-optional-1"]))
        #expect(commands[0].contains("--detach"))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!commands[1].contains("--detach"))
        #expect(await discoveryManager.getRequests == ["demo-optional-1", "demo-api-1"])
    }

    @Test("up skips missing optional dependencies")
    func upSkipsMissingOptionalDependencies() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["optional": ComposeDependency(condition: "service_healthy", required: false)]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-optional-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("create creates resources and service containers without starting them")
    func createCreatesResourcesAndServiceContainersWithoutStartingThem() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
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
                    $0.dnsOptions = ["use-vc"]
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).create(project: project, options: ComposeCreateOptions())

        let commands = runner.commands.map(\.arguments)
        let resources = await resourceManager.requests
        #expect(resources.count == 2)
        #expect(resources.map(\.name) == ["demo_default", "demo_cache"])
        #expect(resources.allSatisfy { $0.labels["com.apple.container.compose.project"] == "demo" })
        #expect(resources.allSatisfy { $0.labels["com.apple.container.compose.project.config-files-hash"]?.count == 64 })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])

        let create = commands[0]
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
        #expect(create.containsSequence(["--dns-option", "use-vc"]))
        #expect(Array(create.suffix(2)) == ["example/api:latest", "serve"])
    }

    @Test("create surfaces network create failures before creating containers")
    func createSurfacesNetworkCreateFailuresBeforeCreatingContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            networkCreateError: ComposeError.invalidProject("network create failed")
        )
        let project = projectWithBackendNetwork(serviceName: "api", image: "example/api")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .create(project: project, options: ComposeCreateOptions())
            Issue.record("Expected network create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("network create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
    }

    @Test("create surfaces volume create failures before creating containers")
    func createSurfacesVolumeCreateFailuresBeforeCreatingContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            volumeCreateError: ComposeError.invalidProject("volume create failed")
        )
        let project = projectWithCacheVolume(serviceName: "api", image: "example/api")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .create(project: project, options: ComposeCreateOptions())
            Issue.record("Expected volume create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("volume create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_cache"])
    }

    @Test("create maps network mode none to no network attachment")
    func createMapsNetworkModeNoneToNoNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networkMode = "none"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--network", "none"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("create skips missing optional dependencies")
    func createSkipsMissingOptionalDependencies() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["optional": ComposeDependency(condition: "service_healthy", required: false)]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-optional-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("create applies build pull policy before creating containers")
    func createAppliesBuildPullPolicyBeforeCreatingContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
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

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
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
        #expect(commands[2].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[3].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-worker-1"])
    }

    @Test("create applies service build pull policy before creating containers")
    func createAppliesServiceBuildPullPolicyBeforeCreatingContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                    $0.pullPolicy = "build"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions()
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/api"]))
        #expect(commands[0].last == "api")
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("create pull if not present pulls only absent images")
    func createPullIfNotPresentPullsOnlyAbsentImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.pullPolicy = "if_not_present"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(await imageManager.requests == [
            .pullMissing("example/api"),
            .pullMissing("postgres"),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-db-1"])
    }

    @Test("create quiet-pull dry run disables pull progress")
    func createQuietPullDryRunDisablesPullProgress() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "alpine")]
        )

        try await orchestrator.create(
            project: project,
            options: ComposeCreateOptions {
                $0.pullPolicy = "always"
                $0.quietPull = true
            }
        )

        let messages = emitted.messages
        #expect(messages.contains("+ container image pull --progress none alpine"))
        #expect(messages.contains { $0.hasPrefix("+ container create ") })
    }

    @Test("create auto builds build-only services by default")
    func createAutoBuildsBuildOnlyServicesByDefault() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(project: project, options: ComposeCreateOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "demo_worker:latest"]))
        #expect(commands[0].last == "worker")
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("create no-build skips auto build for build-only service")
    func createNoBuildSkipsAutoBuildForBuildOnlyService() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.noBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(!commands.contains { $0.containsSequence(["container", "build"]) })
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(commands[0].last == "demo_worker:latest")
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("create reuses or recreates existing containers according to policy")
    func createReusesOrRecreatesExistingContainersAccordingToPolicy() async throws {
        let emitted = MessageRecorder()
        let reuseRunner = RecordingRunner()
        let reuseDiscovery = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running"),
        ])
        try await ComposeOrchestrator(
            runner: reuseRunner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: reuseDiscovery
        )
        .create(
            project: ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")]),
            options: ComposeCreateOptions {
                $0.noRecreate = true
            }
        )

        #expect(reuseRunner.commands.isEmpty)
        #expect(await reuseDiscovery.getRequests == ["demo-api-1"])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])

        let recreateRunner = RecordingRunner(responses: [
            .success,
        ])
        let recreateDiscovery = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: "stale"]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: recreateRunner,
            discoveryManager: recreateDiscovery,
            lifecycleManager: lifecycleManager
        ).create(project: project, options: ComposeCreateOptions())

        #expect(recreateRunner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await recreateDiscovery.getRequests == ["demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("create validates incompatible options and invalid scale before side effects")
    func createValidatesIncompatibleOptionsAndInvalidScaleBeforeSideEffects() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        let incompatibleOptionCases: [(options: ComposeCreateOptions, message: String)] = [
            (
                ComposeCreateOptions {
                    $0.build = true
                    $0.noBuild = true
                },
                "--build and --no-build are incompatible"
            ),
            (
                ComposeCreateOptions {
                    $0.forceRecreate = true
                    $0.noRecreate = true
                },
                "--force-recreate and --no-recreate are incompatible"
            ),
        ]

        for testCase in incompatibleOptionCases {
            let runner = RecordingRunner()
            do {
                try await ComposeOrchestrator(runner: runner).create(project: project, options: testCase.options)
                Issue.record("Expected invalid create option combination")
            } catch let error as ComposeError {
                #expect(error == .invalidProject(testCase.message))
            }
            #expect(runner.commands.isEmpty)
        }

        let scaleRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: scaleRunner).create(
                project: project,
                options: ComposeCreateOptions {
                    $0.scales = ["api=two"]
                }
            )
            Issue.record("Expected invalid create scale failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--scale for service 'api' must be a non-negative integer"))
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

    @Test("create rejects dynamic published ports before side effects")
    func createRejectsDynamicPublishedPortsBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["80"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).create(project: project, options: ComposeCreateOptions())
            Issue.record("Expected unsupported dynamic port failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' publishes target port 80/tcp dynamically; apple/container publish requires explicit host ports"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up validates incompatible build options before side effects")
    func upValidatesIncompatibleBuildOptionsBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.build = true
                    $0.noBuild = true
                }
            )
            Issue.record("Expected invalid up build option combination")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--build and --no-build are incompatible"))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up validates incompatible recreate options before side effects")
    func upValidatesIncompatibleRecreateOptionsBeforeSideEffects() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])
        let incompatibleOptionCases: [(options: ComposeUpOptions, message: String)] = [
            (
                ComposeUpOptions {
                    $0.forceRecreate = true
                    $0.noRecreate = true
                },
                "--force-recreate and --no-recreate are incompatible"
            ),
            (
                ComposeUpOptions {
                    $0.alwaysRecreateDeps = true
                    $0.noRecreate = true
                },
                "--always-recreate-deps and --no-recreate are incompatible"
            ),
        ]

        for testCase in incompatibleOptionCases {
            let runner = RecordingRunner()
            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: testCase.options)
                Issue.record("Expected invalid up option combination")
            } catch let error as ComposeError {
                #expect(error == .invalidProject(testCase.message))
            }
            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up creates scaled service replicas")
    func upCreatesScaledServiceReplicas() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!commands[0].contains("--detach"))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-2", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("create creates scaled service replicas")
    func createCreatesScaledServiceReplicas() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-2"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("up allocates published port ranges per service replica")
    func upAllocatesPublishedPortRangesPerServiceReplica() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.ports = ["8080-8081:80"]
        }])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].containsSequence(["--publish", "8080:80"]))
        #expect(!commands[0].containsSequence(["--publish", "8081:80"]))
        #expect(commands[1].containsSequence(["--publish", "8081:80"]))
        #expect(!commands[1].containsSequence(["--publish", "8080:80"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("up maps anonymous volumes per service replica")
    func upMapsAnonymousVolumesPerServiceReplica() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.volumes = [
                ComposeMount(type: "volume", target: "/scratch"),
            ]
        }])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].contains { $0.hasPrefix("demo_anon-api-1-") && $0.hasSuffix(":/scratch") })
        #expect(commands[1].contains { $0.hasPrefix("demo_anon-api-2-") && $0.hasSuffix(":/scratch") })
        #expect(!commands[0].contains { $0.hasPrefix("demo_anon-api-2-") })
        #expect(!commands[1].contains { $0.hasPrefix("demo_anon-api-1-") })
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("create allocates multi port ranges per service replica")
    func createAllocatesMultiPortRangesPerServiceReplica() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.ports = ["127.0.0.1:8080-8083:80-81/udp"]
        }])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].containsSequence(["--publish", "127.0.0.1:8080:80/udp"]))
        #expect(commands[0].containsSequence(["--publish", "127.0.0.1:8081:81/udp"]))
        #expect(commands[1].containsSequence(["--publish", "127.0.0.1:8082:80/udp"]))
        #expect(commands[1].containsSequence(["--publish", "127.0.0.1:8083:81/udp"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("scale creates detached service replicas")
    func scaleCreatesDetachedServiceReplicas() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).scale(
            project: project,
            options: ComposeScaleOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-2", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("scale no-deps starts only selected services")
    func scaleNoDepsStartsOnlySelectedServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).scale(
            project: project,
            options: ComposeScaleOptions {
                $0.noDeps = true
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-2", "--detach"]))
        #expect(!commands.contains { $0.contains("demo-db-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("scale requires assignment before side effects")
    func scaleRequiresAssignmentBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).scale(project: project, options: ComposeScaleOptions())
            Issue.record("Expected missing scale assignment failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("scale requires at least one SERVICE=REPLICAS argument"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up prunes replicas above requested scale")
    func upPrunesReplicasAboveRequestedScale() async throws {
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
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.noRecreate = true
                $0.scales = ["api=1"]
            }
        )

        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-2", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-2", force: false),
        ])
    }

    @Test("up rejects invalid and unsafe scale before side effects")
    func upRejectsInvalidAndUnsafeScaleBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.scales = ["api=-1"]
                }
            )
            Issue.record("Expected invalid up scale failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--scale for service 'api' must be a non-negative integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(runner.commands.isEmpty)

        let namedRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: namedRunner).up(
                project: ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                    $0.containerName = "fixed-api"
                }]),
                options: ComposeUpOptions {
                    $0.scales = ["api=2"]
                }
            )
            Issue.record("Expected container_name scale failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' uses container_name; scale greater than 1 requires Compose-managed replica names"))
        }
        #expect(namedRunner.commands.isEmpty)

        let portRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: portRunner).up(
                project: ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["8080:80"]
                }]),
                options: ComposeUpOptions {
                    $0.scales = ["api=2"]
                }
            )
            Issue.record("Expected published-port scale failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' publishes '8080:80'; scaled published ports require at least 2 explicit host ports for 2 replicas"))
        }
        #expect(portRunner.commands.isEmpty)

        let serviceMACRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: serviceMACRunner).up(
                project: composeProject(
                    name: "demo",
                    services: [
                        "api": composeService(name: "api", image: "example/api") {
                            $0.macAddress = "02:42:ac:11:00:03"
                            $0.networks = ["backend"]
                        },
                    ]
                ) {
                    $0.networks = ["backend": ComposeNetwork(name: "backend")]
                },
                options: ComposeUpOptions {
                    $0.scales = ["api=2"]
                }
            )
            Issue.record("Expected service mac_address scale failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses mac_address; scaled MAC addresses would collide across replicas"))
        }
        #expect(serviceMACRunner.commands.isEmpty)

        let networkMACRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: networkMACRunner).up(
                project: composeProject(
                    name: "demo",
                    services: [
                        "api": composeService(name: "api", image: "example/api") {
                            $0.networks = ["backend"]
                            $0.networkOptions = [
                                "backend": ComposeNetworkOptions(addressing: .init(macAddress: "02:42:ac:11:00:04")),
                            ]
                        },
                    ]
                ) {
                    $0.networks = ["backend": ComposeNetwork(name: "backend")]
                },
                options: ComposeUpOptions {
                    $0.scales = ["api=2"]
                }
            )
            Issue.record("Expected per-network mac_address scale failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses mac_address; scaled MAC addresses would collide across replicas"))
        }
        #expect(networkMACRunner.commands.isEmpty)
    }

    @Test("up no-deps starts only selected services")
    func upNoDepsStartsOnlySelectedServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noDeps = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-db-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-deps skips dependency metadata validation")
    func upNoDepsSkipsDependencyMetadataValidation() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy", restart: true)]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noDeps = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-db-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-start creates containers without starting them")
    func upNoStartCreatesContainersWithoutStartingThem() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noStart = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.starts(with: ["container", "run"]) })
        #expect(!commands.contains { $0.contains("--detach") })
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
    }

    @Test("up no-start no-deps creates only selected services")
    func upNoStartNoDepsCreatesOnlySelectedServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy", restart: true)]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noDeps = true
                $0.noStart = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-db-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-start always-recreate-deps recreates matching dependency containers")
    func upNoStartAlwaysRecreateDepsRecreatesMatchingDependencyContainers() async throws {
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
                $0.noStart = true
            })

        let dbCreate = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiCreate = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        let dbHash = try #require(composeConfigHash(in: dbCreate))
        let apiHash = try #require(composeConfigHash(in: apiCreate))
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
            $0.noStart = true
            $0.alwaysRecreateDeps = true
            $0.timeout = 12
        })

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(!commands.contains { $0.contains("demo-api-1") })
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: 12),
            .delete(id: "demo-db-1", force: false),
        ])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
    }

    @Test("up no-start quiet build passes quiet through create")
    func upNoStartQuietBuildPassesQuietThroughCreate() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.build = true
                $0.noStart = true
                $0.quietBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "build"]))
        #expect(commands[0].contains("--quiet"))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("up uses external resource names without creating project resources")
    func upUsesExternalResourceNamesWithoutCreatingProjectResources() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
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
        #expect(commands.count == 1)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(!commands.contains { $0.containsSequence(["network", "create"]) })
        #expect(!commands.contains { $0.containsSequence(["volume", "create"]) })

        let run = commands[0]
        #expect(run.containsSequence(["--network", "corp-net"]))
        #expect(run.containsSequence(["--volume", "corp-data:/data"]))
        #expect(!run.contains("demo_shared"))
        #expect(!run.contains("demo_data"))
    }

    @Test("orchestrator honors explicit non external resource names")
    func orchestratorHonorsExplicitNonExternalResourceNames() async throws {
        let upRunner = RecordingRunner(responses: [
            .success,
        ])
        let upResources = RecordingContainerResourceManager()
        let upDiscovery = RecordingContainerDiscoveryManager()
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

        try await ComposeOrchestrator(
            runner: upRunner,
            discoveryManager: upDiscovery,
            resourceManager: upResources
        ).up(project: project, options: ComposeUpOptions())

        let upCommands = upRunner.commands.map(\.arguments)
        let upResourceRequests = await upResources.requests
        #expect(upResourceRequests.map(\.name) == ["team-net", "team-cache"])
        #expect(upCommands[0].containsSequence(["--network", "team-net"]))
        #expect(upCommands[0].containsSequence(["--volume", "team-cache:/cache"]))
        #expect(await upDiscovery.getRequests == ["demo-api-1"])

        let downRunner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let downResources = RecordingContainerResourceManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let downDiscovery = RecordingContainerDiscoveryManager()

        try await ComposeOrchestrator(
            runner: downRunner,
            discoveryManager: downDiscovery,
            lifecycleManager: lifecycleManager,
            resourceManager: downResources
        ).down(project: project, options: ComposeDownOptions(volumes: true))

        let lifecycleRequests = await lifecycleManager.requests
        let downResourceRequests = await downResources.requests
        #expect(downRunner.commands.isEmpty)
        #expect(lifecycleRequests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
        #expect(await downDiscovery.listRequests == [true])
        #expect(downResourceRequests == [
            .deleteNetwork(id: "team-net"),
            .deleteVolume(name: "team-cache"),
        ])
    }

    @Test("up removes orphan containers when requested")
    func upRemovesOrphanContainersWhenRequested() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-worker-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                    composeConfigHashLabel: "worker-hash",
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.removeOrphans = true
            $0.timeout = 7
        })

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!runner.commands[0].arguments.contains("--detach"))
        #expect(runner.commands[0].arguments.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(runner.commands[0].arguments.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(runner.commands[0].arguments.last == "example/api:latest")
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: 7),
            .delete(id: "demo-worker-1", force: false),
        ])
    }

    @Test("up remove orphans preserves declared service replicas without explicit scale")
    func upRemoveOrphansPreservesDeclaredServiceReplicasWithoutExplicitScale() async throws {
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
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-worker-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                    composeConfigHashLabel: "worker-hash",
                ]
            ),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).up(project: project, options: ComposeUpOptions {
            $0.noRecreate = true
            $0.removeOrphans = true
        })

        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-worker-1", force: false),
        ])
    }

    @Test("up emits detach flag only when requested")
    func upEmitsDetachFlagOnlyWhenRequested() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions {
            $0.detach = true
        })

        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(runner.commands[0].arguments.last == "example/api:latest")
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up detaches services that disable attach")
    func upDetachesServicesThatDisableAttach() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.attach = false
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
            })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(!dbRun.contains("--detach"))
        #expect(apiRun.contains("--detach"))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
    }

    @Test("up detaches all services when each service disables attach")
    func upDetachesAllServicesWhenEachServiceDisablesAttach() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.attach = false
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up build does not rebuild build-only services")
    func upBuildDoesNotRebuildBuildOnlyServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
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

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.build = true
        })

        let buildCommands = runner.commands.map(\.arguments).filter { $0.starts(with: ["container", "build"]) }
        #expect(buildCommands.count == 2)
        #expect(buildCommands[0].containsSequence(["--tag", "example/api"]))
        #expect(buildCommands[0].last == "api")
        #expect(buildCommands[1].containsSequence(["--tag", "demo_worker:latest"]))
        #expect(buildCommands[1].last == "worker")
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-worker-1"])
    }

    @Test("up quiet-build suppresses explicit build output")
    func upQuietBuildSuppressesExplicitBuildOutput() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.build = true
                $0.quietBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "build"]))
        #expect(commands[0].contains("--quiet"))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up applies service build pull policy before starting containers")
    func upAppliesServiceBuildPullPolicyBeforeStartingContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                    $0.pullPolicy = "build"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions()
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/api"]))
        #expect(commands[0].last == "api")
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-build skips service build pull policy")
    func upNoBuildSkipsServiceBuildPullPolicy() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                    $0.pullPolicy = "build"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.noBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(!commands.contains { $0.containsSequence(["container", "build"]) })
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-build skips auto build for build-only service")
    func upNoBuildSkipsAutoBuildForBuildOnlyService() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.noBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(!commands.contains { $0.containsSequence(["container", "build"]) })
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-worker-1"]))
        #expect(commands[0].last == "demo_worker:latest")
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("up quiet-build suppresses auto build-only output")
    func upQuietBuildSuppressesAutoBuildOnlyOutput() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.quietBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "build"]))
        #expect(commands[0].contains("--quiet"))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-worker-1"]))
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("up pull missing pulls only absent images")
    func upPullMissingPullsOnlyAbsentImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.pullPolicy = "missing"
        })

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-db-1"]))
        #expect(await imageManager.requests == [
            .pullMissing("example/api"),
            .pullMissing("postgres"),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-db-1"])
    }

    @Test("up pull if not present uses the missing-image flow")
    func upPullIfNotPresentUsesMissingImageFlow() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.pullPolicy = "if_not_present"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await imageManager.requests == [.pullMissing("example/api")])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up quiet-pull uses direct image pull before run")
    func upQuietPullUsesDirectImagePullBeforeRun() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.pullPolicy = "always"
                $0.quietPull = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await imageManager.requests == [.pull("example/api")])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up applies service pull policies when no global pull policy is set")
    func upAppliesServicePullPoliciesWhenNoGlobalPullPolicyIsSet() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
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

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-db-1"]))
        #expect(commands[2].starts(with: ["container", "run", "--name", "demo-worker-1"]))
        #expect(await imageManager.requests == [
            .pull("example/api"),
            .pullMissing("example/worker"),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-db-1", "demo-worker-1"])
    }

    @Test("up pulls service image when daily policy has no metadata")
    func upPullsServiceImageWhenDailyPolicyHasNoMetadata() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager(existingReferences: ["example/api"])
        let metadataStore = RecordingPullMetadataStore()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "daily"
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(currentDate: { now }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
                $0.pullMetadataStore = metadataStore
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(await imageManager.requests == [
            .exists("example/api"),
            .pull("example/api"),
        ])
        #expect(await metadataStore.recordedDate(for: "example/api") == now)
        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
    }

    @Test("up skips service image pull when weekly policy is fresh")
    func upSkipsServiceImagePullWhenWeeklyPolicyIsFresh() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let imageManager = RecordingContainerImageManager(existingReferences: ["example/api"])
        let metadataStore = RecordingPullMetadataStore(dates: [
            "example/api": now.addingTimeInterval(-60 * 60),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "weekly"
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(currentDate: { now }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.pullMetadataStore = metadataStore
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(await imageManager.requests == [.exists("example/api")])
        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
    }

    @Test("up pulls service image when every duration policy is stale")
    func upPullsServiceImageWhenEveryDurationPolicyIsStale() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let imageManager = RecordingContainerImageManager(existingReferences: ["example/api"])
        let metadataStore = RecordingPullMetadataStore(dates: [
            "example/api": now.addingTimeInterval(-91 * 60),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "every_1h30m"
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(currentDate: { now }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.pullMetadataStore = metadataStore
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(await imageManager.requests == [
            .exists("example/api"),
            .pull("example/api"),
        ])
        #expect(await metadataStore.recordedDate(for: "example/api") == now)
        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
    }

    @Test("up quiet-pull dry run disables service pull policy progress")
    func upQuietPullDryRunDisablesServicePullPolicyProgress() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.pullPolicy = "always"
                },
            ]
        )

        try await orchestrator.up(
            project: project,
            options: ComposeUpOptions {
                $0.quietPull = true
            }
        )

        let messages = emitted.messages
        #expect(messages.contains("+ container image pull --progress none alpine"))
        #expect(messages.contains { $0.hasPrefix("+ container run ") })
    }

    @Test("up rejects unsupported service pull policies before creating resources")
    func upRejectsUnsupportedServicePullPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
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
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported service pull policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses pull_policy 'sometimes'; supported values are always, missing, if_not_present, never, build, daily, weekly, and every_<duration>"))
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
                        $0.dependsOn = ["job": ComposeDependency(condition: testCase.condition)]
                    },
                ]
            )

            do {
                try await ComposeOrchestrator(runner: runner)
                    .up(project: project, options: ComposeUpOptions {
                        $0.services = ["api"]
                    })
                Issue.record("Expected unsupported dependency condition")
            } catch let error as ComposeError {
                #expect(error == .unsupported("service 'api' depends on 'job' with condition '\(testCase.condition)'; \(testCase.reason)"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up restarts reused dependents when restart dependencies change")
    func upRestartsReusedDependentsWhenRestartDependenciesChange() async throws {
        let baselineProject = ComposeProject(
            name: "demo",
            services: [
                "db": ComposeService(name: "db", image: "postgres:16"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started", restart: true)]
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )
        let baselineRunner = RecordingRunner()
        try await ComposeOrchestrator(runner: baselineRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: baselineProject, options: ComposeUpOptions())

        let dbRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        let oldDBHash = try #require(composeConfigHash(in: dbRun))
        let apiHash = try #require(composeConfigHash(in: apiRun))

        let changedProject = ComposeProject(
            name: "demo",
            services: [
                "db": composeService(name: "db", image: "postgres:16") {
                    $0.labels = ["com.example.version": "two"]
                },
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started", restart: true)]
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-db-1", status: "running", labels: [composeConfigHashLabel: oldDBHash]),
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: apiHash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        .up(project: changedProject, options: ComposeUpOptions {
            $0.services = ["api"]
        })

        #expect(runner.commands.map(\.arguments).count == 1)
        #expect(runner.commands[0].arguments.containsSequence(["--name", "demo-db-1"]))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-db-1", force: false),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
            .start(id: "demo-api-1"),
        ])
    }

    @Test("up does not dependency restart services already recreated")
    func upDoesNotDependencyRestartServicesAlreadyRecreated() async throws {
        let baselineProject = ComposeProject(
            name: "demo",
            services: [
                "db": ComposeService(name: "db", image: "postgres:16"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started", restart: true)]
                },
            ]
        )
        let baselineRunner = RecordingRunner()
        try await ComposeOrchestrator(runner: baselineRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: baselineProject, options: ComposeUpOptions())

        let dbRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        let oldDBHash = try #require(composeConfigHash(in: dbRun))
        let oldAPIHash = try #require(composeConfigHash(in: apiRun))

        let changedProject = ComposeProject(
            name: "demo",
            services: [
                "db": composeService(name: "db", image: "postgres:16") {
                    $0.labels = ["com.example.version": "two"]
                },
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started", restart: true)]
                    $0.labels = ["com.example.version": "two"]
                },
            ]
        )
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-db-1", status: "running", labels: [composeConfigHashLabel: oldDBHash]),
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: oldAPIHash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        .up(project: changedProject, options: ComposeUpOptions {
            $0.services = ["api"]
        })

        #expect(runner.commands.map(\.arguments).count == 2)
        #expect(runner.commands[0].arguments.containsSequence(["--name", "demo-db-1"]))
        #expect(runner.commands[1].arguments.containsSequence(["--name", "demo-api-1"]))
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-db-1", force: false),
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("rejects unsupported conditions on present optional dependencies")
    func rejectsUnsupportedConditionsOnPresentOptionalDependencies() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": ComposeDependency(condition: "service_healthy", required: false)]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner)
                .up(project: project, options: ComposeUpOptions {
                    $0.services = ["api"]
                })
            Issue.record("Expected unsupported dependency condition")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' depends on 'job' with condition 'service_healthy'; health status support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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

    @Test("up maps DNS options to runtime arguments")
    func upMapsDNSOptionsToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dnsOptions = ["use-vc"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--dns-option", "use-vc"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
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
                        "backend": ComposeNetworkOptions(
                            driverOpts: ["com.example.unsupported": "true"],
                            addressing: .init(ipv4Address: "10.10.0.5"),
                            priority: 42
                        ),
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
            #expect(error == .unsupported("service 'api' uses network attachment options driver_opts, ipv4_address, priority on network 'backend'; network attachment options need an apple/container runtime gap PR"))
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
                    $0.develop = ComposeDevelop()
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
                    $0.build = ComposeBuild(
                        context: "api",
                        options: ComposeBuild.Options(unsupportedFields: ["additional_contexts", "ssh"])
                    )
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
            #expect(error == .unsupported("service 'api' uses unsupported build fields additional_contexts, ssh; advanced build fields need Docker Compose compatible apple/container build primitives"))
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
            #expect(error == .unsupported("service 'api' uses unsupported deploy fields mode, resources.limits, placement; Compose Deploy Specification beyond local replicated mode, replica count, CPU limits, and memory limits is not implemented by container-compose yet"))
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

    @Test("up honors service scale before creating resources")
    func upHonorsServiceScaleBeforeCreatingResources() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-2", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
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

    @Test("up inherits declared volumes from same-project services")
    func upInheritsDeclaredVolumesFromSameProjectServices() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "base": composeService(name: "base", image: "example/base") {
                    $0.volumes = [
                        ComposeMount(type: "volume", source: "data", target: "/data"),
                        ComposeMount(type: "bind", source: "./seed", target: "/seed"),
                    ]
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["base:ro"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = [
                "cache": ComposeVolume(name: "cache"),
                "data": ComposeVolume(name: "data"),
            ]
        }

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["worker"]
            })

        let commands = runner.commands.map(\.arguments)
        let baseRun = try #require(commands.first { $0.containsSequence(["--name", "demo-base-1"]) })
        let workerRun = try #require(commands.first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let baseIndex = try #require(commands.firstIndex(of: baseRun))
        let workerIndex = try #require(commands.firstIndex(of: workerRun))
        #expect(baseIndex < workerIndex)
        #expect(baseRun.containsSequence(["--volume", "demo_data:/data"]))
        #expect(baseRun.containsSequence(["--volume", "./seed:/seed"]))
        #expect(workerRun.containsSequence(["--volume", "demo_data:/data:ro"]))
        #expect(workerRun.containsSequence(["--volume", "./seed:/seed:ro"]))
        #expect(workerRun.containsSequence(["--volume", "demo_cache:/cache"]))
    }

    @Test("up applies volumes_from read-write overrides")
    func upAppliesVolumesFromReadWriteOverrides() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "base": composeService(name: "base", image: "example/base") {
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/data", readOnly: true)]
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["base:rw"]
                },
            ]
        ) {
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["worker"]
            })

        let workerRun = try #require(runner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        #expect(workerRun.containsSequence(["--volume", "demo_data:/data"]))
        #expect(!workerRun.containsSequence(["--volume", "demo_data:/data:ro"]))
    }

    @Test("up config hash includes inherited volumes")
    func upConfigHashIncludesInheritedVolumes() async throws {
        let baselineRunner = RecordingRunner()
        let baseline = composeProjectWithInheritedVolume(target: "/data")
        try await ComposeOrchestrator(runner: baselineRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: baseline, options: ComposeUpOptions {
                $0.services = ["worker"]
                $0.noStart = true
            })
        let baselineWorkerCreate = try #require(baselineRunner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let baselineHash = try #require(composeConfigHash(in: baselineWorkerCreate))

        let changedRunner = RecordingRunner()
        let changed = composeProjectWithInheritedVolume(target: "/state")
        try await ComposeOrchestrator(runner: changedRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: changed, options: ComposeUpOptions {
                $0.services = ["worker"]
                $0.noStart = true
            })
        let changedWorkerCreate = try #require(changedRunner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let changedHash = try #require(composeConfigHash(in: changedWorkerCreate))

        #expect(baselineHash != changedHash)
    }

    @Test("up rejects external container volumes_from before creating resources")
    func upRejectsExternalContainerVolumesFromBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["container:legacy:ro"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported external volumes_from error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'worker' uses volumes_from 'container:legacy:ro'; external container volume inheritance is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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

    @Test("up maps service MAC address to single network attachment")
    func upMapsServiceMACAddressToSingleNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.macAddress = "02:42:ac:11:00:03"
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
        )
            .up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend,mac=02:42:ac:11:00:03"]))
    }

    @Test("up maps per-network MAC address to single network attachment")
    func upMapsPerNetworkMACAddressToSingleNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(addressing: .init(macAddress: "02:42:ac:11:00:04")),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        )
            .up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend,mac=02:42:ac:11:00:04"]))
    }

    @Test("up maps supported network MTU option to single network attachment")
    func upMapsSupportedNetworkMTUOptionToSingleNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            driverOpts: ["com.docker.network.driver.mtu": "1450"],
                            addressing: .init(macAddress: "02:42:ac:11:00:04")
                        ),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        )
            .up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend,mac=02:42:ac:11:00:04,mtu=1450"]))
    }

    @Test("up rejects invalid network MTU before creating resources")
    func upRejectsInvalidNetworkMTUBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(driverOpts: ["com.docker.network.driver.mtu": "fast"]),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid network MTU error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("network MTU driver option 'com.docker.network.driver.mtu' must be a positive integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects MAC address without a single network before creating resources")
    func upRejectsMACAddressWithoutSingleNetworkBeforeCreatingResources() async throws {
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
            #expect(error == .unsupported("service 'api' uses mac_address; MAC address support requires exactly one Compose network"))
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

        let data = Data(try #require(emitted.messages.first).utf8)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(records.map { $0["container"] } == ["demo-api-1", "demo-worker-1"])
        #expect(records.map { $0["repository"] } == ["localhost:5000/example/api", "example/worker"])
        #expect(records.map { $0["tag"] } == ["latest", "debug"])
        #expect(records.map { $0["imageID"] } == ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
        #expect(await discoveryManager.listRequests == [true])
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

        let data = Data(try #require(emitted.messages.first).utf8)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(records == [["driver": "local", "name": "demo_cache"]])
        #expect(await resourceManager.requests == [.listVolumes])
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

    @Test("volumes rejects unsupported output formats")
    func volumesRejectsUnsupportedOutputFormats() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .volumes(project: project, options: ComposeVolumesOptions(format: "yaml"))
            Issue.record("Expected unsupported volumes format error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("volumes --format 'yaml'; supported formats are table and json"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
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
            ContainerStatsRequest(ids: ["demo-api-1", "custom-db"], format: "table", noStream: false, includeStopped: false),
            ContainerStatsRequest(ids: ["demo-api-1", "custom-db"], format: "json", noStream: true, includeStopped: false),
            ContainerStatsRequest(ids: ["demo-api-1"], format: "table", noStream: true, includeStopped: true),
        ])
        #expect(emitted.messages == [
            "stats-output",
            "stats-output",
            "stats-output",
        ])
    }

    @Test("stats dry run emits runtime command instead of direct API stats")
    func statsDryRunEmitsRuntimeCommandInsteadOfDirectAPIStats() async throws {
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
            "+ container stats --format json --no-stream --all demo-api-1 custom-db",
        ])
        #expect(await statsManager.requests.isEmpty)
    }

    @Test("stats rejects unsupported format before runtime commands")
    func statsRejectsUnsupportedFormatBeforeRuntimeCommands() async throws {
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
                options: ComposeStatsOptions(format: "yaml")
            )
            Issue.record("Expected unsupported stats format failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("stats --format 'yaml': apple/container stats supports table and json output"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(runner.commands.isEmpty)
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
        #expect(output.contains("running(1), stopped(1)"))
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

        let data = Data(try #require(emitted.messages.first).utf8)
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(records.map { $0["name"] } == ["demo", "other"])
        #expect(records.map { $0["status"] } == ["running(1), stopped(1)", "running(1)"])
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

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false)

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-api-1"])
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

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: true)

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-api-1", "demo-worker-1"])
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

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, quiet: true)

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(emitted.messages == ["demo-api-1"])
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

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, services: true)

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(emitted.messages == ["api"])
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

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, quiet: true, services: true)

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

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, statuses: ["running"])

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-api-1"])
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

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, filters: ["status=exited"])

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-worker-1"])
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

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false, services: true, statuses: ["running"])

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
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

    @Test("service init key maps to initEnabled")
    func serviceInitKeyMapsToInitEnabled() throws {
        let decoded = try JSONDecoder().decode(ComposeService.self, from: Data(#"{"name":"web","init":true}"#.utf8))

        #expect(decoded.initEnabled == true)

        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(encoded.contains(#""init":true"#))
        #expect(!encoded.contains("initEnabled"))
    }

    @Test("build uses CLI while pull and push use direct image API")
    func buildUsesCLIWhilePullAndPushUseDirectImageAPI() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let imageManager = RecordingContainerImageManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            imageManager: imageManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        dockerfile: "Containerfile",
                        args: ["VERSION": "1"],
                        cache: ComposeBuild.Cache(
                            from: ["type=registry,ref=example/api:cache"],
                            to: ["type=local,dest=.cache"]
                        ),
                        metadata: ComposeBuild.Metadata(
                            labels: ["org.opencontainers.image.title": "api", "build.label": "true"],
                            secrets: [
                                ComposeBuildSecret(id: "file_token", file: "./token.txt"),
                                ComposeBuildSecret(id: "npm_token", environment: "NPM_TOKEN"),
                            ]
                        ),
                        options: ComposeBuild.Options(
                            target: "runtime",
                            noCache: true,
                            pull: true,
                            platforms: ["linux/amd64", "linux/arm64"],
                            tags: ["example/api:latest", "example/api:dev", "example/api:test"]
                        )
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
        #expect(runner.commands[0].arguments.filter { $0 == "example/api:latest" }.count == 1)
        #expect(runner.commands[0].arguments.containsSequence(["--tag", "example/api:dev"]))
        #expect(runner.commands[0].arguments.containsSequence(["--tag", "example/api:test"]))
        #expect(runner.commands[0].arguments.containsSequence(["--file", "Containerfile"]))
        #expect(runner.commands[0].arguments.containsSequence(["--target", "runtime"]))
        #expect(runner.commands[0].arguments.contains("--no-cache"))
        #expect(runner.commands[0].arguments.contains("--pull"))
        #expect(runner.commands[0].arguments.containsSequence(["--platform", "linux/amd64"]))
        #expect(runner.commands[0].arguments.containsSequence(["--platform", "linux/arm64"]))
        #expect(runner.commands[0].arguments.containsSequence(["--cache-in", "type=registry,ref=example/api:cache"]))
        #expect(runner.commands[0].arguments.containsSequence(["--cache-out", "type=local,dest=.cache"]))
        #expect(runner.commands[0].arguments.containsSequence(["--label", "build.label=true"]))
        #expect(runner.commands[0].arguments.containsSequence(["--label", "org.opencontainers.image.title=api"]))
        #expect(runner.commands[0].arguments.containsSequence(["--secret", "id=file_token,src=./token.txt"]))
        #expect(runner.commands[0].arguments.containsSequence(["--secret", "id=npm_token,env=NPM_TOKEN"]))
        #expect(runner.commands[0].arguments.containsSequence(["--build-arg", "VERSION=1"]))
        #expect(runner.commands[0].arguments.last == "api")
        #expect(runner.commands[1].arguments.containsSequence(["--tag", "demo_worker:latest"]))
        #expect(runner.commands.count == 2)
        #expect(await imageManager.requests == [
            .pull("example/api:latest"),
            .push("example/api:latest"),
        ])
        #expect(emitted.messages == ["example/api:latest"])
    }

    @Test("build materializes inline Dockerfile for container build")
    func buildMaterializesInlineDockerfileForContainerBuild() async throws {
        let runner = InlineDockerfileRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:inline") {
                    $0.build = ComposeBuild(
                        context: "api",
                        dockerfileInline: "FROM alpine:3.20\nRUN echo inline\n"
                    )
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(project: project, services: ["api"], noCache: false)

        let command = try #require(runner.commands.first)
        let fileIndex = try #require(command.firstIndex(of: "--file"))
        let dockerfilePath = command[fileIndex + 1]
        #expect(command.containsSequence(["container", "build", "--tag", "example/api:inline"]))
        #expect(dockerfilePath.contains("container-compose-demo-api-"))
        #expect(dockerfilePath.hasSuffix("/Dockerfile"))
        #expect(command.last == "api")
        #expect(runner.dockerfileContents == ["FROM alpine:3.20\nRUN echo inline\n"])
        #expect(!FileManager.default.fileExists(atPath: dockerfilePath))
    }

    @Test("build rejects conflicting Dockerfile forms before emitting commands")
    func buildRejectsConflictingDockerfileFormsBeforeEmittingCommands() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        dockerfile: "Dockerfile",
                        dockerfileInline: "FROM alpine"
                    )
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).build(project: project, services: [], noCache: false)
            Issue.record("Expected conflicting Dockerfile forms error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' cannot define both dockerfile and dockerfile_inline"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("pull include deps with missing policy pulls dependency images first")
    func pullIncludeDepsWithMissingPolicyPullsDependencyImagesFirst() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = [
                        "db": ComposeDependency(condition: "service_started"),
                    ]
                },
                "db": composeService(name: "db", image: "example/db:latest"),
            ]
        )

        try await ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).pull(
            project: project,
            options: ComposePullOptions {
                $0.services = ["api"]
                $0.includeDependencies = true
                $0.policy = "missing"
            }
        )

        #expect(await imageManager.requests == [
            .pullMissing("example/db:latest"),
            .pullMissing("example/api:latest"),
        ])
    }

    @Test("pull ignore buildable skips services with build sections")
    func pullIgnoreBuildableSkipsServicesWithBuildSections() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
                "db": composeService(name: "db", image: "example/db:latest"),
            ]
        )

        try await ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).pull(
            project: project,
            options: ComposePullOptions {
                $0.ignoreBuildable = true
            }
        )

        #expect(await imageManager.requests == [.pull("example/db:latest")])
    }

    @Test("pull ignore failures continues with later services")
    func pullIgnoreFailuresContinuesWithLaterServices() async throws {
        let imageManager = RecordingContainerImageManager(pullFailures: ["example/api:latest"])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
                "worker": composeService(name: "worker", image: "example/worker:latest"),
            ]
        )

        try await ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).pull(
            project: project,
            options: ComposePullOptions {
                $0.ignorePullFailures = true
            }
        )

        #expect(await imageManager.requests == [
            .pull("example/api:latest"),
            .pull("example/worker:latest"),
        ])
    }

    @Test("pull rejects unsupported policy before side effects")
    func pullRejectsUnsupportedPolicyBeforeSideEffects() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
            ]
        )

        do {
            try await ComposeOrchestrator(
                dependencies: orchestratorDependencies {
                    $0.imageManager = imageManager
                }
            ).pull(
                project: project,
                options: ComposePullOptions {
                    $0.policy = "never"
                }
            )
            Issue.record("Expected unsupported pull policy failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unsupported pull policy 'never'"))
        }

        #expect(await imageManager.requests.isEmpty)
    }

    @Test("push include deps pushes dependency images first")
    func pushIncludeDepsPushesDependencyImagesFirst() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = [
                        "db": ComposeDependency(condition: "service_started"),
                    ]
                },
                "db": composeService(name: "db", image: "example/db:latest"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).push(
            project: project,
            options: ComposePushOptions {
                $0.services = ["api"]
                $0.includeDependencies = true
            }
        )

        #expect(await imageManager.requests == [
            .push("example/db:latest"),
            .push("example/api:latest"),
        ])
    }

    @Test("push quiet suppresses emitted pushed references")
    func pushQuietSuppressesEmittedPushedReferences() async throws {
        let emitted = MessageRecorder()
        let imageManager = RecordingContainerImageManager(pushOutputs: [
            "example/api:latest": "registry.example.com/api@sha256:abc",
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
            ]
        )
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.push(
            project: project,
            options: ComposePushOptions {
                $0.quiet = true
            }
        )

        #expect(await imageManager.requests == [.push("example/api:latest")])
        #expect(emitted.messages.isEmpty)
    }

    @Test("push ignore failures continues with later services")
    func pushIgnoreFailuresContinuesWithLaterServices() async throws {
        let imageManager = RecordingContainerImageManager(pushFailures: ["example/api:latest"])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
                "worker": composeService(name: "worker", image: "example/worker:latest"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).push(
            project: project,
            options: ComposePushOptions {
                $0.ignorePushFailures = true
            }
        )

        #expect(await imageManager.requests == [
            .push("example/api:latest"),
            .push("example/worker:latest"),
        ])
    }

    @Test("build options add pull quiet and push service image")
    func buildOptionsAddPullQuietAndPushServiceImage() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { _ in }),
            imageManager: imageManager
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.pull = true
                $0.push = true
                $0.quiet = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains("--pull"))
        #expect(command.contains("--quiet"))
        #expect(command.last == "api")
        #expect(await imageManager.requests == [.push("example/api:latest")])
    }

    @Test("build with dependencies builds dependency images first")
    func buildWithDependenciesBuildsDependencyImagesFirst() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = [
                        "db": ComposeDependency(condition: "service_started"),
                    ]
                    $0.build = ComposeBuild(context: "api")
                },
                "db": composeService(name: "db", image: "example/db:latest") {
                    $0.build = ComposeBuild(context: "db")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.withDependencies = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].containsSequence(["--tag", "example/db:latest"]))
        #expect(commands[0].last == "db")
        #expect(commands[1].containsSequence(["--tag", "example/api:latest"]))
        #expect(commands[1].last == "api")
    }

    @Test("build push skips services without explicit image references")
    func buildPushSkipsServicesWithoutExplicitImageReferences() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).build(
            project: project,
            options: ComposeBuildOptions {
                $0.push = true
            }
        )

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.containsSequence(["--tag", "demo_worker:latest"]))
        #expect(await imageManager.requests.isEmpty)
    }

    @Test("build applies Compose file no cache setting")
    func buildAppliesComposeFileNoCacheSetting() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        options: ComposeBuild.Options(noCache: true)
                    )
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
                    $0.build = ComposeBuild(
                        context: "api",
                        options: ComposeBuild.Options(unsupportedFields: ["secrets"])
                    )
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).build(project: project, services: [], noCache: false)
            Issue.record("Expected unsupported build field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses unsupported build fields secrets; advanced build fields need Docker Compose compatible apple/container build primitives"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("build rejects malformed build secrets before emitting commands")
    func buildRejectsMalformedBuildSecretsBeforeEmittingCommands() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        metadata: ComposeBuild.Metadata(
                            secrets: [ComposeBuildSecret(id: "both", file: "./token.txt", environment: "TOKEN")]
                        )
                    )
                },
            ]
        )
        let runner = RecordingRunner()

        do {
            try await ComposeOrchestrator(runner: runner).build(project: project, services: [], noCache: false)
            Issue.record("Expected invalid build secret error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("build secret 'both' cannot define both file and environment"))
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
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await orchestrator.build(project: project, services: ["api"], noCache: false)

        let command = try #require(runner.commands.first)
        #expect(command.executable == "custom-env")
        #expect(command.arguments.containsSequence(["container", "build", "--tag", "example/api:latest"]))
        #expect(command.arguments.last == "api")
    }

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
        #expect(resources.count == 2)
        #expect(resources.contains { $0.name.hasPrefix("demo_anon-api-1-") })
        #expect(resources.contains { $0.name.hasPrefix("demo_anon-api-2-") })
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
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            copier: copier,
            execManager: execManager,
            lifecycleManager: lifecycleManager,
            logManager: logManager
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

        try await orchestrator.logs(project: project, services: ["api"], follow: true, tail: "10")
        try await orchestrator.exec(project: project, serviceName: "api", command: ["echo", "ok"])
        try await orchestrator.start(project: project, services: ["api"])
        try await orchestrator.stop(project: project, services: ["api"])
        try await orchestrator.restart(project: project, services: ["api"])
        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true)
        try await orchestrator.kill(project: project, services: ["api"], signal: "SIGTERM")
        try await orchestrator.copy(project: project, arguments: ["api:/tmp/file", "."])

        #expect(runner.commands.isEmpty)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["echo", "ok"],
                interactive: true,
                tty: true
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
            .delete(id: "demo-api-1", force: false),
            .kill(id: "demo-api-1", signal: "SIGTERM"),
        ])
        #expect(await copier.requests == [
            .from(id: "demo-api-1", source: "/tmp/file", destination: "."),
        ])
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

        try await ComposeOrchestrator(runner: runner, lifecycleManager: lifecycleManager)
            .start(project: project, services: [])

        #expect(runner.commands.isEmpty)
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

    @Test("kill dry run emits runtime commands instead of direct API calls")
    func killDryRunEmitsRuntimeCommandsInsteadOfDirectAPICalls() async throws {
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
            "+ container kill --signal SIGUSR1 demo-api-1",
        ])
        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests.isEmpty)
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

    @Test("wait rejects already stopped containers before direct API wait")
    func waitRejectsAlreadyStoppedContainersBeforeDirectAPIWait() async throws {
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
            #expect(error == .unsupported("wait: service 'api' container 'demo-api-1' is stopped; apple/container does not expose stored exit codes for already-stopped containers"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("wait dry run emits runtime wait commands")
    func waitDryRunEmitsRuntimeWaitCommands() async throws {
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
            "+ container wait demo-api-1",
            "+ container wait demo-api-2",
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
            "+ container wait demo-api-1",
            "+ container stop --time 7 demo-api-1",
            "+ container delete demo-api-1",
            "+ container stop demo-db-1",
            "+ container delete demo-db-1",
        ])
        #expect(await lifecycleManager.requests.isEmpty)
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
            #expect(error == .unsupported("wait: service 'api' container 'demo-api-1' is stopped; apple/container does not expose stored exit codes for already-stopped containers"))
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
        let exitCode = try await manager.waitContainer(id: "demo-api-1")
        try await manager.deleteContainer(id: "demo-api-1", force: true)

        #expect(exitCode == 4)
        #expect(await client.requests == [
            .start(id: "demo-api-1"),
            .kill(id: "demo-api-1", signal: "SIGTERM"),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 12),
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: 5),
            .wait(id: "demo-api-1"),
            .delete(id: "demo-api-1", force: true),
        ])
    }

    @Test("lifecycle manager rejects stop timeouts outside Apple API range")
    func lifecycleManagerRejectsStopTimeoutsOutsideAppleAPIRange() async throws {
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
            start: { id in
                try await recorder.startContainer(id: id)
            },
            kill: { id, signal in
                try await recorder.killContainer(id: id, signal: signal)
            },
            stop: { id, options in
                try await recorder.stopContainer(id: id, options: options)
            },
            wait: { id in
                try await recorder.waitContainer(id: id)
            },
            delete: { id, force in
                try await recorder.deleteContainer(id: id, force: force)
            }
        )
        let stopOptions = ContainerStopOptions(timeoutInSeconds: 15, signal: "SIGQUIT")

        try await client.startContainer(id: "demo-api-1")
        try await client.killContainer(id: "demo-api-1", signal: "SIGTERM")
        try await client.stopContainer(id: "demo-api-1", options: stopOptions)
        _ = try await client.waitContainer(id: "demo-api-1")
        try await client.deleteContainer(id: "demo-api-1", force: false)

        #expect(await recorder.requests == [
            .start(id: "demo-api-1"),
            .kill(id: "demo-api-1", signal: "SIGTERM"),
            .stop(id: "demo-api-1", signal: "SIGQUIT", timeoutInSeconds: 15),
            .wait(id: "demo-api-1"),
            .delete(id: "demo-api-1", force: false),
        ])
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
                    try PublishPort(
                        hostAddress: try IPAddress("127.0.0.1"),
                        hostPort: 8080,
                        containerPort: 80,
                        proto: .tcp,
                        count: 2
                    ),
                ]
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
                platform: "linux/amd64"
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

        #expect(running.map(\.id) == ["demo-api-1", "demo-worker-1"])
        #expect(running.first == ComposeContainerSummary(
            id: "demo-api-1",
            status: "running",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeConfigHashLabel: "api-hash",
            ],
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64",
            publishedPorts: [
                ComposeContainerPublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, protocolName: "tcp", count: 2),
            ]
        ))
        #expect(all.map(\.status) == ["running", "stopped"])
        #expect(worker?.id == "demo-worker-1")
        #expect(worker?.platform == "linux/amd64")
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

    @Test("log manager reads tailed logs from direct API handles")
    func logManagerReadsTailedLogsFromDirectAPIHandles() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerLogAPIClient(fileHandles: [
            try temporaryLogFileHandle(contents: "one\ntwo\nthree\n"),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(id: "demo-api-1", tail: 2, follow: false, emit: { emitted.append($0) })

        #expect(emitted.messages == ["two\nthree"])
        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager reads all logs from direct API handles")
    func logManagerReadsAllLogsFromDirectAPIHandles() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerLogAPIClient(fileHandles: [
            try temporaryLogFileHandle(contents: "one\ntwo\n"),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { emitted.append($0) })

        #expect(emitted.messages == ["one\ntwo"])
        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager rejects missing direct API log handles")
    func logManagerRejectsMissingDirectAPILogHandles() async throws {
        let client = RecordingContainerLogAPIClient()
        let manager = ContainerClientLogManager(client: client)

        do {
            try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { _ in })
            Issue.record("Expected missing log handle error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container logs returned no stdio handle for demo-api-1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager rejects invalid UTF-8 from direct API logs")
    func logManagerRejectsInvalidUTF8FromDirectAPILogs() async throws {
        let client = RecordingContainerLogAPIClient(fileHandles: [
            try temporaryLogFileHandle(data: Data([0xFF])),
        ])
        let manager = ContainerClientLogManager(client: client)

        do {
            try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { _ in })
            Issue.record("Expected invalid UTF-8 log error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container logs for demo-api-1 are not valid UTF-8"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager follows appended direct API log lines")
    func logManagerFollowsAppendedDirectAPILogLines() async throws {
        let emitted = MessageRecorder()
        let pipe = Pipe()
        let client = RecordingContainerLogAPIClient(fileHandles: [pipe.fileHandleForReading])
        let manager = ContainerClientLogManager(client: client)

        async let followTask: Void = manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        try await Task.sleep(for: .milliseconds(50))
        pipe.fileHandleForWriting.write(Data("live\n".utf8))
        try pipe.fileHandleForWriting.close()
        try await followTask

        #expect(emitted.messages == ["live"])
        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager rejects invalid UTF-8 while following direct API logs")
    func logManagerRejectsInvalidUTF8WhileFollowingDirectAPILogs() async throws {
        let pipe = Pipe()
        let client = RecordingContainerLogAPIClient(fileHandles: [pipe.fileHandleForReading])
        let manager = ContainerClientLogManager(client: client)

        async let followTask: Void = manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { _ in })
        try await Task.sleep(for: .milliseconds(50))
        pipe.fileHandleForWriting.write(Data([0xFF]))
        try pipe.fileHandleForWriting.close()

        do {
            try await followTask
            Issue.record("Expected invalid UTF-8 follow log error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container logs for demo-api-1 are not valid UTF-8"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log API client forwards configured operation")
    func logAPIClientForwardsConfiguredOperation() async throws {
        let fileHandle = try temporaryLogFileHandle(contents: "hello\n")
        let recorder = RecordingContainerLogAPIClient(fileHandles: [fileHandle])
        let client = ContainerLogAPIClient { id in
            try await recorder.logFileHandles(id: id)
        }

        let handles = try await client.logFileHandles(id: "demo-api-1")

        #expect(handles.count == 1)
        #expect(await recorder.requests == ["demo-api-1"])
    }

    @Test("stats manager renders static table from direct API stats")
    func statsManagerRendersStaticTableFromDirectAPIStats() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [
                ComposeStatsTarget(id: "demo-api-1", status: "running"),
                ComposeStatsTarget(id: "demo-db-1", status: "stopped"),
            ],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_250_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { _ in }
        )

        try await manager.stats(ids: ["demo-api-1", "demo-db-1"], format: "table", noStream: true, includeStopped: false, emit: { emitted.append($0) })

        #expect(emitted.messages.count == 1)
        #expect(emitted.messages[0].contains("Container ID"))
        #expect(emitted.messages[0].contains("demo-api-1"))
        #expect(emitted.messages[0].contains("25.00%"))
        #expect(emitted.messages[0].contains("1.00 MiB / 2.00 MiB"))
        #expect(!emitted.messages[0].contains("demo-db-1"))
        #expect(await client.listRequests == [["demo-api-1", "demo-db-1"]])
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats manager includes stopped containers when all is requested")
    func statsManagerIncludesStoppedContainersWhenAllIsRequested() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [
                ComposeStatsTarget(id: "demo-api-1", status: "running"),
                ComposeStatsTarget(id: "demo-db-1", status: "stopped"),
            ],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_250_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { _ in }
        )

        try await manager.stats(ids: ["demo-api-1", "demo-db-1"], format: "table", noStream: true, includeStopped: true, emit: { emitted.append($0) })

        #expect(emitted.messages.count == 1)
        #expect(emitted.messages[0].contains("demo-api-1"))
        #expect(emitted.messages[0].contains("25.00%"))
        #expect(emitted.messages[0].contains("demo-db-1"))
        #expect(emitted.messages[0].contains("-- / --"))
        #expect(await client.listRequests == [["demo-api-1", "demo-db-1"]])
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats manager streams table output from direct API stats")
    func statsManagerStreamsTableOutputFromDirectAPIStats() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_500_000),
                ],
            ]
        )
        let sleeper = ThrowingSleeper(throwOnCall: 2)
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { try await sleeper.sleep($0) }
        )

        do {
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: false, includeStopped: false, emit: { emitted.append($0) })
            Issue.record("Expected streaming stats cancellation")
        } catch is CancellationError {
            // Expected cancellation from the injected sleeper after one streamed frame.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let messages = emitted.messages
        #expect(messages.count == 4)
        if messages.count == 4 {
            #expect(messages[0] == "\u{001B}[?1049h\u{001B}[?25l")
            #expect(messages[1].contains("\u{001B}[H\u{001B}[JContainer ID"))
            #expect(!messages[1].contains("demo-api-1"))
            #expect(messages[2].contains("\u{001B}[H\u{001B}[JContainer ID"))
            #expect(messages[2].contains("demo-api-1"))
            #expect(messages[2].contains("50.00%"))
            #expect(messages[3] == "\u{001B}[?25h\u{001B}[?1049l")
        }
    }

    @Test("stats manager renders unavailable fields in direct API table output")
    func statsManagerRendersUnavailableFieldsInDirectAPITableOutput() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: nil),
                    containerStats(
                        id: "demo-api-1",
                        cpuUsageUsec: nil,
                        memoryUsageBytes: 1_073_741_824,
                        memoryLimitBytes: nil,
                        networkRxBytes: nil,
                        networkTxBytes: nil,
                        blockReadBytes: nil,
                        blockWriteBytes: nil,
                        numProcesses: nil
                    ),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(client: client, sampleInterval: .microseconds(1), sleep: { _ in })

        try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, includeStopped: false, emit: { emitted.append($0) })

        #expect(emitted.messages[0].contains("--"))
        #expect(emitted.messages[0].contains("1.00 GiB / --"))
        #expect(emitted.messages[0].contains("-- / --"))
    }

    @Test("stats manager renders static JSON from direct API stats")
    func statsManagerRendersStaticJSONFromDirectAPIStats() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_500_000, memoryUsageBytes: 2_097_152),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(client: client, sampleInterval: .microseconds(1), sleep: { _ in })

        try await manager.stats(ids: ["demo-api-1"], format: "json", noStream: false, includeStopped: false, emit: { emitted.append($0) })

        let decoded = try JSONDecoder().decode([ContainerStats].self, from: Data(emitted.messages[0].utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].id == "demo-api-1")
        #expect(decoded[0].cpuUsageUsec == 1_500_000)
        #expect(decoded[0].memoryUsageBytes == 2_097_152)
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats manager rejects missing direct API stat targets")
    func statsManagerRejectsMissingDirectAPIStatTargets() async throws {
        let client = RecordingContainerStatsAPIClient()
        let manager = ContainerClientStatsManager(client: client, sleep: { _ in })

        do {
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, includeStopped: false, emit: { _ in })
            Issue.record("Expected missing stats target error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("no such container: demo-api-1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.listRequests == [["demo-api-1"]])
        #expect(await client.statsRequests.isEmpty)
    }

    @Test("stats manager surfaces initial stats failures")
    func statsManagerSurfacesInitialStatsFailures() async throws {
        let expected = ComposeError.invalidProject("initial stats failed")
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsError: expected,
            statsErrorRequestIndex: 1
        )
        let manager = ContainerClientStatsManager(client: client, sleep: { _ in })

        do {
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, includeStopped: false, emit: { _ in })
            Issue.record("Expected initial stats failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.listRequests == [["demo-api-1"]])
        #expect(await client.statsRequests == ["demo-api-1"])
    }

    @Test("stats manager surfaces follow-up stats failures")
    func statsManagerSurfacesFollowUpStatsFailures() async throws {
        let expected = ComposeError.invalidProject("follow-up stats failed")
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                ],
            ],
            statsError: expected,
            statsErrorRequestIndex: 2
        )
        let manager = ContainerClientStatsManager(client: client, sampleInterval: .microseconds(1), sleep: { _ in })

        do {
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, includeStopped: false, emit: { _ in })
            Issue.record("Expected follow-up stats failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.listRequests == [["demo-api-1"]])
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats API client forwards configured operations")
    func statsAPIClientForwardsConfiguredOperations() async throws {
        let recorder = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: ["demo-api-1": [containerStats(id: "demo-api-1", cpuUsageUsec: 42)]]
        )
        let client = ContainerStatsAPIClient(
            list: { ids in try await recorder.listStatsTargets(ids: ids) },
            stats: { id in try await recorder.stats(id: id) }
        )

        let targets = try await client.listStatsTargets(ids: ["demo-api-1"])
        let stats = try await client.stats(id: "demo-api-1")

        #expect(targets == [ComposeStatsTarget(id: "demo-api-1", status: "running")])
        #expect(stats.id == "demo-api-1")
        #expect(stats.cpuUsageUsec == 42)
        #expect(await recorder.listRequests == [["demo-api-1"]])
        #expect(await recorder.statsRequests == ["demo-api-1"])
    }

    @Test("detached exec manager maps request to direct process API")
    func detachedExecManagerMapsRequestToDirectProcessAPI() async throws {
        let emitted = MessageRecorder()
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .running,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        )
        let client = RecordingContainerExecAPIClient(snapshots: [snapshot])
        let manager = ContainerClientExecManager(client: client, processIdentifier: { "process-123" })

        try await manager.execDetached(
            request: ContainerDetachedExecRequest(
                id: "demo-api-1",
                command: ["env", "ARG"],
                environment: ["FOO=bar"],
                user: "1000:1000",
                workingDirectory: "/app"
            ),
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == ["demo-api-1"])
        #expect(await client.getRequests == ["demo-api-1"])
        #expect(await client.processRequests == [
            ContainerExecProcessRequest(
                containerId: "demo-api-1",
                processId: "process-123",
                executable: "env",
                arguments: ["ARG"],
                environment: ["FOO=bar"],
                workingDirectory: "/app",
                terminal: false,
                user: "1000:1000",
                supplementalGroups: [],
                stdioCount: 0
            ),
        ])
    }

    @Test("detached exec manager rejects stopped containers")
    func detachedExecManagerRejectsStoppedContainers() async throws {
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .stopped,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        )
        let client = RecordingContainerExecAPIClient(snapshots: [snapshot])
        let manager = ContainerClientExecManager(client: client, processIdentifier: { "process-123" })

        do {
            try await manager.execDetached(
                request: ContainerDetachedExecRequest(id: "demo-api-1", command: ["true"]),
                emit: { _ in }
            )
            Issue.record("Expected stopped container error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container 'demo-api-1' is not running"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.getRequests == ["demo-api-1"])
        #expect(await client.processRequests.isEmpty)
    }

    @Test("attached exec manager maps request to direct process API")
    func attachedExecManagerMapsRequestToDirectProcessAPI() async throws {
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .running,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        )
        let client = RecordingContainerExecAPIClient(snapshots: [snapshot], attachedStatus: 7)
        let manager = ContainerClientExecManager(client: client, processIdentifier: { "process-456" })

        let status = try await manager.execAttached(
            request: ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["echo", "ok"],
                environment: ["FOO=bar"],
                user: "1000:1000",
                workingDirectory: "/app",
                interactive: true,
                tty: false
            )
        )

        #expect(status == 7)
        #expect(await client.getRequests == ["demo-api-1"])
        #expect(await client.attachedProcessRequests == [
            ContainerAttachedExecProcessRequest(
                containerId: "demo-api-1",
                processId: "process-456",
                executable: "echo",
                arguments: ["ok"],
                environment: ["FOO=bar"],
                workingDirectory: "/app",
                terminal: false,
                user: "1000:1000",
                supplementalGroups: [],
                interactive: true,
                tty: false
            ),
        ])
    }

    @Test("exec API client forwards configured operations")
    func execAPIClientForwardsConfiguredOperations() async throws {
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .running,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        )
        let recorder = RecordingContainerExecAPIClient(snapshots: [snapshot])
        let client = ContainerExecAPIClient(
            get: { try await recorder.getContainer(id: $0) },
            createAndStart: { containerId, processId, configuration, stdio in
                try await recorder.createAndStartProcess(
                    containerId: containerId,
                    processId: processId,
                    configuration: configuration,
                    stdio: stdio
                )
            },
            runAttached: { containerId, processId, configuration, interactive, tty in
                try await recorder.runAttachedProcess(
                    containerId: containerId,
                    processId: processId,
                    configuration: configuration,
                    interactive: interactive,
                    tty: tty
                )
            }
        )
        let configuration = ProcessConfiguration(
            executable: "date",
            arguments: ["-u"],
            environment: ["TZ=UTC"],
            workingDirectory: "/"
        )

        let actualSnapshot = try await client.getContainer(id: "demo-api-1")
        try await client.createAndStartProcess(
            containerId: "demo-api-1",
            processId: "process-123",
            configuration: configuration,
            stdio: []
        )
        let status = try await client.runAttachedProcess(
            containerId: "demo-api-1",
            processId: "process-456",
            configuration: configuration,
            interactive: true,
            tty: false
        )

        #expect(actualSnapshot.id == "demo-api-1")
        #expect(status == 0)
        #expect(await recorder.getRequests == ["demo-api-1"])
        #expect(await recorder.processRequests == [
            ContainerExecProcessRequest(
                containerId: "demo-api-1",
                processId: "process-123",
                executable: "date",
                arguments: ["-u"],
                environment: ["TZ=UTC"],
                workingDirectory: "/",
                terminal: false,
                user: "0:0",
                supplementalGroups: [],
                stdioCount: 0
            ),
        ])
        #expect(await recorder.attachedProcessRequests == [
            ContainerAttachedExecProcessRequest(
                containerId: "demo-api-1",
                processId: "process-456",
                executable: "date",
                arguments: ["-u"],
                environment: ["TZ=UTC"],
                workingDirectory: "/",
                terminal: false,
                user: "0:0",
                supplementalGroups: [],
                interactive: true,
                tty: false
            ),
        ])
    }

    @Test("image manager pulls only missing images through direct API")
    func imageManagerPullsOnlyMissingImagesThroughDirectAPI() async throws {
        let client = RecordingContainerImageAPIClient(existingReferences: ["example/api"])
        let manager = ContainerClientImageManager(client: client)

        let exists = try await manager.imageExists("example/api")
        try await manager.pullMissingImage("example/api")
        try await manager.pullMissingImage("postgres")

        #expect(exists == true)
        #expect(await client.requests == [
            .exists("example/api"),
            .exists("example/api"),
            .exists("postgres"),
            .pull("postgres"),
        ])
    }

    @Test("file pull metadata store persists pull dates")
    func filePullMetadataStorePersistsPullDates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("pull-metadata.json", isDirectory: false)
        let firstStore = FileComposePullMetadataStore(fileURL: fileURL)
        let recorded = Date(timeIntervalSince1970: 1_000_000)

        #expect(try await firstStore.lastPullDate(for: "example/api") == nil)
        try await firstStore.recordPullDate(recorded, for: "example/api")

        let secondStore = FileComposePullMetadataStore(fileURL: fileURL)
        #expect(try await secondStore.lastPullDate(for: "example/api") == recorded)
    }

    @Test("image manager emits pushed and deleted direct API references")
    func imageManagerEmitsPushedAndDeletedDirectAPIReferences() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerImageAPIClient(
            existingReferences: ["example/api:latest"],
            pushOutputs: ["example/api:latest": "registry.example.com/example/api:latest"],
            deleteOutputs: ["example/api:latest": "example/api:latest", "missing:latest": nil]
        )
        let manager = ContainerClientImageManager(client: client)

        try await manager.pullImage("example/api:latest")
        try await manager.pushImage("example/api:latest", emit: { emitted.append($0) })
        try await manager.deleteImage("example/api:latest", force: true, emit: { emitted.append($0) })
        try await manager.deleteImage("missing:latest", force: true, emit: { emitted.append($0) })

        #expect(await client.requests == [
            .pull("example/api:latest"),
            .push("example/api:latest"),
            .delete(reference: "example/api:latest", force: true),
            .delete(reference: "missing:latest", force: true),
        ])
        #expect(emitted.messages == [
            "registry.example.com/example/api:latest",
            "example/api:latest",
        ])
    }

    @Test("image API client forwards configured operations")
    func imageAPIClientForwardsConfiguredOperations() async throws {
        let recorder = RecordingContainerImageAPIClient(
            existingReferences: ["example/api:latest"],
            pushOutputs: ["example/api:latest": "registry.example.com/example/api:latest"],
            deleteOutputs: ["example/api:latest": "example/api:latest"]
        )
        let client = ContainerImageAPIClient(
            exists: { try await recorder.imageExists(reference: $0) },
            pull: { try await recorder.pullImage(reference: $0) },
            push: { try await recorder.pushImage(reference: $0) },
            delete: { try await recorder.deleteImage(reference: $0, force: $1) }
        )

        let exists = try await client.imageExists(reference: "example/api:latest")
        try await client.pullImage(reference: "example/api:latest")
        let pushed = try await client.pushImage(reference: "example/api:latest")
        let deleted = try await client.deleteImage(reference: "example/api:latest", force: true)

        #expect(exists == true)
        #expect(pushed == "registry.example.com/example/api:latest")
        #expect(deleted == "example/api:latest")
        #expect(await recorder.requests == [
            .exists("example/api:latest"),
            .pull("example/api:latest"),
            .push("example/api:latest"),
            .delete(reference: "example/api:latest", force: true),
        ])
    }

    @Test("image API client wraps an injected lower level client")
    func imageAPIClientWrapsInjectedLowerLevelClient() async throws {
        let recorder = RecordingContainerImageAPIClient(
            existingReferences: ["example/api:latest"],
            pushOutputs: ["example/api:latest": "registry.example.com/example/api:latest"],
            deleteOutputs: ["example/api:latest": "example/api:latest"]
        )
        let client = ContainerImageAPIClient(client: recorder)

        let exists = try await client.imageExists(reference: "example/api:latest")
        try await client.pullImage(reference: "example/api:latest")
        let pushed = try await client.pushImage(reference: "example/api:latest")
        let deleted = try await client.deleteImage(reference: "example/api:latest", force: true)

        #expect(exists == true)
        #expect(pushed == "registry.example.com/example/api:latest")
        #expect(deleted == "example/api:latest")
        #expect(await recorder.requests == [
            .exists("example/api:latest"),
            .pull("example/api:latest"),
            .push("example/api:latest"),
            .delete(reference: "example/api:latest", force: true),
        ])
    }

    @Test("resource manager maps compose resources to direct API client")
    func resourceManagerMapsComposeResourcesToDirectAPIClient() async throws {
        let client = RecordingContainerResourceAPIClient(volumes: [
            ComposeVolumeSummary(name: "demo_cache", labels: ["com.example.role": "cache"]),
        ])
        let manager = ContainerClientResourceManager(client: client)
        let labels = ["com.example.role": "cache"]

        try await manager.createNetwork(ComposeNetworkCreateRequest(
            name: "demo_default",
            isInternal: true,
            ipv4Subnet: "10.10.0.0/24",
            ipv6Subnet: "fd00:10::/64",
            labels: labels
        ))
        try await manager.createVolume(ComposeVolumeCreateRequest(
            name: "demo_cache",
            driver: "local",
            driverOpts: ["size": "64m"],
            labels: labels
        ))
        let volumes = try await manager.listVolumes()
        try await manager.deleteNetwork(id: "demo_default")
        try await manager.deleteVolume(name: "demo_cache")

        #expect(volumes == [ComposeVolumeSummary(name: "demo_cache", labels: labels)])
        #expect(await client.requests == [
            .createNetwork(
                name: "demo_default",
                mode: .hostOnly,
                plugin: "container-network-vmnet",
                ipv4Subnet: "10.10.0.0/24",
                ipv6Subnet: "fd00:10::/64",
                labels: labels
            ),
            .createVolume(ComposeVolumeCreateRequest(
                name: "demo_cache",
                driver: "local",
                driverOpts: ["size": "64m"],
                labels: labels
            )),
            .listVolumes,
            .deleteNetwork(id: "demo_default"),
            .deleteVolume(name: "demo_cache"),
        ])
    }

    @Test("resource manager ignores existing network create errors")
    func resourceManagerIgnoresExistingNetworkCreateErrors() async throws {
        let client = RecordingContainerResourceAPIClient(networkCreateError: ContainerizationError(
            .exists,
            message: "network demo_default already exists"
        ))
        let manager = ContainerClientResourceManager(client: client)

        try await manager.createNetwork(ComposeNetworkCreateRequest(name: "demo_default"))

        #expect(await client.requests == [
            .createNetwork(
                name: "demo_default",
                mode: .nat,
                plugin: "container-network-vmnet",
                ipv4Subnet: nil,
                ipv6Subnet: nil,
                labels: [:]
            ),
        ])
    }

    @Test("resource manager rejects invalid network subnet before API create")
    func resourceManagerRejectsInvalidNetworkSubnetBeforeAPICreate() async throws {
        let client = RecordingContainerResourceAPIClient()
        let manager = ContainerClientResourceManager(client: client)

        do {
            try await manager.createNetwork(ComposeNetworkCreateRequest(
                name: "demo_default",
                ipv4Subnet: "not-a-cidr"
            ))
            Issue.record("Expected invalid subnet error")
        } catch CIDR.Error.invalidCIDR(let cidr) {
            #expect(cidr == "not-a-cidr")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests.isEmpty)
    }

    @Test("resource API client forwards configured operations")
    func resourceAPIClientForwardsConfiguredOperations() async throws {
        let recorder = RecordingContainerResourceAPIClient()
        let client = ContainerResourceAPIClient(
            createNetwork: { configuration in
                try await recorder.createNetwork(configuration: configuration)
            },
            deleteNetwork: { id in
                try await recorder.deleteNetwork(id: id)
            },
            createVolume: { request in
                try await recorder.createVolume(request)
            },
            listVolumes: {
                try await recorder.listVolumes()
            },
            deleteVolume: { name in
                try await recorder.deleteVolume(name: name)
            }
        )
        let labels = ["com.example.role": "cache"]
        let configuration = try NetworkConfiguration(
            name: "demo_default",
            mode: .nat,
            labels: try ResourceLabels(labels),
            plugin: "container-network-vmnet"
        )

        try await client.createNetwork(configuration: configuration)
        try await client.createVolume(ComposeVolumeCreateRequest(
            name: "demo_cache",
            driver: "local",
            driverOpts: ["size": "64m"],
            labels: labels
        ))
        _ = try await client.listVolumes()
        try await client.deleteNetwork(id: "demo_default")
        try await client.deleteVolume(name: "demo_cache")

        #expect(await recorder.requests == [
            .createNetwork(
                name: "demo_default",
                mode: .nat,
                plugin: "container-network-vmnet",
                ipv4Subnet: nil,
                ipv6Subnet: nil,
                labels: labels
            ),
            .createVolume(ComposeVolumeCreateRequest(
                name: "demo_cache",
                driver: "local",
                driverOpts: ["size": "64m"],
                labels: labels
            )),
            .listVolumes,
            .deleteNetwork(id: "demo_default"),
            .deleteVolume(name: "demo_cache"),
        ])
    }

    @Test("rm supports force and anonymous volume removal")
    func rmSupportsForceAndAnonymousVolumeRemoval() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        )
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
        #expect(commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-api-1", force: true),
        ])
        let resources = await resourceManager.requests
        #expect(resources.count == 1)
        #expect(resources.first?.name.hasPrefix("demo_anon-") == true)
        #expect(!commands.contains { $0.contains("demo_cache") })
    }

    @Test("rm surfaces anonymous volume removal failures")
    func rmSurfacesAnonymousVolumeRemovalFailures() async throws {
        let runner = RecordingRunner()
        let expected = ComposeError.invalidProject("anonymous volume delete failed")
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager(volumeDeleteError: expected)
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.volumes = [
                        ComposeMount(type: "volume", target: "/scratch"),
                    ]
                },
            ]
        )

        do {
            try await orchestrator.rm(project: project, services: ["api"], stopFirst: false, force: true, volumes: true)
            Issue.record("Expected anonymous volume delete failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-api-1", force: true),
        ])
        let resources = await resourceManager.requests
        #expect(resources.count == 1)
        #expect(resources.first?.name.hasPrefix("demo_anon-") == true)
    }

    @Test("lifecycle timeout overrides service stop grace period")
    func lifecycleTimeoutOverridesServiceStopGracePeriod() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
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

        try await orchestrator.stop(project: project, services: ["api"], timeout: 12)
        try await orchestrator.restart(project: project, services: ["api"], timeout: 13)
        try await orchestrator.down(project: project, options: ComposeDownOptions(timeout: 14))

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 12),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 13),
            .start(id: "demo-api-1"),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 14),
            .delete(id: "demo-api-1", force: false),
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

        do {
            try await orchestrator.up(project: project, options: ComposeUpOptions {
                $0.timeout = -1
            })
            Issue.record("Expected invalid up timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("up --timeout must be between 0 and 2147483647 seconds"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("exec disables TTY while keeping stdin interactive")
    func execDisablesTTYWhileKeepingStdinInteractive() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let orchestrator = ComposeOrchestrator(runner: runner, execManager: execManager)
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

        #expect(runner.commands.isEmpty)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["echo", "ok"],
                interactive: true,
                tty: false
            ),
        ])
    }

    @Test("exec maps environment user workdir and detach options")
    func execMapsEnvironmentUserWorkdirAndDetachOptions() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let execManager = RecordingContainerExecManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            execManager: execManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            options: ComposeExecOptions {
                $0.command = ["env"]
                $0.detach = true
                $0.environment = ["FOO=bar", "DEBUG"]
                $0.user = "1000:1000"
                $0.workingDirectory = "/app"
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await execManager.requests == [
            ContainerDetachedExecRequest(
                id: "demo-api-1",
                command: ["env"],
                environment: ["FOO=bar", "DEBUG"],
                user: "1000:1000",
                workingDirectory: "/app"
            ),
        ])
        #expect(emitted.messages == ["demo-api-1"])
    }

    @Test("exec dry run renders detached runtime command")
    func execDryRunRendersDetachedRuntimeCommand() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let execManager = RecordingContainerExecManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            execManager: execManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            options: ComposeExecOptions {
                $0.command = ["sleep", "60"]
                $0.detach = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(emitted.messages == ["+ container exec --detach demo-api-1 sleep 60"])
        #expect(await execManager.requests.isEmpty)
    }

    @Test("exec resolves selected service container indexes")
    func execResolvesSelectedServiceContainerIndexes() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
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
        let orchestrator = ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.execManager = execManager
        })
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            options: ComposeExecOptions {
                $0.command = ["true"]
                $0.index = 2
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-2",
                command: ["true"],
                interactive: true,
                tty: true
            ),
        ])
    }

    @Test("exec dry run renders selected service container indexes")
    func execDryRunRendersSelectedServiceContainerIndexes() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            options: ComposeExecOptions {
                $0.command = ["true"]
                $0.index = 2
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(emitted.messages == ["+ container exec --interactive --tty demo-api-2 true"])
        #expect(await discoveryManager.listRequests.isEmpty)
    }

    @Test("exec reports missing selected service container indexes")
    func execReportsMissingSelectedServiceContainerIndexes() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.execManager = execManager
        })
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await orchestrator.exec(
                project: project,
                serviceName: "api",
                options: ComposeExecOptions {
                    $0.command = ["true"]
                    $0.index = 2
                }
            )
            Issue.record("Expected missing indexed container error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' container 'demo-api-2' does not exist"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await execManager.attachedRequests.isEmpty)
    }

    @Test("exec rejects privileged mode before runtime commands")
    func execRejectsPrivilegedModeBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await orchestrator.exec(
                project: project,
                serviceName: "api",
                options: ComposeExecOptions {
                    $0.command = ["true"]
                    $0.privileged = true
                }
            )
            Issue.record("Expected unsupported exec privileged error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("exec --privileged: apple/container exec does not expose privileged process execution"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("logs accepts Compose all tail value")
    func logsAcceptsComposeAllTailValue() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["hello"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(project: project, services: ["api"], follow: false, tail: "all")

        #expect(runner.commands.isEmpty)
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
        ])
        #expect(emitted.messages == ["hello"])
    }

    @Test("logs targets selected container index")
    func logsTargetsSelectedContainerIndex() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["replica-log"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
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
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).logs(project: project, services: ["api"], follow: false, tail: nil, index: 2)

        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-2", tail: nil, follow: false),
        ])
        #expect(emitted.messages == ["replica-log"])
    }

    @Test("logs dry run emits runtime command instead of direct API logs")
    func logsDryRunEmitsRuntimeCommandInsteadOfDirectAPILogs() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(project: project, services: ["api"], follow: true, tail: "10")

        #expect(emitted.messages == [
            "+ container logs --follow -n 10 demo-api-1",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("logs dry run emits indexed runtime command")
    func logsDryRunEmitsIndexedRuntimeCommand() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(project: project, services: ["api"], follow: true, tail: "10", index: 2)

        #expect(emitted.messages == [
            "+ container logs --follow -n 10 demo-api-2",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("watch dry run emits the validated trigger plan")
    func watchDryRunEmitsValidatedTriggerPlan() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "src", action: "rebuild", ignore: [".build/"]),
                        ComposeDevelopWatch(
                            path: "assets",
                            action: "sync+exec",
                            target: "/app/assets",
                            include: ["*.swift"],
                            initialSync: true,
                            exec: ComposeDevelopWatchExec(command: ["sh", "-c", "touch /tmp/reloaded"])
                        ),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        ).watch(
            project: project,
            options: ComposeWatchOptions(services: ["api"], noUp: true, prune: false, quiet: true)
        )

        #expect(emitted.messages == [
            "compose: watch project demo services api",
            "compose: watch initial-up disabled",
            "compose: watch prune disabled",
            "compose: watch quiet enabled",
            "compose: watch api rebuild path=src ignore=.build/",
            "compose: watch api sync+exec path=assets target=/app/assets include=*.swift initial-sync=true exec=sh -c 'touch /tmp/reloaded'",
        ])
        #expect(runner.commands.isEmpty)
    }

    @Test("watch validates develop triggers before runtime loop")
    func watchValidatesDevelopTriggersBeforeRuntimeLoop() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "src", action: "rebuild"),
                        ComposeDevelopWatch(path: "assets", action: "sync", target: "/app/assets"),
                    ])
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).watch(
                project: project,
                options: ComposeWatchOptions(services: ["api"], noUp: true, prune: false, quiet: true)
            )
            Issue.record("Expected watch runtime-loop gap")
        } catch let error as ComposeError {
            #expect(error == .unsupported("watch: file watching and develop actions are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("watch rejects services without develop triggers")
    func watchRejectsServicesWithoutDevelopTriggers() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).watch(project: project, options: ComposeWatchOptions(services: ["api"]))
            Issue.record("Expected missing watch trigger error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("selected services does not declare develop.watch triggers"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("watch rejects malformed develop triggers")
    func watchRejectsMalformedDevelopTriggers() async throws {
        let cases: [(trigger: ComposeDevelopWatch, error: ComposeError)] = [
            (
                ComposeDevelopWatch(path: "", action: "rebuild"),
                .invalidProject("service 'api' has a develop.watch trigger without a path")
            ),
            (
                ComposeDevelopWatch(path: "src", action: "sync"),
                .invalidProject("service 'api' develop.watch action 'sync' requires a target")
            ),
            (
                ComposeDevelopWatch(path: "src", action: "sync+exec", target: "/app/src"),
                .invalidProject("service 'api' develop.watch action 'sync+exec' requires exec metadata")
            ),
        ]

        for testCase in cases {
            let runner = RecordingRunner()
            let project = ComposeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        $0.develop = ComposeDevelop(watch: [testCase.trigger])
                    },
                ]
            )

            do {
                try await ComposeOrchestrator(runner: runner).watch(project: project)
                Issue.record("Expected malformed watch trigger error")
            } catch let error as ComposeError {
                #expect(error == testCase.error)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("attach output-only mode follows direct logs")
    func attachOutputOnlyModeFollowsDirectLogs() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["attached"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.sigProxy = "false"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true),
        ])
        #expect(emitted.messages == ["attached"])
    }

    @Test("attach output-only mode targets selected container index")
    func attachOutputOnlyModeTargetsSelectedContainerIndex() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["replica"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
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
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.index = 2
                $0.sigProxy = "false"
            }
        )

        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-2", tail: nil, follow: true),
        ])
        #expect(emitted.messages == ["replica"])
    }

    @Test("attach dry run emits logs follow command")
    func attachDryRunEmitsLogsFollowCommand() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.sigProxy = "false"
            }
        )

        #expect(emitted.messages == [
            "+ container logs --follow demo-api-1",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("attach dry run emits indexed logs follow command")
    func attachDryRunEmitsIndexedLogsFollowCommand() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.index = 2
                $0.sigProxy = "false"
            }
        )

        #expect(emitted.messages == [
            "+ container logs --follow demo-api-2",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("attach rejects unsupported stdin signal and detach options")
    func attachRejectsUnsupportedStdinSignalAndDetachOptions() async throws {
        let cases: [(options: ComposeAttachOptions, error: ComposeError)] = [
            (
                ComposeAttachOptions(),
                .unsupported("attach: apple/container logs is output-only; use --no-stdin --sig-proxy=false")
            ),
            (
                ComposeAttachOptions {
                    $0.noStdin = true
                    $0.sigProxy = "true"
                },
                .unsupported("attach --sig-proxy=true: apple/container logs does not proxy signals to service processes; use --sig-proxy=false")
            ),
            (
                ComposeAttachOptions {
                    $0.noStdin = true
                    $0.sigProxy = "false"
                    $0.detachKeys = "ctrl-x"
                },
                .unsupported("attach --detach-keys: apple/container logs does not expose detach key handling")
            ),
            (
                ComposeAttachOptions {
                    $0.sigProxy = "false"
                },
                .unsupported("attach: apple/container logs is output-only; use --no-stdin --sig-proxy=false")
            ),
        ]
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        for testCase in cases {
            let runner = RecordingRunner()
            let logManager = RecordingContainerLogManager()
            do {
                try await ComposeOrchestrator(
                    runner: runner,
                    options: ComposeExecutionOptions(),
                    logManager: logManager
                ).attach(
                    project: project,
                    serviceName: "api",
                    options: testCase.options
                )
                Issue.record("Expected attach option validation error")
            } catch let error as ComposeError {
                #expect(error == testCase.error)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
            #expect(await logManager.requests.isEmpty)
        }
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
        try await orchestrator.copy(project: project, arguments: ["./seed.sql", "db:/docker-entrypoint-initdb.d/seed.sql"])
        try await orchestrator.copy(project: project, arguments: ["api:/tmp/report.txt", "db:/restore/report.txt"])
        try await orchestrator.copy(project: project, arguments: ["./local:file.txt", "./out:file.txt"])

        #expect(runner.commands.map(\.arguments) == [
            ["container", "cp", "./local:file.txt", "./out:file.txt"],
        ])
        #expect(await copier.requests == [
            .from(id: "demo-api-1", source: "/tmp/report.txt", destination: "./report.txt"),
            .into(id: "custom-db", source: "./seed.sql", destination: "/docker-entrypoint-initdb.d/seed.sql"),
            .between(sourceID: "demo-api-1", source: "/tmp/report.txt", destinationID: "custom-db", destination: "/restore/report.txt"),
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
            .between(sourceID: "demo-api-1", source: "/tmp/report.txt", destinationID: "demo-worker-1", destination: "/var/lib/report.txt"),
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
        ])
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

    @Test("cp dry run emits runtime command instead of direct API copy")
    func cpDryRunEmitsRuntimeCommandInsteadOfDirectAPICopy() async throws {
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
            "+ container cp demo-api-1:/tmp/report.txt ./report.txt",
        ])
        #expect(runner.commands.isEmpty)
        #expect(await copier.requests.isEmpty)
    }

    @Test("container copier stages service-to-service copies on the host")
    func containerCopierStagesServiceToServiceCopiesOnTheHost() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination in
                try await operations.copyInto(id: id, source: source, destination: destination)
            },
            copyFrom: { id, source, destination in
                try await operations.copyFrom(id: id, source: source, destination: destination)
            }
        )

        try await copier.copyBetweenContainers(
            sourceID: "demo-api-1",
            source: "/tmp/report.txt",
            destinationID: "demo-worker-1",
            destination: "/var/lib/report.txt"
        )

        let requests = await operations.requests
        #expect(requests.count == 2)
        guard case .from(let sourceID, let source, let stagedPath) = requests[0] else {
            Issue.record("Expected source container copy-out request")
            return
        }
        guard case .into(let destinationID, let stagedSource, let destination) = requests[1] else {
            Issue.record("Expected destination container copy-in request")
            return
        }
        #expect(sourceID == "demo-api-1")
        #expect(source == "/tmp/report.txt")
        #expect((stagedPath as NSString).lastPathComponent == "report.txt")
        #expect(destinationID == "demo-worker-1")
        #expect(stagedSource == stagedPath)
        #expect(destination == "/var/lib/report.txt")
        #expect(!FileManager.default.fileExists(atPath: (stagedPath as NSString).deletingLastPathComponent))
    }

    @Test("container copier rejects root source for service-to-service copies")
    func containerCopierRejectsRootSourceForServiceToServiceCopies() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination in
                try await operations.copyInto(id: id, source: source, destination: destination)
            },
            copyFrom: { id, source, destination in
                try await operations.copyFrom(id: id, source: source, destination: destination)
            }
        )

        do {
            try await copier.copyBetweenContainers(
                sourceID: "demo-api-1",
                source: "/",
                destinationID: "demo-worker-1",
                destination: "/restore"
            )
            Issue.record("Expected root source copy failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("source path has no last component: /"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await operations.requests.isEmpty)
    }

    @Test("cp rejects unsupported command options before runtime copy")
    func cpRejectsUnsupportedCommandOptionsBeforeRuntimeCopy() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )
        let cases: [(name: String, options: ComposeCopyOptions, expected: ComposeError)] = [
            (
                name: "--archive",
                options: ComposeCopyOptions {
                    $0.arguments = ["api:/tmp/report.txt", "./report.txt"]
                    $0.archive = true
                },
                expected: .unsupported("cp --archive: apple/container cp does not expose archive mode")
            ),
            (
                name: "--follow-link",
                options: ComposeCopyOptions {
                    $0.arguments = ["api:/tmp/report.txt", "./report.txt"]
                    $0.followLink = true
                },
                expected: .unsupported("cp --follow-link: apple/container cp does not expose follow-link mode")
            ),
        ]

        for testCase in cases {
            let runner = RecordingRunner()
            let copier = RecordingContainerCopier()
            do {
                try await ComposeOrchestrator(runner: runner, copier: copier).copy(project: project, options: testCase.options)
                Issue.record("Expected unsupported cp \(testCase.name) error")
            } catch let error as ComposeError {
                #expect(error == testCase.expected)
            } catch {
                Issue.record("Unexpected error for cp \(testCase.name): \(error)")
            }
            #expect(runner.commands.isEmpty)
            #expect(await copier.requests.isEmpty)
        }
    }

    @Test("cp all stages service to service copies into every destination container")
    func cpAllStagesServiceToServiceCopiesIntoEveryDestinationContainer() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
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
        ])
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
            .between(sourceID: "demo-api-1", source: "/tmp/report.txt", destinationID: "demo-worker-1", destination: "/tmp/report.txt"),
            .between(sourceID: "demo-api-1", source: "/tmp/report.txt", destinationID: "demo-worker-run-first", destination: "/tmp/report.txt"),
        ])
    }

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
            ContainerExportRequest(id: "demo-api-1", output: nil),
            ContainerExportRequest(id: "custom-db", output: "db.tar"),
        ])
        #expect(runner.commands.isEmpty)
    }

    @Test("export dry run emits runtime command")
    func exportDryRunEmitsRuntimeCommand() async throws {
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
            "+ container export --output api.tar demo-api-1",
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
        #expect(await exporter.requests == [
            ContainerExportRequest(id: "demo-api-2", output: "api.tar"),
        ])
    }

    @Test("port prints runtime published bindings")
    func portPrintsRuntimePublishedBindings() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
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

    @Test("port rejects dynamic bindings that need explicit host ports")
    func portRejectsDynamicBindingsThatNeedExplicitHostPorts() async throws {
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
            try await orchestrator.port(project: project, serviceName: "api", privatePort: "80", protocolName: "tcp", index: 1)
            Issue.record("Expected unsupported dynamic port lookup")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' publishes target port 80/tcp dynamically; apple/container publish requires explicit host ports"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("port resolves explicit ranges from runtime published ports")
    func portResolvesExplicitRangesFromRuntimePublishedPorts() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
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
                    $0.dnsOptions = ["use-vc"]
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
        #expect(command.containsSequence(["--dns-option", "use-vc"]))
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

    @Test("run rejects dynamic published ports only when publishing them")
    func runRejectsDynamicPublishedPortsOnlyWhenPublishingThem() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.ports = ["80"]
                },
            ]
        )

        let defaultRunner = RecordingRunner()
        try await ComposeOrchestrator(runner: defaultRunner).run(
            project: project,
            serviceName: "api",
            options: composeRunOptions(command: ["true"])
        )
        let defaultCommand = try #require(defaultRunner.commands.first?.arguments)
        #expect(!defaultCommand.contains("--publish"))

        let servicePortsRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: servicePortsRunner).run(
                project: project,
                serviceName: "api",
                options: composeRunOptions(command: ["true"]) {
                    $0.servicePorts = true
                }
            )
            Issue.record("Expected unsupported dynamic service port failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' publishes target port 80/tcp dynamically; apple/container publish requires explicit host ports"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(servicePortsRunner.commands.isEmpty)

        let hostIPRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: hostIPRunner).run(
                project: project,
                serviceName: "api",
                options: composeRunOptions(command: ["true"]) {
                    $0.publish = ["127.0.0.1:80"]
                }
            )
            Issue.record("Expected unsupported host IP dynamic publish failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' publishes target port 80/tcp dynamically; apple/container publish requires explicit host ports"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(hostIPRunner.commands.isEmpty)

        let publishRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: publishRunner).run(
                project: project,
                serviceName: "api",
                options: composeRunOptions(command: ["true"]) {
                    $0.publish = ["80/udp"]
                }
            )
            Issue.record("Expected unsupported dynamic run publish failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' publishes target port 80/udp dynamically; apple/container publish requires explicit host ports"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(publishRunner.commands.isEmpty)
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
        #expect(await imageManager.requests == [.pull("alpine")])
        #expect(commands[0].starts(with: ["container", "run", "--name"]))
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
        #expect(commands[0].last == "job")
        #expect(commands[1].starts(with: ["container", "run", "--name"]))
        #expect(Array(commands[1].suffix(2)) == ["example/job", "true"])
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
                    $0.develop = ComposeDevelop()
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
                    $0.build = ComposeBuild(
                        context: "job",
                        options: ComposeBuild.Options(unsupportedFields: ["entitlements", "ssh"])
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
            #expect(error == .unsupported("service 'job' uses unsupported build fields entitlements, ssh; advanced build fields need Docker Compose compatible apple/container build primitives"))
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
                    $0.unsupportedDeployFields = ["restart_policy"]
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
            #expect(error == .unsupported("service 'job' uses deploy.restart_policy; restart policy support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects deploy endpoint mode as a networking runtime gap")
    func runRejectsDeployEndpointModeAsNetworkingRuntimeGap() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.unsupportedDeployFields = ["endpoint_mode"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported deploy endpoint mode error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses deploy.endpoint_mode; service endpoint mode support needs an apple/container networking gap PR"))
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

    @Test("run rejects external container volumes_from before creating resources")
    func runRejectsExternalContainerVolumesFromBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "example/job") {
                    $0.volumesFrom = ["container:legacy:ro"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported external volumes_from error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses volumes_from 'container:legacy:ro'; external container volume inheritance is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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
                            unsupportedFields: ["volume.nocopy", "volume.subpath", "volume.nocopy"]
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
            #expect(error == .unsupported("service 'job' uses unsupported volume fields volume.nocopy, volume.subpath; advanced service volume options are not implemented by container-compose yet"))
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
                            readOnly: true,
                            tmpfsSize: "67108864",
                            tmpfsMode: "1777"
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
        #expect(await imageManager.requests == [.pull("alpine")])
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
        #expect(await presentImages.requests == [.pullMissing("alpine")])
        #expect(presentCommands[0].starts(with: ["container", "run"]))
        let absentCommands = absentRunner.commands.map(\.arguments)
        #expect(await absentImages.requests == [.pullMissing("alpine")])
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
        #expect(await imageManager.requests == [.pullMissing("alpine")])
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

    @Test("up applies service annotations as runtime metadata labels")
    func upAppliesServiceAnnotationsAsRuntimeMetadataLabels() async throws {
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
        #expect(command.containsSequence(["--label", "example.com/owner=platform"]))
        #expect(command.containsSequence(["--label", "example.com/purpose=local-dev"]))
    }

    @Test("up rejects service annotation label conflicts before creating resources")
    func upRejectsServiceAnnotationLabelConflictsBeforeCreatingResources() async throws {
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

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected annotation conflict error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' annotation 'com.example.role' conflicts with a service label mapped to the same runtime metadata key"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests == [])
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

    @Test("run rejects label overrides that conflict with service annotations")
    func runRejectsLabelOverridesThatConflictWithServiceAnnotations() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.annotations = ["com.example.owner": "platform"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["true"]) {
                    $0.labels = ["com.example.owner=override"]
                }
            )
            Issue.record("Expected annotation override conflict")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("run --label cannot override service 'job' annotation 'com.example.owner' because annotations map to runtime metadata labels"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run applies one-off volume overrides")
    func runAppliesOneOffVolumeOverrides() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.volumes = [ComposeMount(type: "bind", source: "/default", target: "/default")]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["ls"]) {
                $0.volumes = ["/host:/container:ro", "cache:/cache", "/scratch"]
            }
        )

        #expect(await resourceManager.requests == [
            .createVolume(ComposeVolumeCreateRequest(name: "demo_cache", labels: [
                "com.apple.container.compose.project": "demo",
                "com.apple.container.compose.version": "1",
                "com.apple.container.compose.project.working-directory": FileManager.default.currentDirectoryPath,
                "com.apple.container.compose.project.config-files": "",
                "com.apple.container.compose.project.config-files-hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ])),
        ])
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

    @Test("up ignores deploy labels when comparing runtime config hashes")
    func upIgnoresDeployLabelsWhenComparingRuntimeConfigHashes() async throws {
        let initialProject = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])
        let createDiscovery = RecordingContainerDiscoveryManager()
        let createRunner = RecordingRunner(responses: [.success])

        try await ComposeOrchestrator(
            runner: createRunner,
            discoveryManager: createDiscovery
        ).up(project: initialProject, options: ComposeUpOptions())

        let run = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: run))
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: hash]),
        ])
        let projectWithDeployLabels = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployLabels = ["com.example.service": "api"]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        ).up(project: projectWithDeployLabels, options: ComposeUpOptions())

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
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

private extension CommandResult {
    static let success = CommandResult(status: 0, stdout: "", stderr: "")
    static let failure = CommandResult(status: 1, stdout: "", stderr: "")
}

private let composeConfigHashLabel = "com.apple.container.compose.config-hash"
private let composeOneOffLabel = "com.apple.container.compose.oneoff"
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
            composeName: "volume_driver",
            reason: "service-level volume driver support is not implemented by container-compose yet",
            configure: { $0.volumeDriver = "local" }
        ),
    ]
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

private func discoveredContainers() -> [ComposeContainerSummary] {
    [
        ComposeContainerSummary(
            id: "demo-api-1",
            status: "running",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "api",
                composeConfigHashLabel: "api-hash",
                composeProjectConfigFilesLabel: "/tmp/demo/compose.yml,/tmp/demo/compose.override.yml",
            ],
            imageReference: "localhost:5000/example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        ),
        ComposeContainerSummary(
            id: "other-api-1",
            status: "running",
            labels: [
                composeProjectLabel: "other",
                composeServiceLabel: "api",
                composeConfigHashLabel: "other-hash",
                composeProjectConfigFilesLabel: "/tmp/other/compose.yml",
            ],
            imageReference: "other/api:latest",
            imageDigest: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            platform: "linux/arm64"
        ),
        ComposeContainerSummary(
            id: "demo-worker-1",
            status: "stopped",
            labels: [
                composeProjectLabel: "demo",
                composeServiceLabel: "worker",
                composeConfigHashLabel: "worker-hash",
                composeProjectConfigFilesLabel: "/tmp/demo/compose.yml",
            ],
            imageReference: "example/worker:debug",
            imageDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            platform: "linux/amd64"
        ),
    ]
}

private func containerSnapshot(
    id: String,
    status: RuntimeStatus,
    labels: [String: String] = [:],
    imageReference: String,
    imageDigest: String,
    platform: String,
    publishedPorts: [PublishPort] = []
) throws -> ContainerSnapshot {
    var configuration = ContainerConfiguration(
        id: id,
        image: ImageDescription(
            reference: imageReference,
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: imageDigest,
                size: 0
            )
        ),
        process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
    )
    configuration.labels = labels
    configuration.platform = try ociPlatform(platform)
    configuration.publishedPorts = publishedPorts
    return ContainerSnapshot(configuration: configuration, status: status, networks: [])
}

private func ociPlatform(_ value: String) throws -> Platform {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else {
        throw ComposeError.invalidProject("invalid platform fixture '\(value)'")
    }
    let variant = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
    return Platform(arch: parts[1], os: parts[0], variant: variant)
}

private func temporaryLogFileHandle(contents: String) throws -> FileHandle {
    try temporaryLogFileHandle(data: Data(contents.utf8))
}

private func temporaryLogFileHandle(data: Data) throws -> FileHandle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("log")
    try data.write(to: url)
    let handle = try FileHandle(forReadingFrom: url)
    try? FileManager.default.removeItem(at: url)
    return handle
}

private func containerStats(
    id: String,
    cpuUsageUsec: UInt64?,
    memoryUsageBytes: UInt64? = 1_048_576,
    memoryLimitBytes: UInt64? = 2_097_152,
    networkRxBytes: UInt64? = 1_024,
    networkTxBytes: UInt64? = 2_048,
    blockReadBytes: UInt64? = 4_096,
    blockWriteBytes: UInt64? = 8_192,
    numProcesses: UInt64? = 3
) -> ContainerStats {
    ContainerStats(
        id: id,
        memoryUsageBytes: memoryUsageBytes,
        memoryLimitBytes: memoryLimitBytes,
        cpuUsageUsec: cpuUsageUsec,
        networkRxBytes: networkRxBytes,
        networkTxBytes: networkTxBytes,
        blockReadBytes: blockReadBytes,
        blockWriteBytes: blockWriteBytes,
        numProcesses: numProcesses
    )
}

private struct ListedContainer: Decodable {
    var id: String
}

private func listedContainerIDs(from output: String) throws -> [String] {
    try JSONDecoder().decode([ListedContainer].self, from: Data(output.utf8)).map(\.id)
}

private struct ContainerExportRequest: Equatable {
    var id: String
    var output: String?
}

private enum ContainerCopyRequest: Equatable {
    case into(id: String, source: String, destination: String)
    case from(id: String, source: String, destination: String)
    case between(sourceID: String, source: String, destinationID: String, destination: String)
}

private enum ContainerLifecycleRequest: Equatable {
    case start(id: String)
    case kill(id: String, signal: String)
    case stop(id: String, signal: String?, timeoutInSeconds: Int?)
    case wait(id: String)
    case delete(id: String, force: Bool)
}

private struct ContainerLogRequest: Equatable {
    var id: String
    var tail: Int?
    var follow: Bool
}

private struct ContainerExecProcessRequest: Equatable {
    var containerId: String
    var processId: String
    var executable: String
    var arguments: [String]
    var environment: [String]
    var workingDirectory: String
    var terminal: Bool
    var user: String
    var supplementalGroups: [UInt32]
    var stdioCount: Int
}

private struct ContainerAttachedExecProcessRequest: Equatable {
    var containerId: String
    var processId: String
    var executable: String
    var arguments: [String]
    var environment: [String]
    var workingDirectory: String
    var terminal: Bool
    var user: String
    var supplementalGroups: [UInt32]
    var interactive: Bool
    var tty: Bool
}

private struct ContainerStatsRequest: Equatable {
    var ids: [String]
    var format: String
    var noStream: Bool
    var includeStopped: Bool
}

private enum ContainerImageRequest: Equatable {
    case exists(String)
    case pull(String)
    case pullMissing(String)
    case push(String)
    case delete(reference: String, force: Bool)
}

private enum ContainerResourceRequest: Equatable {
    case createNetwork(ComposeNetworkCreateRequest)
    case deleteNetwork(id: String)
    case createVolume(ComposeVolumeCreateRequest)
    case listVolumes
    case deleteVolume(name: String)

    var name: String {
        switch self {
        case .createNetwork(let request):
            request.name
        case .createVolume(let request):
            request.name
        case .deleteVolume(let name):
            name
        case .listVolumes:
            ""
        case .deleteNetwork(let id):
            id
        }
    }

    var labels: [String: String] {
        switch self {
        case .createNetwork(let request):
            request.labels
        case .createVolume(let request):
            request.labels
        case .deleteNetwork, .listVolumes, .deleteVolume:
            [:]
        }
    }
}

private enum ContainerResourceAPIRequest: Equatable {
    case createNetwork(
        name: String,
        mode: NetworkMode,
        plugin: String,
        ipv4Subnet: String?,
        ipv6Subnet: String?,
        labels: [String: String]
    )
    case deleteNetwork(id: String)
    case createVolume(ComposeVolumeCreateRequest)
    case listVolumes
    case deleteVolume(name: String)
}

private actor RecordingContainerCopier: ContainerCopying {
    private var storage: [ContainerCopyRequest] = []

    var requests: [ContainerCopyRequest] {
        storage
    }

    func copyIntoContainer(id: String, source: String, destination: String) async throws {
        storage.append(.into(id: id, source: source, destination: destination))
    }

    func copyFromContainer(id: String, source: String, destination: String) async throws {
        storage.append(.from(id: id, source: source, destination: destination))
    }

    func copyBetweenContainers(sourceID: String, source: String, destinationID: String, destination: String) async throws {
        storage.append(.between(sourceID: sourceID, source: source, destinationID: destinationID, destination: destination))
    }
}

private actor RecordingContainerCopyOperations {
    private var storage: [ContainerCopyRequest] = []

    var requests: [ContainerCopyRequest] {
        storage
    }

    func copyInto(id: String, source: String, destination: String) async throws {
        guard FileManager.default.fileExists(atPath: source) else {
            throw ComposeError.invalidProject("source path does not exist: \(source)")
        }
        storage.append(.into(id: id, source: source, destination: destination))
    }

    func copyFrom(id: String, source: String, destination: String) async throws {
        storage.append(.from(id: id, source: source, destination: destination))
        let destinationURL = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("staged".utf8).write(to: destinationURL)
    }
}

private actor RecordingContainerLifecycleManager: ContainerLifecycleManaging {
    private let stopError: (any Error)?
    private let deleteError: (any Error)?
    private let waitExitCodes: [String: Int32]
    private var storage: [ContainerLifecycleRequest] = []

    init(stopError: (any Error)? = nil, deleteError: (any Error)? = nil, waitExitCodes: [String: Int32] = [:]) {
        self.stopError = stopError
        self.deleteError = deleteError
        self.waitExitCodes = waitExitCodes
    }

    var requests: [ContainerLifecycleRequest] {
        storage
    }

    func startContainer(id: String) async throws {
        storage.append(.start(id: id))
    }

    func killContainer(id: String, signal: String) async throws {
        storage.append(.kill(id: id, signal: signal))
    }

    func stopContainer(id: String, signal: String?, timeoutInSeconds: Int?) async throws {
        storage.append(.stop(id: id, signal: signal, timeoutInSeconds: timeoutInSeconds))
        if let stopError {
            throw stopError
        }
    }

    func waitContainer(id: String) async throws -> Int32 {
        storage.append(.wait(id: id))
        return waitExitCodes[id] ?? 0
    }

    func deleteContainer(id: String, force: Bool) async throws {
        storage.append(.delete(id: id, force: force))
        if let deleteError {
            throw deleteError
        }
    }
}

private actor RecordingContainerDiscoveryManager: ContainerDiscoveryManaging {
    private let containers: [ComposeContainerSummary]
    private var lists: [Bool] = []
    private var gets: [String] = []

    init(containers: [ComposeContainerSummary] = []) {
        self.containers = containers
    }

    var listRequests: [Bool] {
        lists
    }

    var getRequests: [String] {
        gets
    }

    func listContainers(all: Bool) async throws -> [ComposeContainerSummary] {
        lists.append(all)
        if all {
            return containers
        }
        return containers.filter { $0.status == "running" }
    }

    func getContainer(id: String) async throws -> ComposeContainerSummary? {
        gets.append(id)
        return containers.first { $0.id == id }
    }
}

private actor RecordingContainerDiscoveryAPIClient: ContainerDiscoveryAPIClienting {
    private let listResponse: [ContainerSnapshot]
    private let getResponse: ContainerSnapshot?
    private let getError: (any Error)?
    private var filters: [ContainerListFilters] = []
    private var gets: [String] = []

    init(
        listResponse: [ContainerSnapshot] = [],
        getResponse: ContainerSnapshot? = nil,
        getError: (any Error)? = nil
    ) {
        self.listResponse = listResponse
        self.getResponse = getResponse
        self.getError = getError
    }

    var listFilters: [ContainerListFilters] {
        filters
    }

    var getRequests: [String] {
        gets
    }

    func listContainers(filters: ContainerListFilters) async throws -> [ContainerSnapshot] {
        self.filters.append(filters)
        return listResponse
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        gets.append(id)
        if let getError {
            throw getError
        }
        return getResponse
    }
}

private actor RecordingContainerLogManager: ContainerLogManaging {
    private let outputs: [String]
    private var storage: [ContainerLogRequest] = []

    init(outputs: [String] = []) {
        self.outputs = outputs
    }

    var requests: [ContainerLogRequest] {
        storage
    }

    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        storage.append(ContainerLogRequest(id: id, tail: tail, follow: follow))
        for output in outputs {
            emit(output)
        }
    }
}

private actor RecordingContainerLogAPIClient: ContainerLogAPIClienting {
    private let fileHandles: [FileHandle]
    private var storage: [String] = []

    init(fileHandles: [FileHandle] = []) {
        self.fileHandles = fileHandles
    }

    var requests: [String] {
        storage
    }

    func logFileHandles(id: String) async throws -> [FileHandle] {
        storage.append(id)
        return fileHandles
    }
}

private actor RecordingContainerExecManager: ContainerExecManaging {
    private let outputs: [String: String]
    private let attachedStatus: Int32
    private var attachedStorage: [ContainerAttachedExecRequest] = []
    private var storage: [ContainerDetachedExecRequest] = []

    init(outputs: [String: String] = [:], attachedStatus: Int32 = 0) {
        self.outputs = outputs
        self.attachedStatus = attachedStatus
    }

    var attachedRequests: [ContainerAttachedExecRequest] {
        attachedStorage
    }

    var requests: [ContainerDetachedExecRequest] {
        storage
    }

    func execAttached(request: ContainerAttachedExecRequest) async throws -> Int32 {
        attachedStorage.append(request)
        return attachedStatus
    }

    func execDetached(
        request: ContainerDetachedExecRequest,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        storage.append(request)
        emit(outputs[request.id] ?? request.id)
    }
}

private actor RecordingContainerExecAPIClient: ContainerExecAPIClienting {
    private let snapshots: [String: ContainerSnapshot]
    private let attachedStatus: Int32
    private var gets: [String] = []
    private var processes: [ContainerExecProcessRequest] = []
    private var attachedProcesses: [ContainerAttachedExecProcessRequest] = []

    init(snapshots: [ContainerSnapshot] = [], attachedStatus: Int32 = 0) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        self.attachedStatus = attachedStatus
    }

    var getRequests: [String] {
        gets
    }

    var processRequests: [ContainerExecProcessRequest] {
        processes
    }

    var attachedProcessRequests: [ContainerAttachedExecProcessRequest] {
        attachedProcesses
    }

    func getContainer(id: String) async throws -> ContainerSnapshot {
        gets.append(id)
        guard let snapshot = snapshots[id] else {
            throw ComposeError.invalidProject("missing snapshot \(id)")
        }
        return snapshot
    }

    func createAndStartProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        processes.append(ContainerExecProcessRequest(
            containerId: containerId,
            processId: processId,
            executable: configuration.executable,
            arguments: configuration.arguments,
            environment: configuration.environment,
            workingDirectory: configuration.workingDirectory,
            terminal: configuration.terminal,
            user: configuration.user.description,
            supplementalGroups: configuration.supplementalGroups,
            stdioCount: stdio.count
        ))
    }

    func runAttachedProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        interactive: Bool,
        tty: Bool
    ) async throws -> Int32 {
        attachedProcesses.append(ContainerAttachedExecProcessRequest(
            containerId: containerId,
            processId: processId,
            executable: configuration.executable,
            arguments: configuration.arguments,
            environment: configuration.environment,
            workingDirectory: configuration.workingDirectory,
            terminal: configuration.terminal,
            user: configuration.user.description,
            supplementalGroups: configuration.supplementalGroups,
            interactive: interactive,
            tty: tty
        ))
        return attachedStatus
    }
}

private actor RecordingContainerStatsManager: ContainerStatsManaging {
    private let outputs: [String]
    private var storage: [ContainerStatsRequest] = []

    init(outputs: [String] = []) {
        self.outputs = outputs
    }

    var requests: [ContainerStatsRequest] {
        storage
    }

    func stats(
        ids: [String],
        format: String,
        noStream: Bool,
        includeStopped: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        storage.append(ContainerStatsRequest(ids: ids, format: format, noStream: noStream, includeStopped: includeStopped))
        for output in outputs {
            emit(output)
        }
    }
}

private actor RecordingContainerStatsAPIClient: ContainerStatsAPIClienting {
    private let targets: [ComposeStatsTarget]
    private var statsResponses: [String: [ContainerStats]]
    private let statsError: (any Error)?
    private let statsErrorRequestIndex: Int
    private var lists: [[String]] = []
    private var statsStorage: [String] = []

    init(
        targets: [ComposeStatsTarget] = [],
        statsResponses: [String: [ContainerStats]] = [:],
        statsError: (any Error)? = nil,
        statsErrorRequestIndex: Int = 1
    ) {
        self.targets = targets
        self.statsResponses = statsResponses
        self.statsError = statsError
        self.statsErrorRequestIndex = statsErrorRequestIndex
    }

    var listRequests: [[String]] {
        lists
    }

    var statsRequests: [String] {
        statsStorage
    }

    func listStatsTargets(ids: [String]) async throws -> [ComposeStatsTarget] {
        lists.append(ids)
        return targets.filter { ids.contains($0.id) }
    }

    func stats(id: String) async throws -> ContainerStats {
        statsStorage.append(id)
        if let statsError, statsStorage.filter({ $0 == id }).count == statsErrorRequestIndex {
            throw statsError
        }
        guard var responses = statsResponses[id], let response = responses.first else {
            throw ComposeError.invalidProject("missing stats fixture for \(id)")
        }
        responses.removeFirst()
        statsResponses[id] = responses.isEmpty ? [response] : responses
        return response
    }
}

private actor RecordingContainerImageManager: ContainerImageManaging {
    private var storage: [ContainerImageRequest] = []
    private var existingReferences: Set<String>
    private let pullFailures: Set<String>
    private let pullMissingFailures: Set<String>
    private var pushOutputs: [String: String]
    private let pushFailures: Set<String>
    private var deleteOutputs: [String: String?]
    private let failure: ComposeError?

    init(
        existingReferences: Set<String> = [],
        pullFailures: Set<String> = [],
        pullMissingFailures: Set<String> = [],
        pushOutputs: [String: String] = [:],
        pushFailures: Set<String> = [],
        deleteOutputs: [String: String?] = [:],
        failure: ComposeError? = nil
    ) {
        self.existingReferences = existingReferences
        self.pullFailures = pullFailures
        self.pullMissingFailures = pullMissingFailures
        self.pushOutputs = pushOutputs
        self.pushFailures = pushFailures
        self.deleteOutputs = deleteOutputs
        self.failure = failure
    }

    var requests: [ContainerImageRequest] {
        storage
    }

    func imageExists(_ reference: String) async throws -> Bool {
        if let failure {
            throw failure
        }
        storage.append(.exists(reference))
        return existingReferences.contains(reference)
    }

    func pullImage(_ reference: String) async throws {
        if let failure {
            throw failure
        }
        storage.append(.pull(reference))
        if pullFailures.contains(reference) {
            throw ComposeError.invalidProject("pull failed: \(reference)")
        }
        existingReferences.insert(reference)
    }

    func pullMissingImage(_ reference: String) async throws {
        if let failure {
            throw failure
        }
        storage.append(.pullMissing(reference))
        if pullMissingFailures.contains(reference) {
            throw ComposeError.invalidProject("pull failed: \(reference)")
        }
        existingReferences.insert(reference)
    }

    func pushImage(_ reference: String, emit: @escaping @Sendable (String) -> Void) async throws {
        if let failure {
            throw failure
        }
        storage.append(.push(reference))
        if pushFailures.contains(reference) {
            throw ComposeError.invalidProject("push failed: \(reference)")
        }
        emit(pushOutputs[reference] ?? reference)
    }

    func deleteImage(_ reference: String, force: Bool, emit: @escaping @Sendable (String) -> Void) async throws {
        if let failure {
            throw failure
        }
        storage.append(.delete(reference: reference, force: force))
        let output: String?
        if deleteOutputs.keys.contains(reference) {
            output = deleteOutputs[reference] ?? nil
        } else {
            output = reference
        }
        if let output {
            emit(output)
        }
    }
}

private actor RecordingContainerImageAPIClient: ContainerImageAPIClienting {
    private var existingReferences: Set<String>
    private var pushOutputs: [String: String]
    private var deleteOutputs: [String: String?]
    private var storage: [ContainerImageRequest] = []

    init(
        existingReferences: Set<String> = [],
        pushOutputs: [String: String] = [:],
        deleteOutputs: [String: String?] = [:]
    ) {
        self.existingReferences = existingReferences
        self.pushOutputs = pushOutputs
        self.deleteOutputs = deleteOutputs
    }

    var requests: [ContainerImageRequest] {
        storage
    }

    func imageExists(reference: String) async throws -> Bool {
        storage.append(.exists(reference))
        return existingReferences.contains(reference)
    }

    func pullImage(reference: String) async throws {
        storage.append(.pull(reference))
        existingReferences.insert(reference)
    }

    func pushImage(reference: String) async throws -> String {
        storage.append(.push(reference))
        return pushOutputs[reference] ?? reference
    }

    func deleteImage(reference: String, force: Bool) async throws -> String? {
        storage.append(.delete(reference: reference, force: force))
        let output: String?
        if deleteOutputs.keys.contains(reference) {
            output = deleteOutputs[reference] ?? nil
        } else {
            output = reference
        }
        if let output {
            existingReferences.remove(reference)
            return output
        }
        return nil
    }
}

private actor RecordingPullMetadataStore: ComposePullMetadataStoring {
    private var dates: [String: Date]

    init(dates: [String: Date] = [:]) {
        self.dates = dates
    }

    func lastPullDate(for reference: String) async throws -> Date? {
        dates[reference]
    }

    func recordPullDate(_ date: Date, for reference: String) async throws {
        dates[reference] = date
    }

    func recordedDate(for reference: String) -> Date? {
        dates[reference]
    }
}

private actor ThrowingSleeper {
    private let throwOnCall: Int
    private var calls = 0

    init(throwOnCall: Int) {
        self.throwOnCall = throwOnCall
    }

    func sleep(_: Duration) async throws {
        calls += 1
        if calls >= throwOnCall {
            throw CancellationError()
        }
    }
}

private actor RecordingContainerLifecycleAPIClient: ContainerLifecycleAPIClienting {
    private let waitExitCodes: [String: Int32]
    private var storage: [ContainerLifecycleRequest] = []

    init(waitExitCodes: [String: Int32] = [:]) {
        self.waitExitCodes = waitExitCodes
    }

    var requests: [ContainerLifecycleRequest] {
        storage
    }

    func startContainer(id: String) async throws {
        storage.append(.start(id: id))
    }

    func killContainer(id: String, signal: String) async throws {
        storage.append(.kill(id: id, signal: signal))
    }

    func stopContainer(id: String, options: ContainerStopOptions) async throws {
        storage.append(.stop(
            id: id,
            signal: options.signal,
            timeoutInSeconds: Int(options.timeoutInSeconds)
        ))
    }

    func waitContainer(id: String) async throws -> Int32 {
        storage.append(.wait(id: id))
        return waitExitCodes[id] ?? 0
    }

    func deleteContainer(id: String, force: Bool) async throws {
        storage.append(.delete(id: id, force: force))
    }
}

private actor RecordingContainerResourceAPIClient: ContainerResourceAPIClienting {
    private let volumes: [ComposeVolumeSummary]
    private let networkCreateError: (any Error)?
    private var storage: [ContainerResourceAPIRequest] = []

    init(volumes: [ComposeVolumeSummary] = [], networkCreateError: (any Error)? = nil) {
        self.volumes = volumes
        self.networkCreateError = networkCreateError
    }

    var requests: [ContainerResourceAPIRequest] {
        storage
    }

    func createNetwork(configuration: NetworkConfiguration) async throws {
        storage.append(.createNetwork(
            name: configuration.name,
            mode: configuration.mode,
            plugin: configuration.plugin,
            ipv4Subnet: configuration.ipv4Subnet?.description,
            ipv6Subnet: configuration.ipv6Subnet?.description,
            labels: configuration.labels.dictionary
        ))
        if let networkCreateError {
            throw networkCreateError
        }
    }

    func deleteNetwork(id: String) async throws {
        storage.append(.deleteNetwork(id: id))
    }

    func createVolume(_ request: ComposeVolumeCreateRequest) async throws {
        storage.append(.createVolume(request))
    }

    func listVolumes() async throws -> [ComposeVolumeSummary] {
        storage.append(.listVolumes)
        return volumes
    }

    func deleteVolume(name: String) async throws {
        storage.append(.deleteVolume(name: name))
    }
}

private actor RecordingContainerResourceManager: ContainerResourceManaging {
    private let volumes: [ComposeVolumeSummary]
    private let networkCreateError: (any Error)?
    private let networkDeleteError: (any Error)?
    private let volumeCreateError: (any Error)?
    private let volumeDeleteError: (any Error)?
    private var storage: [ContainerResourceRequest] = []

    init(
        volumes: [ComposeVolumeSummary] = [],
        networkCreateError: (any Error)? = nil,
        networkDeleteError: (any Error)? = nil,
        volumeCreateError: (any Error)? = nil,
        volumeDeleteError: (any Error)? = nil
    ) {
        self.volumes = volumes
        self.networkCreateError = networkCreateError
        self.networkDeleteError = networkDeleteError
        self.volumeCreateError = volumeCreateError
        self.volumeDeleteError = volumeDeleteError
    }

    var requests: [ContainerResourceRequest] {
        storage
    }

    func createNetwork(_ request: ComposeNetworkCreateRequest) async throws {
        storage.append(.createNetwork(request))
        if let networkCreateError {
            throw networkCreateError
        }
    }

    func deleteNetwork(id: String) async throws {
        storage.append(.deleteNetwork(id: id))
        if let networkDeleteError {
            throw networkDeleteError
        }
    }

    func createVolume(_ request: ComposeVolumeCreateRequest) async throws {
        storage.append(.createVolume(request))
        if let volumeCreateError {
            throw volumeCreateError
        }
    }

    func listVolumes() async throws -> [ComposeVolumeSummary] {
        storage.append(.listVolumes)
        return volumes
    }

    func deleteVolume(name: String) async throws {
        storage.append(.deleteVolume(name: name))
        if let volumeDeleteError {
            throw volumeDeleteError
        }
    }
}

private actor RecordingContainerExporter: ContainerExporting {
    private var storage: [ContainerExportRequest] = []

    var requests: [ContainerExportRequest] {
        storage
    }

    func exportContainer(id: String, output: String?) async throws {
        storage.append(ContainerExportRequest(id: id, output: output))
    }
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
