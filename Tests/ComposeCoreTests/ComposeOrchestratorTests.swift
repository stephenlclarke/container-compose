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
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = value.contains(".")
        ? [.withInternetDateTime, .withFractionalSeconds]
        : [.withInternetDateTime]
    return formatter.date(from: value)!
}

private func localDate(_ value: String, format: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = format
    return formatter.date(from: value)!
}

private func composeTextEventTimestamp(_ value: String) -> String {
    let eventDate = date(value)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second, .nanosecond],
        from: eventDate
    )
    let microseconds = (components.nanosecond ?? 0) / 1_000
    return String(
        format: "%04d-%02d-%02d %02d:%02d:%02d.%06d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0,
        components.hour ?? 0,
        components.minute ?? 0,
        components.second ?? 0,
        microseconds
    )
}

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

private func readOnlyVolumeSource(target: String, in arguments: [String]) -> String? {
    let suffix = ":\(target):ro"
    for index in arguments.indices where arguments[index] == "--volume" {
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            continue
        }
        let value = arguments[valueIndex]
        if value.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count))
        }
    }
    return nil
}

private func posixPermissions(at path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}

private final class LockedStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return values
    }
}

private func progressReportingOptions(recordingTo recorder: LockedStringRecorder) -> ComposeExecutionOptions {
    ComposeExecutionOptions(progress: ComposeProgressReporter(
        style: .plain,
        emitData: { recorder.append(String(decoding: $0, as: UTF8.self)) }
    ))
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

private func temporaryExecutable(name: String = "provider") throws -> URL {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent(name)
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
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

private final class ProgressAssertingRunner: CommandRunning, @unchecked Sendable {
    private let onRun: @Sendable ([String]) -> Void
    private(set) var commands: [[String]] = []

    init(onRun: @escaping @Sendable ([String]) -> Void) {
        self.onRun = onRun
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        io: CommandIO
    ) async throws -> CommandResult {
        onRun(arguments)
        _ = executable
        _ = workingDirectory
        _ = environment
        _ = io
        commands.append(arguments)
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

private func orchestratorDependencies(
    configure: (inout ComposeOrchestratorDependencies) -> Void
) -> ComposeOrchestratorDependencies {
    var dependencies = ComposeOrchestratorDependencies()
    dependencies.copier = RecordingContainerCopier()
    dependencies.discoveryManager = RecordingContainerDiscoveryManager()
    dependencies.eventsManager = RecordingContainerEventsManager()
    dependencies.execManager = RecordingContainerExecManager()
    dependencies.exporter = RecordingContainerExporter()
    dependencies.imageManager = RecordingContainerImageManager()
    dependencies.lifecycleManager = RecordingContainerLifecycleManager()
    dependencies.logManager = RecordingContainerLogManager()
    dependencies.pullMetadataStore = RecordingPullMetadataStore()
    dependencies.resourceManager = RecordingContainerResourceManager()
    dependencies.signalProxy = RecordingComposeSignalProxy()
    dependencies.statsManager = RecordingContainerStatsManager()
    dependencies.topManager = RecordingContainerTopManager()
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
        runner: CommandRunning = RecordingRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
        eventsManager: ContainerEventsManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies { $0.eventsManager = eventsManager })
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
        discoveryManager: ContainerDiscoveryManaging,
        lifecycleManager: ContainerLifecycleManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.lifecycleManager = lifecycleManager
        })
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
        runner: CommandRunning = RecordingRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
        discoveryManager: ContainerDiscoveryManaging = RecordingContainerDiscoveryManager(),
        topManager: ContainerTopManaging
    ) {
        self.init(runner: runner, options: options, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.topManager = topManager
        })
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
                discoveryManager: discoveryManager,
                eventsManager: eventsManager,
                lifecycleManager: lifecycleManager,
                resourceManager: resourceManager,
                statsManager: statsManager,
                topManager: topManager
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

    @Test("up maps list entrypoint to executable and command prefix")
    func upMapsListEntrypointToExecutableAndCommandPrefix() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine:3.20") {
                    $0.entrypoint = ["/bin/sh", "-c"]
                    $0.command = ["printf ready"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--entrypoint", "/bin/sh"]))
        #expect(!command.containsSequence(["--entrypoint", "/bin/sh -c"]))
        #expect(Array(command.suffix(3)) == ["alpine:3.20", "-c", "printf ready"])
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

    @Test("up waits for running service-completed dependencies before starting dependents")
    func upWaitsForRunningServiceCompletedDependenciesBeforeStartingDependents() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-job-1": 0])
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-job-1": [
                nil,
                ComposeContainerSummary(id: "demo-job-1", status: "running"),
            ],
            "demo-api-1": [nil],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": ComposeDependency(condition: "service_completed_successfully")]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-job-1"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-job-1"),
        ])
        #expect(await discoveryManager.getRequests == ["demo-job-1", "demo-job-1", "demo-api-1"])
    }

    @Test("up replays stored exit codes for completed dependencies")
    func upReplaysStoredExitCodesForCompletedDependencies() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-job-1": [
                nil,
                ComposeContainerSummary(id: "demo-job-1", status: "stopped", exitCode: 0),
            ],
            "demo-api-1": [nil],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": ComposeDependency(condition: "service_completed_successfully")]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-job-1"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("up waits for healthy dependencies before starting dependents")
    func upWaitsForHealthyDependenciesBeforeStartingDependents() async throws {
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
            "demo-api-1": [nil],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "db": ComposeService(name: "db", image: "postgres:16"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy")]
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.discoveryManager = discoveryManager
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { _ in }),
            dependencies: dependencies
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-db-1"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-db-1", "demo-db-1", "demo-api-1"])
    }

    @Test("up rejects unhealthy dependencies before starting dependents")
    func upRejectsUnhealthyDependenciesBeforeStartingDependents() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-db-1": [
                nil,
                ComposeContainerSummary(id: "demo-db-1", status: "running", health: "unhealthy"),
            ],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "db": ComposeService(name: "db", image: "postgres:16"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy")]
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.discoveryManager = discoveryManager
        }

        do {
            try await ComposeOrchestrator(
                runner: runner,
                options: ComposeExecutionOptions(sleep: { _ in }),
                dependencies: dependencies
            ).up(
                project: project,
                options: ComposeUpOptions {
                    $0.services = ["api"]
                }
            )
            Issue.record("Expected unhealthy dependency to stop dependent startup")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' dependency 'db' container 'demo-db-1' is unhealthy"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-db-1"]))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-db-1"])
    }

    @Test("up rejects failed service-completed dependencies before starting dependents")
    func upRejectsFailedServiceCompletedDependenciesBeforeStartingDependents() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-job-1": [
                nil,
                ComposeContainerSummary(id: "demo-job-1", status: "stopped", exitCode: 2),
            ],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": ComposeDependency(condition: "service_completed_successfully")]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: runner,
                discoveryManager: discoveryManager,
                lifecycleManager: lifecycleManager
            ).up(
                project: project,
                options: ComposeUpOptions {
                    $0.services = ["api"]
                }
            )
            Issue.record("Expected failed dependency to stop dependent startup")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' dependency 'job' container 'demo-job-1' exited with status 2"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-job-1"]))
        #expect(await lifecycleManager.requests.isEmpty)
        #expect(await discoveryManager.getRequests == ["demo-job-1", "demo-job-1"])
    }

    @Test("create creates resources and service containers without starting them")
    func createCreatesResourcesAndServiceContainersWithoutStartingThem() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let progress = LockedStringRecorder()
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
                    $0.hostname = "custom-api"
                    $0.domainName = "example.test"
                    $0.extraHosts = ["db=10.0.0.5", "myhostv6=[::1]"]
                    $0.privileged = true
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.resourceManager = resourceManager
            }
        ).create(project: project, options: ComposeCreateOptions())

        let commands = runner.commands.map(\.arguments)
        let resources = await resourceManager.requests
        #expect(resources.count == 2)
        #expect(resources.map(\.name) == ["demo_default", "demo_cache"])
        #expect(resources.allSatisfy { $0.labels["com.apple.container.compose.project"] == "demo" })
        #expect(resources.allSatisfy { $0.labels["com.apple.container.compose.project.config-files-hash"]?.count == 64 })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(progress.snapshot.joined() == "⠓ Creating api\n✓ Creating api\n")

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
        #expect(create.containsSequence(["--hostname", "custom-api"]))
        #expect(create.containsSequence(["--domainname", "example.test"]))
        #expect(create.containsSequence(["--add-host", "db:10.0.0.5"]))
        #expect(create.containsSequence(["--add-host", "myhostv6:::1"]))
        #expect(create.contains("--privileged"))
        #expect(Array(create.suffix(2)) == ["example/api:latest", "serve"])
    }

    @Test("create maps disabled logging driver to runtime policy")
    func createMapsDisabledLoggingDriverToRuntimePolicy() async throws {
        for testCase in disabledServiceLoggingFieldCases() {
            let runner = RecordingRunner(responses: [.success])
            let discoveryManager = RecordingContainerDiscoveryManager()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
                .create(project: project, options: ComposeCreateOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
            #expect(command.containsSequence(["--log-driver", "none"]))
            #expect(!command.contains("--log-opt"))
        }
    }

    @Test("create maps local logging options to runtime policy")
    func createMapsLocalLoggingOptionsToRuntimePolicy() async throws {
        for testCase in supportedLocalServiceLoggingOptionCases() {
            let runner = RecordingRunner(responses: [.success])
            let discoveryManager = RecordingContainerDiscoveryManager()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
                .create(project: project, options: ComposeCreateOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
            #expect(!command.contains("--log-driver"))
            for option in testCase.expectedOptions {
                #expect(command.containsSequence(["--log-opt", option]))
            }
        }
    }

    @Test("service create plan maps logging to typed policy")
    func serviceCreatePlanMapsLoggingToTypedPolicy() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.logging = .object([
                        "driver": .string("local"),
                        "options": .object(["max-file": .string("3")]),
                    ])
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "api")

        #expect(plan.name == "demo-api-1")
        #expect(plan.imageReference == "example/api")
        #expect(plan.logging.storage == .local)
        #expect(plan.logging.maxFileCount == 3)
        #expect(plan.logging.maxSizeInBytes == nil)
    }

    @Test("service create plan maps disabled logging to typed policy")
    func serviceCreatePlanMapsDisabledLoggingToTypedPolicy() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.logging = .object(["driver": .string("none")])
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "api")

        #expect(plan.logging.storage == .none)
        #expect(plan.logging.maxFileCount == nil)
        #expect(plan.logging.maxSizeInBytes == nil)
    }

    @Test("service create plan maps create-time runtime primitives")
    func serviceCreatePlanMapsCreateTimeRuntimePrimitives() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.restart = "on-failure:3"
                    $0.hostname = "api-01"
                    $0.domainName = "example.test"
                    $0.extraHosts = ["db:10.0.0.5"]
                    $0.sysctls = ["net.core.somaxconn": "1024"]
                    $0.privileged = true
                    $0.blkioConfig = ComposeBlkioConfig(
                        weight: 300,
                        weightDevice: [ComposeBlkioWeightDevice(path: "8:0", weight: 700)],
                        deviceReadIOps: [ComposeBlkioThrottleDevice(path: "8:0", rate: "1000")]
                    )
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "api")

        #expect(plan.restartPolicy.mode == .onFailure)
        #expect(plan.restartPolicy.maximumRetryCount == 3)
        #expect(plan.hostname == "api-01")
        #expect(plan.domainname == "example.test")
        #expect(plan.hosts.map(\.ipAddress) == ["10.0.0.5"])
        #expect(plan.hosts.flatMap(\.hostnames) == ["db"])
        #expect(plan.sysctls == ["net.core.somaxconn": "1024"])
        #expect(plan.initProcess.privileged)
        #expect(plan.blockIO?.weight == 300)
        #expect(plan.blockIO?.weightDevice.first?.major == 8)
        #expect(plan.blockIO?.weightDevice.first?.minor == 0)
        #expect(plan.blockIO?.weightDevice.first?.weight == 700)
        #expect(plan.blockIO?.throttleReadIOPSDevice.first?.rate == 1000)
    }

    @Test("service create plan maps entrypoint and command to init process")
    func serviceCreatePlanMapsEntrypointAndCommandToInitProcess() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.entrypoint = ["/bin/sh", "-c"]
                    $0.command = ["printf ready"]
                    $0.environment = [
                        "EMPTY": nil,
                        "LOG_LEVEL": "debug",
                    ]
                    $0.workingDir = "/work"
                    $0.user = "1000:1000"
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")

        #expect(plan.initProcess.executable == "/bin/sh")
        #expect(plan.initProcess.arguments == ["-c", "printf ready"])
        #expect(plan.initProcess.environment == ["EMPTY", "LOG_LEVEL=debug"])
        #expect(plan.initProcess.workingDirectory == "/work")
        #expect(plan.initProcess.user.description == "1000:1000")
    }

    @Test("service create plan maps explicit healthcheck to typed policy")
    func serviceCreatePlanMapsExplicitHealthcheckToTypedPolicy() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.command = ["serve"]
                    $0.environment = ["LOG_LEVEL": "debug"]
                    $0.workingDir = "/srv"
                    $0.user = "1000:1000"
                    $0.healthcheck = .object([
                        "test": .array([.string("CMD-SHELL"), .string("test -f /tmp/ready")]),
                        "interval": .string("5s"),
                        "retries": .number(2),
                    ])
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "api")
        let healthCheck = try #require(plan.healthCheck)

        #expect(healthCheck.process.executable == "/bin/sh")
        #expect(healthCheck.process.arguments == ["-c", "test -f /tmp/ready"])
        #expect(healthCheck.process.environment == ["LOG_LEVEL=debug"])
        #expect(healthCheck.process.workingDirectory == "/srv")
        #expect(healthCheck.process.user.description == "1000:1000")
        #expect(healthCheck.intervalInNanoseconds == 5_000_000_000)
        #expect(healthCheck.retries == 2)
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
            .healthCheck(reference: "example/api", platform: nil),
            .healthCheck(reference: "postgres", platform: nil),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-db-1"])
    }

    @Test("create build with missing pull builds buildable images and pulls only runtime images")
    func createBuildWithMissingPullBuildsBuildableImagesAndPullsOnlyRuntimeImages() async throws {
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
                    $0.build = ComposeBuild(context: "api")
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.build = true
                $0.pullPolicy = "missing"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/api"]))
        #expect(commands[0].last == "api")
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[2].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(await imageManager.requests == [
            .pullMissing("postgres"),
            .healthCheck(reference: "example/api", platform: nil),
            .healthCheck(reference: "postgres", platform: nil),
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

    @Test("create allocates dynamic published ports before creating containers")
    func createAllocatesDynamicPublishedPortsBeforeCreatingContainers() async throws {
        let ports = HostPortSource([49153, 49154])
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["80-81/udp"]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) }),
            discoveryManager: RecordingContainerDiscoveryManager()
        ).create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--publish", "49153:80/udp"]))
        #expect(command.containsSequence(["--publish", "49154:81/udp"]))
        #expect(ports.requests == [
            HostPortAllocationRequest(hostAddress: nil, protocolName: "udp"),
            HostPortAllocationRequest(hostAddress: nil, protocolName: "udp"),
        ])
    }

    @Test("default dynamic host port allocator allocates local tcp ports")
    func defaultDynamicHostPortAllocatorAllocatesLocalTCPPorts() throws {
        let port = try ComposeExecutionOptions.defaultHostPortAllocator(
            hostAddress: "127.0.0.1",
            protocolName: "tcp"
        )

        #expect(port > 0)
    }

    @Test("default dynamic host port allocator rejects unknown protocols")
    func defaultDynamicHostPortAllocatorRejectsUnknownProtocols() throws {
        do {
            _ = try ComposeExecutionOptions.defaultHostPortAllocator(
                hostAddress: nil,
                protocolName: "sctp"
            )
            Issue.record("Expected invalid protocol failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("dynamic host-port allocation supports tcp and udp protocols, got 'sctp'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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
            (
                ComposeUpOptions {
                    $0.wait = true
                    $0.noStart = true
                },
                "--wait and --no-start are incompatible"
            ),
            (
                ComposeUpOptions {
                    $0.noRecreate = true
                    $0.renewAnonymousVolumes = true
                },
                "--no-recreate and --renew-anon-volumes are incompatible"
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

    @Test("up wait implies detached containers and polls until running")
    func upWaitImpliesDetachedContainersAndPollsUntilRunning() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-api-1", status: "starting"),
                    ComposeContainerSummary(id: "demo-api-1", status: "running"),
                ],
            ]
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { _ in }),
            discoveryManager: discoveryManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.wait = true
                $0.waitTimeout = 5
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-1", "demo-api-1"])
    }

    @Test("up wait dry run emits wait-running operations")
    func upWaitDryRunEmitsWaitRunningOperations() async throws {
        let emitted = MessageRecorder()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.wait = true
                $0.waitTimeout = 3
            }
        )

        #expect(emitted.messages.contains("+ container inspect demo-api-1"))
        #expect(emitted.messages.contains { message in
            message.contains("container run --name demo-api-1 --detach")
                && message.contains("com.apple.container.compose.service=api")
                && message.hasSuffix("example/api")
        })
        #expect(emitted.messages.contains("+ compose-runtime wait-running --timeout 3 demo-api-1"))
    }

    @Test("up wait timeout reports up command")
    func upWaitTimeoutReportsUpCommand() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-api-1", status: "starting"),
                ],
            ]
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        let now = Date(timeIntervalSince1970: 1_000)
        do {
            try await ComposeOrchestrator(
                runner: runner,
                options: ComposeExecutionOptions(runtimeHooks: .init(currentDate: { now }, sleep: { _ in })),
                discoveryManager: discoveryManager
            ).up(
                project: project,
                options: ComposeUpOptions {
                    $0.wait = true
                    $0.waitTimeout = 0
                }
            )
            Issue.record("Expected up wait timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("up --wait timed out waiting for demo-api-1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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

    @Test("up allocates dynamic published ports per service replica")
    func upAllocatesDynamicPublishedPortsPerServiceReplica() async throws {
        let ports = HostPortSource([49154, 49155])
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.ports = ["80"]
        }])

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) }),
            discoveryManager: discoveryManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].containsSequence(["--publish", "49154:80"]))
        #expect(commands[1].containsSequence(["--publish", "49155:80"]))
        #expect(ports.requests == [
            HostPortAllocationRequest(hostAddress: nil, protocolName: "tcp"),
            HostPortAllocationRequest(hostAddress: nil, protocolName: "tcp"),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("up allocates dynamic published ports with host addresses and protocols")
    func upAllocatesDynamicPublishedPortsWithHostAddressesAndProtocols() async throws {
        let ports = HostPortSource([49156, 49157])
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.ports = ["127.0.0.1::80/udp", "[::1]::81"]
        }])

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) }),
            discoveryManager: discoveryManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--publish", "127.0.0.1:49156:80/udp"]))
        #expect(command.containsSequence(["--publish", "[::1]:49157:81"]))
        #expect(ports.requests == [
            HostPortAllocationRequest(hostAddress: "127.0.0.1", protocolName: "udp"),
            HostPortAllocationRequest(hostAddress: "[::1]", protocolName: "tcp"),
        ])
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

    @Test("up renew anonymous volumes recreates matching containers")
    func upRenewAnonymousVolumesRecreatesMatchingContainers() async throws {
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.volumes = [
                ComposeMount(type: "volume", target: "/scratch"),
            ]
        }])
        let createRunner = RecordingRunner(responses: [.success])
        let createDiscovery = RecordingContainerDiscoveryManager()

        try await ComposeOrchestrator(runner: createRunner, discoveryManager: createDiscovery)
            .up(project: project, options: ComposeUpOptions())

        let createCommand = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: createCommand))
        let anonymousVolume = try #require(createCommand.compactMap { argument -> String? in
            guard argument.hasPrefix("demo_anon-"), argument.hasSuffix(":/scratch") else {
                return nil
            }
            return String(argument.split(separator: ":", maxSplits: 1)[0])
        }.first)
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: hash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager(volumes: [
            ComposeVolumeSummary(name: anonymousVolume),
        ])

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions {
            $0.renewAnonymousVolumes = true
        })

        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
        #expect(await resourceManager.requests == [
            .listVolumes,
            .deleteVolume(name: anonymousVolume),
        ])
        #expect(runner.commands.map(\.arguments).count == 1)
        #expect(try #require(runner.commands.last?.arguments).contains { $0 == "\(anonymousVolume):/scratch" })
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

    @Test("up accepts deploy endpoint mode metadata normalized by compose-go")
    func upAcceptsDeployEndpointModeMetadataNormalizedByComposeGo() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: alpine:3.20
            deploy:
              endpoint_mode: dnsrr
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "demo",
            projectDirectory: directory.path
        ))
        let api = try #require(project.services["api"])
        #expect(api.unsupportedDeployFields == nil)

        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.noStart = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-api-1"]) })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
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
            $0.assumeYes = true
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

    @Test("up remove orphans cancellation leaves orphan containers")
    func upRemoveOrphansCancellationLeavesOrphanContainers() async throws {
        let prompts = MessageRecorder()
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
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                runtimeHooks: .init(confirm: { prompt in
                    prompts.append(prompt)
                    return false
                })
            ),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
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
        #expect(await discoveryManager.listRequests == [true])
        #expect(prompts.messages == ["Going to remove orphan containers demo-worker-1\nAre you sure? [yN] "])
        #expect(await lifecycleManager.requests.isEmpty)
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
            $0.assumeYes = true
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

    @Test("up no-attach detaches named service and attaches next eligible dependency")
    func upNoAttachDetachesNamedServiceAndAttachesNextEligibleDependency() async throws {
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

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noAttach = ["api"]
            })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(!dbRun.contains("--detach"))
        #expect(apiRun.contains("--detach"))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
    }

    @Test("up attach follows selected service logs after detached start")
    func upAttachFollowsSelectedServiceLogsAfterDetachedStart() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let logManager = RecordingContainerLogManager(outputs: ["ready\n"])
        let emitted = MessageRecorder()
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
            runner: runner,
            options: ComposeExecutionOptions(runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
            )),
            dependencies: orchestratorDependencies {
                $0.logManager = logManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.attach = ["api"]
        })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(dbRun.contains("--detach"))
        #expect(apiRun.contains("--detach"))
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true),
        ])
        #expect(emitted.messages == ["api-1 | ready"])
    }

    @Test("up attach dependencies follows selected service and dependency logs")
    func upAttachDependenciesFollowsSelectedServiceAndDependencyLogs() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let logManager = RecordingContainerLogManager()
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
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.logManager = logManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.attach = ["api"]
            $0.attachDependencies = true
            $0.timestamps = true
        })

        #expect(await logManager.requests.sorted { $0.id < $1.id } == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true, timestamps: true),
            ContainerLogRequest(id: "demo-db-1", tail: nil, follow: true, timestamps: true),
        ])
    }

    @Test("up menu follows attachable selected service logs through menu controller")
    func upMenuFollowsAttachableSelectedServiceLogsThroughMenuController() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let logManager = RecordingContainerLogManager(outputs: ["ready\n"])
        let menuController = RecordingComposeUpMenuController()
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "src", action: "sync", target: "/app/src"),
                    ])
                },
                "db": composeService(name: "db", image: "postgres") {
                    $0.attach = false
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
            )),
            dependencies: orchestratorDependencies {
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
        })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(dbRun.contains("--detach"))
        #expect(apiRun.contains("--detach"))
        #expect(await menuController.requests == [
            ComposeUpMenuConfigurationSnapshot(
                projectName: "demo",
                watchEnabled: false,
                watchAvailable: true,
                colorEnabled: false
            ),
        ])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true),
        ])
        #expect(emitted.messages == ["api-1 | ready"])
    }

    @Test("up menu dry run emits log follow plan without invoking menu controller")
    func upMenuDryRunEmitsLogFollowPlanWithoutInvokingMenuController() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let menuController = RecordingComposeUpMenuController()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
        })

        #expect(emitted.messages.contains("+ compose-runtime logs --follow demo-api-1"))
        #expect(await menuController.requests.isEmpty)
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up menu waits on selected services when no logs are attachable")
    func upMenuWaitsOnSelectedServicesWhenNoLogsAreAttachable() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let menuController = RecordingComposeUpMenuController()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.attach = false
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
        })

        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(apiRun.contains("--detach"))
        #expect(await menuController.requests == [
            ComposeUpMenuConfigurationSnapshot(
                projectName: "demo",
                watchEnabled: false,
                watchAvailable: false,
                colorEnabled: false
            ),
        ])
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-api-1"),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up menu rejects exit-control options before side effects")
    func upMenuRejectsExitControlOptionsBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.services = ["api"]
                    $0.menu = true
                    $0.abortOnContainerExit = true
                }
            )
            Issue.record("Expected menu exit-control incompatibility")
        } catch let error as ComposeError {
            #expect(error == .unsupported("up --menu with exit-control options"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up menu watch toggle validates before reporting watch enabled")
    func upMenuWatchToggleValidatesBeforeReportingWatchEnabled() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let menuController = RecordingComposeUpMenuController(actions: [.toggleWatch])
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-menu-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        var project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "missing-src", action: "sync", target: "/app/src"),
                    ])
                },
            ]
        )
        project.workingDirectory = temporaryDirectory.path

        do {
            try await ComposeOrchestrator(
                runner: runner,
                dependencies: orchestratorDependencies {
                    $0.logManager = logManager
                    $0.upMenuController = menuController
                }
            )
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
                $0.menu = true
            })
            Issue.record("Expected menu watch preflight to reject the missing watch path")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("develop.watch path does not exist: missing-src"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await menuController.requests == [
            ComposeUpMenuConfigurationSnapshot(
                projectName: "demo",
                watchEnabled: false,
                watchAvailable: true,
                colorEnabled: false
            ),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up menu shortcut actions stop and kill selected service graph")
    func upMenuShortcutActionsStopAndKillSelectedServiceGraph() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["ready\n"])
        let menuController = RecordingComposeUpMenuController(actions: [.gracefulStop, .forceStop])
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
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
            $0.timeout = 4
        })

        let lifecycleRequests = await lifecycleManager.requests
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: nil, timeoutInSeconds: 4)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-db-1", signal: nil, timeoutInSeconds: 4)))
        #expect(lifecycleRequests.contains(.kill(id: "demo-api-1", signal: "KILL")))
        #expect(lifecycleRequests.contains(.kill(id: "demo-db-1", signal: "KILL")))
    }

    @Test("up attach rejects services outside selected start graph")
    func upAttachRejectsServicesOutsideSelectedStartGraph() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.services = ["api"]
                    $0.attach = ["worker"]
                }
            )
            Issue.record("Expected attach selection error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("up --attach service 'worker' is not being started"))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up exit-code-from returns selected service status and tears down project")
    func upExitCodeFromReturnsSelectedServiceStatusAndTearsDownProject() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-api-1": 7])
        let discoveryManager = RecordingContainerDiscoveryManager(
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
                    id: "demo-db-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "db",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
                "demo-db-1": [nil],
            ]
        )
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

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.exitCodeFrom = "api"
        })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(exitCode == 7)
        #expect(dbRun.contains("--detach"))
        #expect(apiRun.contains("--detach"))
        let lifecycleRequests = await lifecycleManager.requests
        #expect(lifecycleRequests.contains(.wait(id: "demo-api-1")))
        #expect(lifecycleRequests.contains(.wait(id: "demo-db-1")))
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9)))
        #expect(lifecycleRequests.contains(.delete(id: "demo-api-1", force: false)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.delete(id: "demo-db-1", force: false)))
        #expect(await discoveryManager.listRequests == [true, true])
    }

    @Test("up exit-code-from aborts when another service exits first and returns selected status")
    func upExitCodeFromAbortsOnOtherServiceExitAndReturnsSelectedStatus() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(
            waitExitCodes: [
                "demo-api-1": 7,
                "demo-db-1": 0,
            ],
            waitDelaysByID: [
                "demo-api-1": .milliseconds(20),
            ]
        )
        let discoveryManager = RecordingContainerDiscoveryManager(
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
                    id: "demo-db-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "db",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
                "demo-db-1": [nil],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.exitCodeFrom = "api"
        })
        let lifecycleRequests = await lifecycleManager.requests

        #expect(exitCode == 7)
        #expect(lifecycleRequests.contains(.wait(id: "demo-db-1")))
        #expect(lifecycleRequests.contains(.wait(id: "demo-api-1")))
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.delete(id: "demo-api-1", force: false)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.delete(id: "demo-db-1", force: false)))
    }

    @Test("up abort-on-container-failure returns failing status and tears down project")
    func upAbortOnContainerFailureReturnsFailingStatusAndTearsDownProject() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: [
            "demo-api-1": 0,
            "demo-worker-1": 8,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(
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
                    id: "demo-worker-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "worker",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
                "demo-worker-1": [nil],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.abortOnContainerFailure = true
        })
        let lifecycleRequests = await lifecycleManager.requests

        #expect(exitCode == 8)
        #expect(lifecycleRequests.contains(.wait(id: "demo-api-1")))
        #expect(lifecycleRequests.contains(.wait(id: "demo-worker-1")))
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.delete(id: "demo-api-1", force: false)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.delete(id: "demo-worker-1", force: false)))
    }

    @Test("up abort-on-container-exit returns first status and tears down project")
    func upAbortOnContainerExitReturnsFirstStatusAndTearsDownProject() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(
            waitExitCodes: [
                "demo-api-1": 3,
                "demo-worker-1": 0,
            ],
            waitDelaysByID: [
                "demo-worker-1": .milliseconds(20),
            ]
        )
        let discoveryManager = RecordingContainerDiscoveryManager(
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
                    id: "demo-worker-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "worker",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
                "demo-worker-1": [nil],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.abortOnContainerExit = true
        })
        let lifecycleRequests = await lifecycleManager.requests

        #expect(exitCode == 3)
        #expect(lifecycleRequests.contains(.wait(id: "demo-api-1")))
        #expect(lifecycleRequests.contains(.wait(id: "demo-worker-1")))
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.delete(id: "demo-api-1", force: false)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.delete(id: "demo-worker-1", force: false)))
    }

    @Test("up exit-control dry run renders wait then down plan")
    func upExitControlDryRunRendersWaitThenDownPlan() async throws {
        let emitted = MessageRecorder()
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

        let exitCode = try await ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.exitCodeFrom = "api"
        })

        #expect(exitCode == 0)
        #expect(emitted.messages.contains("+ compose-runtime wait demo-api-1"))
        #expect(emitted.messages.contains("+ container stop --time 7 demo-api-1"))
        #expect(emitted.messages.contains("+ container delete demo-api-1"))
        #expect(emitted.messages.contains("+ container stop demo-db-1"))
        #expect(emitted.messages.contains("+ container delete demo-db-1"))
    }

    @Test("up exit-control rejects detached mode before side effects")
    func upExitControlRejectsDetachedModeBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.detach = true
                    $0.exitCodeFrom = "api"
                }
            )
            Issue.record("Expected detached exit-control validation error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--exit-code-from and --detach are incompatible"))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up no-attach rejects unknown services before side effects")
    func upNoAttachRejectsUnknownServicesBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.noAttach = ["missing"]
                }
            )
            Issue.record("Expected unknown no-attach service error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unknown service 'missing'"))
        }
        #expect(runner.commands.isEmpty)
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

    @Test("up timestamps detaches foreground service and follows timestamped logs")
    func upTimestampsDetachesForegroundServiceAndFollowsTimestampedLogs() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let logManager = RecordingContainerLogManager(outputs: ["2026-06-18T10:00:00Z ready"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.timestamps = true
                $0.noLogPrefix = true
            }
        )

        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true, timestamps: true),
        ])
        #expect(emitted.messages == ["2026-06-18T10:00:00Z ready"])
    }

    @Test("up timestamps dry run renders detached run and followed timestamped logs")
    func upTimestampsDryRunRendersDetachedRunAndFollowedTimestampedLogs() async throws {
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        ).up(project: project, options: ComposeUpOptions {
            $0.timestamps = true
        })

        #expect(emitted.messages.contains { $0.contains("+ container run --name demo-api-1 --detach") })
        #expect(emitted.messages.contains("+ compose-runtime logs --follow --timestamps demo-api-1"))
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
            .healthCheck(reference: "example/api", platform: nil),
            .healthCheck(reference: "postgres", platform: nil),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-db-1"])
    }

    @Test("up build with missing pull builds buildable images and pulls only runtime images")
    func upBuildWithMissingPullBuildsBuildableImagesAndPullsOnlyRuntimeImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.build = true
            $0.pullPolicy = "missing"
        })

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/api"]))
        #expect(commands[0].last == "api")
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(commands[2].starts(with: ["container", "run", "--name", "demo-db-1"]))
        #expect(await imageManager.requests == [
            .pullMissing("postgres"),
            .healthCheck(reference: "example/api", platform: nil),
            .healthCheck(reference: "postgres", platform: nil),
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
        #expect(await imageManager.requests == [
            .pullMissing("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
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
        #expect(await imageManager.requests == [
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up direct image pull emits progress before run")
    func upDirectImagePullEmitsProgressBeforeRun() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let progress = LockedStringRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.pullPolicy = "always"
        })

        #expect(progress.snapshot.joined() == """
        ⠓ Pulling image example/api
        ✓ Pulling image example/api
        ⠓ Starting api
        ✓ Starting api

        """)
        #expect(await imageManager.requests == [
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
    }

    @Test("up direct image pull emits first progress row before pull starts")
    func upDirectImagePullEmitsFirstProgressRowBeforePullStarts() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let progress = LockedStringRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager(onPullImage: { reference in
            #expect(reference == "example/api")
            #expect(progress.snapshot == ["⠓ Pulling image example/api\n"])
        })
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.pullPolicy = "always"
        })

        #expect(progress.snapshot.joined().hasPrefix("⠓ Pulling image example/api\n"))
        #expect(await imageManager.requests == [
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
    }

    @Test("up quiet-pull suppresses direct image pull progress")
    func upQuietPullSuppressesDirectImagePullProgress() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let progress = LockedStringRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.pullPolicy = "always"
            $0.quietPull = true
        })

        #expect(progress.snapshot.joined() == "⠓ Starting api\n✓ Starting api\n")
        #expect(await imageManager.requests == [
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
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
            .healthCheck(reference: "example/api", platform: nil),
            .healthCheck(reference: "postgres", platform: nil),
            .healthCheck(reference: "example/worker", platform: nil),
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
            .healthCheck(reference: "example/api", platform: nil),
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

        #expect(await imageManager.requests == [
            .exists("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
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
            .healthCheck(reference: "example/api", platform: nil),
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

    @Test("rejects missing health status on present optional dependencies")
    func rejectsMissingHealthStatusOnPresentOptionalDependencies() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-job-1": [
                nil,
                ComposeContainerSummary(id: "demo-job-1", status: "running"),
            ],
        ])
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
            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
                .up(project: project, options: ComposeUpOptions {
                    $0.services = ["api"]
                })
            Issue.record("Expected missing health status")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' dependency 'job' container 'demo-job-1' has no health status"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-job-1"]))
    }

    @Test("up maps links to target network aliases")
    func upMapsLinksToTargetNetworkAliases() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
            })

        let commands = runner.commands.map(\.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-redis-1"]))
        #expect(commands[0].containsSequence(["--network", "demo_backend,alias=cache"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(commands[1].containsSequence(["--network", "demo_backend"]))
    }

    @Test("up maps link without alias to target service name")
    func upMapsLinkWithoutAliasToTargetServiceName() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
            })

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-redis-1"]))
        #expect(commands[0].containsSequence(["--network", "demo_backend,alias=redis"]))
    }

    @Test("up maps links on the normalized default network")
    func upMapsLinksOnNormalizedDefaultNetwork() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["default"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache"]
                    $0.networks = ["default"]
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "demo_default")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
            })

        let commands = runner.commands.map(\.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_default"])
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-redis-1"]))
        #expect(commands[0].containsSequence(["--network", "demo_default,alias=cache"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(commands[1].containsSequence(["--network", "demo_default"]))
    }

    @Test("up maps external links to generated host entries")
    func upMapsExternalLinksToGeneratedHostEntries() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy_db",
                status: "running",
                networks: [
                    ComposeContainerNetworkAttachment(network: "demo_backend", ipv4Address: "192.168.64.20"),
                ]
            ),
            ComposeContainerSummary(
                id: "legacy_cache",
                status: "running",
                networks: [
                    ComposeContainerNetworkAttachment(network: "demo_backend", ipv4Address: "192.168.64.21"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.externalLinks = ["legacy_db:db", "legacy_cache"]
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
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--network", "demo_backend"]))
        #expect(command.containsSequence(["--add-host", "db:192.168.64.20"]))
        #expect(command.containsSequence(["--add-host", "legacy_cache:192.168.64.21"]))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(await discoveryManager.getRequests.contains("legacy_db"))
        #expect(await discoveryManager.getRequests.contains("legacy_cache"))
    }

    @Test("up rejects external links without a shared runtime network")
    func upRejectsExternalLinksWithoutSharedRuntimeNetwork() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy_db",
                status: "running",
                networks: [
                    ComposeContainerNetworkAttachment(network: "other", ipv4Address: "192.168.64.20"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.externalLinks = ["legacy_db:db"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(
                runner: runner,
                discoveryManager: discoveryManager,
                resourceManager: resourceManager
            ).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported external links error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' external_links to 'legacy_db'; external container must share exactly one runtime network with the service"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects invalid link aliases before creating resources")
    func upRejectsInvalidLinkAliasesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:bad_alias"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid link alias error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' link alias 'bad_alias' is not a valid RFC1123 hostname"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects links without one shared network")
    func upRejectsLinksWithoutOneSharedNetwork() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": ComposeService(name: "redis", image: "redis:7"),
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
            })
            Issue.record("Expected unsupported links error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' links to 'redis'; links require both services to share exactly one Compose network until apple/container exposes source-scoped DNS links"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects shared link aliases before creating resources")
    func upRejectsSharedLinkAliasesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "cache": composeService(name: "cache", image: "redis:7") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["database"]]
                },
                "db": composeService(name: "db", image: "postgres:18") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["db:database"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected shared alias error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("services 'cache' and 'db' share network alias 'database' on network 'backend'; shared aliases need apple/container source-scoped DNS support"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps hostnames to runtime arguments")
    func upMapsHostnamesToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.hostname = "custom-api"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--hostname", "custom-api"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up rejects invalid hostnames before creating resources")
    func upRejectsInvalidHostnamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.hostname = "bad_name"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid hostname error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' hostname 'bad_name' is not a valid RFC1123 hostname"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps domain names to runtime arguments")
    func upMapsDomainNamesToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.domainName = "example.test."
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--domainname", "example.test"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up rejects invalid domain names before creating resources")
    func upRejectsInvalidDomainNamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.domainName = "bad_name"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid domain name error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' domainname 'bad_name' is not a valid RFC1123 hostname"))
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

    @Test("up maps extra hosts to runtime host entries")
    func upMapsExtraHostsToRuntimeHostEntries() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.extraHosts = ["db=10.0.0.5", "myhostv6=[::1]"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--add-host", "db:10.0.0.5"]))
        #expect(command.containsSequence(["--add-host", "myhostv6:::1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up maps host-gateway extra hosts to runtime host entries")
    func upMapsHostGatewayExtraHostsToRuntimeHostEntries() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.extraHosts = ["host.docker.internal=host-gateway"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--add-host", "host.docker.internal:host-gateway"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up maps sysctls to runtime arguments")
    func upMapsSysctlsToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.sysctls = [
                        "net.core.somaxconn": "1024",
                        "net.ipv4.ip_forward": "1",
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--sysctl", "net.core.somaxconn=1024"]))
        #expect(command.containsSequence(["--sysctl", "net.ipv4.ip_forward=1"]))
    }

    @Test("up maps network aliases to single network attachment")
    func upMapsNetworkAliasesToSingleNetworkAttachment() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["api", "api.internal"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend,alias=api,alias=api.internal"]))
    }

    @Test("up rejects invalid network aliases before creating resources")
    func upRejectsInvalidNetworkAliasesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["bad_alias"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid network alias error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' network alias 'bad_alias' is not a valid RFC1123 hostname"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects aliases on unattached networks before creating resources")
    func upRejectsAliasesOnUnattachedNetworksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["frontend": ["api"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(name: "backend"),
                "frontend": ComposeNetwork(name: "frontend"),
            ]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unattached network alias error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' sets network aliases on unattached network 'frontend'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
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

    @Test("up maps block IO config to runtime arguments")
    func upMapsBlockIOConfigToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.blkioConfig = ComposeBlkioConfig(
                        weight: 300,
                        weightDevice: [ComposeBlkioWeightDevice(path: "8:0", weight: 700)],
                        deviceReadBps: [ComposeBlkioThrottleDevice(path: "8:0", rate: "1048576")]
                    )
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--blkio", "weight=300"]))
        #expect(command.containsSequence(["--blkio", "device=8:0,weight=700"]))
        #expect(command.containsSequence(["--blkio", "device=8:0,read-bps=1048576"]))
    }

    @Test("up treats develop watch metadata as harmless")
    func upTreatsDevelopWatchMetadataAsHarmless() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
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
        ).up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.containsSequence(["run", "--name", "demo-api-1"]))
    }

    @Test("up rejects unmapped build fields before creating resources")
    func upRejectsUnmappedBuildFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(
                        context: "api",
                        options: ComposeBuild.Options(unsupportedFields: ["secrets"])
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
            #expect(error == .unsupported("service 'api' uses unsupported build fields secrets; advanced build fields need Docker Compose compatible apple/container build primitives"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported deploy modes as apple/container runtime gaps")
    func upRejectsUnsupportedDeployModesAsAppleContainerRuntimeGaps() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["mode"]
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
            #expect(error == .unsupported("service 'api' uses deploy.mode; deploy modes outside local replicated/global behavior need apple/container scheduler or job lifecycle primitives"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up waits for deploy job mode replicas")
    func upWaitsForDeployJobModeReplicas() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: [
            "demo-migrate-1": 0,
            "demo-migrate-2": 0,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-migrate-1"]))
        #expect(commands[0].contains("--detach"))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-migrate-2"]))
        #expect(commands[1].contains("--detach"))
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-migrate-1"),
            .wait(id: "demo-migrate-2"),
        ])
    }

    @Test("up fails deploy job mode on nonzero exit")
    func upFailsDeployJobModeOnNonzeroExit() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: [
            "demo-migrate-1": 0,
            "demo-migrate-2": 7,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.scale = 2
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["migrate": ComposeDependency(condition: "service_started")]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: runner,
                lifecycleManager: lifecycleManager
            ).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected deploy job failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'migrate' job container 'demo-migrate-2' exited with status 7"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.containsSequence(["example/migrate"]) })
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-migrate-1"),
            .wait(id: "demo-migrate-2"),
        ])
    }

    @Test("up rejects unsupported deploy update order as apple/container orchestration gap")
    func upRejectsUnsupportedDeployUpdateOrderAsAppleContainerOrchestrationGap() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["update_config.order"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported deploy update order error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.update_config.order; unsupported update orders need Docker Compose compatible apple/container update orchestration primitives"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported deploy resource limits as apple/container runtime gaps")
    func upRejectsUnsupportedDeployResourceLimitsAsAppleContainerRuntimeGaps() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["resources.limits.pids"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported deploy resource limit error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.resources.limits.pids; apple/container exposes local deploy CPU and memory limits but not this deploy resource limit yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects start-first deploy updates as an apple/container runtime gap")
    func upRejectsStartFirstDeployUpdatesAsAppleContainerRuntimeGaps() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["update_config.order.start-first"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected start-first deploy update error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.update_config.order: start-first; start-first updates need an apple/container container rename or service alias handoff primitive"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects deploy resource reservations as apple/container runtime gaps")
    func upRejectsDeployResourceReservationsAsAppleContainerRuntimeGaps() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["resources.reservations.memory"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported deploy resource reservation error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.resources.reservations.memory; resource reservations need an apple/container scheduler/resource reservation gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported model fields before creating resources")
    func upRejectsUnsupportedModelFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedModelFieldCases() {
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

    @Test("up runs provider services and injects setenv into dependents")
    func upRunsProviderServicesAndInjectsSetenvIntoDependents() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[{"name":"name","required":true},{"name":"size"}]},"down":{"parameters":[{"name":"name","required":true}]}}
            """, stderr: ""),
            CommandResult(status: 0, stdout: """
            {"type":"info","message":"provisioned database"}
            {"type":"setenv","message":"URL=https://magic.cloud/database"}
            """, stderr: ""),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(
                        type: provider.path,
                        options: [
                            "ignored": ["not-forwarded"],
                            "name": ["db"],
                            "size": ["small"],
                        ]
                    )
                },
                "api": composeService(name: "api", image: "alpine") {
                    $0.dependsOn = ["database": ComposeDependency()]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies { _ in }
        ).up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages == ["compose: provider database: provisioned database"])
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
            "--name=db",
            "--size=small",
            "database",
        ])
        #expect(!runner.commands[1].arguments.contains("--ignored=not-forwarded"))
        let runArguments = runner.commands[2].arguments
        #expect(runArguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(runArguments.contains("--env"))
        #expect(runArguments.contains("DATABASE_URL=https://magic.cloud/database"))
    }

    @Test("down runs provider service down lifecycle")
    func downRunsProviderServiceDownLifecycle() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[]},"down":{"parameters":[{"name":"name","required":true}]}}
            """, stderr: ""),
            CommandResult(status: 0, stdout: "", stderr: ""),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(type: provider.path, options: ["name": ["db"]])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).down(project: project, options: ComposeDownOptions())

        #expect(runner.commands.map(\.executable) == [provider.path, provider.path])
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
        #expect(runner.commands[1].arguments == [
            "compose",
            "--project-name=demo",
            "down",
            "--name=db",
            "database",
        ])
    }

    @Test("stop runs advertised provider stop lifecycle")
    func stopRunsAdvertisedProviderStopLifecycle() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[]},"down":{"parameters":[]},"stop":{"parameters":[{"name":"name","required":true}]}}
            """, stderr: ""),
            CommandResult(status: 0, stdout: "", stderr: ""),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(type: provider.path, options: ["name": ["db"]])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).stop(project: project, services: [])

        #expect(runner.commands.map(\.executable) == [provider.path, provider.path])
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
        #expect(runner.commands[1].arguments == [
            "compose",
            "--project-name=demo",
            "stop",
            "--name=db",
            "database",
        ])
    }

    @Test("stop skips provider service without advertised stop lifecycle")
    func stopSkipsProviderServiceWithoutAdvertisedStopLifecycle() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[]},"down":{"parameters":[]}}
            """, stderr: ""),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(type: provider.path)
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).stop(project: project, services: [])

        #expect(runner.commands.map(\.executable) == [provider.path])
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
    }

    @Test("stop all uses reverse dependency order")
    func stopAllUsesReverseDependencyOrder() async throws {
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
        ).stop(project: project, services: [])

        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
        ])
    }

    @Test("stop selected service does not include dependencies")
    func stopSelectedServiceDoesNotIncludeDependencies() async throws {
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
        ).stop(project: project, services: ["api"])

        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
        ])
    }

    @Test("up rejects provider missing required metadata option")
    func upRejectsProviderMissingRequiredMetadataOption() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[{"name":"name","required":true}]}}
            """, stderr: ""),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(type: provider.path)
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected required provider option failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("required parameter 'name' is missing from provider '\(provider.path)' definition"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.map(\.executable) == [provider.path])
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
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

    @Test("up accepts local logging drivers without options")
    func upAcceptsLocalLoggingDriversWithoutOptions() async throws {
        for testCase in supportedLocalServiceLoggingFieldCases() {
            let runner = RecordingRunner(responses: [.success])
            let discoveryManager = RecordingContainerDiscoveryManager()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
                .up(project: project, options: ComposeUpOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "run", "--name", "demo-api-1"]))
            #expect(!command.contains("--log-driver"))
            #expect(!command.contains("--log-opt"))
        }
    }

    @Test("up maps local logging options to runtime policy")
    func upMapsLocalLoggingOptionsToRuntimePolicy() async throws {
        for testCase in supportedLocalServiceLoggingOptionCases() {
            let runner = RecordingRunner(responses: [.success])
            let discoveryManager = RecordingContainerDiscoveryManager()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
                .up(project: project, options: ComposeUpOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "run", "--name", "demo-api-1"]))
            #expect(!command.contains("--log-driver"))
            for option in testCase.expectedOptions {
                #expect(command.containsSequence(["--log-opt", option]))
            }
        }
    }

    @Test("up maps disabled logging driver to runtime policy")
    func upMapsDisabledLoggingDriverToRuntimePolicy() async throws {
        for testCase in disabledServiceLoggingFieldCases() {
            let runner = RecordingRunner(responses: [.success])
            let discoveryManager = RecordingContainerDiscoveryManager()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
                .up(project: project, options: ComposeUpOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "run", "--name", "demo-api-1"]))
            #expect(command.containsSequence(["--log-driver", "none"]))
            #expect(!command.contains("--log-opt"))
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

    @Test("up accepts local service volume driver")
    func upAcceptsLocalServiceVolumeDriver() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumeDriver = "local"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager(),
            resourceManager: resourceManager
        )
            .up(project: project, options: ComposeUpOptions())

        let volumeRequest = try #require(await resourceManager.requests.compactMap { request -> ComposeVolumeCreateRequest? in
            guard case .createVolume(let volume) = request else {
                return nil
            }
            return volume
        }.first)
        #expect(volumeRequest.name == "demo_cache")
        #expect(volumeRequest.resolvedDriver == "local")
        #expect(volumeRequest.driverOpts == [:])
        #expect(volumeRequest.labels[composeProjectLabel] == "demo")
        let run = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(run.containsSequence(["--volume", "demo_cache:/cache"]))
    }

    @Test("up accepts volume nocopy normalized marker")
    func upAcceptsVolumeNoCopyNormalizedMarker() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            source: "cache",
                            target: "/cache",
                            unsupportedFields: ["volume.nocopy"]
                        ),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions())

        let run = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(run.containsSequence(["--volume", "demo_cache:/cache"]))
    }

    @Test("up rejects volume subpath as apple/container mount gap")
    func upRejectsVolumeSubpathAsAppleContainerMountGap() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            source: "cache",
                            target: "/cache",
                            unsupportedFields: ["volume.subpath"]
                        ),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported volume subpath error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses volume.subpath; volume subpath mounts need an apple/container mount primitive gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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

    @Test("up config hash includes external inherited volumes")
    func upConfigHashIncludesExternalInheritedVolumes() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["container:legacy"]
                },
            ]
        )

        let baselineRunner = RecordingRunner()
        try await ComposeOrchestrator(
            runner: baselineRunner,
            discoveryManager: RecordingContainerDiscoveryManager(containers: [
                ComposeContainerSummary(
                    id: "legacy",
                    status: "running",
                    mounts: [ComposeMount(type: "external-volume", source: "legacy_data", target: "/data")]
                ),
            ])
        ).up(project: project, options: ComposeUpOptions {
            $0.noStart = true
        })
        let baselineCreate = try #require(baselineRunner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let baselineHash = try #require(composeConfigHash(in: baselineCreate))

        let changedRunner = RecordingRunner()
        try await ComposeOrchestrator(
            runner: changedRunner,
            discoveryManager: RecordingContainerDiscoveryManager(containers: [
                ComposeContainerSummary(
                    id: "legacy",
                    status: "running",
                    mounts: [ComposeMount(type: "external-volume", source: "legacy_state", target: "/state")]
                ),
            ])
        ).up(project: project, options: ComposeUpOptions {
            $0.noStart = true
        })
        let changedCreate = try #require(changedRunner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let changedHash = try #require(composeConfigHash(in: changedCreate))

        #expect(baselineHash != changedHash)
    }

    @Test("up inherits external container volumes from direct inspect")
    func upInheritsExternalContainerVolumesFromDirectInspect() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy",
                status: "running",
                mounts: [
                    ComposeMount(type: "external-volume", source: "legacy_data", target: "/data"),
                    ComposeMount(type: "bind", source: "/host/seed", target: "/seed", readOnly: true),
                    ComposeMount(type: "tmpfs", target: "/scratch"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["container:legacy:ro"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        #expect(await discoveryManager.getRequests.contains("legacy"))
        let workerRun = try #require(runner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        #expect(workerRun.containsSequence(["--volume", "legacy_data:/data:ro"]))
        #expect(workerRun.containsSequence(["--volume", "/host/seed:/seed:ro"]))
        #expect(workerRun.containsSequence(["--mount", "type=tmpfs,destination=/scratch,readonly"]))
        #expect(workerRun.containsSequence(["--volume", "demo_cache:/cache"]))
    }

    @Test("up rejects missing external container volumes_from before creating resources")
    func upRejectsMissingExternalContainerVolumesFromBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["container:legacy:ro"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected missing external volumes_from error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'worker' volumes_from 'container:legacy:ro' references missing external container 'legacy'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported external container volume mounts before creating resources")
    func upRejectsUnsupportedExternalContainerVolumeMountsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy",
                status: "running",
                mounts: [
                    ComposeMount(
                        type: "block",
                        source: "/tmp/disk.img",
                        target: "/disk",
                        unsupportedFields: ["apple.container.block"]
                    ),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["container:legacy:ro"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported external volume mount error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'worker' uses volumes_from 'container:legacy:ro'; external container 'legacy' has unsupported mount fields apple.container.block"))
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
            #expect(error == .unsupported("service 'api' uses use_api_socket; Docker-compatible API socket and credential handoff need an apple/container runtime boundary"))
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

    @Test("up maps disabled healthchecks to container flags")
    func upMapsDisabledHealthchecksToContainerFlags() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
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

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(command.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(command.contains("--no-healthcheck"))
    }

    @Test("up maps inherited image healthchecks to container flags")
    func upMapsInheritedImageHealthchecksToContainerFlags() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(healthChecks: [
            "example/api": ComposeImageHealthCheck(
                test: ["CMD-SHELL", "curl -fsS http://localhost/health || exit 1"],
                intervalInNanoseconds: 30_000_000_000,
                timeoutInNanoseconds: 3_000_000_000,
                startPeriodInNanoseconds: 10_000_000_000,
                startIntervalInNanoseconds: 1_500_000_000,
                retries: 4
            ),
        ])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
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

        try await ComposeOrchestrator(
            runner: runner,
            imageManager: imageManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(await imageManager.requests == [.healthCheck(reference: "example/api", platform: nil)])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(command.containsSequence(["--health-cmd", "curl -fsS http://localhost/health || exit 1"]))
        #expect(command.containsSequence(["--health-interval", "30s"]))
        #expect(command.containsSequence(["--health-timeout", "3s"]))
        #expect(command.containsSequence(["--health-start-period", "10s"]))
        #expect(command.containsSequence(["--health-start-interval", "1.5s"]))
        #expect(command.containsSequence(["--health-retries", "4"]))
    }

    @Test("up merges timing-only healthcheck overrides with image metadata")
    func upMergesTimingOnlyHealthcheckOverridesWithImageMetadata() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(healthChecks: [
            "example/api": ComposeImageHealthCheck(
                test: ["CMD", "/usr/local/bin/health"],
                intervalInNanoseconds: 30_000_000_000,
                timeoutInNanoseconds: 3_000_000_000,
                retries: 4
            ),
        ])
        let project = composeProject(
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

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(await imageManager.requests == [.healthCheck(reference: "example/api", platform: nil)])
        #expect(command.containsSequence(["--health-cmd", "/usr/local/bin/health"]))
        #expect(command.containsSequence(["--health-interval", "5s"]))
        #expect(command.containsSequence(["--health-timeout", "3s"]))
        #expect(command.containsSequence(["--health-retries", "2"]))
        #expect(!command.containsSequence(["--health-interval", "30s"]))
        #expect(!command.containsSequence(["--health-retries", "4"]))
    }

    @Test("up rejects timing-only healthchecks without image metadata before creating resources")
    func upRejectsTimingOnlyHealthchecksWithoutImageMetadataBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.healthcheck = .object(["interval": .string("5s")])
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(
                runner: runner,
                imageManager: imageManager,
                resourceManager: resourceManager
            ).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported inherited healthcheck error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' tunes an image healthcheck, but image 'example/api' does not expose Dockerfile HEALTHCHECK metadata"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await imageManager.requests == [.healthCheck(reference: "example/api", platform: nil)])
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up maps file-backed configs and secrets to read-only bind mounts")
    func upMapsFileBackedConfigsAndSecretsToReadOnlyBindMounts() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let config = directory.appendingPathComponent("app.conf")
        let otherConfig = directory.appendingPathComponent("other.conf")
        let secret = directory.appendingPathComponent("token.txt")
        let otherSecret = directory.appendingPathComponent("other-token.txt")
        try Data("config\n".utf8).write(to: config)
        try Data("other-config\n".utf8).write(to: otherConfig)
        try Data("secret\n".utf8).write(to: secret)
        try Data("other-secret\n".utf8).write(to: otherSecret)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [
                        .object(["source": .string("app_config")]),
                        .object(["source": .string("other_config"), "target": .string("/etc/other.conf")]),
                    ]
                    $0.secrets = [
                        .object(["source": .string("app_secret")]),
                        .object(["source": .string("other_secret"), "target": .string("custom-token")]),
                    ]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.configs = [
                "app_config": .object(["file": .string("app.conf")]),
                "other_config": .object(["file": .string(otherConfig.path)]),
            ]
            $0.secrets = [
                "app_secret": .object(["file": .string(secret.path)]),
                "other_secret": .object(["file": .string(otherSecret.path)]),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--volume", "\(config.path):/app_config:ro"]))
        #expect(command.containsSequence(["--volume", "\(otherConfig.path):/etc/other.conf:ro"]))
        #expect(command.containsSequence(["--volume", "\(secret.path):/run/secrets/app_secret:ro"]))
        #expect(command.containsSequence(["--volume", "\(otherSecret.path):/run/secrets/custom-token:ro"]))
    }

    @Test("up materializes inline configs and environment backed secrets")
    func upMaterializesInlineConfigsAndEnvironmentBackedSecrets() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let configEnvironment = "COMPOSE_CONFIG_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let secretEnvironment = "COMPOSE_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(configEnvironment, "from environment\n", 1)
        setenv(secretEnvironment, "super-secret", 1)
        defer {
            unsetenv(configEnvironment)
            unsetenv(secretEnvironment)
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [
                        .object(["source": .string("inline_config"), "target": .string("/etc/inline.conf"), "mode": .string("0555")]),
                        .object(["source": .string("env_config"), "target": .string("env.conf"), "mode": .string("0666")]),
                    ]
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("runtime-token"), "mode": .string("0440")])]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.composeFiles = [directory.appendingPathComponent("compose.yaml").path]
            $0.configs = [
                "inline_config": .object(["content": .string("inline config\n")]),
                "env_config": .object(["environment": .string(configEnvironment)]),
            ]
            $0.secrets = ["app_secret": .object(["environment": .string(secretEnvironment)])]
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(materializedConfigSecretDirectory: directory.appendingPathComponent("state", isDirectory: true)),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = RecordingContainerDiscoveryManager()
            }
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        let inlineConfig = try #require(readOnlyVolumeSource(target: "/etc/inline.conf", in: command))
        let environmentConfig = try #require(readOnlyVolumeSource(target: "/env.conf", in: command))
        let secret = try #require(readOnlyVolumeSource(target: "/run/secrets/runtime-token", in: command))
        #expect(try String(contentsOfFile: inlineConfig, encoding: .utf8) == "inline config\n")
        #expect(try String(contentsOfFile: environmentConfig, encoding: .utf8) == "from environment\n")
        #expect(try String(contentsOfFile: secret, encoding: .utf8) == "super-secret")
        #expect(try posixPermissions(at: inlineConfig) == 0o555)
        #expect(try posixPermissions(at: environmentConfig) == 0o444)
        #expect(try posixPermissions(at: secret) == 0o440)
    }

    @Test("down removes materialized config and secret files")
    func downRemovesMaterializedConfigAndSecretFiles() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let stateRoot = directory.appendingPathComponent("state", isDirectory: true)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("inline_config"), "target": .string("/etc/inline.conf")])]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.configs = ["inline_config": .object(["content": .string("inline config\n")])]
        }
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(materializedConfigSecretDirectory: stateRoot),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = RecordingContainerDiscoveryManager()
                $0.lifecycleManager = lifecycleManager
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        let inlineConfig = try #require(readOnlyVolumeSource(target: "/etc/inline.conf", in: command))
        #expect(FileManager.default.fileExists(atPath: inlineConfig))

        try await orchestrator.down(project: project, options: ComposeDownOptions())

        #expect(!FileManager.default.fileExists(atPath: inlineConfig))
        let remainingEntries = (try? FileManager.default.contentsOfDirectory(atPath: stateRoot.path)) ?? []
        #expect(remainingEntries.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("up dry run does not materialize inline configs")
    func upDryRunDoesNotMaterializeInlineConfigs() async throws {
        let emitted = LockedStringRecorder()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let stateRoot = directory.appendingPathComponent("state", isDirectory: true)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("inline_config"), "target": .string("/etc/inline.conf")])]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.configs = ["inline_config": .object(["content": .string("inline config\n")])]
        }

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(
                dryRun: true,
                materializedConfigSecretDirectory: stateRoot,
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(emit: emitted.append)
            )
        ).up(project: project, options: ComposeUpOptions())

        #expect(!FileManager.default.fileExists(atPath: stateRoot.path))
        #expect(emitted.snapshot.contains { $0.contains("--volume") && $0.contains(":/etc/inline.conf:ro") })
    }

    @Test("up rejects generated config ownership remapping before creating resources")
    func upRejectsGeneratedConfigOwnershipRemappingBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("inline_config"), "target": .string("/etc/inline.conf"), "uid": .string("103"), "gid": .string("103")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.configs = ["inline_config": .object(["content": .string("inline config\n")])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected generated config ownership remapping to fail")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses uid/gid on generated config 'inline_config'; apple/container bind mounts do not expose config/secret ownership remapping"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects invalid generated secret mode before creating resources")
    func upRejectsInvalidGeneratedSecretModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let secretEnvironment = "BAD_MODE_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(secretEnvironment, "secret", 1)
        defer {
            unsetenv(secretEnvironment)
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("runtime-token"), "mode": .string("0999")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.secrets = ["app_secret": .object(["environment": .string(secretEnvironment)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid generated secret mode to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' secret 'app_secret' mode '0999' must be an octal file mode between 0000 and 0777"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects external configs before creating resources")
    func upRejectsExternalConfigsBeforeCreatingResources() async throws {
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
            Issue.record("Expected external config error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses external config 'app_config'; external configs need an apple/container config store primitive"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps service restart policies to container create flags")
    func upMapsServiceRestartPoliciesToContainerCreateFlags() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
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

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.contains("--restart"))
        #expect(runArguments.contains("unless-stopped"))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("up maps deploy restart policy to container create flags")
    func upMapsDeployRestartPolicyToContainerCreateFlags() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "on-failure",
                        maxAttempts: 3
                    )
                    $0.restart = "unless-stopped"
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
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.contains("--restart"))
        #expect(runArguments.contains("on-failure:3"))
        #expect(!runArguments.contains("unless-stopped"))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("up maps deploy restart max attempts zero to unlimited on failure")
    func upMapsDeployRestartMaxAttemptsZeroToUnlimitedOnFailure() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "on-failure",
                        maxAttempts: 0
                    )
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.containsSequence(["--restart", "on-failure"]))
        #expect(!runArguments.contains("on-failure:0"))
    }

    @Test("up rejects deploy job restart policy")
    func upRejectsDeployJobRestartPolicy() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "any",
                        maxAttempts: 3
                    )
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected deploy job restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'migrate' uses deploy.restart_policy with deploy.mode 'replicated-job'; job restart policies need a restart-aware apple/container wait primitive"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects service restart policies for deploy jobs")
    func upRejectsServiceRestartPoliciesForDeployJobs() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.restart = "always"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected deploy job restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'migrate' uses restart policy 'always' with deploy.mode 'replicated-job'; job restart policies need a restart-aware apple/container wait primitive"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects on-failure service restart policies for deploy jobs")
    func upRejectsOnFailureServiceRestartPoliciesForDeployJobs() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.restart = "on-failure:3"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected deploy job restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'migrate' uses restart policy 'on-failure:3' with deploy.mode 'replicated-job'; job restart policies need a restart-aware apple/container wait primitive"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up allows service restart none for deploy jobs")
    func upAllowsServiceRestartNoneForDeployJobs() async throws {
        let runner = RecordingRunner(responses: [.success])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-migrate-1": 0])
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.restart = "no"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.containsSequence(["--restart", "no"]))
        #expect(await lifecycleManager.requests == [.wait(id: "demo-migrate-1")])
    }

    @Test("up allows deploy restart policy none for deploy jobs")
    func upAllowsDeployRestartPolicyNoneForDeployJobs() async throws {
        let runner = RecordingRunner(responses: [.success])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-migrate-1": 0])
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(condition: "none")
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.containsSequence(["--restart", "no"]))
        #expect(await lifecycleManager.requests == [.wait(id: "demo-migrate-1")])
    }

    @Test("up rejects invalid restart policies before creating resources")
    func upRejectsInvalidRestartPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.restart = "sometimes"
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
            Issue.record("Expected invalid restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses restart policy 'sometimes'; supported values are no, always, on-failure[:max-retries], and unless-stopped"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps deploy restart timing to container create flags")
    func upMapsDeployRestartTimingToContainerCreateFlags() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "on-failure",
                        delayNanoseconds: 1_500_000_000,
                        maxAttempts: 3,
                        windowNanoseconds: 50_000_000
                    )
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
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.contains("--restart"))
        #expect(runArguments.contains("on-failure:3"))
        #expect(runArguments.contains("--restart-delay"))
        #expect(runArguments.contains("1.5s"))
        #expect(runArguments.contains("--restart-window"))
        #expect(runArguments.contains("0.05s"))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("up rejects deploy restart max attempts without on-failure")
    func upRejectsDeployRestartMaxAttemptsWithoutOnFailure() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "any",
                        maxAttempts: 3
                    )
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
            Issue.record("Expected deploy restart max attempts error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.restart_policy.max_attempts with condition 'any'; apple/container retry limits are only available for on-failure restart policies"))
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

        let data = Data(try #require(emitted.messages.first).utf8)
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

        let data = Data(try #require(emitted.messages.first).utf8)
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

    @Test("volumes rejects unsupported template actions")
    func volumesRejectsUnsupportedTemplateActions() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .volumes(project: project, options: ComposeVolumesOptions(format: "{{json .}}"))
            Issue.record("Expected unsupported volumes template action error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("format template action '{{json .}}'; supported actions are field references like '{{.Name}}'"))
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
        let client = RecordingContainerEventsAPIClient(data: try containerEventData(events, trailingNewline: false))
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
        let client = RecordingContainerEventsAPIClient(data: try containerEventData(events))
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

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]))

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [false])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-api-1"])
    }

    @Test("ps default discovery uses configured container binary and environment launcher")
    func psDefaultDiscoveryUsesConfiguredContainerBinaryAndEnvironmentLauncher() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: "[]", stderr: ""),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                containerBinary: "custom-container",
                environmentLauncher: "custom-env",
                runtimeHooks: .init(emit: { emitted.append($0) })
            )
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
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-worker-1"])
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
            demo-worker-1  worker   stopped
            """,
        ])
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

        #expect(emitted.messages == ["healthy\t0\t127.0.0.1:8080->80/tcp"])
    }

    @Test("ps can exclude orphaned service containers")
    func psCanExcludeOrphanedServiceContainers() async throws {
        let emitted = MessageRecorder()
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

        let data = Data(try #require(emitted.messages.first).utf8)
        let containers = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(containers.compactMap { $0["id"] as? String } == ["demo-api-1"])
    }

    @Test("ps rejects unsupported template fields")
    func psRejectsUnsupportedTemplateFields() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [])
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)

        do {
            try await orchestrator.ps(
                project: ComposeProject(name: "demo", services: [:]),
                options: ComposePsOptions { $0.format = "{{.Command}}" }
            )
            Issue.record("Expected unsupported ps template field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("ps --format field '.Command'; supported fields are ExitCode, Health, ID, Image, Name, Ports, Project, Publishers, Service, State, Status"))
        } catch {
            Issue.record("Unexpected error: \(error)")
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

        try await orchestrator.ps(
            project: ComposeProject(name: "demo", services: [:]),
            options: ComposePsOptions { $0.filters = ["status=exited"] }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-worker-1"])
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
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-paused-1"])
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
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-paused-1"])
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
            #expect(error == .unsupported("ps status 'restarting'; apple/container exposes paused, running, stopped, stopping, and unknown"))
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
            $0.extensions = ["x-project": .object(["enabled": .bool(true)])]
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
        #expect(yaml.contains("extensions:\n  x-project:\n    enabled: true"))
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
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.networks = ["back"]
                },
            ]
        ) {
            $0.networks = ["front": ComposeNetwork(name: "front"), "back": ComposeNetwork(name: "back")]
            $0.volumes = ["cache": ComposeVolume(name: "cache"), "unused": ComposeVolume(name: "unused")]
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
                            image: ComposeBuild.Options.Image(
                                target: "runtime",
                                noCache: true,
                                pull: true,
                                platforms: ["linux/amd64", "linux/arm64"],
                                tags: ["example/api:latest", "example/api:dev", "example/api:test"]),
                            attestations: ComposeBuild.Options.Attestations(
                                provenance: "mode=min",
                                sbom: "false"
                            )
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
        #expect(runner.commands[0].arguments.containsSequence(["--file", "api/Containerfile"]))
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
        #expect(runner.commands[0].arguments.containsSequence(["--provenance", "mode=min"]))
        #expect(!runner.commands[0].arguments.contains("--sbom"))
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

    @Test("build resolves Dockerfile relative to build context")
    func buildResolvesDockerfileRelativeToBuildContext() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions()
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api") {
                    $0.build = ComposeBuild(
                        context: "/tmp/container-compose-build-context/api",
                        dockerfile: "docker/Dockerfile"
                    )
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(
                        context: "worker",
                        dockerfile: "Containerfile"
                    )
                },
                "remote": composeService(name: "remote") {
                    $0.build = ComposeBuild(
                        context: "https://example.com/repo.git",
                        dockerfile: "Containerfile"
                    )
                },
            ]
        )

        try await orchestrator.build(project: project, services: ["api", "worker", "remote"], noCache: false)

        let apiCommand = try #require(runner.commands.first { command in
            command.arguments.last == "/tmp/container-compose-build-context/api"
        }?.arguments)
        let workerCommand = try #require(runner.commands.first { command in
            command.arguments.last == "worker"
        }?.arguments)
        let remoteCommand = try #require(runner.commands.first { command in
            command.arguments.last == "https://example.com/repo.git"
        }?.arguments)

        #expect(apiCommand.containsSequence([
            "--file",
            "/tmp/container-compose-build-context/api/docker/Dockerfile",
        ]))
        #expect(workerCommand.containsSequence(["--file", "worker/Containerfile"]))
        #expect(remoteCommand.containsSequence(["--file", "Containerfile"]))
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

    @Test("build options add CLI build args and memory")
    func buildOptionsAddCLIBuildArgsAndMemory() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "base": composeService(name: "base", image: "example/base:latest") {
                    $0.build = ComposeBuild(context: "base")
                },
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        contexts: ComposeBuild.Contexts(
                            context: "api",
                            additionalContexts: [
                                "base": "service:base",
                                "shared": "/workspace/shared",
                            ]),
                        args: ["FILE_ARG": "1"],
                        metadata: ComposeBuild.Metadata(
                            ssh: ["default", "git=/tmp/git.sock"]
                        ),
                        options: ComposeBuild.Options(
                            frontend: ComposeBuild.Options.Frontend(
                                entitlements: ["network.host"],
                                extraHosts: ["build.local=127.0.0.1"],
                                network: "host",
                                privileged: true,
                                shmSize: "67108864",
                                ulimits: ["nofile=1024:2048"])
                        )
                    )
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.buildArguments = ["CLI_ARG=2"]
                $0.memory = "256m"
                $0.ssh = ["default=/tmp/cli.sock", "deploy=/tmp/deploy.sock"]
            }
        )

        #expect(runner.commands.count == 2)
        let baseCommand = try #require(runner.commands.first?.arguments)
        #expect(baseCommand.last == "base")

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--memory", "256m"]))
        #expect(!command.containsSequence(["--ssh", "default"]))
        #expect(command.containsSequence(["--ssh", "git=/tmp/git.sock"]))
        #expect(command.containsSequence(["--ssh", "default=/tmp/cli.sock"]))
        #expect(command.containsSequence(["--ssh", "deploy=/tmp/deploy.sock"]))
        #expect(command.containsSequence(["--build-context", "base=docker-image://example/base:latest"]))
        #expect(command.containsSequence(["--build-context", "shared=/workspace/shared"]))
        #expect(command.containsSequence(["--allow", "network.host"]))
        #expect(command.containsSequence(["--add-host", "build.local=127.0.0.1"]))
        #expect(command.containsSequence(["--network", "host"]))
        #expect(command.contains("--privileged"))
        #expect(command.containsSequence(["--shm-size", "67108864"]))
        #expect(command.containsSequence(["--ulimit", "nofile=1024:2048"]))
        #expect(command.containsSequence(["--build-arg", "FILE_ARG=1"]))
        #expect(command.containsSequence(["--build-arg", "CLI_ARG=2"]))
        #expect(command.last == "api")
    }

    @Test("build rejects unknown service additional contexts before side effects")
    func buildRejectsUnknownServiceAdditionalContextsBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        contexts: ComposeBuild.Contexts(
                            context: "api",
                            additionalContexts: [
                                "base": "service:missing",
                            ])
                    )
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).build(
                project: project,
                options: ComposeBuildOptions {
                    $0.services = ["api"]
                }
            )
            Issue.record("Expected unknown build additional_contexts service failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("build additional_contexts references unknown service 'missing'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("build print renders bake targets without build side effects")
    func buildPrintRendersBakeTargetsWithoutBuildSideEffects() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let imageManager = RecordingContainerImageManager()
        var project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = [
                        "db": ComposeDependency(condition: "service_started"),
                    ]
                    $0.build = ComposeBuild(
                        contexts: ComposeBuild.Contexts(
                            context: "api",
                            dockerfile: "Containerfile",
                            additionalContexts: [
                                "db": "service:db",
                                "shared": "/workspace/project/shared",
                            ]),
                        args: ["FILE_ARG": "1"],
                        cache: ComposeBuild.Cache(
                            from: ["type=registry,ref=example/api:cache"],
                            to: ["type=local,dest=.cache"]
                        ),
                        metadata: ComposeBuild.Metadata(
                            labels: ["org.opencontainers.image.title": "api"],
                            secrets: [
                                ComposeBuildSecret(id: "file_token", file: "token.txt"),
                                ComposeBuildSecret(id: "npm_token", environment: "NPM_TOKEN"),
                            ],
                            ssh: ["default", "git=/tmp/git.sock"]
                        ),
                        options: ComposeBuild.Options(
                            image: ComposeBuild.Options.Image(
                                target: "runtime",
                                noCache: true,
                                pull: true,
                                platforms: ["linux/arm64"],
                                tags: ["example/api:dev"]),
                            frontend: ComposeBuild.Options.Frontend(
                                entitlements: ["network.host"],
                                extraHosts: ["build.local=127.0.0.1"],
                                network: "host",
                                privileged: true,
                                shmSize: "67108864",
                                ulimits: ["nofile=1024:2048"]),
                            attestations: ComposeBuild.Options.Attestations(
                                provenance: "mode=min",
                                sbom: "true"
                            )
                        )
                    )
                },
                "db": composeService(name: "db") {
                    $0.build = ComposeBuild(context: "db")
                },
            ]
        )
        project.workingDirectory = "/workspace/project"
        project.environment = ["ENV_ONLY": "from-env"]

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            imageManager: imageManager
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.buildArguments = ["CLI_ARG=2", "ENV_ONLY", "MISSING_ENV"]
                $0.noCache = true
                $0.printBake = true
                $0.pull = true
                $0.push = true
                $0.provenance = "mode=max"
                $0.sbom = "true"
                $0.ssh = ["deploy=/tmp/deploy.sock"]
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await imageManager.requests.isEmpty)
        let output = try #require(emitted.messages.first)
        let bake = try bakeJSON(output)
        #expect(try bakeGroupTargets(bake) == ["db", "api"])

        let api = try bakeTarget(bake, name: "api")
        #expect(api["context"] as? String == "/workspace/project/api")
        #expect(api["dockerfile"] as? String == "/workspace/project/api/Containerfile")
        #expect(api["target"] as? String == "runtime")
        #expect(api["pull"] as? Bool == true)
        #expect(api["no-cache"] as? Bool == true)
        #expect(api["tags"] as? [String] == ["example/api:dev", "example/api:latest"])
        #expect(api["cache-from"] as? [String] == ["type=registry,ref=example/api:cache"])
        #expect(api["cache-to"] as? [String] == ["type=local,dest=.cache"])
        #expect(api["contexts"] as? [String: String] == [
            "db": "target:db",
            "shared": "/workspace/project/shared",
        ])
        #expect(api["entitlements"] as? [String] == ["network.host"])
        #expect(api["extra-hosts"] as? [String] == ["build.local=127.0.0.1"])
        #expect(api["network"] as? String == "host")
        #expect(api["privileged"] as? Bool == true)
        #expect(api["shm-size"] as? String == "67108864")
        #expect(api["ulimits"] as? [String] == ["nofile=1024:2048"])
        #expect(api["platforms"] as? [String] == ["linux/arm64"])
        #expect(api["attest"] as? [String] == ["type=provenance,mode=max", "type=sbom"])
        #expect(api["secret"] as? [String] == [
            "id=file_token,type=file,src=/workspace/project/token.txt",
            "id=npm_token,type=env,env=NPM_TOKEN",
        ])
        #expect(api["ssh"] as? [String] == ["default", "git=/tmp/git.sock", "deploy=/tmp/deploy.sock"])
        #expect(api["output"] as? [String] == ["type=registry"])
        #expect((api["labels"] as? [String: String])?["org.opencontainers.image.title"] == "api")
        let arguments = try #require(api["args"] as? [String: String])
        #expect(arguments["FILE_ARG"] == "1")
        #expect(arguments["CLI_ARG"] == "2")
        #expect(arguments["ENV_ONLY"] == "from-env")
        #expect(arguments["MISSING_ENV"] == nil)

        let db = try bakeTarget(bake, name: "db")
        #expect(db["context"] as? String == "/workspace/project/db")
        #expect(db["dockerfile"] as? String == "/workspace/project/db/Dockerfile")
        #expect(db["tags"] as? [String] == ["demo_db:latest"])
        #expect(db["output"] as? [String] == ["type=docker"])
    }

    @Test("build print check renders lint bake call without output")
    func buildPrintCheckRendersLintBakeCallWithoutOutput() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.check = true
                $0.printBake = true
            }
        )

        let output = try #require(emitted.messages.first)
        let api = try bakeTarget(try bakeJSON(output), name: "api")
        #expect(api["call"] as? String == "lint")
        #expect(api["output"] == nil)
    }

    @Test("build print renders inline Dockerfile")
    func buildPrintRendersInlineDockerfile() async throws {
        let emitted = MessageRecorder()
        var project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:inline") {
                    $0.build = ComposeBuild(
                        context: ".",
                        dockerfileInline: "FROM alpine:3.20\nRUN echo inline\n"
                    )
                },
            ]
        )
        project.workingDirectory = "/workspace/inline"

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.printBake = true
            }
        )

        let output = try #require(emitted.messages.first)
        let api = try bakeTarget(try bakeJSON(output), name: "api")
        #expect(api["context"] as? String == "/workspace/inline")
        #expect(api["dockerfile"] == nil)
        #expect(api["dockerfile-inline"] as? String == "FROM alpine:3.20\nRUN echo inline\n")
        #expect(api["tags"] as? [String] == ["example/api:inline"])
    }

    @Test("build print rejects empty build argument names")
    func buildPrintRejectsEmptyBuildArgumentNames() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        do {
            try await ComposeOrchestrator().build(
                project: project,
                options: ComposeBuildOptions {
                    $0.services = ["api"]
                    $0.buildArguments = ["=bad"]
                    $0.printBake = true
                }
            )
            Issue.record("Expected empty build argument name error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("build --build-arg requires KEY or KEY=VALUE"))
        }
    }

    @Test("build emits progress rows when progress is enabled")
    func buildEmitsProgressRowsWhenProgressIsEnabled() async throws {
        let runner = RecordingRunner()
        let emitted = LockedStringRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )
        let progress = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append(String(bytes: $0, encoding: .utf8) ?? "") }
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(progress: progress)
        ).build(project: project, services: ["api"], noCache: false)

        #expect(runner.commands.count == 1)
        #expect(emitted.snapshot == [
            "⠓ Building api\n",
            "✓ Building api\n",
        ])
    }

    @Test("build emits first progress row before container build starts")
    func buildEmitsFirstProgressRowBeforeContainerBuildStarts() async throws {
        let emitted = LockedStringRecorder()
        let runner = ProgressAssertingRunner { arguments in
            #expect(arguments.containsSequence(["container", "build"]))
            #expect(emitted.snapshot == ["⠓ Building api\n"])
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )
        let progress = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(progress: progress)
        ).build(project: project, services: ["api"], noCache: false)

        #expect(runner.commands.count == 1)
        #expect(emitted.snapshot == [
            "⠓ Building api\n",
            "✓ Building api\n",
        ])
    }

    @Test("quiet build suppresses progress rows")
    func quietBuildSuppressesProgressRows() async throws {
        let runner = RecordingRunner()
        let emitted = LockedStringRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )
        let progress = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append(String(bytes: $0, encoding: .utf8) ?? "") }
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(progress: progress)
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.quiet = true
            }
        )

        #expect(runner.commands.count == 1)
        #expect(emitted.snapshot.isEmpty)
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
                        options: ComposeBuild.Options(
                            image: ComposeBuild.Options.Image(noCache: true)
                        )
                    )
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(project: project, services: ["api"], noCache: false)

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.contains("--no-cache"))
    }

    @Test("build check forwards check flag and skips push")
    func buildCheckForwardsCheckFlagAndSkipsPush() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).build(
            project: project,
            options: ComposeBuildOptions {
                $0.check = true
                $0.push = true
            }
        )

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.contains("--check"))
        #expect(await imageManager.requests.isEmpty)
    }

    @Test("build forwards default builder selection")
    func buildForwardsDefaultBuilderSelection() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(
            project: project,
            options: ComposeBuildOptions {
                $0.builder = "default"
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["container", "build", "--builder", "default", "--tag", "example/api:latest"]))
    }

    @Test("build forwards named builders")
    func buildForwardsNamedBuilders() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(
            project: project,
            options: ComposeBuildOptions {
                $0.builder = "remote"
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["container", "build", "--builder", "remote", "--tag", "example/api:latest"]))
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
        #expect(resources.count == 1)
        if case .deleteVolume(let name) = resources[0] {
            #expect(name.hasPrefix("demo_anon-"))
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

    @Test("up detached runs post start hooks through direct exec")
    func upDetachedRunsPostStartHooksThroughDirectExec() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
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

        try await ComposeOrchestrator(runner: runner, execManager: execManager)
            .up(project: project, options: ComposeUpOptions { $0.detach = true })

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
        let execManager = RecordingContainerExecManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.postStart = [ComposeServiceHook(command: ["sh", "-c", "touch /tmp/ready"])]
                    $0.preStop = [ComposeServiceHook(command: ["sh", "-c", "rm -f /tmp/ready"])]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
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
                    $0.postStart = [ComposeServiceHook()]
                },
                ComposeUpOptions { $0.detach = true },
                .invalidProject("service 'api' post_start[0] requires a command")
            ),
            (
                composeService(name: "api", image: "example/api") {
                    $0.postStart = [ComposeServiceHook(command: ["true"])]
                },
                ComposeUpOptions(),
                .unsupported("service 'api' uses post_start; attached up cannot run lifecycle hooks before foreground attach because apple/container does not expose reattaching to the init process after a hookable detached start, use --detach")
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

    @Test("run rejects foreground post start hooks before creating one off containers")
    func runRejectsForegroundPostStartHooksBeforeCreatingOneOffContainers() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.postStart = [ComposeServiceHook(command: ["true"])]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected foreground post_start hook error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses post_start; foreground compose run cannot execute post_start before attach because apple/container does not expose reattaching to the init process after a hookable detached start, use --detach"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects foreground pre stop hooks before creating one off containers")
    func runRejectsForegroundPreStopHooksBeforeCreatingOneOffContainers() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.preStop = [ComposeServiceHook(command: ["true"])]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(
                project: project,
                serviceName: "job",
                options: composeRunOptions(command: ["sleep", "60"])
            )
            Issue.record("Expected foreground pre_stop hook error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses pre_stop; foreground compose run cannot execute pre_stop before the one-off init process exits because apple/container does not expose an interceptable foreground stop boundary"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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

    @Test("start wait dry run emits wait-running operations")
    func startWaitDryRunEmitsWaitRunningOperations() async throws {
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
            "+ compose-runtime wait-running --timeout 3 demo-api-1",
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
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: 5),
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
                ],
                mounts: [
                    Filesystem.volume(name: "legacy_data", format: "ext4", source: "/tmp/legacy-data", destination: "/data", options: ["ro"]),
                    Filesystem.virtiofs(source: "/tmp/seed", destination: "/seed", options: []),
                    Filesystem.tmpfs(destination: "/scratch", options: ["ro"]),
                ],
                networks: [
                    ContainerResource.Attachment(
                        network: "demo_backend",
                        hostname: "demo-api-1",
                        aliases: ["api"],
                        ipv4Address: try CIDRv4("192.168.64.20/24"),
                        ipv4Gateway: try IPv4Address("192.168.64.1"),
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
                    ComposeMount(type: "external-volume", source: "legacy_data", target: "/data", readOnly: true),
                    ComposeMount(type: "bind", source: "/tmp/seed", target: "/seed"),
                    ComposeMount(type: "tmpfs", target: "/scratch", readOnly: true),
                ],
                networks: [
                    ComposeContainerNetworkAttachment(network: "demo_backend", ipv4Address: "192.168.64.20"),
                ]
            ),
            state: ComposeContainerSummary.State(health: "healthy")
        ))
        #expect(all.map(\.status) == ["running", "stopped"])
        #expect(worker?.id == "demo-worker-1")
        #expect(worker?.platform == "linux/amd64")
        #expect(worker?.exitCode == 17)
        #expect(worker?.exitedDate == Date(timeIntervalSince1970: 1_700_000_000))
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
                try PublishPort(
                    hostAddress: try IPAddress("127.0.0.1"),
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
                    ipv4Address: try CIDRv4("192.168.64.20/24"),
                    ipv4Gateway: try IPv4Address("192.168.64.1"),
                    ipv6Address: nil,
                    macAddress: nil
                ),
            ]
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
            exitCode: 17,
            exitedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: try managedContainerJSON([runningSnapshot]), stderr: ""),
            CommandResult(status: 0, stdout: try managedContainerJSON([runningSnapshot, stoppedSnapshot]), stderr: ""),
        ])
        let manager = ContainerCLIJSONDiscoveryManager(
            runner: runner,
            environmentLauncher: "/usr/bin/env",
            containerBinary: "forked-container"
        )

        let running = try await manager.listContainers(all: false)
        let worker = try await manager.getContainer(id: "demo-worker-1")

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
                )
            ),
        ])
        #expect(worker?.id == "demo-worker-1")
        #expect(worker?.status == "stopped")
        #expect(worker?.exitCode == 17)
        #expect(worker?.exitedDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(worker?.health == nil)
        #expect(runner.commands.map(\.arguments) == [
            ["forked-container", "list", "--format", "json"],
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
            guard case .invalidProject(let message) = error else {
                Issue.record("Unexpected compose error: \(error)")
                return
            }
            #expect(message.contains("failed to decode container list JSON"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("live discovery manager uses CLI list and direct detail")
    func liveDiscoveryManagerUsesCLIListAndDirectDetail() async throws {
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

    @Test("log manager passes tail to direct API for static logs")
    func logManagerPassesTailToDirectAPIForStaticLogs() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerLogAPIClient(fileHandles: [
            try temporaryLogFileHandle(contents: "one\ntwo\nthree\n"),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(id: "demo-api-1", tail: 2, follow: false, emit: { emitted.append($0) })

        #expect(emitted.messages == ["one\ntwo\nthree"])
        #expect(await client.requests == ["demo-api-1"])
        #expect(await client.options == [
            ContainerLogOptions(tail: 2)
        ])
        #expect(await client.replayOptions == [
            ContainerLogReplayOptions(includeRotated: true)
        ])
    }

    @Test("log manager applies static time filters through structured records")
    func logManagerAppliesStaticTimeFiltersThroughStructuredRecords() async throws {
        let emitted = MessageRecorder()
        let since = Date(timeIntervalSince1970: 100)
        let until = Date(timeIntervalSince1970: 200)
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: since.addingTimeInterval(-1), stream: .stdout, data: Data("old\n".utf8)),
            ContainerLogRecord(timestamp: since, stream: .stdout, data: Data("inside".utf8)),
            ContainerLogRecord(timestamp: until, stream: .stdout, data: Data("-line\n".utf8)),
            ContainerLogRecord(timestamp: until.addingTimeInterval(1), stream: .stdout, data: Data("new\n".utf8)),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: 5,
            follow: false,
            since: since,
            until: until,
            timestamps: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == ["inside-line"])
        #expect(await client.recordRequests == ["demo-api-1"])
        #expect(await client.recordOptions == [
            ContainerLogOptions(tail: 5, since: since, until: until)
        ])
        #expect(await client.recordReplayOptions == [
            ContainerLogReplayOptions(includeRotated: true)
        ])
        #expect(await client.requests.isEmpty)
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

    @Test("log manager preserves blank lines from direct API logs")
    func logManagerPreservesBlankLinesFromDirectAPILogs() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerLogAPIClient(fileHandles: [
            try temporaryLogFileHandle(contents: "one\n\ntwo\n"),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { emitted.append($0) })

        #expect(emitted.messages == ["one\n\ntwo"])
        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager preserves Compose line boundary fixtures")
    func logManagerPreservesComposeLineBoundaryFixtures() async throws {
        struct Fixture {
            var name: String
            var input: Data
            var expectedMessages: [String]
        }

        let fixtures = [
            Fixture(name: "empty file emits nothing", input: Data(), expectedMessages: []),
            Fixture(name: "single blank line", input: Data("\n".utf8), expectedMessages: [""]),
            Fixture(name: "two blank lines", input: Data("\n\n".utf8), expectedMessages: ["\n"]),
            Fixture(name: "final newline is not an extra record", input: Data("one\n".utf8), expectedMessages: ["one"]),
            Fixture(name: "blank record before final newline", input: Data("one\n\n".utf8), expectedMessages: ["one\n"]),
            Fixture(name: "unterminated final record", input: Data("one\n\npartial".utf8), expectedMessages: ["one\n\npartial"]),
            Fixture(name: "CRLF and CR separators", input: Data("one\r\ntwo\rthree\n".utf8), expectedMessages: ["one\ntwo\nthree"]),
        ]

        for fixture in fixtures {
            let emitted = MessageRecorder()
            let client = RecordingContainerLogAPIClient(fileHandles: [
                try temporaryLogFileHandle(data: fixture.input),
            ])
            let manager = ContainerClientLogManager(client: client)

            try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { emitted.append($0) })

            #expect(emitted.messages == fixture.expectedMessages, "Fixture failed: \(fixture.name)")
            #expect(await client.requests == ["demo-api-1"], "Fixture did not request logs: \(fixture.name)")
        }
    }

    @Test("log manager renders timestamped records from direct API")
    func logManagerRendersTimestampedRecordsFromDirectAPI() async throws {
        let emitted = MessageRecorder()
        let firstTimestamp = date("2026-06-18T10:00:00.123Z")
        let secondTimestamp = date("2026-06-18T10:00:01.456Z")
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: firstTimestamp, stream: .stdout, data: Data("one\npa".utf8)),
            ContainerLogRecord(timestamp: secondTimestamp, stream: .stderr, data: Data("rt\n\n".utf8)),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: false,
            since: nil,
            until: nil,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            "2026-06-18T10:00:00.123Z one\n2026-06-18T10:00:00.123Z part\n2026-06-18T10:00:01.456Z "
        ])
        #expect(await client.recordRequests == ["demo-api-1"])
        #expect(await client.recordOptions == [
            ContainerLogOptions()
        ])
        #expect(await client.recordReplayOptions == [
            ContainerLogReplayOptions(includeRotated: true)
        ])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager applies static timestamped tail through direct API")
    func logManagerAppliesStaticTimestampedTailThroughDirectAPI() async throws {
        let emitted = MessageRecorder()
        let timestamp = date("2026-06-18T10:00:00Z")
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("one\n".utf8)),
            ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("two\n".utf8)),
            ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("three\n".utf8)),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: 2,
            follow: false,
            since: nil,
            until: nil,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            "2026-06-18T10:00:00.000Z two\n2026-06-18T10:00:00.000Z three"
        ])
        #expect(await client.recordOptions == [
            ContainerLogOptions(tail: 2)
        ])
        #expect(await client.recordReplayOptions == [
            ContainerLogReplayOptions(includeRotated: true)
        ])
    }

    @Test("log manager filters static timestamped records through direct API")
    func logManagerFiltersStaticTimestampedRecordsThroughDirectAPI() async throws {
        let emitted = MessageRecorder()
        let before = date("2026-06-18T10:00:00Z")
        let since = date("2026-06-18T10:00:01Z")
        let until = date("2026-06-18T10:00:02Z")
        let after = date("2026-06-18T10:00:03Z")
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: before, stream: .stdout, data: Data("old\n".utf8)),
            ContainerLogRecord(timestamp: since, stream: .stdout, data: Data("inside\n".utf8)),
            ContainerLogRecord(timestamp: until, stream: .stdout, data: Data("closing\n".utf8)),
            ContainerLogRecord(timestamp: after, stream: .stdout, data: Data("new\n".utf8)),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: false,
            since: since,
            until: until,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            "2026-06-18T10:00:01.000Z inside\n2026-06-18T10:00:02.000Z closing"
        ])
        #expect(await client.recordOptions == [
            ContainerLogOptions(since: since, until: until)
        ])
        #expect(await client.recordReplayOptions == [
            ContainerLogReplayOptions(includeRotated: true)
        ])
    }

    @Test("log manager preserves non-UTF-8 bytes from timestamped records")
    func logManagerPreservesNonUTF8BytesFromTimestampedRecords() async throws {
        let emitted = DataRecorder()
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: date("2026-06-18T10:00:00Z"), stream: .stdout, data: Data([0xFF, 0xFE, 0x0A, 0x41])),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: false,
            since: nil,
            until: nil,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.data == [Data("2026-06-18T10:00:00.000Z ".utf8) + Data([0xFF, 0xFE, 0x0A]) + Data("2026-06-18T10:00:00.000Z A".utf8)])
        #expect(await client.recordRequests == ["demo-api-1"])
    }

    @Test("log manager rejects missing direct API log handles")
    func logManagerRejectsMissingDirectAPILogHandles() async throws {
        let client = RecordingContainerLogAPIClient()
        let manager = ContainerClientLogManager(client: client)

        do {
            try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { (_: Data) in })
            Issue.record("Expected missing log handle error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container logs returned no stdio handle for demo-api-1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager preserves non-UTF-8 bytes from direct API logs")
    func logManagerPreservesNonUTF8BytesFromDirectAPILogs() async throws {
        let emitted = DataRecorder()
        let client = RecordingContainerLogAPIClient(fileHandles: [
            try temporaryLogFileHandle(data: Data([0xFF, 0xFE, 0x0A, 0x41])),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { emitted.append($0) })

        #expect(emitted.data == [Data([0xFF, 0xFE, 0x0A, 0x41])])
        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager follows appended direct API log stream")
    func logManagerFollowsAppendedDirectAPILogStream() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("live\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["live"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["live"])
        #expect(await client.followRequests == ["demo-api-1"])
        #expect(await client.followOptions == [ContainerLogOptions(tail: 0)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager follows blank and split direct API log stream")
    func logManagerFollowsBlankAndSplitDirectAPILogStream() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("one\n\npa".utf8),
            Data("rt\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["one", "", "part"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["one", "", "part"])
        #expect(await client.followRequests == ["demo-api-1"])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager completes initial followed direct API stream partial line")
    func logManagerCompletesInitialFollowedDirectAPIStreamPartialLine() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("pa".utf8),
            Data("rt\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: nil, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["part"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["part"])
        #expect(await client.followOptions == [ContainerLogOptions()])
    }

    @Test("log manager passes tail zero to followed direct API stream")
    func logManagerPassesTailZeroToFollowedDirectAPIStream() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("new\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["new"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["new"])
        #expect(await client.followOptions == [ContainerLogOptions(tail: 0)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager flushes initial followed direct API stream partial line after stop")
    func logManagerFlushesInitialFollowedDirectAPIStreamPartialLineAfterStop() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("partial".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider(responses: [true, false])
        )

        try await manager.logs(id: "demo-api-1", tail: nil, follow: true, emit: { emitted.append($0) })

        #expect(emitted.messages == ["partial"])
        #expect(await client.followRequests == ["demo-api-1"])
    }

    @Test("log manager emits runtime-followed rotated direct API stream")
    func logManagerEmitsRuntimeFollowedRotatedDirectAPIStream() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("new\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["new"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["new"])
        #expect(await client.followOptions == [ContainerLogOptions(tail: 0)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager keeps followed direct API stream partial line pending while live")
    func logManagerKeepsFollowedDirectAPIStreamPartialLinePendingWhileLive() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("partial".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await Task.sleep(for: .milliseconds(300))
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages.isEmpty)
        #expect(await client.followRequests == ["demo-api-1"])
    }

    @Test("log manager flushes followed direct API stream partial line after stop")
    func logManagerFlushesFollowedDirectAPIStreamPartialLineAfterStop() async throws {
        let emitted = MessageRecorder()
        let stateProvider = RecordingContainerLogFollowStateProvider(responses: [true, false])
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("partial".utf8),
        ])
        let manager = ContainerClientLogManager(client: client, followStateProvider: stateProvider)

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["partial"], in: emitted)
        try await followTask.value

        #expect(emitted.messages == ["partial"])
        #expect(await stateProvider.requests == ["demo-api-1", "demo-api-1"])
        #expect(await client.followRequests == ["demo-api-1"])
    }

    @Test("log manager preserves non-UTF-8 bytes while following direct API stream")
    func logManagerPreservesNonUTF8BytesWhileFollowingDirectAPIStream() async throws {
        let emitted = DataRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data([0xFF, 0xFE, 0x0A, 0x41, 0x0A]),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForData([Data([0xFF, 0xFE]), Data([0x41])], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.data == [Data([0xFF, 0xFE]), Data([0x41])])
        #expect(await client.followRequests == ["demo-api-1"])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager follows timestamped structured record stream")
    func logManagerFollowsTimestampedStructuredRecordStream() async throws {
        let emitted = MessageRecorder()
        let firstTimestamp = date("2026-06-18T10:00:00.123Z")
        let secondTimestamp = date("2026-06-18T10:00:01.456Z")
        let client = RotatingContainerLogAPIClient(recordSnapshots: [
            [],
            [
                ContainerLogRecord(timestamp: firstTimestamp, stream: .stdout, data: Data("one\npa".utf8)),
                ContainerLogRecord(timestamp: secondTimestamp, stream: .stderr, data: Data("rt\n".utf8)),
            ],
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: nil,
                until: nil,
                timestamps: true,
                emit: { emitted.append($0) }
            )
        }
        try await waitForMessages([
            "2026-06-18T10:00:00.123Z one",
            "2026-06-18T10:00:00.123Z part",
        ], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == [
            "2026-06-18T10:00:00.123Z one",
            "2026-06-18T10:00:00.123Z part",
        ])
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.recordOptions.isEmpty)
        #expect(await client.recordReplayOptions.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager follows runtime structured record stream")
    func logManagerFollowsRuntimeStructuredRecordStream() async throws {
        let emitted = MessageRecorder()
        let first = ContainerLogRecord(timestamp: date("2026-06-18T10:00:00Z"), stream: .stdout, data: Data("one\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-06-18T10:00:01Z"), stream: .stdout, data: Data("two\n".utf8))
        let third = ContainerLogRecord(timestamp: date("2026-06-18T10:00:02Z"), stream: .stdout, data: Data("three\n".utf8))
        let client = RotatingContainerLogAPIClient(recordSnapshots: [
            [first, second],
            [second, third],
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: nil,
                until: nil,
                timestamps: true,
                emit: { emitted.append($0) }
            )
        }
        try await waitForMessages(["2026-06-18T10:00:02.000Z three"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["2026-06-18T10:00:02.000Z three"])
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0)])
    }

    @Test("log manager filters followed structured records")
    func logManagerFiltersFollowedStructuredRecords() async throws {
        let emitted = MessageRecorder()
        let base = date("2100-01-01T00:00:00Z")
        let since = date("2100-01-01T00:00:01Z")
        let until = date("2100-01-01T00:00:02Z")
        let client = RotatingContainerLogAPIClient(recordSnapshots: [
            [],
            [
                ContainerLogRecord(timestamp: base, stream: .stdout, data: Data("old\n".utf8)),
                ContainerLogRecord(timestamp: since, stream: .stdout, data: Data("inside\n".utf8)),
                ContainerLogRecord(timestamp: until.addingTimeInterval(1), stream: .stdout, data: Data("new\n".utf8)),
            ],
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: since,
                until: until,
                timestamps: false,
                emit: { emitted.append($0) }
            )
        }
        try await waitForMessages(["inside"], in: emitted)
        try await followTask.value

        #expect(emitted.messages == ["inside"])
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.recordOptions.isEmpty)
        #expect(await client.recordReplayOptions.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [
            ContainerLogOptions(tail: 0, since: since, until: until)
        ])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager skips structured follow when until already elapsed")
    func logManagerSkipsStructuredFollowWhenUntilAlreadyElapsed() async throws {
        let emitted = MessageRecorder()
        let until = Date().addingTimeInterval(-1)
        let records = [
            ContainerLogRecord(timestamp: until.addingTimeInterval(-1), stream: .stdout, data: Data("snapshot\n".utf8)),
        ]
        let client = RotatingContainerLogAPIClient(recordSnapshots: [records])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: true,
            since: nil,
            until: until,
            timestamps: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == ["snapshot"])
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.recordOptions.isEmpty)
        #expect(await client.recordReplayOptions.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(until: until)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager flushes structured partial line when until already elapsed")
    func logManagerFlushesStructuredPartialLineWhenUntilAlreadyElapsed() async throws {
        let emitted = MessageRecorder()
        let until = Date().addingTimeInterval(-1)
        let records = [
            ContainerLogRecord(timestamp: until.addingTimeInterval(-1), stream: .stdout, data: Data("snapshot".utf8)),
        ]
        let client = RotatingContainerLogAPIClient(recordSnapshots: [records])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: true,
            since: nil,
            until: until,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages.count == 1)
        #expect(emitted.messages[0].hasSuffix(" snapshot"))
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.recordOptions.isEmpty)
        #expect(await client.recordReplayOptions.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(until: until)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager keeps followed structured partial line pending while live")
    func logManagerKeepsFollowedStructuredPartialLinePendingWhileLive() async throws {
        let emitted = MessageRecorder()
        let timestamp = date("2026-06-18T10:00:00.123Z")
        let client = RotatingContainerLogAPIClient(
            recordSnapshots: [
                [],
                [
                    ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("partial".utf8)),
                ],
            ],
            closeFollowRecordStream: false
        )
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: nil,
                until: nil,
                timestamps: true,
                emit: { emitted.append($0) }
            )
        }
        try await Task.sleep(for: .milliseconds(300))
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0)])
    }

    @Test("log manager flushes followed structured partial line when runtime stream ends")
    func logManagerFlushesFollowedStructuredPartialLineWhenRuntimeStreamEnds() async throws {
        let emitted = MessageRecorder()
        let timestamp = date("2026-06-18T10:00:00.123Z")
        let client = RotatingContainerLogAPIClient(recordSnapshots: [
            [],
            [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("partial".utf8)),
            ],
        ])
        let manager = ContainerClientLogManager(client: client)

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: nil,
                until: nil,
                timestamps: true,
                emit: { emitted.append($0) }
            )
        }
        try await waitForMessages(["2026-06-18T10:00:00.123Z partial"], in: emitted)
        try await followTask.value

        #expect(emitted.messages == ["2026-06-18T10:00:00.123Z partial"])
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0)])
    }

    @Test("log manager delegates quiet structured follow deadline to runtime")
    func logManagerDelegatesQuietStructuredFollowDeadlineToRuntime() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(recordSnapshots: [[]])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )
        let until = Date().addingTimeInterval(1)

        try await manager.logs(
            id: "demo-api-1",
            tail: 0,
            follow: true,
            since: nil,
            until: until,
            timestamps: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages.isEmpty)
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0, until: until)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log API client forwards configured operation")
    func logAPIClientForwardsConfiguredOperation() async throws {
        let fileHandle = try temporaryLogFileHandle(contents: "hello\n")
        let recorder = RecordingContainerLogAPIClient(fileHandles: [fileHandle])
        let options = ContainerLogOptions(tail: 1)
        let replay = ContainerLogReplayOptions(includeRotated: true)
        let client = ContainerLogAPIClient { id, options, replay in
            try await recorder.logFileHandles(id: id, options: options, replay: replay)
        }

        let handles = try await client.logFileHandles(id: "demo-api-1", options: options, replay: replay)

        #expect(handles.count == 1)
        #expect(await recorder.requests == ["demo-api-1"])
        #expect(await recorder.options == [options])
        #expect(await recorder.replayOptions == [replay])
    }

    @Test("log API client forwards configured record operation")
    func logAPIClientForwardsConfiguredRecordOperation() async throws {
        let records = [
            ContainerLogRecord(timestamp: date("2026-06-18T10:00:00Z"), stream: .stdout, data: Data("hello\n".utf8)),
        ]
        let recorder = RecordingContainerLogAPIClient(records: records)
        let options = ContainerLogOptions(tail: 1)
        let replay = ContainerLogReplayOptions(includeRotated: true)
        let client = ContainerLogAPIClient(
            logs: { id, options, replay in
                try await recorder.logFileHandles(id: id, options: options, replay: replay)
            },
            logRecords: { id, options, replay in
                try await recorder.logRecords(id: id, options: options, replay: replay)
            }
        )

        let response = try await client.logRecords(id: "demo-api-1", options: options, replay: replay)

        #expect(response == records)
        #expect(await recorder.recordRequests == ["demo-api-1"])
        #expect(await recorder.recordOptions == [options])
        #expect(await recorder.recordReplayOptions == [replay])
    }

    @Test("log API client forwards configured follow operation")
    func logAPIClientForwardsConfiguredFollowOperation() async throws {
        let fileHandle = try temporaryLogFileHandle(contents: "hello\n")
        let recorder = RecordingContainerLogAPIClient(fileHandles: [fileHandle])
        let options = ContainerLogOptions(tail: 1)
        let client = ContainerLogAPIClient(followLogs: { id, options in
            try await recorder.followLogs(id: id, options: options)
        })

        let handle = try await client.followLogs(id: "demo-api-1", options: options)
        defer {
            try? handle.close()
        }

        #expect(try handle.readToEnd() == Data("hello\n".utf8))
        #expect(await recorder.followRequests == ["demo-api-1"])
        #expect(await recorder.followOptions == [options])
    }

    @Test("log API client forwards configured structured follow operation")
    func logAPIClientForwardsConfiguredStructuredFollowOperation() async throws {
        let records = [
            ContainerLogRecord(timestamp: date("2026-06-18T10:00:00Z"), stream: .stdout, data: Data("hello\n".utf8)),
        ]
        let recorder = RecordingContainerLogAPIClient(records: records)
        let options = ContainerLogOptions(tail: 1)
        let client = ContainerLogAPIClient(followLogRecords: { id, options in
            try await recorder.followLogRecords(id: id, options: options)
        })

        let handle = try await client.followLogRecords(id: "demo-api-1", options: options)
        defer {
            try? handle.close()
        }

        let data = try #require(try handle.readToEnd())

        #expect(try logRecords(from: data) == records)
        #expect(await recorder.followRecordRequests == ["demo-api-1"])
        #expect(await recorder.followRecordOptions == [options])
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

        try await manager.stats(ids: ["demo-api-1", "demo-db-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { emitted.append($0) })

        #expect(emitted.messages.count == 1)
        #expect(emitted.messages[0].contains("CONTAINER ID"))
        #expect(emitted.messages[0].contains("MEM %"))
        #expect(emitted.messages[0].contains("demo-api-1"))
        #expect(emitted.messages[0].contains("25.00%"))
        #expect(emitted.messages[0].contains("1MiB / 2MiB"))
        #expect(emitted.messages[0].contains("50.00%"))
        #expect(emitted.messages[0].contains("1.024kB / 2.048kB"))
        #expect(emitted.messages[0].contains("4.096kB / 8.192kB"))
        #expect(!emitted.messages[0].contains("demo-db-1"))
        #expect(await client.listRequests == [["demo-api-1", "demo-db-1"]])
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats manager renders template output from direct API stats")
    func statsManagerRendersTemplateOutputFromDirectAPIStats() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
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

        try await manager.stats(
            ids: ["demo-api-1"],
            format: #"table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"#,
            noStream: true,
            noTrunc: false,
            includeStopped: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages.count == 1)
        #expect(emitted.messages[0].contains("CONTAINER"))
        #expect(emitted.messages[0].contains("CPUPERC"))
        #expect(emitted.messages[0].contains("MEMUSAGE"))
        #expect(emitted.messages[0].contains("MEMPERC"))
        #expect(emitted.messages[0].contains("demo-api-1"))
        #expect(emitted.messages[0].contains("25.00%"))
        #expect(emitted.messages[0].contains("1MiB / 2MiB"))
        #expect(emitted.messages[0].contains("50.00%"))
    }

    @Test("stats manager honors no trunc table output")
    func statsManagerHonorsNoTruncTableOutput() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1-very-long-id", status: "running")],
            statsResponses: [
                "demo-api-1-very-long-id": [
                    containerStats(id: "demo-api-1-very-long-id", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1-very-long-id", cpuUsageUsec: 1_500_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(client: client, sampleInterval: .microseconds(1), sleep: { _ in })

        try await manager.stats(
            ids: ["demo-api-1-very-long-id"],
            format: "table",
            noStream: true,
            noTrunc: false,
            includeStopped: false,
            emit: { emitted.append($0) }
        )
        try await manager.stats(
            ids: ["demo-api-1-very-long-id"],
            format: "table",
            noStream: true,
            noTrunc: true,
            includeStopped: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages.count == 2)
        #expect(emitted.messages[0].contains("demo-api-1-v"))
        #expect(!emitted.messages[0].contains("demo-api-1-very-long-id"))
        #expect(emitted.messages[1].contains("demo-api-1-very-long-id"))
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

        try await manager.stats(ids: ["demo-api-1", "demo-db-1"], format: "table", noStream: true, noTrunc: false, includeStopped: true, emit: { emitted.append($0) })

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
            try await manager.stats(ids: ["demo-api-1"], format: " TABLE ", noStream: false, noTrunc: false, includeStopped: false, emit: { emitted.append($0) })
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
            #expect(messages[1].contains("\u{001B}[H\u{001B}[JCONTAINER ID"))
            #expect(!messages[1].contains("demo-api-1"))
            #expect(messages[2].contains("\u{001B}[H\u{001B}[JCONTAINER ID"))
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

        try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { emitted.append($0) })

        #expect(emitted.messages[0].contains("--"))
        #expect(emitted.messages[0].contains("1GiB / --"))
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
                    containerStats(
                        id: "demo-api-1",
                        cpuUsageUsec: 1_500_000,
                        memoryUsageBytes: 2_097_152,
                        networkRxBytes: 1_100,
                        networkTxBytes: 126,
                        blockReadBytes: 0,
                        blockWriteBytes: 0
                    ),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(client: client, sampleInterval: .microseconds(1), sleep: { _ in })

        try await manager.stats(ids: ["demo-api-1"], format: "json", noStream: false, noTrunc: false, includeStopped: false, emit: { emitted.append($0) })

        let decoded = try #require(JSONSerialization.jsonObject(with: Data(emitted.messages[0].utf8)) as? [String: String])
        #expect(decoded["Container"] == "demo-api-1")
        #expect(decoded["ID"] == "demo-api-1")
        #expect(decoded["Name"] == "demo-api-1")
        #expect(decoded["CPUPerc"] == "25.00%")
        #expect(decoded["MemUsage"] == "2MiB / 2MiB")
        #expect(decoded["MemPerc"] == "100.00%")
        #expect(decoded["NetIO"] == "1.1kB / 126B")
        #expect(decoded["BlockIO"] == "0B / 0B")
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats manager rejects missing direct API stat targets")
    func statsManagerRejectsMissingDirectAPIStatTargets() async throws {
        let client = RecordingContainerStatsAPIClient()
        let manager = ContainerClientStatsManager(client: client, sleep: { _ in })

        do {
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { _ in })
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
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { _ in })
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
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { _ in })
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

    @Test("top manager renders process identifiers from direct API")
    func topManagerRendersProcessIdentifiersFromDirectAPI() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerTopAPIClient(responses: [
            "demo-api-1": ContainerProcesses(id: "demo-api-1", processIdentifiers: [42, 99]),
            "demo-db-1": ContainerProcesses(id: "demo-db-1", processIdentifiers: [7]),
        ])
        let manager = ContainerClientTopManager(client: client)

        try await manager.top(
            targets: [
                ComposeTopTarget(service: "api", containerID: "demo-api-1"),
                ComposeTopTarget(service: "db", containerID: "demo-db-1"),
            ],
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            "Service  Container ID  PID\napi      demo-api-1    42\napi      demo-api-1    99\ndb       demo-db-1     7",
        ])
        #expect(await client.requests == ["demo-api-1", "demo-db-1"])
    }

    @Test("top API client forwards configured operation")
    func topAPIClientForwardsConfiguredOperation() async throws {
        let recorder = RecordingContainerTopAPIClient(
            responses: ["demo-api-1": ContainerProcesses(id: "demo-api-1", processIdentifiers: [42])]
        )
        let client = ContainerTopAPIClient(processes: { id in try await recorder.processes(id: id) })

        let processes = try await client.processes(id: "demo-api-1")

        #expect(processes == ContainerProcesses(id: "demo-api-1", processIdentifiers: [42]))
        #expect(await recorder.requests == ["demo-api-1"])
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
                workingDirectory: "/app",
                privileged: true
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
                privileged: true,
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
                privileged: true,
                terminal: .init(interactive: true, tty: false)
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
                privileged: true,
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

    @Test("image manager returns image healthchecks through direct API")
    func imageManagerReturnsImageHealthchecksThroughDirectAPI() async throws {
        let healthCheck = ComposeImageHealthCheck(
            test: ["CMD-SHELL", "test -f /ready"],
            intervalInNanoseconds: 5_000_000_000,
            retries: 2
        )
        let client = RecordingContainerImageAPIClient(platformHealthChecks: [
            ImageHealthCheckRequestKey(reference: "example/api", platform: "linux/arm64"): healthCheck,
        ])
        let manager = ContainerClientImageManager(client: client)

        let resolved = try await manager.imageHealthCheck("example/api", platform: "linux/arm64")

        #expect(resolved == healthCheck)
        #expect(await client.requests == [
            .healthCheck(reference: "example/api", platform: "linux/arm64"),
        ])
    }

    @Test("image manager resolves image digests through direct API")
    func imageManagerResolvesImageDigestsThroughDirectAPI() async throws {
        let client = RecordingContainerImageAPIClient(digests: [
            "example/api:latest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ])
        let manager = ContainerClientImageManager(client: client)

        let digest = try await manager.imageDigest("example/api:latest")

        #expect(digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(await client.requests == [.digest("example/api:latest")])
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
            healthCheck: { try await recorder.imageHealthCheck(reference: $0, platform: $1) },
            pull: { try await recorder.pullImage(reference: $0) },
            push: { try await recorder.pushImage(reference: $0) },
            delete: { try await recorder.deleteImage(reference: $0, force: $1) }
        )

        let exists = try await client.imageExists(reference: "example/api:latest")
        let healthCheck = try await client.imageHealthCheck(reference: "example/api:latest", platform: nil)
        try await client.pullImage(reference: "example/api:latest")
        let pushed = try await client.pushImage(reference: "example/api:latest")
        let deleted = try await client.deleteImage(reference: "example/api:latest", force: true)

        #expect(exists == true)
        #expect(healthCheck == nil)
        #expect(pushed == "registry.example.com/example/api:latest")
        #expect(deleted == "example/api:latest")
        #expect(await recorder.requests == [
            .exists("example/api:latest"),
            .healthCheck(reference: "example/api:latest", platform: nil),
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
        let healthCheck = try await client.imageHealthCheck(reference: "example/api:latest", platform: nil)
        try await client.pullImage(reference: "example/api:latest")
        let pushed = try await client.pushImage(reference: "example/api:latest")
        let deleted = try await client.deleteImage(reference: "example/api:latest", force: true)

        #expect(exists == true)
        #expect(healthCheck == nil)
        #expect(pushed == "registry.example.com/example/api:latest")
        #expect(deleted == "example/api:latest")
        #expect(await recorder.requests == [
            .exists("example/api:latest"),
            .healthCheck(reference: "example/api:latest", platform: nil),
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
            .networkExists(id: "demo_default"),
            .deleteNetwork(id: "demo_default"),
            .listVolumes,
            .deleteVolume(name: "demo_cache"),
        ])
    }

    @Test("resource manager skips deleting missing networks")
    func resourceManagerSkipsDeletingMissingNetworks() async throws {
        let client = RecordingContainerResourceAPIClient(existingNetworks: [])
        let manager = ContainerClientResourceManager(client: client)

        try await manager.deleteNetwork(id: "demo_default")

        #expect(await client.requests == [
            .networkExists(id: "demo_default"),
        ])
    }

    @Test("resource manager ignores networks removed after preflight")
    func resourceManagerIgnoresNetworksRemovedAfterPreflight() async throws {
        let client = RecordingContainerResourceAPIClient(
            networkDeleteError: ContainerizationError(
                .notFound,
                message: "network demo_default not found"
            )
        )
        let manager = ContainerClientResourceManager(client: client)

        try await manager.deleteNetwork(id: "demo_default")

        #expect(await client.requests == [
            .networkExists(id: "demo_default"),
            .deleteNetwork(id: "demo_default"),
        ])
    }

    @Test("resource manager skips deleting missing volumes")
    func resourceManagerSkipsDeletingMissingVolumes() async throws {
        let client = RecordingContainerResourceAPIClient(volumes: [])
        let manager = ContainerClientResourceManager(client: client)

        try await manager.deleteVolume(name: "demo_cache")

        #expect(await client.requests == [
            .listVolumes,
        ])
    }

    @Test("resource manager ignores volumes removed after preflight")
    func resourceManagerIgnoresVolumesRemovedAfterPreflight() async throws {
        let client = RecordingContainerResourceAPIClient(
            volumes: [ComposeVolumeSummary(name: "demo_cache", labels: [:])],
            volumeDeleteError: VolumeError.volumeNotFound("demo_cache")
        )
        let manager = ContainerClientResourceManager(client: client)

        try await manager.deleteVolume(name: "demo_cache")

        #expect(await client.requests == [
            .listVolumes,
            .deleteVolume(name: "demo_cache"),
        ])
    }

    @Test("resource manager surfaces volume delete failures")
    func resourceManagerSurfacesVolumeDeleteFailures() async throws {
        let client = RecordingContainerResourceAPIClient(
            volumes: [ComposeVolumeSummary(name: "demo_cache", labels: [:])],
            volumeDeleteError: VolumeError.volumeInUse("demo_cache")
        )
        let manager = ContainerClientResourceManager(client: client)

        do {
            try await manager.deleteVolume(name: "demo_cache")
            Issue.record("Expected volume-in-use failure")
        } catch VolumeError.volumeInUse(let name) {
            #expect(name == "demo_cache")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests == [
            .listVolumes,
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
            networkExists: { id in
                try await recorder.networkExists(id: id)
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
        _ = try await client.networkExists(id: "demo_default")
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
            .networkExists(id: "demo_default"),
            .deleteNetwork(id: "demo_default"),
            .deleteVolume(name: "demo_cache"),
        ])
    }

    @Test("rm supports force and anonymous volume removal")
    func rmSupportsForceAndAnonymousVolumeRemoval() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
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
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-api-1", force: true),
        ])
        let resources = await resourceManager.requests
        #expect(resources.count == 1)
        #expect(resources.first?.name.hasPrefix("demo_anon-") == true)
        #expect(!commands.contains { $0.contains("demo_cache") })
    }

    @Test("rm skips running containers unless stop is requested")
    func rmSkipsRunningContainersUnlessStopIsRequested() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: false, force: true)

        #expect(emitted.messages == ["No stopped containers"])
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("rm ignores containers that disappear during removal")
    func rmIgnoresContainersThatDisappearDuringRemoval() async throws {
        let missing = ContainerizationError(.notFound, message: "container not found")
        let deleteError = ContainerizationError(.internalError, message: "failed to delete container", cause: missing)
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(deleteErrorsByID: [
            "demo-api-1": deleteError,
        ])
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: false, force: true)

        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-api-1", force: true),
        ])
    }

    @Test("rm cancellation avoids stop and delete")
    func rmCancellationAvoidsStopAndDelete() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let prompts = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                runtimeHooks: .init(confirm: { prompt in
                    prompts.append(prompt)
                    return false
                })
            ),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true, force: false)

        #expect(prompts.messages == ["Going to remove demo-api-1\nAre you sure? [yN] "])
        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("rm confirms before stopping containers")
    func rmConfirmsBeforeStoppingContainers() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let prompts = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                runtimeHooks: .init(confirm: { prompt in
                    prompts.append(prompt)
                    return true
                })
            ),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true, force: false)

        #expect(prompts.messages == ["Going to remove demo-api-1\nAre you sure? [yN] "])
        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("rm stop skips stop for already stopped containers")
    func rmStopSkipsStopForAlreadyStoppedContainers() async throws {
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true, force: true)

        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-api-1", force: true),
        ])
    }

    @Test("rm surfaces anonymous volume removal failures")
    func rmSurfacesAnonymousVolumeRemovalFailures() async throws {
        let runner = RecordingRunner()
        let expected = ComposeError.invalidProject("anonymous volume delete failed")
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager(volumeDeleteError: expected)
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
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
        #expect(await discoveryManager.listRequests == [true])
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

        do {
            try await orchestrator.up(project: project, options: ComposeUpOptions {
                $0.waitTimeout = -1
            })
            Issue.record("Expected invalid up wait timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("up --wait-timeout must be between 0 and 2147483647 seconds"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await orchestrator.start(project: project, options: ComposeStartOptions {
                $0.waitTimeout = -1
            })
            Issue.record("Expected invalid start wait timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("start --wait-timeout must be between 0 and 2147483647 seconds"))
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
                terminal: .init(interactive: true, tty: false)
            ),
        ])
    }

    @Test("attached exec emits progress before terminal handoff")
    func attachedExecEmitsProgressBeforeTerminalHandoff() async throws {
        let runner = RecordingRunner()
        let progress = LockedStringRecorder()
        let execManager = RecordingContainerExecManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
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
            command: ["sh"],
            interactive: true,
            tty: true
        )

        #expect(progress.snapshot.joined() == "⠓ Executing api\n")
        #expect(runner.commands.isEmpty)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh"],
                terminal: .init(interactive: true, tty: true)
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
                $0.privileged = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await execManager.requests == [
            ContainerDetachedExecRequest(
                id: "demo-api-1",
                command: ["env"],
                environment: ["FOO=bar", "DEBUG"],
                user: "1000:1000",
                workingDirectory: "/app",
                privileged: true
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
                $0.privileged = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(emitted.messages == ["+ container exec --detach --privileged demo-api-1 sleep 60"])
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
                terminal: .init(interactive: true, tty: true)
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

    @Test("exec maps privileged mode to runtime requests")
    func execMapsPrivilegedModeToRuntimeRequests() async throws {
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
            options: ComposeExecOptions {
                $0.command = ["true"]
                $0.privileged = true
                $0.interactive = false
                $0.tty = false
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["true"],
                privileged: true,
                terminal: .init(interactive: false, tty: false)
            ),
        ])
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.tail = "all"
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
        ])
        #expect(emitted.messages == ["api-1 | hello"])
    }

    @Test("logs no log prefix emits raw output")
    func logsNoLogPrefixEmitsRawOutput() async throws {
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.noLogPrefix = true
                $0.colorPrefixes = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
        ])
        #expect(emitted.messages == ["hello"])
    }

    @Test("logs prefixes every emitted line")
    func logsPrefixesEveryEmittedLine() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["one\ntwo"])
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
        ).logs(project: project, services: ["api"])

        #expect(emitted.messages == ["api-1 | one\napi-1 | two"])
    }

    @Test("logs prefixes Compose line boundary fixtures")
    func logsPrefixesComposeLineBoundaryFixtures() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["one\n\npartial"])
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
        ).logs(project: project, services: ["api"])

        #expect(emitted.messages == ["api-1 | one\napi-1 | \napi-1 | partial"])
    }

    @Test("logs colorizes prefixes when requested")
    func logsColorizesPrefixesWhenRequested() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["hello"])
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.colorPrefixes = true
            }
        )

        #expect(emitted.messages == ["\u{001B}[35mapi-1\u{001B}[0m | hello"])
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.index = 2
            }
        )

        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-2", tail: nil, follow: false),
        ])
        #expect(emitted.messages == ["api-2 | replica-log"])
    }

    @Test("logs targets all existing replicas for selected services by default")
    func logsTargetsAllExistingReplicasForSelectedServicesByDefault() async throws {
        let logManager = RecordingContainerLogManager(outputs: ["log"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-1",
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
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).logs(project: project, services: ["api"])

        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
            ContainerLogRequest(id: "demo-api-2", tail: nil, follow: false),
        ])
    }

    @Test("logs follow starts selected service replicas concurrently")
    func logsFollowStartsSelectedServiceReplicasConcurrently() async throws {
        let logManager = BlockingContainerLogManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
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
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        )
        let followTask = Task {
            try await orchestrator.logs(
                project: project,
                services: ["api"],
                options: ComposeLogsOptions {
                    $0.follow = true
                    $0.tail = "10"
                }
            )
        }

        let startedBothTargets = try await logManager.waitForRequestCount(2)
        await logManager.releaseAll()
        try await followTask.value

        #expect(startedBothTargets)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests.sorted { $0.id < $1.id } == [
            ContainerLogRequest(id: "demo-api-1", tail: 10, follow: true),
            ContainerLogRequest(id: "demo-api-2", tail: 10, follow: true),
        ])
    }

    @Test("logs with no service targets all project service replicas")
    func logsWithNoServiceTargetsAllProjectServiceReplicas() async throws {
        let logManager = RecordingContainerLogManager(outputs: ["log"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-worker-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-1",
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
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).logs(project: project, services: [])

        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
            ContainerLogRequest(id: "demo-api-2", tail: nil, follow: false),
            ContainerLogRequest(id: "demo-worker-1", tail: nil, follow: false),
        ])
    }

    @Test("logs explicit index narrows selected services")
    func logsExplicitIndexNarrowsSelectedServices() async throws {
        let logManager = RecordingContainerLogManager(outputs: ["log"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
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
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.index = 1
            }
        )

        #expect(await discoveryManager.listRequests == [])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
        ])
    }

    @Test("logs passes timestamp filters to log manager")
    func logsPassesTimestampFiltersToLogManager() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let now = date("2026-06-18T12:00:00Z")
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                dryRun: false,
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    currentDate: { now },
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.tail = "10"
                $0.since = "2026-06-18T10:00:00Z"
                $0.until = "30m"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(
                id: "demo-api-1",
                tail: 10,
                follow: false,
                since: date("2026-06-18T10:00:00Z"),
                until: date("2026-06-18T11:30:00Z")
            ),
        ])
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs accepts Unix timestamp filters")
    func logsAcceptsUnixTimestampFilters() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                dryRun: false,
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.since = "1781776800"
                $0.until = "1781782200.25"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(
                id: "demo-api-1",
                tail: nil,
                follow: false,
                since: date("2026-06-18T10:00:00Z"),
                until: date("2026-06-18T11:30:00.250Z")
            ),
        ])
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs accepts Docker timestamp layout filters")
    func logsAcceptsDockerTimestampLayoutFilters() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.since = "2026-06-18T10:00:00.123456789Z"
                $0.until = "2026-06-18T11:30"
            }
        )

        let request = try #require(await logManager.requests.first)
        #expect(request.id == "demo-api-1")
        #expect(request.tail == nil)
        #expect(request.follow == false)
        let expectedSince = date("2026-06-18T10:00:00Z").addingTimeInterval(0.123_456_789)
        let expectedUntil = localDate("2026-06-18T11:30", format: "yyyy-MM-dd'T'HH:mm")
        #expect(abs(try #require(request.since).timeIntervalSince(expectedSince)) < 0.001)
        #expect(abs(try #require(request.until).timeIntervalSince(expectedUntil)) < 0.000_001)
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs accepts date-only timestamp filters")
    func logsAcceptsDateOnlyTimestampFilters() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.since = "2026-06-18"
            }
        )

        let request = try #require(await logManager.requests.first)
        #expect(request.id == "demo-api-1")
        #expect(request.since == date("2026-06-18T00:00:00Z"))
        #expect(request.until == nil)
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs accepts fractional relative duration filters")
    func logsAcceptsFractionalRelativeDurationFilters() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let now = date("2026-06-18T12:00:00Z")
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    currentDate: { now },
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.since = "1.5h"
                $0.until = "250ms"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(
                id: "demo-api-1",
                tail: nil,
                follow: false,
                since: date("2026-06-18T10:30:00Z"),
                until: date("2026-06-18T11:59:59.750Z")
            ),
        ])
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs rejects malformed Unix timestamp filters")
    func logsRejectsMalformedUnixTimestampFilters() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        for value in ["1781776800.", ".25", "1781776800.1234567890"] {
            do {
                try await ComposeOrchestrator(runner: RecordingRunner()).logs(
                    project: project,
                    services: ["api"],
                    options: ComposeLogsOptions {
                        $0.since = value
                    }
                )
                Issue.record("Expected invalid Unix timestamp filter error for \(value)")
            } catch let error as ComposeError {
                #expect(error == .invalidProject("logs time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("logs rejects malformed relative duration filters")
    func logsRejectsMalformedRelativeDurationFilters() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        for value in ["-1s", "1d", "1ms2", "1..5s"] {
            do {
                try await ComposeOrchestrator(runner: RecordingRunner()).logs(
                    project: project,
                    services: ["api"],
                    options: ComposeLogsOptions {
                        $0.since = value
                    }
                )
                Issue.record("Expected invalid relative duration filter error for \(value)")
            } catch let error as ComposeError {
                #expect(error == .invalidProject("logs time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("logs passes timestamps to log manager")
    func logsPassesTimestampsToLogManager() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["timestamped-log"])
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.timestamps = true
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false, timestamps: true),
        ])
        #expect(emitted.messages == ["api-1 | timestamped-log"])
    }

    @Test("logs passes timestamped follow to log manager")
    func logsPassesTimestampedFollowToLogManager() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["timestamped-live"])
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.timestamps = true
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true, timestamps: true),
        ])
        #expect(emitted.messages == ["api-1 | timestamped-live"])
    }

    @Test("logs passes filtered follow to log manager")
    func logsPassesFilteredFollowToLogManager() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-live"])
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.since = "2026-06-18T10:00:00Z"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(
                id: "demo-api-1",
                tail: nil,
                follow: true,
                since: date("2026-06-18T10:00:00Z")
            ),
        ])
        #expect(emitted.messages == ["api-1 | filtered-live"])
    }

    @Test("logs rejects invalid time filters")
    func logsRejectsInvalidTimeFilters() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: RecordingRunner()).logs(
                project: project,
                services: ["api"],
                options: ComposeLogsOptions {
                    $0.since = "soon"
                }
            )
            Issue.record("Expected invalid time filter error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("logs time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("logs dry run emits compose runtime operation")
    func logsDryRunEmitsComposeRuntimeOperation() async throws {
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.tail = "10"
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime logs --follow -n 10 demo-api-1",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("logs dry run emits configured service replicas")
    func logsDryRunEmitsConfiguredServiceReplicas() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.tail = "10"
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime logs --follow -n 10 demo-api-1",
            "+ compose-runtime logs --follow -n 10 demo-api-2",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("logs dry run emits timestamp options")
    func logsDryRunEmitsTimestampOptions() async throws {
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.since = "2026-06-18T10:00:00Z"
                $0.until = "2026-06-18T11:00:00Z"
                $0.timestamps = true
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime logs --follow --since 2026-06-18T10:00:00Z --until 2026-06-18T11:00:00Z --timestamps demo-api-1",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("logs dry run emits indexed compose runtime operation")
    func logsDryRunEmitsIndexedComposeRuntimeOperation() async throws {
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
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.tail = "10"
                $0.index = 2
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime logs --follow -n 10 demo-api-2",
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

    @Test("watch applies initial sync before polling")
    func watchAppliesInitialSyncBeforePolling() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceFile = sourceDirectory.appendingPathComponent("main.swift")
        try "initial".write(to: sourceFile, atomically: true, encoding: .utf8)

        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let sleeper = ThrowingSleeper(throwOnCall: 1)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(
                            path: sourceDirectory.path,
                            action: "sync",
                            target: "/app/src",
                            include: ["*.swift"],
                            initialSync: true
                        ),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            copier: copier
        ).watch(project: project, options: ComposeWatchOptions(services: ["api"], noUp: true, quiet: true))

        #expect(runner.commands.isEmpty)
        let copyRequests = await copier.requests
        #expect(copyRequests.count == 1)
        if case .into(let id, let source, let destination) = copyRequests.first {
            #expect(id == "demo-api-1")
            #expect(source.hasSuffix("/src/main.swift"))
            #expect(destination == "/app/src/main.swift")
        } else {
            Issue.record("Expected initial watch sync copy")
        }
    }

    @Test("watch syncs changed files and runs sync exec hooks")
    func watchSyncsChangedFilesAndRunsSyncExecHooks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceFile = sourceDirectory.appendingPathComponent("main.swift")
        try "before".write(to: sourceFile, atomically: true, encoding: .utf8)

        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let execManager = RecordingContainerExecManager()
        let sleeper = FileMutationSleeper(file: sourceFile, contents: "after")
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
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
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(
                            path: sourceDirectory.path,
                            action: "sync+exec",
                            target: "/app/src",
                            include: ["*.swift"],
                            exec: ComposeDevelopWatchExec(
                                command: ["sh", "-c", "touch /tmp/reloaded"],
                                user: "1000",
                                privileged: true,
                                workingDir: "/app",
                                environment: ["A": "1", "B": nil]
                            )
                        ),
                    ])
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.copier = copier
            $0.discoveryManager = discoveryManager
            $0.execManager = execManager
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            dependencies: dependencies
        ).watch(project: project, options: ComposeWatchOptions(services: ["api"], noUp: true, quiet: true))

        #expect(runner.commands.isEmpty)
        let copyRequests = await copier.requests
        #expect(copyRequests.count == 1)
        if case .into(let id, let source, let destination) = copyRequests.first {
            #expect(id == "demo-api-1")
            #expect(source.hasSuffix("/src/main.swift"))
            #expect(destination == "/app/src/main.swift")
        } else {
            Issue.record("Expected changed file watch sync copy")
        }
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "touch /tmp/reloaded"],
                environment: ["A=1", "B"],
                user: "1000",
                workingDirectory: "/app",
                privileged: true,
                terminal: .init(interactive: false, tty: false)
            ),
        ])
    }

    @Test("watch removes deleted synced files")
    func watchRemovesDeletedSyncedFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceFile = sourceDirectory.appendingPathComponent("main.swift")
        try "before".write(to: sourceFile, atomically: true, encoding: .utf8)

        let execManager = RecordingContainerExecManager()
        let sleeper = FileDeletionSleeper(file: sourceFile)
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
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
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: sourceDirectory.path, action: "sync", target: "/app/src"),
                    ])
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.execManager = execManager
        }

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            dependencies: dependencies
        ).watch(project: project, options: ComposeWatchOptions(services: ["api"], noUp: true, quiet: true))

        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "rm -rf -- /app/src/main.swift"],
                terminal: .init(interactive: false, tty: false)
            ),
        ])
    }

    @Test("watch rebuilds services and prunes images")
    func watchRebuildsServicesAndPrunesImages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFile = directory.appendingPathComponent("Dockerfile")
        try "FROM scratch\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let runner = RecordingRunner()
        let sleeper = FileMutationSleeper(file: sourceFile, contents: "FROM busybox\n")
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api") {
                    $0.build = ComposeBuild(context: directory.path)
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: sourceFile.path, action: "rebuild"),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            discoveryManager: RecordingContainerDiscoveryManager()
        ).watch(project: project, options: ComposeWatchOptions(services: ["api"], noUp: true, quiet: true))

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 3)
        #expect(commands[0].containsSequence(["build", "--tag", "demo_api:latest", "--quiet", directory.path]))
        #expect(commands[1].containsSequence(["run", "--name", "demo-api-1"]))
        #expect(commands[2].containsSequence(["image", "prune"]))
    }

    @Test("watch applies provided initial up options")
    func watchAppliesProvidedInitialUpOptions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFile = directory.appendingPathComponent("Dockerfile")
        try "FROM scratch\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let runner = RecordingRunner()
        let sleeper = ThrowingSleeper(throwOnCall: 1)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api") {
                    $0.build = ComposeBuild(context: directory.path)
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: sourceFile.path, action: "rebuild"),
                    ])
                },
                "db": composeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            discoveryManager: RecordingContainerDiscoveryManager()
        ).watch(
            project: project,
            options: ComposeWatchOptions(
                services: ["api"],
                initialUpOptions: ComposeUpOptions {
                    $0.services = ["api"]
                    $0.noDeps = true
                    $0.build = true
                    $0.quietBuild = true
                    $0.scales = ["api=2"]
                }
            )
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 3)
        #expect(commands[0].containsSequence(["build", "--tag", "demo_api:latest", "--quiet", directory.path]))
        #expect(commands[1].containsSequence(["run", "--name", "demo-api-1", "--detach"]))
        #expect(commands[2].containsSequence(["run", "--name", "demo-api-2", "--detach"]))
        #expect(commands.allSatisfy { !$0.contains("demo-db-1") })
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
            (
                ComposeDevelopWatch(path: "src", action: "sync+exec", target: "/app/src", exec: ComposeDevelopWatchExec()),
                .invalidProject("service 'api' develop.watch action 'sync+exec' requires an exec command")
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

    @Test("attach output-only mode ignores detach keys")
    func attachOutputOnlyModeIgnoresDetachKeys() async throws {
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
                $0.detachKeys = "ctrl-x"
                $0.sigProxy = "false"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true),
        ])
        #expect(emitted.messages == ["attached"])
    }

    @Test("attach output-only mode proxies received signals by default")
    func attachOutputOnlyModeProxiesReceivedSignalsByDefault() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["attached"])
        let signalProxy = RecordingComposeSignalProxy(forwardedSignals: ["SIGINT", "SIGTERM"])
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
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.signalProxy = signalProxy
            }
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
            }
        )

        #expect(await signalProxy.requests == [
            ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"],
        ])
        #expect(await lifecycleManager.requests == [
            .kill(id: "demo-api-1", signal: "SIGINT"),
            .kill(id: "demo-api-1", signal: "SIGTERM"),
        ])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true),
        ])
        #expect(emitted.messages == ["attached"])
    }

    @Test("attach output-only mode skips signal proxy when disabled")
    func attachOutputOnlyModeSkipsSignalProxyWhenDisabled() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["attached"])
        let signalProxy = RecordingComposeSignalProxy(forwardedSignals: ["SIGINT"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            dependencies: orchestratorDependencies {
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.signalProxy = signalProxy
            }
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.sigProxy = "false"
            }
        )

        #expect(await signalProxy.requests.isEmpty)
        #expect(await lifecycleManager.requests.isEmpty)
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true),
        ])
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

    @Test("attach dry run emits compose runtime log follow")
    func attachDryRunEmitsComposeRuntimeLogFollow() async throws {
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
            "+ compose-runtime logs --follow demo-api-1",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("attach dry run emits indexed compose runtime log follow")
    func attachDryRunEmitsIndexedComposeRuntimeLogFollow() async throws {
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
            "+ compose-runtime logs --follow demo-api-2",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("attach reports apple/container runtime gap for interactive options")
    func attachReportsAppleContainerRuntimeGapForInteractiveOptions() async throws {
        let cases: [(options: ComposeAttachOptions, error: ComposeError)] = [
            (
                ComposeAttachOptions(),
                .unsupported("attach: apple/container does not expose stdin/stdout/stderr reattach for already-running service containers; use --no-stdin for output-only logs")
            ),
            (
                ComposeAttachOptions {
                    $0.sigProxy = "false"
                    $0.detachKeys = "ctrl-x"
                },
                .unsupported("attach --detach-keys: apple/container does not expose detach-key handling for interactive attach")
            ),
            (
                ComposeAttachOptions {
                    $0.sigProxy = "false"
                },
                .unsupported("attach: apple/container does not expose stdin/stdout/stderr reattach for already-running service containers; use --no-stdin for output-only logs")
            ),
            (
                ComposeAttachOptions {
                    $0.noStdin = true
                    $0.sigProxy = "maybe"
                },
                .invalidProject("attach --sig-proxy must be true or false")
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
            try await ComposeOrchestrator(runner: runner).logs(
                project: project,
                services: ["api"],
                options: ComposeLogsOptions {
                    $0.tail = "latest"
                }
            )
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
        try await orchestrator.copy(project: project, arguments: ["./local:file.txt", "db:/restore/local.txt"])
        try await orchestrator.copy(project: project, arguments: ["api:etc/os-release", "./os-release"])
        try await orchestrator.copy(project: project, arguments: ["./seed.sql", "db:tmp/seed.sql"])
        try await orchestrator.copy(project: project, arguments: ["api:.", "db:tmp/root-copy"])

        #expect(runner.commands.isEmpty)
        #expect(await copier.requests == [
            .from(id: "demo-api-1", source: "/tmp/report.txt", destination: "./report.txt"),
            .into(id: "custom-db", source: "./seed.sql", destination: "/docker-entrypoint-initdb.d/seed.sql"),
            .between(sourceID: "demo-api-1", source: "/tmp/report.txt", destinationID: "custom-db", destination: "/restore/report.txt"),
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

    @Test("cp rejects stdio tar streaming operands")
    func cpRejectsStdioTarStreamingOperands() async throws {
        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )
        let orchestrator = ComposeOrchestrator(runner: runner, copier: copier)

        for arguments in [["-", "api:/tmp"], ["api:/tmp/report.txt", "-"]] {
            do {
                try await orchestrator.copy(project: project, arguments: arguments)
                Issue.record("Expected stdio tar stream cp to fail")
            } catch let error as ComposeError {
                #expect(error == .unsupported("cp '-': tar archive streaming requires an apple/container copy stream API"))
            }
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
            .between(sourceID: "demo-api-1", source: "/tmp/report-link", destinationID: "demo-db-1", destination: "/tmp/report.txt"),
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
            .between(sourceID: "demo-api-1", source: "/tmp/report.txt", destinationID: "demo-db-1", destination: "/tmp/report.txt"),
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

    @Test("container copier stages service-to-service copies on the host")
    func containerCopierStagesServiceToServiceCopiesOnTheHost() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination, options in
                try await operations.copyInto(id: id, source: source, destination: destination, options: options)
            },
            copyFrom: { id, source, destination, options in
                try await operations.copyFrom(id: id, source: source, destination: destination, options: options)
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

    @Test("container copier follows source link only when staging service-to-service copies")
    func containerCopierFollowsSourceLinkOnlyWhenStagingServiceToServiceCopies() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination, options in
                try await operations.copyInto(id: id, source: source, destination: destination, options: options)
            },
            copyFrom: { id, source, destination, options in
                try await operations.copyFrom(id: id, source: source, destination: destination, options: options)
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

    @Test("container copier requests ownership preservation when staging service-to-service copies")
    func containerCopierRequestsOwnershipPreservationWhenStagingServiceToServiceCopies() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination, options in
                try await operations.copyInto(id: id, source: source, destination: destination, options: options)
            },
            copyFrom: { id, source, destination, options in
                try await operations.copyFrom(id: id, source: source, destination: destination, options: options)
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

    @Test("container copier rejects root source for service-to-service copies")
    func containerCopierRejectsRootSourceForServiceToServiceCopies() async throws {
        let operations = RecordingContainerCopyOperations()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination, options in
                try await operations.copyInto(id: id, source: source, destination: destination, options: options)
            },
            copyFrom: { id, source, destination, options in
                try await operations.copyFrom(id: id, source: source, destination: destination, options: options)
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
                    $0.hostname = "custom-job"
                    $0.extraHosts = ["db=10.0.0.5"]
                    $0.capAdd = ["NET_ADMIN"]
                    $0.capDrop = ["MKNOD"]
                    $0.privileged = true
                    $0.memLimit = "1024"
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
        #expect(command.contains("--privileged"))
        #expect(command.containsSequence(["--dns", "1.1.1.1"]))
        #expect(command.containsSequence(["--dns-search", "local"]))
        #expect(command.containsSequence(["--dns-option", "use-vc"]))
        #expect(command.containsSequence(["--hostname", "custom-job"]))
        #expect(command.containsSequence(["--add-host", "db:10.0.0.5"]))
        #expect(command.containsSequence(["--memory", "1024"]))
        #expect(command.containsSequence(["--cpus", "2"]))
        #expect(command.containsSequence(["--shm-size", "67108864"]))
        #expect(command.containsSequence(["--ulimit", "nofile=1024:2048"]))
        #expect(command.containsSequence(["--ulimit", "nproc=512"]))
        #expect(command.containsSequence(["--entrypoint", "/bin/sh"]))
        #expect(command.contains("--read-only"))
        #expect(command.contains("--init"))
        #expect(Array(command.suffix(4)) == ["alpine", "-c", "echo", "ok"])
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
        #expect(commands[0].last == "job")
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

    @Test("run rejects missing external links before creating resources")
    func runRejectsMissingExternalLinksBeforeCreatingResources() async throws {
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

        do {
            try await ComposeOrchestrator(
                runner: runner,
                discoveryManager: discoveryManager,
                resourceManager: resourceManager
            ).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected missing external links error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'job' external_links references missing container 'legacy_db'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("run maps external links to generated host entries")
    func runMapsExternalLinksToGeneratedHostEntries() async throws {
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
        #expect(command.containsSequence(["--network", "demo_backend"]))
        #expect(command.containsSequence(["--add-host", "db:192.168.64.20"]))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(await discoveryManager.getRequests.contains("legacy_db"))
    }

    @Test("run maps links to dependency network aliases")
    func runMapsLinksToDependencyNetworkAliases() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
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

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .run(project: project, serviceName: "job", command: ["true"], remove: true)

        let commands = runner.commands.map(\.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-db-1"]))
        #expect(commands[0].containsSequence(["--network", "demo_backend,alias=database"]))
        #expect(commands[1].starts(with: ["container", "run", "--name"]))
        #expect(commands[1].containsSequence(["--network", "demo_backend"]))
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

    @Test("run use-aliases maps network aliases to single network attachment")
    func runUseAliasesMapsNetworkAliasesToSingleNetworkAttachment() async throws {
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
            .run(project: project, serviceName: "job", options: composeRunOptions(command: ["true"]) {
                $0.remove = true
                $0.useAliases = true
            })

        let commands = runner.commands.map(\.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend,alias=job,alias=job.internal"]))
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

    @Test("run rejects start-first deploy updates as an apple/container runtime gap")
    func runRejectsStartFirstDeployUpdatesAsAppleContainerRuntimeGaps() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.unsupportedDeployFields = ["update_config.order.start-first"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected start-first deploy update error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses deploy.update_config.order: start-first; start-first updates need an apple/container container rename or service alias handoff primitive"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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
            #expect(error == .unsupported("service 'job' uses volume.subpath; volume subpath mounts need an apple/container mount primitive gap PR"))
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
                            unsupportedFields: ["consistency", "bind.propagation"]
                        ),
                    ]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported advanced mount option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses unsupported volume fields consistency, bind.propagation; advanced service volume options need an apple/container mount primitive gap PR"))
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
                            tmpfs: .init(size: "67108864", mode: "1777")
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
        let secret = try #require(readOnlyVolumeSource(target: "/run/secrets/runtime-token", in: command))
        #expect(try String(contentsOfFile: secret, encoding: .utf8) == "run-secret")
        #expect(try posixPermissions(at: secret) == 0o444)
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

    @Test("up applies deploy update delay between recreated replicas")
    func upAppliesDeployUpdateDelayBetweenRecreatedReplicas() async throws {
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
                    $0.deployUpdateDelayNanoseconds = 2_000_000_000
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
        #expect(await sleeper.durations == [.nanoseconds(2_000_000_000)])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
            .stop(id: "demo-api-2", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-2", force: false),
        ])
    }

    @Test("up does not apply deploy update delay to new replicas")
    func upDoesNotApplyDeployUpdateDelayToNewReplicas() async throws {
        let sleeper = DurationRecorder()
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
                    $0.deployUpdateDelayNanoseconds = 2_000_000_000
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { try await sleeper.sleep($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
            }
        ).up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.map(\.arguments).count == 2)
        #expect(await sleeper.durations.isEmpty)
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
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
    ]
}

private struct UnsupportedModelFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

private func unsupportedModelFieldCases() -> [UnsupportedModelFieldCase] {
    [
        UnsupportedModelFieldCase(
            composeName: "models",
            reason: "Compose model bindings need a model-runner backend and endpoint injection primitive that is not available through apple/container yet",
            configure: { $0.models = ["llm": ComposeServiceModelBinding(endpointVariable: "MODEL_URL", modelVariable: "MODEL")] }
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

private struct SupportedServiceLoggingFieldCase: Sendable {
    let configure: @Sendable (inout ComposeService) -> Void
}

private struct SupportedServiceLoggingOptionCase: Sendable {
    let configure: @Sendable (inout ComposeService) -> Void
    let expectedOptions: [String]
}

private struct DisabledServiceLoggingFieldCase: Sendable {
    let configure: @Sendable (inout ComposeService) -> Void
}

private func supportedLocalServiceLoggingFieldCases() -> [SupportedServiceLoggingFieldCase] {
    [
        SupportedServiceLoggingFieldCase(
            configure: { $0.logging = .object(["driver": .string("json-file")]) }
        ),
        SupportedServiceLoggingFieldCase(
            configure: { $0.logging = .object(["driver": .string("json-file"), "options": .object([:])]) }
        ),
        SupportedServiceLoggingFieldCase(
            configure: { $0.logging = .object(["driver": .string("local")]) }
        ),
        SupportedServiceLoggingFieldCase(
            configure: { $0.logging = .object(["driver": .string("local"), "options": .object([:])]) }
        ),
        SupportedServiceLoggingFieldCase(
            configure: { $0.logDriver = "json-file" }
        ),
        SupportedServiceLoggingFieldCase(
            configure: { $0.logDriver = "local" }
        ),
    ]
}

private func supportedLocalServiceLoggingOptionCases() -> [SupportedServiceLoggingOptionCase] {
    [
        SupportedServiceLoggingOptionCase(
            configure: {
                $0.logging = .object([
                    "driver": .string("json-file"),
                    "options": .object(["max-size": .string("10m"), "max-file": .string("3")]),
                ])
            },
            expectedOptions: ["max-size=10m", "max-file=3"]
        ),
        SupportedServiceLoggingOptionCase(
            configure: {
                $0.logging = .object([
                    "driver": .string("local"),
                    "options": .object(["max-size": .string("512b")]),
                ])
            },
            expectedOptions: ["max-size=512b"]
        ),
        SupportedServiceLoggingOptionCase(
            configure: {
                $0.logging = .object(["options": .object(["max-file": .string("5")])])
            },
            expectedOptions: ["max-file=5"]
        ),
        SupportedServiceLoggingOptionCase(
            configure: {
                $0.logDriver = "local"
                $0.logOptions = ["max-size": "20m", "max-file": "4"]
            },
            expectedOptions: ["max-size=20m", "max-file=4"]
        ),
        SupportedServiceLoggingOptionCase(
            configure: {
                $0.logOptions = ["max-size": "1g"]
            },
            expectedOptions: ["max-size=1g"]
        ),
    ]
}

private func disabledServiceLoggingFieldCases() -> [DisabledServiceLoggingFieldCase] {
    [
        DisabledServiceLoggingFieldCase(
            configure: { $0.logging = .object(["driver": .string("none")]) }
        ),
        DisabledServiceLoggingFieldCase(
            configure: { $0.logging = .object(["driver": .string("none"), "options": .object([:])]) }
        ),
        DisabledServiceLoggingFieldCase(
            configure: { $0.logDriver = "none" }
        ),
    ]
}

private func unsupportedServiceMetadataAndLoggingFieldCases() -> [UnsupportedServiceMetadataAndLoggingFieldCase] {
    [
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "logging",
            reason: "service logging driver/options need an apple/container runtime gap PR",
            configure: { $0.logging = .object(["driver": .string("syslog")]) }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "logging",
            reason: "service logging driver/options need an apple/container runtime gap PR",
            configure: { $0.logging = .object(["driver": .string("local"), "options": .object(["mode": .string("non-blocking")])]) }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "logging",
            reason: "service logging driver/options need an apple/container runtime gap PR",
            configure: { $0.logging = .object(["driver": .string("none"), "options": .object(["max-size": .string("10m")])]) }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "log_driver",
            reason: "service logging driver/options need an apple/container runtime gap PR",
            configure: { $0.logDriver = "syslog" }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "log_opt",
            reason: "service logging driver/options need an apple/container runtime gap PR",
            configure: { $0.logOptions = ["mode": "non-blocking"] }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "log_opt",
            reason: "service logging driver/options need an apple/container runtime gap PR",
            configure: {
                $0.logDriver = "none"
                $0.logOptions = ["max-size": "10m"]
            }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "storage_opt",
            reason: "per-container storage options need an apple/container rootfs storage runtime gap PR",
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
            reason: "non-local service volume drivers need an apple/container volume driver runtime gap PR",
            configure: { $0.volumeDriver = "nfs" }
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
            image: .init(
                reference: "localhost:5000/example/api:latest",
                digest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                platform: "linux/arm64"
            )
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
            image: .init(
                reference: "other/api:latest",
                digest: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                platform: "linux/arm64"
            )
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
            image: .init(
                reference: "example/worker:debug",
                digest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                platform: "linux/amd64"
            )
        ),
    ]
}

private func discoveredServiceContainer(
    id: String,
    projectName: String = "demo",
    serviceName: String,
    status: String
) -> ComposeContainerSummary {
    ComposeContainerSummary(id: id, status: status, labels: [
        composeProjectLabel: projectName,
        composeServiceLabel: serviceName,
        composeOneOffLabel: "false",
    ])
}

private func pausedDiscoveredContainers() -> [ComposeContainerSummary] {
    discoveredContainers() + [
        ComposeContainerSummary(id: "demo-paused-1", status: "paused", labels: [
            composeProjectLabel: "demo",
            composeServiceLabel: "paused",
        ]),
    ]
}

private func containerSnapshot(
    id: String,
    status: RuntimeStatus,
    labels: [String: String] = [:],
    imageReference: String,
    imageDigest: String,
    platform: String,
    publishedPorts: [PublishPort] = [],
    mounts: [Filesystem] = [],
    networks: [ContainerResource.Attachment] = [],
    exitCode: Int32? = nil,
    exitedDate: Date? = nil,
    health: HealthStatus? = nil
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
    configuration.mounts = mounts
    return ContainerSnapshot(
        configuration: configuration,
        status: status,
        networks: networks,
        exitCode: exitCode,
        exitedDate: exitedDate,
        health: health
    )
}

private func managedContainerJSON(_ snapshots: [ContainerSnapshot]) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshots.map(ManagedContainer.init))
    return String(decoding: data, as: UTF8.self)
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

private final class TemporaryLogFile: @unchecked Sendable {
    private let url: URL
    private let writeHandle: FileHandle
    let readHandle: FileHandle

    init(data: Data = Data()) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        try data.write(to: url)
        readHandle = try FileHandle(forReadingFrom: url)
        writeHandle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) throws {
        try writeHandle.seekToEnd()
        writeHandle.write(data)
    }

    deinit {
        try? readHandle.close()
        try? writeHandle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

private func logRecordData(_ records: [ContainerLogRecord]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = Data()
    for record in records {
        data.append(try encoder.encode(record))
        data.append(UInt8(ascii: "\n"))
    }
    return data
}

private func containerEventData(_ events: [ContainerEvent], trailingNewline: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = Data()
    for event in events {
        data.append(try encoder.encode(event))
        data.append(UInt8(ascii: "\n"))
    }
    if !trailingNewline, data.last == UInt8(ascii: "\n") {
        data.removeLast()
    }
    return data
}

private func logRecords(from data: Data) throws -> [ContainerLogRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data.split(separator: UInt8(ascii: "\n")).map { line in
        try decoder.decode(ContainerLogRecord.self, from: Data(line))
    }
}

private func waitForMessages(_ expected: [String], in recorder: MessageRecorder) async throws {
    for _ in 0..<100 {
        if recorder.messages == expected {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func waitForData(_ expected: [Data], in recorder: DataRecorder) async throws {
    for _ in 0..<100 {
        if recorder.data == expected {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
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
    case pause(id: String)
    case unpause(id: String)
    case wait(id: String)
    case delete(id: String, force: Bool)
}

private struct ContainerLogRequest: Equatable {
    var id: String
    var tail: Int?
    var follow: Bool
    var since: Date? = nil
    var until: Date? = nil
    var timestamps = false
}

private struct ComposeUpMenuConfigurationSnapshot: Equatable {
    var projectName: String
    var watchEnabled: Bool
    var watchAvailable: Bool
    var colorEnabled: Bool
}

private enum ComposeUpMenuTestAction {
    case gracefulStop
    case forceStop
    case toggleWatch
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
    var privileged = false
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
    var privileged = false
    var interactive: Bool
    var tty: Bool
}

private struct ContainerStatsRequest: Equatable {
    var ids: [String]
    var format: String
    var noStream: Bool
    var noTrunc: Bool
    var includeStopped: Bool
}

private struct ContainerTopRequest: Equatable {
    var targets: [ComposeTopTarget]
}

private enum ContainerImageRequest: Equatable {
    case exists(String)
    case digest(String)
    case healthCheck(reference: String, platform: String?)
    case pull(String)
    case pullMissing(String)
    case push(String)
    case delete(reference: String, force: Bool)
}

private struct ImageHealthCheckRequestKey: Hashable {
    var reference: String
    var platform: String?
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
    case networkExists(id: String)
    case deleteNetwork(id: String)
    case createVolume(ComposeVolumeCreateRequest)
    case listVolumes
    case deleteVolume(name: String)
}

private actor RecordingComposeSignalProxy: ComposeSignalProxying {
    private let forwardedSignals: [String]
    private var storage: [[String]] = []

    init(forwardedSignals: [String] = []) {
        self.forwardedSignals = forwardedSignals
    }

    var requests: [[String]] {
        storage
    }

    func withSignalProxy(
        signals: [String],
        handler: @escaping @Sendable (String) async -> Void,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        storage.append(signals)
        for signal in forwardedSignals {
            await handler(signal)
        }
        try await operation()
    }
}

private actor RecordingComposeUpMenuController: ComposeUpMenuControlling {
    private let actions: [ComposeUpMenuTestAction]
    private var storage: [ComposeUpMenuConfigurationSnapshot] = []

    init(actions: [ComposeUpMenuTestAction] = []) {
        self.actions = actions
    }

    var requests: [ComposeUpMenuConfigurationSnapshot] {
        storage
    }

    func runMenuSession(
        configuration: ComposeUpMenuConfiguration,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        storage.append(ComposeUpMenuConfigurationSnapshot(
            projectName: configuration.projectName,
            watchEnabled: configuration.watchEnabled,
            watchAvailable: configuration.watchAvailable,
            colorEnabled: configuration.colorEnabled
        ))
        for action in actions {
            switch action {
            case .gracefulStop:
                try await configuration.actions.gracefulStop()
            case .forceStop:
                try await configuration.actions.forceStop()
            case .toggleWatch:
                _ = try await configuration.actions.toggleWatch(true) { _ in }
            }
        }
        try await operation()
    }
}

private actor RecordingContainerCopier: ContainerCopying {
    private var storage: [ContainerCopyRequest] = []
    private var optionStorage: [ContainerCopyTransferOptions] = []

    var requests: [ContainerCopyRequest] {
        storage
    }

    var options: [ContainerCopyTransferOptions] {
        optionStorage
    }

    func copyIntoContainer(id: String, source: String, destination: String, options: ContainerCopyTransferOptions) async throws {
        storage.append(.into(id: id, source: source, destination: destination))
        optionStorage.append(options)
    }

    func copyFromContainer(id: String, source: String, destination: String, options: ContainerCopyTransferOptions) async throws {
        storage.append(.from(id: id, source: source, destination: destination))
        optionStorage.append(options)
    }

    func copyBetweenContainers(sourceID: String, source: String, destinationID: String, destination: String, options: ContainerCopyTransferOptions) async throws {
        storage.append(.between(sourceID: sourceID, source: source, destinationID: destinationID, destination: destination))
        optionStorage.append(options)
    }
}

private actor RecordingContainerCopyOperations {
    private var storage: [ContainerCopyRequest] = []
    private var optionStorage: [ContainerCopyTransferOptions] = []

    var requests: [ContainerCopyRequest] {
        storage
    }

    var options: [ContainerCopyTransferOptions] {
        optionStorage
    }

    func copyInto(id: String, source: String, destination: String, options: ContainerCopyTransferOptions) async throws {
        guard FileManager.default.fileExists(atPath: source) else {
            throw ComposeError.invalidProject("source path does not exist: \(source)")
        }
        storage.append(.into(id: id, source: source, destination: destination))
        optionStorage.append(options)
    }

    func copyFrom(id: String, source: String, destination: String, options: ContainerCopyTransferOptions) async throws {
        storage.append(.from(id: id, source: source, destination: destination))
        optionStorage.append(options)
        let destinationURL = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("staged".utf8).write(to: destinationURL)
    }
}

private actor RecordingContainerLifecycleManager: ContainerLifecycleManaging {
    private let stopError: (any Error)?
    private let deleteError: (any Error)?
    private let stopErrorsByID: [String: any Error]
    private let deleteErrorsByID: [String: any Error]
    private let waitExitCodes: [String: Int32]
    private let waitDelaysByID: [String: Duration]
    private var storage: [ContainerLifecycleRequest] = []

    init(
        stopError: (any Error)? = nil,
        deleteError: (any Error)? = nil,
        stopErrorsByID: [String: any Error] = [:],
        deleteErrorsByID: [String: any Error] = [:],
        waitExitCodes: [String: Int32] = [:],
        waitDelaysByID: [String: Duration] = [:]
    ) {
        self.stopError = stopError
        self.deleteError = deleteError
        self.stopErrorsByID = stopErrorsByID
        self.deleteErrorsByID = deleteErrorsByID
        self.waitExitCodes = waitExitCodes
        self.waitDelaysByID = waitDelaysByID
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
        if let error = stopErrorsByID[id] {
            throw error
        }
        if let stopError {
            throw stopError
        }
    }

    func pauseContainer(id: String) async throws {
        storage.append(.pause(id: id))
    }

    func unpauseContainer(id: String) async throws {
        storage.append(.unpause(id: id))
    }

    func waitContainer(id: String) async throws -> Int32 {
        storage.append(.wait(id: id))
        if let delay = waitDelaysByID[id] {
            try await Task.sleep(for: delay)
        }
        return waitExitCodes[id] ?? 0
    }

    func deleteContainer(id: String, force: Bool) async throws {
        storage.append(.delete(id: id, force: force))
        if let error = deleteErrorsByID[id] {
            throw error
        }
        if let deleteError {
            throw deleteError
        }
    }
}

private actor RecordingContainerDiscoveryManager: ContainerDiscoveryManaging {
    private let containers: [ComposeContainerSummary]
    private var getResponses: [String: [ComposeContainerSummary?]]
    private var lists: [Bool] = []
    private var gets: [String] = []

    init(
        containers: [ComposeContainerSummary] = [],
        getResponses: [String: [ComposeContainerSummary?]] = [:]
    ) {
        self.containers = containers
        self.getResponses = getResponses
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
        if var responses = getResponses[id], !responses.isEmpty {
            let response = responses.removeFirst()
            getResponses[id] = responses
            return response
        }
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
        since: Date?,
        until: Date?,
        timestamps: Bool,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        storage.append(
            ContainerLogRequest(
                id: id,
                tail: tail,
                follow: follow,
                since: since,
                until: until,
                timestamps: timestamps
            )
        )
        for output in outputs {
            emit(Data(output.utf8))
        }
    }
}

private actor RecordingContainerLogFollowStateProvider: ContainerLogFollowStateProviding {
    private var responses: [Bool]
    private var storage: [String] = []

    init(responses: [Bool] = []) {
        self.responses = responses
    }

    var requests: [String] {
        storage
    }

    func isLiveForLogFollow(id: String) async throws -> Bool {
        storage.append(id)
        guard !responses.isEmpty else {
            return true
        }
        guard responses.count > 1 else {
            return responses[0]
        }
        return responses.removeFirst()
    }
}

private actor BlockingContainerLogManager: ContainerLogManaging {
    private var storage: [ContainerLogRequest] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    var requests: [ContainerLogRequest] {
        storage
    }

    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        storage.append(
            ContainerLogRequest(
                id: id,
                tail: tail,
                follow: follow,
                since: since,
                until: until,
                timestamps: timestamps
            )
        )
        guard follow, !released else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseContinuations.append(continuation)
        }
    }

    func waitForRequestCount(_ count: Int) async throws -> Bool {
        for _ in 0..<100 {
            if storage.count >= count {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return storage.count >= count
    }

    func releaseAll() {
        released = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }
}

private actor RecordingContainerLogAPIClient: ContainerLogAPIClienting {
    private let fileHandles: [FileHandle]
    private let records: [ContainerLogRecord]
    private var storage: [String] = []
    private var optionsStorage: [ContainerLogOptions] = []
    private var replayStorage: [ContainerLogReplayOptions] = []
    private var recordStorage: [String] = []
    private var recordOptionsStorage: [ContainerLogOptions] = []
    private var recordReplayStorage: [ContainerLogReplayOptions] = []
    private var followStorage: [String] = []
    private var followOptionsStorage: [ContainerLogOptions] = []
    private var followRecordStorage: [String] = []
    private var followRecordOptionsStorage: [ContainerLogOptions] = []

    init(fileHandles: [FileHandle] = [], records: [ContainerLogRecord] = []) {
        self.fileHandles = fileHandles
        self.records = records
    }

    var requests: [String] {
        storage
    }

    var options: [ContainerLogOptions] {
        optionsStorage
    }

    var replayOptions: [ContainerLogReplayOptions] {
        replayStorage
    }

    var recordRequests: [String] {
        recordStorage
    }

    var recordOptions: [ContainerLogOptions] {
        recordOptionsStorage
    }

    var recordReplayOptions: [ContainerLogReplayOptions] {
        recordReplayStorage
    }

    var followRequests: [String] {
        followStorage
    }

    var followOptions: [ContainerLogOptions] {
        followOptionsStorage
    }

    var followRecordRequests: [String] {
        followRecordStorage
    }

    var followRecordOptions: [ContainerLogOptions] {
        followRecordOptionsStorage
    }

    func logFileHandles(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> [FileHandle] {
        storage.append(id)
        optionsStorage.append(options)
        replayStorage.append(replay)
        return fileHandles
    }

    func logRecords(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> [ContainerLogRecord] {
        recordStorage.append(id)
        recordOptionsStorage.append(options)
        recordReplayStorage.append(replay)
        return applyLogOptions(to: records, options: options)
    }

    func followLogs(id: String, options: ContainerLogOptions) async throws -> FileHandle {
        followStorage.append(id)
        followOptionsStorage.append(options)
        if let fileHandle = fileHandles.first {
            return fileHandle
        }
        return try temporaryLogFileHandle(data: Data())
    }

    func followLogRecords(id: String, options: ContainerLogOptions) async throws -> FileHandle {
        followRecordStorage.append(id)
        followRecordOptionsStorage.append(options)
        return try temporaryLogFileHandle(data: logRecordData(applyLogOptions(to: records, options: options)))
    }
}

private actor RotatingContainerLogAPIClient: ContainerLogAPIClienting {
    private var logSnapshots: [Data]
    private var recordSnapshots: [[ContainerLogRecord]]
    private let followChunks: [Data]
    private let closeFollowRecordStream: Bool
    private var storage: [String] = []
    private var optionsStorage: [ContainerLogOptions] = []
    private var replayStorage: [ContainerLogReplayOptions] = []
    private var recordStorage: [String] = []
    private var recordOptionsStorage: [ContainerLogOptions] = []
    private var recordReplayStorage: [ContainerLogReplayOptions] = []
    private var followStorage: [String] = []
    private var followOptionsStorage: [ContainerLogOptions] = []
    private var followRecordStorage: [String] = []
    private var followRecordOptionsStorage: [ContainerLogOptions] = []
    private var followWriters: [FileHandle] = []
    private var followRecordWriters: [FileHandle] = []

    init(
        logSnapshots: [Data] = [],
        recordSnapshots: [[ContainerLogRecord]] = [],
        followChunks: [Data] = [],
        closeFollowRecordStream: Bool = true
    ) {
        self.logSnapshots = logSnapshots
        self.recordSnapshots = recordSnapshots
        self.followChunks = followChunks
        self.closeFollowRecordStream = closeFollowRecordStream
    }

    var requests: [String] {
        storage
    }

    var options: [ContainerLogOptions] {
        optionsStorage
    }

    var replayOptions: [ContainerLogReplayOptions] {
        replayStorage
    }

    var recordRequests: [String] {
        recordStorage
    }

    var recordOptions: [ContainerLogOptions] {
        recordOptionsStorage
    }

    var recordReplayOptions: [ContainerLogReplayOptions] {
        recordReplayStorage
    }

    var followRequests: [String] {
        followStorage
    }

    var followOptions: [ContainerLogOptions] {
        followOptionsStorage
    }

    var followRecordRequests: [String] {
        followRecordStorage
    }

    var followRecordOptions: [ContainerLogOptions] {
        followRecordOptionsStorage
    }

    func logFileHandles(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> [FileHandle] {
        storage.append(id)
        optionsStorage.append(options)
        replayStorage.append(replay)
        return [try temporaryLogFileHandle(data: nextLogSnapshot())]
    }

    func logRecords(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> [ContainerLogRecord] {
        recordStorage.append(id)
        recordOptionsStorage.append(options)
        recordReplayStorage.append(replay)
        let snapshot = nextRecordSnapshot()
        return applyLogOptions(to: snapshot, options: options)
    }

    func followLogs(id: String, options: ContainerLogOptions) async throws -> FileHandle {
        followStorage.append(id)
        followOptionsStorage.append(options)
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        followWriters.append(writer)
        let chunks = followChunks
        Task {
            for chunk in chunks {
                try? await Task.sleep(for: .milliseconds(50))
                try? writer.write(contentsOf: chunk)
            }
        }
        return pipe.fileHandleForReading
    }

    func followLogRecords(id: String, options: ContainerLogOptions) async throws -> FileHandle {
        followRecordStorage.append(id)
        followRecordOptionsStorage.append(options)
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        followRecordWriters.append(writer)
        let snapshots = recordSnapshots
        let closeStream = closeFollowRecordStream
        Task {
            var previous: [ContainerLogRecord] = []
            for (index, snapshot) in snapshots.enumerated() {
                try? await Task.sleep(for: .milliseconds(50))
                let records: [ContainerLogRecord]
                if index == 0 {
                    records = applyLogOptions(to: snapshot, options: options)
                    previous = snapshot
                } else {
                    let appended = appendedLogRecords(previous: &previous, current: snapshot)
                    let followOptions = ContainerLogOptions(since: options.since, until: options.until)
                    records = applyLogOptions(to: appended, options: followOptions)
                }
                if !records.isEmpty {
                    try? writer.write(contentsOf: logRecordData(records))
                }
            }
            if closeStream {
                try? writer.close()
            }
        }
        return pipe.fileHandleForReading
    }

    private func nextLogSnapshot() -> Data {
        guard logSnapshots.count > 1 else {
            return logSnapshots.first ?? Data()
        }
        return logSnapshots.removeFirst()
    }

    private func nextRecordSnapshot() -> [ContainerLogRecord] {
        guard recordSnapshots.count > 1 else {
            return recordSnapshots.first ?? []
        }
        return recordSnapshots.removeFirst()
    }
}

private func applyLogOptions(
    to records: [ContainerLogRecord],
    options: ContainerLogOptions
) -> [ContainerLogRecord] {
    var filtered = records.filter { record in
        if let since = options.since, record.timestamp < since {
            return false
        }
        if let until = options.until, record.timestamp > until {
            return false
        }
        return true
    }

    if let tail = options.tail, tail >= 0 {
        if tail == 0 {
            return []
        }
        filtered = Array(filtered.suffix(tail))
    }

    return filtered
}

private func appendedLogRecords(
    previous: inout [ContainerLogRecord],
    current: [ContainerLogRecord]
) -> [ContainerLogRecord] {
    let overlap = logRecordOverlapLength(previous: previous, current: current)
    previous = current
    guard overlap < current.count else {
        return []
    }
    return Array(current.dropFirst(overlap))
}

private func logRecordOverlapLength(previous: [ContainerLogRecord], current: [ContainerLogRecord]) -> Int {
    guard !previous.isEmpty, !current.isEmpty else {
        return 0
    }
    if current.starts(with: previous) {
        return previous.count
    }
    for length in stride(from: min(previous.count, current.count), through: 1, by: -1) {
        if Array(previous.suffix(length)) == Array(current.prefix(length)) {
            return length
        }
    }
    return 0
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
            privileged: configuration.privileged,
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
            privileged: configuration.privileged,
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
        noTrunc: Bool,
        includeStopped: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        storage.append(ContainerStatsRequest(ids: ids, format: format, noStream: noStream, noTrunc: noTrunc, includeStopped: includeStopped))
        for output in outputs {
            emit(output)
        }
    }
}

private actor RecordingContainerTopManager: ContainerTopManaging {
    private let outputs: [String]
    private var storage: [ContainerTopRequest] = []

    init(outputs: [String] = []) {
        self.outputs = outputs
    }

    var requests: [[ComposeTopTarget]] {
        storage.map(\.targets)
    }

    func top(targets: [ComposeTopTarget], emit: @escaping @Sendable (String) -> Void) async throws {
        storage.append(ContainerTopRequest(targets: targets))
        for output in outputs {
            emit(output)
        }
    }
}

private struct ComposeEventsRequest: Equatable {
    var projectName: String
    var services: [String]
    var format: ComposeEventsOutputFormat
    var since: Date? = nil
    var until: Date? = nil
}

private actor RecordingContainerEventsManager: ContainerEventsManaging {
    private let outputs: [String]
    private var storage: [ComposeEventsRequest] = []

    init(outputs: [String] = []) {
        self.outputs = outputs
    }

    var requests: [ComposeEventsRequest] {
        storage
    }

    func events(
        projectName: String,
        services: [String],
        format: ComposeEventsOutputFormat,
        since: Date?,
        until: Date?,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        storage.append(ComposeEventsRequest(
            projectName: projectName,
            services: services,
            format: format,
            since: since,
            until: until
        ))
        for output in outputs {
            emit(output)
        }
    }
}

private actor RecordingContainerEventsAPIClient: ContainerEventsAPIClienting {
    private let data: Data
    private var storage: [ContainerEventOptions] = []

    init(data: Data) {
        self.data = data
    }

    var options: [ContainerEventOptions] {
        storage
    }

    func events(options: ContainerEventOptions) async throws -> FileHandle {
        storage.append(options)
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let data = data
        Task {
            try? writer.write(contentsOf: data)
            try? writer.close()
        }
        return pipe.fileHandleForReading
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

private actor RecordingContainerTopAPIClient: ContainerTopAPIClienting {
    private let responses: [String: ContainerProcesses]
    private let error: (any Error)?
    private var storage: [String] = []

    init(responses: [String: ContainerProcesses] = [:], error: (any Error)? = nil) {
        self.responses = responses
        self.error = error
    }

    var requests: [String] {
        storage
    }

    func processes(id: String) async throws -> ContainerProcesses {
        storage.append(id)
        if let error {
            throw error
        }
        guard let response = responses[id] else {
            throw ComposeError.invalidProject("missing process fixture for \(id)")
        }
        return response
    }
}

private actor RecordingContainerImageManager: ContainerImageManaging {
    private var storage: [ContainerImageRequest] = []
    private var existingReferences: Set<String>
    private var digests: [String: String]
    private var healthChecks: [ImageHealthCheckRequestKey: ComposeImageHealthCheck]
    private let pullFailures: Set<String>
    private let pullMissingFailures: Set<String>
    private let onPullImage: @Sendable (String) async -> Void
    private var pushOutputs: [String: String]
    private let pushFailures: Set<String>
    private var deleteOutputs: [String: String?]
    private let failure: ComposeError?

    init(
        existingReferences: Set<String> = [],
        digests: [String: String] = [:],
        healthChecks: [String: ComposeImageHealthCheck] = [:],
        platformHealthChecks: [ImageHealthCheckRequestKey: ComposeImageHealthCheck] = [:],
        pullFailures: Set<String> = [],
        pullMissingFailures: Set<String> = [],
        onPullImage: @escaping @Sendable (String) async -> Void = { _ in },
        pushOutputs: [String: String] = [:],
        pushFailures: Set<String> = [],
        deleteOutputs: [String: String?] = [:],
        failure: ComposeError? = nil
    ) {
        self.existingReferences = existingReferences
        self.digests = digests
        var mappedHealthChecks = platformHealthChecks
        for (reference, healthCheck) in healthChecks {
            mappedHealthChecks[ImageHealthCheckRequestKey(reference: reference, platform: nil)] = healthCheck
        }
        self.healthChecks = mappedHealthChecks
        self.pullFailures = pullFailures
        self.pullMissingFailures = pullMissingFailures
        self.onPullImage = onPullImage
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

    func imageDigest(_ reference: String) async throws -> String {
        if let failure {
            throw failure
        }
        storage.append(.digest(reference))
        guard let digest = digests[reference] else {
            throw ComposeError.invalidProject("missing digest fixture for \(reference)")
        }
        return digest
    }

    func imageHealthCheck(_ reference: String, platform: String?) async throws -> ComposeImageHealthCheck? {
        if let failure {
            throw failure
        }
        storage.append(.healthCheck(reference: reference, platform: platform))
        return healthChecks[ImageHealthCheckRequestKey(reference: reference, platform: platform)]
    }

    func pullImage(_ reference: String) async throws {
        if let failure {
            throw failure
        }
        await onPullImage(reference)
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
    private var digests: [String: String]
    private var healthChecks: [ImageHealthCheckRequestKey: ComposeImageHealthCheck]
    private var pushOutputs: [String: String]
    private var deleteOutputs: [String: String?]
    private var storage: [ContainerImageRequest] = []

    init(
        existingReferences: Set<String> = [],
        digests: [String: String] = [:],
        healthChecks: [String: ComposeImageHealthCheck] = [:],
        platformHealthChecks: [ImageHealthCheckRequestKey: ComposeImageHealthCheck] = [:],
        pushOutputs: [String: String] = [:],
        deleteOutputs: [String: String?] = [:]
    ) {
        self.existingReferences = existingReferences
        self.digests = digests
        var mappedHealthChecks = platformHealthChecks
        for (reference, healthCheck) in healthChecks {
            mappedHealthChecks[ImageHealthCheckRequestKey(reference: reference, platform: nil)] = healthCheck
        }
        self.healthChecks = mappedHealthChecks
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

    func imageDigest(reference: String) async throws -> String {
        storage.append(.digest(reference))
        guard let digest = digests[reference] else {
            throw ComposeError.invalidProject("missing digest fixture for \(reference)")
        }
        return digest
    }

    func imageHealthCheck(reference: String, platform: String?) async throws -> ComposeImageHealthCheck? {
        storage.append(.healthCheck(reference: reference, platform: platform))
        return healthChecks[ImageHealthCheckRequestKey(reference: reference, platform: platform)]
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

private actor FileMutationSleeper {
    private let file: URL
    private let contents: String
    private var calls = 0

    init(file: URL, contents: String) {
        self.file = file
        self.contents = contents
    }

    func sleep(_: Duration) async throws {
        calls += 1
        if calls == 1 {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        throw CancellationError()
    }
}

private actor FileDeletionSleeper {
    private let file: URL
    private var calls = 0

    init(file: URL) {
        self.file = file
    }

    func sleep(_: Duration) async throws {
        calls += 1
        if calls == 1 {
            try FileManager.default.removeItem(at: file)
            return
        }
        throw CancellationError()
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

    func pauseContainer(id: String) async throws {
        storage.append(.pause(id: id))
    }

    func unpauseContainer(id: String) async throws {
        storage.append(.unpause(id: id))
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
    private let existingNetworks: Set<String>
    private let volumes: [ComposeVolumeSummary]
    private let networkCreateError: (any Error)?
    private let networkDeleteError: (any Error)?
    private let volumeDeleteError: (any Error)?
    private var storage: [ContainerResourceAPIRequest] = []

    init(
        existingNetworks: Set<String> = ["demo_default"],
        volumes: [ComposeVolumeSummary] = [],
        networkCreateError: (any Error)? = nil,
        networkDeleteError: (any Error)? = nil,
        volumeDeleteError: (any Error)? = nil
    ) {
        self.existingNetworks = existingNetworks
        self.volumes = volumes
        self.networkCreateError = networkCreateError
        self.networkDeleteError = networkDeleteError
        self.volumeDeleteError = volumeDeleteError
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

    func networkExists(id: String) async throws -> Bool {
        storage.append(.networkExists(id: id))
        return existingNetworks.contains(id)
    }

    func deleteNetwork(id: String) async throws {
        storage.append(.deleteNetwork(id: id))
        if let networkDeleteError {
            throw networkDeleteError
        }
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
        if let volumeDeleteError {
            throw volumeDeleteError
        }
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

private actor DurationRecorder {
    private var storage: [Duration] = []

    var durations: [Duration] {
        storage
    }

    func sleep(_ duration: Duration) async throws {
        storage.append(duration)
    }
}

private func bakeJSON(_ output: String) throws -> [String: Any] {
    guard let data = output.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ComposeError.invalidProject("build --print emitted malformed bake JSON")
    }
    return object
}

private func bakeGroupTargets(_ bake: [String: Any]) throws -> [String] {
    guard let groups = bake["group"] as? [String: Any],
          let defaultGroup = groups["default"] as? [String: Any],
          let targets = defaultGroup["targets"] as? [String] else {
        throw ComposeError.invalidProject("build --print emitted malformed bake group")
    }
    return targets
}

private func bakeTarget(_ bake: [String: Any], name: String) throws -> [String: Any] {
    guard let targets = bake["target"] as? [String: Any],
          let target = targets[name] as? [String: Any] else {
        throw ComposeError.invalidProject("build --print emitted no bake target named '\(name)'")
    }
    return target
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

private final class DataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var data: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
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

private struct HostPortAllocationRequest: Equatable {
    var hostAddress: String?
    var protocolName: String
}

private final class HostPortSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt16]
    private var storage: [HostPortAllocationRequest] = []

    init(_ values: [UInt16]) {
        self.values = values
    }

    var requests: [HostPortAllocationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func next(hostAddress: String?, protocolName: String) throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        storage.append(HostPortAllocationRequest(hostAddress: hostAddress, protocolName: protocolName))
        return values.isEmpty ? 49152 : values.removeFirst()
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
