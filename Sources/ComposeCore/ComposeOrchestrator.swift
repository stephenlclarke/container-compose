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

import CryptoKit
import Foundation

/// Runtime settings used while translating Compose operations to `container`.
public struct ComposeExecutionOptions {
    public static let defaultEnvironmentLauncher = ["", "usr", "bin", "env"].joined(separator: "/")

    public var dryRun: Bool
    public var containerBinary: String
    public var environmentLauncher: String
    public var oneOffIdentifier: @Sendable () -> String
    public var emit: @Sendable (String) -> Void

    public init(
        dryRun: Bool = false,
        containerBinary: String = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container",
        environmentLauncher: String = ComposeExecutionOptions.defaultEnvironmentLauncher,
        oneOffIdentifier: @escaping @Sendable () -> String = ComposeExecutionOptions.defaultOneOffIdentifier,
        emit: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.dryRun = dryRun
        self.containerBinary = containerBinary
        self.environmentLauncher = environmentLauncher
        self.oneOffIdentifier = oneOffIdentifier
        self.emit = emit
    }

    public static func defaultOneOffIdentifier() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }
}

/// Container command collaborators used by the Compose orchestrator.
public struct ComposeOrchestratorCommandDependencies: Sendable {
    public var copier: ContainerCopying
    public var execManager: ContainerExecManaging
    public var exporter: ContainerExporting
    public var logManager: ContainerLogManaging

    public init(
        copier: ContainerCopying = ContainerClientCopier(),
        execManager: ContainerExecManaging = ContainerClientExecManager(),
        exporter: ContainerExporting = ContainerClientExporter(),
        logManager: ContainerLogManaging = ContainerClientLogManager()
    ) {
        self.copier = copier
        self.execManager = execManager
        self.exporter = exporter
        self.logManager = logManager
    }
}

/// Container lifecycle collaborators used by the Compose orchestrator.
public struct ComposeOrchestratorRuntimeDependencies: Sendable {
    public var discoveryManager: ContainerDiscoveryManaging
    public var lifecycleManager: ContainerLifecycleManaging
    public var resourceManager: ContainerResourceManaging
    public var statsManager: ContainerStatsManaging

    public init(
        discoveryManager: ContainerDiscoveryManaging = ContainerClientDiscoveryManager(),
        lifecycleManager: ContainerLifecycleManaging = ContainerClientLifecycleManager(),
        resourceManager: ContainerResourceManaging = ContainerClientResourceManager(),
        statsManager: ContainerStatsManaging = ContainerClientStatsManager()
    ) {
        self.discoveryManager = discoveryManager
        self.lifecycleManager = lifecycleManager
        self.resourceManager = resourceManager
        self.statsManager = statsManager
    }
}

/// Runtime collaborators used by the Compose orchestrator.
public struct ComposeOrchestratorDependencies: Sendable {
    public var commands: ComposeOrchestratorCommandDependencies
    public var runtime: ComposeOrchestratorRuntimeDependencies
    public var imageManager: ContainerImageManaging

    public init(
        commands: ComposeOrchestratorCommandDependencies = ComposeOrchestratorCommandDependencies(),
        runtime: ComposeOrchestratorRuntimeDependencies = ComposeOrchestratorRuntimeDependencies(),
        imageManager: ContainerImageManaging = ContainerClientImageManager()
    ) {
        self.commands = commands
        self.runtime = runtime
        self.imageManager = imageManager
    }

    public var copier: ContainerCopying {
        get { commands.copier }
        set { commands.copier = newValue }
    }

    public var discoveryManager: ContainerDiscoveryManaging {
        get { runtime.discoveryManager }
        set { runtime.discoveryManager = newValue }
    }

    public var execManager: ContainerExecManaging {
        get { commands.execManager }
        set { commands.execManager = newValue }
    }

    public var exporter: ContainerExporting {
        get { commands.exporter }
        set { commands.exporter = newValue }
    }

    public var lifecycleManager: ContainerLifecycleManaging {
        get { runtime.lifecycleManager }
        set { runtime.lifecycleManager = newValue }
    }

    public var logManager: ContainerLogManaging {
        get { commands.logManager }
        set { commands.logManager = newValue }
    }

    public var resourceManager: ContainerResourceManaging {
        get { runtime.resourceManager }
        set { runtime.resourceManager = newValue }
    }

    public var statsManager: ContainerStatsManaging {
        get { runtime.statsManager }
        set { runtime.statsManager = newValue }
    }
}

/// Options for `compose up`.
public struct ComposeUpOptions {
    public var services: [String] = []
    public var build = false
    public var noBuild = false
    public var detach = false
    public var forceRecreate = false
    public var noRecreate = false
    public var removeOrphans = false
    public var pullPolicy: String?
    public var scales: [String] = []
    public var noDeps = false
    public var noStart = false
    public var quietBuild = false

    public init() {
        // Stored property defaults represent Docker Compose's default up behavior.
    }

    public init(_ configure: (inout ComposeUpOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose create`.
public struct ComposeCreateOptions {
    public var services: [String] = []
    public var build = false
    public var noBuild = false
    public var forceRecreate = false
    public var noRecreate = false
    public var removeOrphans = false
    public var pullPolicy: String?
    public var scales: [String] = []
    public var noDeps = false
    public var quietBuild = false

    public init() {
        // Stored property defaults represent Docker Compose's default create behavior.
    }

    public init(_ configure: (inout ComposeCreateOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose down`.
public struct ComposeDownOptions {
    public var volumes: Bool
    public var removeOrphans: Bool
    public var timeout: Int?
    public var rmi: String?

    public init(volumes: Bool = false, removeOrphans: Bool = false, timeout: Int? = nil, rmi: String? = nil) {
        self.volumes = volumes
        self.removeOrphans = removeOrphans
        self.timeout = timeout
        self.rmi = rmi
    }
}

/// Options for `compose build`.
public struct ComposeBuildOptions {
    public var services: [String] = []
    public var noCache = false
    public var pull = false
    public var push = false
    public var quiet = false
    public var withDependencies = false

    public init() {
        // Stored property defaults represent Docker Compose's default build behavior.
    }

    public init(_ configure: (inout ComposeBuildOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose pull`.
public struct ComposePullOptions {
    public var services: [String] = []
    public var ignoreBuildable = false
    public var ignorePullFailures = false
    public var includeDependencies = false
    public var policy: String?
    public var quiet = false

    public init() {
        // Stored property defaults represent Docker Compose's default pull behavior.
    }

    public init(_ configure: (inout ComposePullOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose push`.
public struct ComposePushOptions {
    public var services: [String] = []
    public var ignorePushFailures = false
    public var includeDependencies = false
    public var quiet = false

    public init() {
        // Stored property defaults represent Docker Compose's default push behavior.
    }

    public init(_ configure: (inout ComposePushOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose images`.
public struct ComposeImagesOptions {
    public var quiet: Bool
    public var format: String

    public init(quiet: Bool = false, format: String = "table") {
        self.quiet = quiet
        self.format = format
    }
}

/// Options for `compose volumes`.
public struct ComposeVolumesOptions {
    public var services: [String]
    public var quiet: Bool
    public var format: String

    public init(services: [String] = [], quiet: Bool = false, format: String = "table") {
        self.services = services
        self.quiet = quiet
        self.format = format
    }
}

/// Options for `compose stats`.
public struct ComposeStatsOptions {
    public var services: [String]
    public var all: Bool
    public var format: String
    public var noStream: Bool
    public var noTrunc: Bool

    public init(services: [String] = [], all: Bool = false, format: String = "table", noStream: Bool = false, noTrunc: Bool = false) {
        self.services = services
        self.all = all
        self.format = format
        self.noStream = noStream
        self.noTrunc = noTrunc
    }
}

/// Options for `compose attach` commands.
public struct ComposeAttachOptions {
    public var noStdin = false
    public var detachKeys: String?
    public var index = 1
    public var sigProxy = "true"

    public init() {
        // Stored property defaults represent Docker Compose's default attach behavior.
    }

    public init(_ configure: (inout ComposeAttachOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose exec` commands.
public struct ComposeExecOptions {
    public var command: [String] = []
    public var interactive = true
    public var tty = true
    public var detach = false
    public var environment: [String] = []
    public var index = 1
    public var privileged = false
    public var user: String?
    public var workingDirectory: String?

    public init() {
        // Stored property defaults represent Docker Compose's default exec behavior.
    }

    public init(_ configure: (inout ComposeExecOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose cp` commands.
public struct ComposeCopyOptions {
    public var arguments: [String] = []
    public var all = false
    public var archive = false
    public var followLink = false
    public var index = 1

    public init() {
        // Stored property defaults represent Docker Compose's default copy behavior.
    }

    public init(_ configure: (inout ComposeCopyOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose export` commands.
public struct ComposeExportOptions {
    public var output: String?
    public var index: Int

    public init(output: String? = nil, index: Int = 1) {
        self.output = output
        self.index = index
    }
}

/// Options for `compose ls`.
public struct ComposeLsOptions {
    public var all: Bool
    public var quiet: Bool
    public var format: String
    public var filters: [String]

    public init(all: Bool = false, quiet: Bool = false, format: String = "table", filters: [String] = []) {
        self.all = all
        self.quiet = quiet
        self.format = format
        self.filters = filters
    }
}

/// Options for `compose run` one-off containers.
public struct ComposeRunOptions {
    public var command: [String] = []
    public var remove = false
    public var detach = false
    public var noTty = false
    public var noDeps = false
    public var servicePorts = false
    public var publish: [String] = []
    public var pullPolicy: String?
    public var containerName: String?
    public var entrypoint: String?
    public var workingDirectory: String?
    public var user: String?
    public var environment: [String] = []
    public var envFiles: [String] = []
    public var labels: [String] = []
    public var volumes: [String] = []

    public init() {
        // Stored property defaults represent Docker Compose's default run behavior.
    }

    public init(_ configure: (inout ComposeRunOptions) -> Void) {
        configure(&self)
    }
}

private struct RunArgumentOptions {
    var command = "run"
    var detach = false
    var remove = false
    var oneOff = false
    var publishedPorts: [String]?
    var containerNameOverride: String?
    var labelOverrides: [ComposeLabelOverride] = []

    init() {
        // Stored property defaults represent unmodified service run arguments.
    }

    init(_ configure: (inout RunArgumentOptions) -> Void) {
        configure(&self)
    }
}

private enum DownImageRemovalPolicy {
    case none
    case local
    case all
}

private enum ComposeImagesFormat {
    case table
    case json
}

private enum ComposeVolumesFormat {
    case table
    case json
}

private struct ComposeCopyContainerTarget {
    var id: String
    var path: String

    var runtimeArgument: String {
        "\(id):\(path)"
    }
}

private enum ComposeCopyEndpoint {
    case local(String)
    case containers([ComposeCopyContainerTarget])

    var runtimeArgument: String {
        switch self {
        case .local(let path):
            path
        case .containers(let containers):
            containers.first?.runtimeArgument ?? ""
        }
    }
}

/// Converts a normalized Compose project into deterministic `container`
/// commands.
public final class ComposeOrchestrator: @unchecked Sendable {
    private let runner: CommandRunning
    private let options: ComposeExecutionOptions
    private let copier: ContainerCopying
    private let discoveryManager: ContainerDiscoveryManaging
    private let execManager: ContainerExecManaging
    private let exporter: ContainerExporting
    private let imageManager: ContainerImageManaging
    private let lifecycleManager: ContainerLifecycleManaging
    private let logManager: ContainerLogManaging
    private let resourceManager: ContainerResourceManaging
    private let statsManager: ContainerStatsManaging

    public init(
        runner: CommandRunning = ProcessRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
        dependencies: ComposeOrchestratorDependencies = ComposeOrchestratorDependencies()
    ) {
        self.runner = runner
        self.options = options
        self.copier = dependencies.copier
        self.discoveryManager = dependencies.discoveryManager
        self.execManager = dependencies.execManager
        self.exporter = dependencies.exporter
        self.imageManager = dependencies.imageManager
        self.lifecycleManager = dependencies.lifecycleManager
        self.logManager = dependencies.logManager
        self.resourceManager = dependencies.resourceManager
        self.statsManager = dependencies.statsManager
    }

    /// Returns canonical project JSON for `compose config`.
    public func config(project: ComposeProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        return String(decoding: data, as: UTF8.self)
    }

    /// Creates project resources and starts selected services in dependency order.
    public func up(project: ComposeProject, options up: ComposeUpOptions) async throws {
        try validate(project: project)
        try validateUpOptions(up)
        if up.noStart {
            try await create(project: project, options: createOptions(from: up))
            return
        }
        let services = try up.noDeps && !up.services.isEmpty
            ? selectedServices(project: project, selected: up.services)
            : orderedServices(project: project, selected: up.services)
        let validateDependencies = !(up.noDeps && !up.services.isEmpty)
        try validatePullPolicy(up.pullPolicy)
        try validateRuntimeSupport(services: services, project: project, validateDependencies: validateDependencies)
        try validatePublishedPorts(services: services)

        try await ensureResources(project: project)

        try await applyPullPolicy(up.pullPolicy, project: project, services: services)

        if up.build {
            try await build(project: project, services: services.map(\.name), noCache: false, quiet: up.quietBuild)
        }

        let attachedForegroundServiceIndex = up.detach ? nil : services.indices.last
        var changedServices = Set<String>()
        for (index, service) in services.enumerated() {
            if shouldBuildServiceForUp(up, service: service) {
                try await build(project: project, services: [service.name], noCache: false, quiet: up.quietBuild)
            }

            let name = containerName(project: project, service: service, oneOff: false)
            let existing = try await inspectContainer(name)
            var serviceChanged = false
            if let existing {
                // Reuse containers only when the Compose-derived service hash
                // still matches, unless the caller chose an explicit recreate
                // policy.
                if up.noRecreate {
                    options.emit("compose: reusing existing container \(name)")
                } else if !up.forceRecreate, existing.configHash == (try configHash(project: project, service: service)) {
                    options.emit("compose: reusing existing container \(name)")
                } else {
                    try await stopContainer(service: service, containerName: name)
                    try await deleteContainer(name)
                    try await runContainer(
                        try runArguments(
                            project: project,
                            service: service,
                            options: RunArgumentOptions {
                                $0.detach = up.detach || index != attachedForegroundServiceIndex
                            }
                        )
                    )
                    serviceChanged = true
                }
            } else {
                try await runContainer(
                    try runArguments(
                        project: project,
                        service: service,
                        options: RunArgumentOptions {
                            $0.detach = up.detach || index != attachedForegroundServiceIndex
                        }
                    )
                )
                serviceChanged = true
            }

            if serviceChanged {
                changedServices.insert(service.name)
                continue
            }
            if existing != nil, shouldRestartAfterDependencyChange(service: service, changedServices: changedServices) {
                try await restartContainer(service: service, containerName: name)
                changedServices.insert(service.name)
            }
        }

        if up.removeOrphans {
            let declaredContainers = Set(project.services.values.map { containerName(project: project, service: $0, oneOff: false) })
            try await removeRemainingProjectContainers(project: project, excluding: declaredContainers)
        }
    }

    /// Creates project resources and selected service containers without starting them.
    public func create(project: ComposeProject, options create: ComposeCreateOptions) async throws {
        try validate(project: project)
        try validateCreateOptions(create)
        let services = try create.noDeps && !create.services.isEmpty
            ? selectedServices(project: project, selected: create.services)
            : orderedServices(project: project, selected: create.services)
        let validateDependencies = !(create.noDeps && !create.services.isEmpty)
        try validateCreatePullPolicy(create.pullPolicy)
        try validateRuntimeSupport(services: services, project: project, validateDependencies: validateDependencies)
        try validatePublishedPorts(services: services)

        try await ensureResources(project: project)

        try await applyCreateImagePolicy(create, project: project, services: services)

        for service in services {
            if shouldBuildServiceForCreate(create, service: service) {
                try await build(project: project, services: [service.name], noCache: false, quiet: create.quietBuild)
            }

            let name = containerName(project: project, service: service, oneOff: false)
            let existing = try await inspectContainer(name)
            if let existing {
                if create.noRecreate {
                    options.emit("compose: reusing existing container \(name)")
                    continue
                }
                if !create.forceRecreate, existing.configHash == (try configHash(project: project, service: service)) {
                    options.emit("compose: reusing existing container \(name)")
                    continue
                }
                try await stopContainer(service: service, containerName: name)
                try await deleteContainer(name)
            }

            try await runContainer(
                try runArguments(
                    project: project,
                    service: service,
                    options: RunArgumentOptions {
                        $0.command = "create"
                    }
                )
            )
        }

        if create.removeOrphans {
            let declaredContainers = Set(project.services.values.map { containerName(project: project, service: $0, oneOff: false) })
            try await removeRemainingProjectContainers(project: project, excluding: declaredContainers)
        }
    }

    /// Converts `up --no-start` options into the equivalent `create` request.
    private func createOptions(from up: ComposeUpOptions) -> ComposeCreateOptions {
        ComposeCreateOptions {
            $0.services = up.services
            $0.build = up.build
            $0.noBuild = up.noBuild
            $0.forceRecreate = up.forceRecreate
            $0.noRecreate = up.noRecreate
            $0.removeOrphans = up.removeOrphans
            $0.pullPolicy = up.pullPolicy
            $0.scales = up.scales
            $0.noDeps = up.noDeps
            $0.quietBuild = up.quietBuild
        }
    }

    /// Stops and removes project-scoped resources.
    public func down(project: ComposeProject, options down: ComposeDownOptions) async throws {
        try validateTimeoutSeconds(down.timeout, command: "down")
        let imageRemovalPolicy = try downImageRemovalPolicy(down.rmi)
        let services = try orderedServices(project: project, selected: [])
        let declaredContainers = Set(services.map { containerName(project: project, service: $0, oneOff: false) })
        for service in services.reversed() {
            let name = containerName(project: project, service: service, oneOff: false)
            try await stopContainer(service: service, containerName: name, timeout: down.timeout)
            try await deleteContainer(name)
        }
        if down.removeOrphans {
            try await removeRemainingProjectContainers(project: project, excluding: declaredContainers)
        }

        for (name, network) in project.networks.sorted(by: { $0.key < $1.key }) where network.external != true {
            let runtimeName = networkRuntimeName(project: project, composeName: name, network: network)
            let args = ["network", "delete", runtimeName]
            if options.dryRun {
                try await runContainer(args, check: false)
            } else {
                try await resourceManager.deleteNetwork(id: runtimeName)
            }
        }

        if down.volumes {
            for (name, volume) in project.volumes.sorted(by: { $0.key < $1.key }) where volume.external != true {
                let runtimeName = volumeRuntimeName(project: project, composeName: name, volume: volume)
                let args = ["volume", "delete", runtimeName]
                if options.dryRun {
                    try await runContainer(args, check: false)
                } else {
                    try await resourceManager.deleteVolume(name: runtimeName)
                }
            }
        }

        try await removeImages(project: project, policy: imageRemovalPolicy)
    }

    /// Builds images for services that declare a build section.
    public func build(project: ComposeProject, services selected: [String], noCache: Bool, quiet: Bool = false) async throws {
        try await build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = selected
                $0.noCache = noCache
                $0.quiet = quiet
            }
        )
    }

    /// Builds images for selected services with Docker Compose compatible options.
    public func build(project: ComposeProject, options build: ComposeBuildOptions) async throws {
        let services = try build.withDependencies
            ? orderedServices(project: project, selected: build.services)
            : selectedServices(project: project, selected: build.services)
        for service in services where service.build != nil {
            try await buildService(project: project, service: service, options: build)
            if build.push, let image = service.image {
                if options.dryRun {
                    try await runContainer(["image", "push", image])
                } else {
                    try await imageManager.pushImage(image, emit: options.emit)
                }
            }
        }
    }

    /// Pulls images for selected services.
    public func pull(project: ComposeProject, services selected: [String]) async throws {
        try await pull(
            project: project,
            options: ComposePullOptions {
                $0.services = selected
            }
        )
    }

    /// Pulls images for selected services with Docker Compose compatible options.
    public func pull(project: ComposeProject, options pull: ComposePullOptions) async throws {
        try validateComposePullPolicy(pull.policy)
        let services = try pull.includeDependencies
            ? orderedServices(project: project, selected: pull.services)
            : selectedServices(project: project, selected: pull.services)
        for service in services {
            if pull.ignoreBuildable, service.build != nil {
                continue
            }
            guard let image = service.image else { continue }
            do {
                if pull.policy == "missing" {
                    try await pullMissingImage(image)
                } else if options.dryRun {
                    try await runContainer(["image", "pull", image])
                } else {
                    try await imageManager.pullImage(image)
                }
            } catch {
                guard pull.ignorePullFailures else {
                    throw error
                }
            }
        }
    }

    /// Pushes images for selected services.
    public func push(project: ComposeProject, services selected: [String]) async throws {
        try await push(
            project: project,
            options: ComposePushOptions {
                $0.services = selected
            }
        )
    }

    /// Pushes images for selected services with Docker Compose compatible options.
    public func push(project: ComposeProject, options push: ComposePushOptions) async throws {
        let services = try push.includeDependencies
            ? orderedServices(project: project, selected: push.services)
            : selectedServices(project: project, selected: push.services)
        let emit: @Sendable (String) -> Void
        if push.quiet {
            emit = { _ in }
        } else {
            emit = options.emit
        }
        for service in services {
            guard let image = service.image else { continue }
            let args = ["image", "push", image]
            if options.dryRun {
                try await runContainer(args)
            } else {
                do {
                    try await imageManager.pushImage(image, emit: emit)
                } catch {
                    guard push.ignorePushFailures else {
                        throw error
                    }
                }
            }
        }
    }

    /// Lists Compose projects discovered through project-scoped container labels.
    public func ls(options list: ComposeLsOptions = ComposeLsOptions()) async throws {
        let nameFilters = try lsNameFilters(list.filters)
        let format = try composeLsFormat(list.format)
        var args = ["list", "--format", "json"]
        if list.all {
            args.append("--all")
        }
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let containers = try await discoveryManager.listContainers(all: list.all)
        let records = composeProjectRecords(containers: containers, nameFilters: nameFilters)
        if list.quiet {
            let names = records.map(\.name)
            if !names.isEmpty {
                options.emit(names.joined(separator: "\n"))
            }
            return
        }

        switch format {
        case .table:
            let table = renderComposeProjectTable(records)
            if !table.isEmpty {
                options.emit(table)
            }
        case .json:
            options.emit(try renderComposeProjectJSON(records))
        }
    }

    /// Lists containers belonging to the Compose project.
    public func ps(
        project: ComposeProject,
        all: Bool,
        quiet: Bool = false,
        services: Bool = false,
        statuses: [String] = [],
        filters: [String] = []
    ) async throws {
        let statusFilters = try psStatusFilters(statuses: statuses, filters: filters)
        var args = ["list", "--format", "json"]
        if all || !statusFilters.isEmpty {
            args.append("--all")
        }
        if options.dryRun {
            try await runContainer(args)
            return
        }
        let containers = try await projectContainers(projectName: project.name, all: all || !statusFilters.isEmpty)
        let filteredContainers = filterContainersByStatus(containers, statuses: statusFilters)
        if quiet {
            let identifiers = containerIdentifiers(filteredContainers)
            if !identifiers.isEmpty {
                options.emit(identifiers.joined(separator: "\n"))
            }
            return
        }
        if services {
            let names = containerServiceNames(filteredContainers)
            if !names.isEmpty {
                options.emit(names.joined(separator: "\n"))
            }
            return
        }
        options.emit(try containerListJSON(filteredContainers))
    }

    /// Streams or prints logs for selected service containers.
    public func logs(project: ComposeProject, services selected: [String], follow: Bool, tail: String?) async throws {
        let services = try selectedServices(project: project, selected: selected)
        let runtimeTail = try runtimeLogTail(tail)
        for service in services {
            var args = ["logs"]
            if follow {
                args.append("--follow")
            }
            if let runtimeTail {
                args.append(contentsOf: ["-n", String(runtimeTail)])
            }
            let id = containerName(project: project, service: service, oneOff: false)
            args.append(id)
            if options.dryRun {
                try await runContainer(args)
            } else {
                try await logManager.logs(id: id, tail: runtimeTail, follow: follow, emit: options.emit)
            }
        }
    }

    /// Attaches to service output using the Apple log stream.
    public func attach(project: ComposeProject, serviceName: String, options attach: ComposeAttachOptions) async throws {
        try validateAttachOptions(attach)
        try await logs(project: project, services: [serviceName], follow: true, tail: nil)
    }

    /// Executes a command in an existing service container.
    public func exec(
        project: ComposeProject,
        serviceName: String,
        command: [String],
        interactive: Bool = true,
        tty: Bool = true
    ) async throws {
        try await exec(
            project: project,
            serviceName: serviceName,
            options: ComposeExecOptions {
                $0.command = command
                $0.interactive = interactive
                $0.tty = tty
            }
        )
    }

    /// Executes a command in an existing service container with Compose options.
    public func exec(project: ComposeProject, serviceName: String, options exec: ComposeExecOptions) async throws {
        try validateExecOptions(exec)
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        guard !exec.command.isEmpty else {
            throw ComposeError.invalidProject("exec requires a command")
        }
        var args = ["exec"]
        if exec.detach {
            args.append("--detach")
        }
        for environment in exec.environment {
            args.append(contentsOf: ["--env", environment])
        }
        if let user = exec.user {
            args.append(contentsOf: ["--user", user])
        }
        if let workingDirectory = exec.workingDirectory {
            args.append(contentsOf: ["--workdir", workingDirectory])
        }
        if exec.interactive, !exec.detach {
            args.append("--interactive")
        }
        if exec.tty, !exec.detach {
            args.append("--tty")
        }
        let containerID = try await serviceContainerID(project: project, service: service, index: exec.index)
        args.append(containerID)
        args.append(contentsOf: exec.command)
        if !options.dryRun {
            if exec.detach {
                try await execManager.execDetached(
                    request: ContainerDetachedExecRequest(
                        id: containerID,
                        command: exec.command,
                        environment: exec.environment,
                        user: exec.user,
                        workingDirectory: exec.workingDirectory
                    ),
                    emit: options.emit
                )
                return
            }
            let status = try await execManager.execAttached(
                request: ContainerAttachedExecRequest(
                    id: containerID,
                    command: exec.command,
                    environment: exec.environment,
                    user: exec.user,
                    workingDirectory: exec.workingDirectory,
                    interactive: exec.interactive,
                    tty: exec.tty
                )
            )
            if status != 0 {
                throw ComposeError.commandFailed(command: shellQuoted([options.containerBinary] + args), status: status, stderr: "")
            }
            return
        }
        try await runContainer(args, inheritedIO: !exec.detach && (exec.interactive || exec.tty))
    }

    /// Runs a one-off container for a service.
    public func run(project: ComposeProject, serviceName: String, command: [String], remove: Bool) async throws {
        try await run(
            project: project,
            serviceName: serviceName,
            options: ComposeRunOptions {
                $0.command = command
                $0.remove = remove
            }
        )
    }

    /// Runs a one-off container for a service with Docker Compose compatible options.
    public func run(project: ComposeProject, serviceName: String, options run: ComposeRunOptions) async throws {
        var runProject = project
        guard var service = runProject.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        if !run.command.isEmpty {
            service.command = run.command
        }
        if let entrypoint = run.entrypoint {
            service.entrypoint = [entrypoint]
        }
        if let workingDirectory = run.workingDirectory {
            service.workingDir = workingDirectory
        }
        if let user = run.user {
            service.user = user
        }
        if run.noTty {
            service.tty = false
        }
        try applyRunEnvironmentOverrides(run, service: &service)
        try applyRunVolumeOverrides(run, project: &runProject, service: &service)
        try validateProjectNetworks(runProject)
        let labelOverrides = try parseRunLabelOverrides(run.labels)
        try validatePullPolicy(run.pullPolicy)
        let dependencyServices = try run.noDeps
            ? []
            : orderedServices(project: runProject, selected: [serviceName]).filter { $0.name != serviceName }
        try validateRuntimeSupport(services: dependencyServices + [service], project: runProject, validateDependencies: !run.noDeps)
        try validatePublishedPorts(services: dependencyServices)
        let publishedPorts = (run.servicePorts ? service.ports ?? [] : []) + run.publish
        try validatePublishedPorts(publishedPorts, serviceName: service.name)
        try await applyPullPolicy(run.pullPolicy, project: runProject, services: [service])
        try await ensureResources(project: runProject)
        try await startDependencyServices(project: runProject, services: dependencyServices)
        try await runContainer(
            try runArguments(
                project: runProject,
                service: service,
                options: RunArgumentOptions {
                    $0.detach = run.detach
                    $0.remove = run.remove
                    $0.oneOff = true
                    $0.publishedPorts = publishedPorts
                    $0.containerNameOverride = run.containerName
                    $0.labelOverrides = labelOverrides
                }
            ),
            inheritedIO: !run.detach && (service.tty == true || service.stdinOpen == true)
        )
    }

    /// Starts selected service containers.
    public func start(project: ComposeProject, services selected: [String]) async throws {
        for service in try selectedServices(project: project, selected: selected) {
            try await startContainer(containerName: containerName(project: project, service: service, oneOff: false))
        }
    }

    /// Stops selected service containers.
    public func stop(project: ComposeProject, services selected: [String], timeout: Int? = nil) async throws {
        try validateTimeoutSeconds(timeout, command: "stop")
        for service in try selectedServices(project: project, selected: selected) {
            try await stopContainer(
                service: service,
                containerName: containerName(project: project, service: service, oneOff: false),
                timeout: timeout
            )
        }
    }

    /// Restarts selected service containers.
    public func restart(project: ComposeProject, services selected: [String], timeout: Int? = nil) async throws {
        try await stop(project: project, services: selected, timeout: timeout)
        try await start(project: project, services: selected)
    }

    /// Removes selected service containers.
    public func rm(
        project: ComposeProject,
        services selected: [String],
        stopFirst: Bool,
        force: Bool = false,
        volumes: Bool = false
    ) async throws {
        let services = try selectedServices(project: project, selected: selected)
        if stopFirst {
            try await stop(project: project, services: services.map(\.name))
        }
        for service in services {
            let name = containerName(project: project, service: service, oneOff: false)
            try await deleteContainer(name, force: force)
        }
        if volumes {
            for volume in anonymousVolumeRuntimeNames(project: project, services: services) {
                let args = ["volume", "delete", volume]
                if options.dryRun {
                    try await runContainer(args, check: false)
                } else {
                    try await resourceManager.deleteVolume(name: volume)
                }
            }
        }
    }

    /// Lists images used by created project containers.
    public func images(project: ComposeProject, services selected: [String], options images: ComposeImagesOptions) async throws {
        let services = try selectedServices(project: project, selected: selected)
        let selectedServiceNames = selected.isEmpty ? nil : Set(services.map(\.name))
        let format = try composeImagesFormat(images.format)
        let args = ["list", "--format", "json", "--all"]
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let containers = try await projectContainers(projectName: project.name, all: true)
        let records = composeImageRecords(containers: containers, selectedServices: selectedServiceNames)
        if images.quiet {
            let identifiers = records.map(\.imageID).filter { !$0.isEmpty }
            if !identifiers.isEmpty {
                options.emit(identifiers.joined(separator: "\n"))
            }
            return
        }

        switch format {
        case .table:
            let table = renderComposeImageTable(records)
            if !table.isEmpty {
                options.emit(table)
            }
        case .json:
            options.emit(try renderComposeImageJSON(records))
        }
    }

    /// Lists volumes that belong to the Compose project or selected services.
    public func volumes(project: ComposeProject, options volumes: ComposeVolumesOptions) async throws {
        let services = try selectedServices(project: project, selected: volumes.services)
        let format = try composeVolumesFormat(volumes.format)
        let args = ["volume", "list", "--format", "json"]
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let records = try await composeVolumeRecords(
            project: project,
            services: services,
            restrictToSelectedServices: !volumes.services.isEmpty
        )
        if volumes.quiet {
            let names = records.map(\.name)
            if !names.isEmpty {
                options.emit(names.joined(separator: "\n"))
            }
            return
        }

        switch format {
        case .table:
            let table = renderComposeVolumeTable(records)
            if !table.isEmpty {
                options.emit(table)
            }
        case .json:
            options.emit(try renderComposeVolumeJSON(records))
        }
    }

    /// Displays resource usage statistics for selected service containers.
    public func stats(project: ComposeProject, options stats: ComposeStatsOptions) async throws {
        try validate(project: project)
        try validateStatsOptions(stats)
        let services = try selectedServices(project: project, selected: stats.services)
        var args = ["stats"]
        if stats.format != "table" {
            args.append(contentsOf: ["--format", stats.format])
        }
        if stats.noStream {
            args.append("--no-stream")
        }
        if stats.all {
            args.append("--all")
        }
        let ids = services.map { containerName(project: project, service: $0, oneOff: false) }
        args.append(contentsOf: ids)
        if options.dryRun {
            try await runContainer(args)
            return
        }
        try await statsManager.stats(
            ids: ids,
            format: stats.format,
            noStream: stats.noStream,
            includeStopped: stats.all,
            emit: options.emit
        )
    }

    /// Sends a signal to selected service containers.
    public func kill(project: ComposeProject, services selected: [String], signal: String?) async throws {
        for service in try selectedServices(project: project, selected: selected) {
            var args = ["kill"]
            if let signal {
                args.append(contentsOf: ["--signal", signal])
            }
            let containerID = containerName(project: project, service: service, oneOff: false)
            args.append(containerID)
            if options.dryRun {
                try await runContainer(args, check: false)
                continue
            }
            try await lifecycleManager.killContainer(id: containerID, signal: signal ?? "KILL")
        }
    }

    /// Copies files between a Compose service container and the local host.
    public func copy(project: ComposeProject, arguments: [String]) async throws {
        try await copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = arguments
            }
        )
    }

    /// Copies files between a Compose service container and the local host with Compose options.
    public func copy(project: ComposeProject, options copy: ComposeCopyOptions) async throws {
        try validateCopyOptions(copy)
        guard copy.arguments.count == 2 else {
            throw ComposeError.invalidProject("cp requires exactly source and destination")
        }

        let source = try await copyEndpoint(
            copy.arguments[0],
            project: project,
            index: copy.index,
            includeOneOff: copy.all && !options.dryRun
        )
        let destination = try await copyEndpoint(
            copy.arguments[1],
            project: project,
            index: copy.index,
            includeOneOff: copy.all && !options.dryRun
        )
        switch (source, destination) {
        case (.containers(let sources), .local(let localPath)):
            guard let source = sources.first else {
                throw ComposeError.invalidProject("no source container found for cp")
            }
            if options.dryRun {
                try await runContainer(["cp", source.runtimeArgument, localPath])
                return
            }
            try await copier.copyFromContainer(id: source.id, source: source.path, destination: localPath)
        case (.local(let localPath), .containers(let destinations)):
            if options.dryRun {
                for destination in destinations {
                    try await runContainer(["cp", localPath, destination.runtimeArgument])
                }
                return
            }
            for destination in destinations {
                try await copier.copyIntoContainer(id: destination.id, source: localPath, destination: destination.path)
            }
        case (.containers(let sources), .containers(let destinations)):
            try await copyBetweenContainerTargets(sources: sources, destinations: destinations, allDestinations: copy.all)
        case (.local, .local):
            try await runContainer(["cp", source.runtimeArgument, destination.runtimeArgument])
        }
    }

    /// Stages copies from one source service container into selected destination containers.
    private func copyBetweenContainerTargets(
        sources: [ComposeCopyContainerTarget],
        destinations: [ComposeCopyContainerTarget],
        allDestinations: Bool
    ) async throws {
        guard let source = sources.first else {
            throw ComposeError.invalidProject("no source or destination container found for cp")
        }
        let selectedDestinations = allDestinations ? destinations : Array(destinations.prefix(1))
        guard !selectedDestinations.isEmpty else {
            throw ComposeError.invalidProject("no source or destination container found for cp")
        }

        if options.dryRun {
            for destination in selectedDestinations {
                try await runContainer(["cp", source.runtimeArgument, destination.runtimeArgument])
            }
            return
        }

        for destination in selectedDestinations {
            try await copier.copyBetweenContainers(
                sourceID: source.id,
                source: source.path,
                destinationID: destination.id,
                destination: destination.path
            )
        }
    }

    /// Exports an existing service container filesystem as a tar archive.
    public func export(project: ComposeProject, serviceName: String, options export: ComposeExportOptions = ComposeExportOptions()) async throws {
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }

        var args = ["export"]
        if let output = export.output {
            args.append(contentsOf: ["--output", output])
        }
        let containerID = try await serviceContainerID(project: project, service: service, index: export.index)
        args.append(containerID)
        if options.dryRun {
            try await runContainer(args, inheritedIO: export.output == nil)
            return
        }
        try await exporter.exportContainer(id: containerID, output: export.output)
    }

    /// Prints the public address for a published service port from runtime state.
    public func port(
        project: ComposeProject,
        serviceName: String,
        privatePort: String,
        protocolName: String,
        index: Int
    ) async throws {
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }

        let requested = try parsePortLookup(privatePort: privatePort, protocolName: protocolName)
        try validatePublishedPorts(service.ports ?? [], serviceName: service.name)
        if options.dryRun {
            try emitDryRunPort(service: service, requested: requested)
            return
        }

        let containerID = try await serviceContainerID(project: project, service: service, index: index)
        guard let container = try await discoveryManager.getContainer(id: containerID) else {
            throw ComposeError.invalidProject("service '\(service.name)' container '\(containerID)' does not exist")
        }

        guard let mapping = publishedPort(
            in: container.publishedPorts,
            target: requested.target,
            protocolName: requested.protocolName
        ) else {
            throw ComposeError.invalidProject("service '\(service.name)' does not publish target port \(requested.target)/\(requested.protocolName)")
        }
        options.emit("\(mapping.hostAddress):\(mapping.hostPort)")
    }

    /// Throws a consistently formatted unsupported-feature error.
    public func unsupported(_ feature: String, reason: String) throws -> Never {
        throw ComposeError.unsupported("\(feature): \(reason)")
    }
}

public extension ComposeOrchestrator {
    /// Returns selected services after their dependencies using a stable
    /// depth-first traversal. Optional dependencies are included when the
    /// service exists and skipped when the project does not define it.
    func orderedServices(project: ComposeProject, selected: [String]) throws -> [ComposeService] {
        let selectedSet = Set(selected)
        var visiting = Set<String>()
        var visited = Set<String>()
        var ordered: [ComposeService] = []

        func visit(_ name: String) throws {
            if visited.contains(name) {
                return
            }
            if visiting.contains(name) {
                throw ComposeError.invalidProject("dependency cycle involving '\(name)'")
            }
            guard let service = project.services[name] else {
                throw ComposeError.invalidProject("unknown service '\(name)'")
            }
            visiting.insert(name)
            for (dependency, metadata) in (service.dependsOn ?? [:]).sorted(by: { $0.key < $1.key }) {
                if metadata.required == false, project.services[dependency] == nil {
                    continue
                }
                try visit(dependency)
            }
            visiting.remove(name)
            visited.insert(name)
            ordered.append(service)
        }

        let roots = selected.isEmpty ? project.services.keys.sorted() : selectedSet.sorted()
        for name in roots {
            try visit(name)
        }
        return ordered
    }
}

private extension ComposeOrchestrator {
    /// Resolves an optional service selection into deterministic services.
    func selectedServices(project: ComposeProject, selected: [String]) throws -> [ComposeService] {
        if selected.isEmpty {
            return project.services.values.sorted { $0.name < $1.name }
        }
        return try selected.map { name in
            guard let service = project.services[name] else {
                throw ComposeError.invalidProject("unknown service '\(name)'")
            }
            return service
        }
    }

    /// Returns the deterministic container name for a service or one-off run.
    func containerName(project: ComposeProject, service: ComposeService, oneOff: Bool) -> String {
        if !oneOff, let containerName = service.containerName, !containerName.isEmpty {
            return slug(containerName)
        }
        let suffix = oneOff ? "run-\(slug(options.oneOffIdentifier()))" : "1"
        return "\(slug(project.name))-\(slug(service.name))-\(suffix)"
    }

    /// Resolves the runtime ID for a service container index.
    func serviceContainerID(project: ComposeProject, service: ComposeService, index: Int) async throws -> String {
        let id = try serviceContainerName(project: project, service: service, index: index)
        guard index != 1, !options.dryRun else {
            return id
        }

        let containers = try await projectContainers(projectName: project.name, all: true)
        guard serviceContainerExists(containers, service: service, id: id) else {
            throw ComposeError.invalidProject("service '\(service.name)' container '\(id)' does not exist")
        }
        return id
    }

    /// Returns the deterministic runtime name for a service container index.
    func serviceContainerName(project: ComposeProject, service: ComposeService, index: Int) throws -> String {
        guard index >= 1 else {
            throw ComposeError.invalidProject("container index must be greater than zero")
        }
        if index == 1 {
            return containerName(project: project, service: service, oneOff: false)
        }
        if let containerName = service.containerName, !containerName.isEmpty {
            throw ComposeError.invalidProject("service '\(service.name)' uses container_name; --index \(index) requires Compose-managed replica names")
        }
        return "\(slug(project.name))-\(slug(service.name))-\(index)"
    }

    /// Validates project-level invariants before runtime orchestration starts.
    func validate(project: ComposeProject) throws {
        guard !project.name.isEmpty else {
            throw ComposeError.invalidProject("project name is empty")
        }
        guard !project.services.isEmpty else {
            throw ComposeError.invalidProject("no services defined")
        }
        try validateProjectNetworks(project)
    }

    /// Rejects Compose features that need runtime support not available yet.
    func validateRuntimeSupport(
        service: ComposeService,
        project: ComposeProject,
        validateDependencies: Bool = true
    ) throws {
        try validateBuildSupport(service: service)
        try validateDeploySupport(service: service)
        try validateProviderModelAndHookSupport(service: service)
        let networks = service.networks ?? []
        if networks.count > 1 {
            throw ComposeError.unsupported("service '\(service.name)' declares multiple networks; apple/container does not expose network connect yet")
        }
        if let networkAliases = service.networkAliases,
           networkAliases.contains(where: { !$0.value.isEmpty }) {
            throw ComposeError.unsupported("service '\(service.name)' uses network aliases; network alias support needs an apple/container runtime gap PR")
        }
        if let networkOptions = service.networkOptions {
            for (network, options) in networkOptions.sorted(by: { $0.key < $1.key }) {
                let fields = try options.unsupportedFieldNames()
                if !fields.isEmpty {
                    let fieldList = fields.joined(separator: ", ")
                    throw ComposeError.unsupported("service '\(service.name)' uses network attachment options \(fieldList) on network '\(network)'; network attachment options need an apple/container runtime gap PR")
                }
            }
        }
        if let networkMode = service.networkMode, !networkMode.isEmpty, !isNoNetworkMode(networkMode) {
            throw ComposeError.unsupported("service '\(service.name)' uses network_mode '\(networkMode)'; network mode support needs an apple/container runtime gap PR")
        }
        if let gap = unsupportedRuntimeStringFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName) '\(gap.value)'; \(gap.reason)")
        }
        if let gap = unsupportedCPUResourceFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName) '\(gap.value)'; \(gap.reason)")
        }
        if let gap = unsupportedMemoryAndProcessResourceFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName) '\(gap.value)'; \(gap.reason)")
        }
        if service.blkioConfig == true {
            throw ComposeError.unsupported("service '\(service.name)' uses blkio_config; block I/O controls are not implemented by container-compose yet")
        }
        if service.develop == true {
            throw ComposeError.unsupported("service '\(service.name)' uses develop; develop/watch workflows are not implemented by container-compose yet")
        }
        if let gap = unsupportedUserAndSecurityOptionFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName) '\(gap.value)'; \(gap.reason)")
        }
        if let gap = unsupportedDeviceAccessFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        if let scale = service.scale, scale != 1 {
            throw ComposeError.unsupported("service '\(service.name)' uses scale \(scale); service replica scaling is not implemented by container-compose yet")
        }
        if let gap = unsupportedServiceMetadataAndLoggingFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        try validateServiceLabels(project: project, service: service)
        if let gap = unsupportedServiceVolumeShortcutFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        if let fields = unsupportedServiceMountFields(service: service) {
            let fieldList = fields.joined(separator: ", ")
            throw ComposeError.unsupported("service '\(service.name)' uses unsupported volume fields \(fieldList); advanced service volume options are not implemented by container-compose yet")
        }
        if service.useAPISocket == true {
            throw ComposeError.unsupported("service '\(service.name)' uses use_api_socket; API socket mounting is not implemented by container-compose yet")
        }
        try validateNetworkMACAddressSupport(service: service, networks: networks)
        if validateDependencies, let dependsOn = service.dependsOn {
            for (dependency, metadata) in dependsOn.sorted(by: { $0.key < $1.key }) {
                if metadata.required == false, project.services[dependency] == nil {
                    continue
                }
                let condition = metadata.condition
                if condition != "service_started" && condition != "" {
                    let reason = unsupportedDependencyConditionReason(condition)
                    throw ComposeError.unsupported("service '\(service.name)' depends on '\(dependency)' with condition '\(condition)'; \(reason)")
                }
            }
        }
        if let links = service.links, !links.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses links; legacy link support needs an apple/container runtime gap PR")
        }
        if let externalLinks = service.externalLinks, !externalLinks.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses external_links; legacy link support needs an apple/container runtime gap PR")
        }
        if let extraHosts = service.extraHosts, !extraHosts.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses extra_hosts; host-entry support needs an apple/container runtime gap PR")
        }
        if let hostname = service.hostname, !hostname.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses hostname; custom hostname support needs an apple/container runtime gap PR")
        }
        if let domainName = service.domainName, !domainName.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses domainname; custom domain name support needs an apple/container runtime gap PR")
        }
        if let sysctls = service.sysctls, !sysctls.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses sysctls; sysctl support needs an apple/container runtime gap PR")
        }
        if service.healthcheck != nil {
            throw ComposeError.unsupported("service '\(service.name)' uses healthcheck; health status support needs an apple/container runtime gap PR")
        }
        if let configs = service.configs, !configs.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses configs; config mount support needs an apple/container runtime gap PR")
        }
        if let secrets = service.secrets, !secrets.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses secrets; secret mount support needs an apple/container runtime gap PR")
        }
        if let pullPolicy = service.pullPolicy, !pullPolicy.isEmpty, !isSupportedServicePullPolicy(pullPolicy) {
            throw ComposeError.unsupported("service '\(service.name)' uses pull_policy '\(pullPolicy)'; supported values are always, missing, if_not_present, and never")
        }
        if let restart = service.restart, !restart.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses restart policy '\(restart)'; restart policy support needs an apple/container runtime gap PR")
        }
    }

    /// Rejects project network fields that are not mapped to Apple network creation.
    func validateProjectNetworks(_ project: ComposeProject) throws {
        for (name, network) in project.networks.sorted(by: { $0.key < $1.key }) {
            guard let fields = network.unsupportedFields, !fields.isEmpty else {
                continue
            }
            let fieldList = fields.joined(separator: ", ")
            throw ComposeError.unsupported("network '\(name)' uses unsupported fields \(fieldList); only internal and one IPv4/IPv6 IPAM subnet are mapped to apple/container networks")
        }
    }

    /// Returns whether the service explicitly disables container networking.
    func isNoNetworkMode(_ networkMode: String?) -> Bool {
        networkMode == "none"
    }

    /// Allows MAC addresses only for the single-network attachment that Apple
    /// `container --network name,mac=...` can represent.
    func validateNetworkMACAddressSupport(service: ComposeService, networks: [String]) throws {
        let serviceMACAddress = nonEmpty(service.macAddress)
        let networkMACAddresses = (service.networkOptions ?? [:]).compactMapValues { nonEmpty($0.macAddress) }
        guard serviceMACAddress != nil || !networkMACAddresses.isEmpty else {
            return
        }
        guard networks.count == 1, let network = networks.first else {
            throw ComposeError.unsupported("service '\(service.name)' uses mac_address; MAC address support requires exactly one Compose network")
        }
        for networkName in networkMACAddresses.keys.sorted() where networkName != network {
            throw ComposeError.unsupported("service '\(service.name)' sets mac_address on unattached network '\(networkName)'")
        }
        if let serviceMACAddress,
           let networkMACAddress = networkMACAddresses[network],
           serviceMACAddress != networkMACAddress {
            throw ComposeError.invalidProject("service '\(service.name)' sets conflicting mac_address values '\(serviceMACAddress)' and '\(networkMACAddress)' on network '\(network)'")
        }
    }

    /// Rejects build fields that are not translated to `container build` yet.
    func validateBuildSupport(service: ComposeService) throws {
        guard let fields = service.build?.unsupportedFields, !fields.isEmpty else {
            return
        }
        let fieldList = fields.joined(separator: ", ")
        throw ComposeError.unsupported("service '\(service.name)' uses unsupported build fields \(fieldList); advanced build fields are not implemented by container-compose yet")
    }

    /// Rejects deploy fields beyond replica count that are not orchestrated yet.
    func validateDeploySupport(service: ComposeService) throws {
        guard let fields = service.unsupportedDeployFields, !fields.isEmpty else {
            return
        }
        let fieldList = fields.joined(separator: ", ")
        throw ComposeError.unsupported("service '\(service.name)' uses unsupported deploy fields \(fieldList); Compose Deploy Specification beyond replica count is not implemented by container-compose yet")
    }

    /// Rejects service extension points that need explicit orchestration design.
    func validateProviderModelAndHookSupport(service: ComposeService) throws {
        if service.provider == true {
            throw ComposeError.unsupported("service '\(service.name)' uses provider; service providers are not implemented by container-compose yet")
        }
        if service.models == true {
            throw ComposeError.unsupported("service '\(service.name)' uses models; service model bindings are not implemented by container-compose yet")
        }
        if service.postStart == true {
            throw ComposeError.unsupported("service '\(service.name)' uses post_start; lifecycle hooks are not implemented by container-compose yet")
        }
        if service.preStop == true {
            throw ComposeError.unsupported("service '\(service.name)' uses pre_stop; lifecycle hooks are not implemented by container-compose yet")
        }
    }

    /// Validates all selected services before any runtime side effects occur.
    func validateRuntimeSupport(
        services: [ComposeService],
        project: ComposeProject,
        validateDependencies: Bool = true
    ) throws {
        for service in services {
            try validateRuntimeSupport(service: service, project: project, validateDependencies: validateDependencies)
        }
    }

    /// Returns unsupported string-valued fields that need missing runtime primitives.
    func unsupportedRuntimeStringFields(service: ComposeService) -> [(composeName: String, value: String, reason: String)] {
        [
            ("cgroup", service.cgroup, "cgroup namespace support needs an apple/container runtime gap PR"),
            ("cgroup_parent", service.cgroupParent, "cgroup parent support needs an apple/container runtime gap PR"),
            ("ipc", service.ipc, "IPC namespace support needs an apple/container runtime gap PR"),
            ("isolation", service.isolation, "isolation support needs an apple/container runtime gap PR"),
            ("pid", service.pid, "PID namespace support needs an apple/container runtime gap PR"),
            ("userns_mode", service.usernsMode, "user namespace support needs an apple/container runtime gap PR"),
            ("uts", service.uts, "UTS namespace support needs an apple/container runtime gap PR"),
        ].compactMap { composeName, value, reason in
            guard let value, !value.isEmpty else {
                return nil
            }
            return (composeName, value, reason)
        }
    }

    /// Returns unsupported CPU scheduler fields beyond the supported `cpus` limit.
    func unsupportedCPUResourceFields(service: ComposeService) -> [(composeName: String, value: String, reason: String)] {
        let reason = "advanced CPU resource support needs an apple/container runtime gap PR"
        var fields: [(composeName: String, value: String, reason: String)] = []
        appendUnsupportedIntegerField("cpu_count", value: service.cpuCount, reason: reason, to: &fields)
        appendUnsupportedFloatingPointField("cpu_percent", value: service.cpuPercent, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_period", value: service.cpuPeriod, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_quota", value: service.cpuQuota, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_rt_period", value: service.cpuRealtimePeriod, reason: reason, to: &fields)
        appendUnsupportedIntegerField("cpu_rt_runtime", value: service.cpuRealtimeRuntime, reason: reason, to: &fields)
        if let cpuset = service.cpuset, !cpuset.isEmpty {
            fields.append(("cpuset", cpuset, reason))
        }
        appendUnsupportedIntegerField("cpu_shares", value: service.cpuShares, reason: reason, to: &fields)
        return fields
    }

    /// Returns unsupported memory, OOM, and process resource controls beyond `mem_limit`.
    func unsupportedMemoryAndProcessResourceFields(service: ComposeService) -> [(composeName: String, value: String, reason: String)] {
        let reason = "memory, OOM, and process resource support needs an apple/container runtime gap PR"
        var fields: [(composeName: String, value: String, reason: String)] = []
        appendUnsupportedStringField("mem_reservation", value: service.memReservation, reason: reason, to: &fields)
        appendUnsupportedStringField("memswap_limit", value: service.memSwapLimit, reason: reason, to: &fields)
        appendUnsupportedStringField("mem_swappiness", value: service.memSwappiness, reason: reason, to: &fields)
        if service.oomKillDisable == true {
            fields.append(("oom_kill_disable", "true", reason))
        }
        appendUnsupportedIntegerField("oom_score_adj", value: service.oomScoreAdj, reason: reason, to: &fields)
        appendUnsupportedIntegerField("pids_limit", value: service.pidsLimit, reason: reason, to: &fields)
        return fields
    }

    /// Returns unsupported user and security option fields.
    func unsupportedUserAndSecurityOptionFields(service: ComposeService) -> [(composeName: String, value: String, reason: String)] {
        var fields: [(composeName: String, value: String, reason: String)] = []
        if let group = service.groupAdd?.first(where: { !$0.isEmpty }) {
            fields.append(("group_add", group, "supplemental group support needs an apple/container runtime gap PR"))
        }
        if let securityOption = service.securityOpt?.first(where: { !$0.isEmpty }) {
            fields.append(("security_opt", securityOption, "security option support needs an apple/container runtime gap PR"))
        }
        return fields
    }

    /// Returns unsupported host device, GPU, and credential access fields.
    func unsupportedDeviceAccessFields(service: ComposeService) -> [(composeName: String, reason: String)] {
        var fields: [(composeName: String, reason: String)] = []
        if service.credentialSpec != nil {
            fields.append(("credential_spec", "credential spec support needs an apple/container runtime gap PR"))
        }
        if let rules = service.deviceCgroupRules, !rules.isEmpty {
            fields.append(("device_cgroup_rules", "device cgroup rule support needs an apple/container runtime gap PR"))
        }
        if let devices = service.devices, !devices.isEmpty {
            fields.append(("devices", "host device access support needs an apple/container runtime gap PR"))
        }
        if let gpus = service.gpus, !gpus.isEmpty {
            fields.append(("gpus", "GPU device access support needs an apple/container runtime gap PR"))
        }
        if service.privileged == true {
            fields.append(("privileged", "privileged mode support needs an apple/container runtime gap PR"))
        }
        return fields
    }

    /// Returns the runtime gap that prevents a dependency condition.
    func unsupportedDependencyConditionReason(_ condition: String) -> String {
        switch condition {
        case "service_healthy":
            "health status support needs an apple/container runtime gap PR"
        case "service_completed_successfully":
            "exit code and completion time need an apple/container runtime gap PR"
        default:
            "dependency condition support needs an apple/container runtime gap PR"
        }
    }

    /// Returns unsupported service metadata, attach, logging, and storage option fields.
    func unsupportedServiceMetadataAndLoggingFields(service: ComposeService) -> [(composeName: String, reason: String)] {
        var fields: [(composeName: String, reason: String)] = []
        if let annotations = service.annotations, !annotations.isEmpty {
            fields.append(("annotations", "service annotations are not implemented by container-compose yet"))
        }
        if service.attach != nil {
            fields.append(("attach", "service attach behavior is not implemented by container-compose yet"))
        }
        if service.logging != nil {
            fields.append(("logging", "service logging configuration is not implemented by container-compose yet"))
        }
        if let logDriver = service.logDriver, !logDriver.isEmpty {
            fields.append(("log_driver", "service logging configuration is not implemented by container-compose yet"))
        }
        if let logOptions = service.logOptions, !logOptions.isEmpty {
            fields.append(("log_opt", "service logging configuration is not implemented by container-compose yet"))
        }
        if let storageOptions = service.storageOptions, !storageOptions.isEmpty {
            fields.append(("storage_opt", "service storage options are not implemented by container-compose yet"))
        }
        return fields
    }

    /// Returns unsupported service-level volume inheritance and driver fields.
    func unsupportedServiceVolumeShortcutFields(service: ComposeService) -> [(composeName: String, reason: String)] {
        var fields: [(composeName: String, reason: String)] = []
        if let volumesFrom = service.volumesFrom, !volumesFrom.isEmpty {
            fields.append(("volumes_from", "volume inheritance is not implemented by container-compose yet"))
        }
        if let volumeDriver = service.volumeDriver, !volumeDriver.isEmpty {
            fields.append(("volume_driver", "service-level volume driver support is not implemented by container-compose yet"))
        }
        return fields
    }

    /// Returns unsupported long-form service mount fields that cannot be
    /// represented by the current Apple `container --volume/--tmpfs` mapping.
    func unsupportedServiceMountFields(service: ComposeService) -> [String]? {
        var seen = Set<String>()
        let fields = (service.volumes ?? []).flatMap { $0.unsupportedFields ?? [] }.filter { field in
            seen.insert(field).inserted
        }
        return fields.isEmpty ? nil : fields
    }

    /// Appends an unsupported string field only when Compose supplied a non-empty value.
    func appendUnsupportedStringField(
        _ composeName: String,
        value: String?,
        reason: String,
        to fields: inout [(composeName: String, value: String, reason: String)]
    ) {
        guard let value, !value.isEmpty else {
            return
        }
        fields.append((composeName, value, reason))
    }

    /// Appends an unsupported integer field only when Compose supplied a non-zero value.
    func appendUnsupportedIntegerField(
        _ composeName: String,
        value: Int?,
        reason: String,
        to fields: inout [(composeName: String, value: String, reason: String)]
    ) {
        guard let value, value != 0 else {
            return
        }
        fields.append((composeName, String(value), reason))
    }

    /// Appends an unsupported floating-point field only when Compose supplied a non-zero value.
    func appendUnsupportedFloatingPointField(
        _ composeName: String,
        value: Double?,
        reason: String,
        to fields: inout [(composeName: String, value: String, reason: String)]
    ) {
        guard let value, value != 0 else {
            return
        }
        let displayValue = value.rounded() == value ? String(Int(value)) : String(value)
        fields.append((composeName, displayValue, reason))
    }

    /// Validates the global `up --pull` policy before resources are created.
    func validatePullPolicy(_ policy: String?) throws {
        guard let policy, !policy.isEmpty else {
            return
        }
        if !["always", "missing", "if_not_present", "never"].contains(policy) {
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
        }
    }

    /// Validates the command-level `pull --policy` subset from Docker Compose.
    func validateComposePullPolicy(_ policy: String?) throws {
        guard let policy, !policy.isEmpty else {
            return
        }
        if !["always", "missing"].contains(policy) {
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
        }
    }

    /// Validates command-level `compose up` option combinations before runtime side effects.
    func validateUpOptions(_ options: ComposeUpOptions) throws {
        if options.build, options.noBuild {
            throw ComposeError.invalidProject("--build and --no-build are incompatible")
        }
        if options.forceRecreate, options.noRecreate {
            throw ComposeError.invalidProject("--force-recreate and --no-recreate are incompatible")
        }
        if !options.scales.isEmpty {
            throw ComposeError.unsupported("up --scale: service replica scaling is not implemented by container-compose yet")
        }
    }

    /// Validates command-level `compose create` option combinations before runtime side effects.
    func validateCreateOptions(_ options: ComposeCreateOptions) throws {
        if options.build, options.noBuild {
            throw ComposeError.invalidProject("--build and --no-build are incompatible")
        }
        if options.forceRecreate, options.noRecreate {
            throw ComposeError.invalidProject("--force-recreate and --no-recreate are incompatible")
        }
        if !options.scales.isEmpty {
            throw ComposeError.unsupported("create --scale: service replica scaling is not implemented by container-compose yet")
        }
    }

    /// Validates `create --pull`, including Docker Compose's build policy.
    func validateCreatePullPolicy(_ policy: String?) throws {
        guard let policy, !policy.isEmpty else {
            return
        }
        if !["always", "missing", "if_not_present", "never", "build"].contains(policy) {
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
        }
    }

    /// Validates `compose stats` options before invoking runtime stats.
    func validateStatsOptions(_ options: ComposeStatsOptions) throws {
        if options.noTrunc {
            throw ComposeError.unsupported("stats --no-trunc: apple/container stats does not expose truncation control")
        }
        if !["table", "json"].contains(options.format) {
            throw ComposeError.unsupported("stats --format '\(options.format)': apple/container stats supports table and json output")
        }
    }

    /// Validates service port mappings before resource creation.
    func validatePublishedPorts(services: [ComposeService]) throws {
        for service in services {
            try validatePublishedPorts(service.ports ?? [], serviceName: service.name)
        }
    }

    /// Validates one service's port mappings before they reach Apple `container`.
    func validatePublishedPorts(_ ports: [String], serviceName: String) throws {
        for port in ports {
            try validatePublishedPort(port, serviceName: serviceName)
        }
    }

    /// Rejects Docker Compose dynamic host-port allocation because Apple
    /// `container --publish` currently requires an explicit host port.
    func validatePublishedPort(_ value: String, serviceName: String) throws {
        let protocolSplit = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let rawBinding = protocolSplit.first, !rawBinding.isEmpty else {
            throw ComposeError.invalidProject("service '\(serviceName)' has an empty port mapping")
        }
        let protocolName = try normalizedPortProtocol(protocolSplit.count == 2 ? protocolSplit[1] : "tcp")
        let parts = rawBinding.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else {
            throw dynamicPortUnsupported(serviceName: serviceName, target: rawBinding, protocolName: protocolName)
        }

        let published = parts[parts.count - 2]
        guard isExplicitHostPort(published) else {
            throw dynamicPortUnsupported(serviceName: serviceName, target: parts.last ?? rawBinding, protocolName: protocolName)
        }
    }

    /// Returns true when a publish field names concrete Apple host ports.
    func isExplicitHostPort(_ value: String) -> Bool {
        let bounds = value.split(separator: "-", omittingEmptySubsequences: false)
        guard [1, 2].contains(bounds.count) else {
            return false
        }
        let ports = bounds.compactMap { UInt16($0) }
        guard ports.count == bounds.count, ports.allSatisfy({ $0 > 1 }) else {
            return false
        }
        return ports.count == 1 || ports[0] <= ports[1]
    }

    /// Creates the unsupported-feature error for dynamic host-port allocation.
    func dynamicPortUnsupported(serviceName: String, target: String, protocolName: String) -> ComposeError {
        .unsupported("service '\(serviceName)' publishes target port \(target)/\(protocolName) dynamically; apple/container publish requires explicit host ports")
    }

    /// Validates `compose exec` options before invoking runtime exec.
    func validateExecOptions(_ options: ComposeExecOptions) throws {
        if options.privileged {
            throw ComposeError.unsupported("exec --privileged: apple/container exec does not expose privileged process execution")
        }
    }

    /// Validates `compose cp` options before invoking runtime copy.
    func validateCopyOptions(_ options: ComposeCopyOptions) throws {
        if options.archive {
            throw ComposeError.unsupported("cp --archive: apple/container cp does not expose archive mode")
        }
        if options.followLink {
            throw ComposeError.unsupported("cp --follow-link: apple/container cp does not expose follow-link mode")
        }
    }

    /// Validates a Compose CLI shutdown timeout before runtime side effects.
    func validateTimeoutSeconds(_ timeout: Int?, command: String) throws {
        guard let timeout else {
            return
        }
        guard timeout >= 0, timeout <= Int(Int32.max) else {
            throw ComposeError.invalidProject("\(command) --timeout must be between 0 and \(Int32.max) seconds")
        }
    }

    /// Validates the `down --rmi` policy before removing resources.
    func downImageRemovalPolicy(_ policy: String?) throws -> DownImageRemovalPolicy {
        guard let policy else {
            return .none
        }
        switch policy {
        case "all":
            return .all
        case "local":
            return .local
        default:
            throw ComposeError.invalidProject("down --rmi must be 'all' or 'local'")
        }
    }

    /// Creates project networks and volumes required before containers start.
    func ensureResources(project: ComposeProject) async throws {
        for (name, network) in project.networks.sorted(by: { $0.key < $1.key }) where network.external != true {
            try await ensureNetwork(project: project, composeName: name, network: network)
        }
        for (name, volume) in project.volumes.sorted(by: { $0.key < $1.key }) where volume.external != true {
            try await ensureVolume(project: project, composeName: name, volume: volume)
        }
    }

    /// Creates a project network unless it already exists.
    func ensureNetwork(project: ComposeProject, composeName: String, network: ComposeNetwork) async throws {
        var args = ["network", "create"]
        if network.isInternal == true {
            args.append("--internal")
        }
        if let ipv4Subnet = network.ipv4Subnet, !ipv4Subnet.isEmpty {
            args.append(contentsOf: ["--subnet", ipv4Subnet])
        }
        if let ipv6Subnet = network.ipv6Subnet, !ipv6Subnet.isEmpty {
            args.append(contentsOf: ["--subnet-v6", ipv6Subnet])
        }
        for label in resourceLabels(project: project) {
            args.append(contentsOf: ["--label", label])
        }
        for label in (network.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(label.key)=\(label.value)"])
        }
        let runtimeName = networkRuntimeName(project: project, composeName: composeName, network: network)
        args.append(runtimeName)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await resourceManager.createNetwork(ComposeNetworkCreateRequest(
                name: runtimeName,
                isInternal: network.isInternal == true,
                ipv4Subnet: network.ipv4Subnet,
                ipv6Subnet: network.ipv6Subnet,
                labels: resourceLabels(project: project, labels: network.labels)
            ))
        }
    }

    /// Creates a project volume unless it already exists.
    func ensureVolume(project: ComposeProject, composeName: String, volume: ComposeVolume) async throws {
        var args = ["volume", "create"]
        for label in resourceLabels(project: project) {
            args.append(contentsOf: ["--label", label])
        }
        for label in (volume.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(label.key)=\(label.value)"])
        }
        let runtimeName = volumeRuntimeName(project: project, composeName: composeName, volume: volume)
        args.append(runtimeName)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await resourceManager.createVolume(name: runtimeName, labels: resourceLabels(project: project, labels: volume.labels))
        }
    }

    /// Translates one Compose build section into a `container build` command.
    func buildService(project: ComposeProject, service: ComposeService, options buildOptions: ComposeBuildOptions) async throws {
        guard let build = service.build else {
            return
        }
        try validateBuildSupport(service: service)
        var args = ["build"]
        guard let image = serviceImage(project: project, service: service) else {
            throw ComposeError.invalidProject("service '\(service.name)' has no image or build")
        }
        args.append(contentsOf: ["--tag", image])
        for tag in build.tags ?? [] where !tag.isEmpty && tag != image {
            args.append(contentsOf: ["--tag", tag])
        }
        if let dockerfile = build.dockerfile, !dockerfile.isEmpty {
            args.append(contentsOf: ["--file", dockerfile])
        }
        if let target = build.target, !target.isEmpty {
            args.append(contentsOf: ["--target", target])
        }
        if buildOptions.noCache || build.noCache == true {
            args.append("--no-cache")
        }
        if buildOptions.pull || build.pull == true {
            args.append("--pull")
        }
        if buildOptions.quiet {
            args.append("--quiet")
        }
        for platform in build.platforms ?? [] where !platform.isEmpty {
            args.append(contentsOf: ["--platform", platform])
        }
        for cacheSource in build.cacheFrom ?? [] where !cacheSource.isEmpty {
            args.append(contentsOf: ["--cache-in", cacheSource])
        }
        for cacheDestination in build.cacheTo ?? [] where !cacheDestination.isEmpty {
            args.append(contentsOf: ["--cache-out", cacheDestination])
        }
        for (key, value) in (build.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(key)=\(value)"])
        }
        for secret in build.secrets ?? [] {
            args.append(contentsOf: ["--secret", try buildSecretArgument(secret)])
        }
        for (key, value) in (build.args ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--build-arg", "\(key)=\(value)"])
        }
        args.append(build.context ?? ".")
        try await runContainer(args)
    }

    /// Encodes one Compose build secret for Apple `container build --secret`.
    func buildSecretArgument(_ secret: ComposeBuildSecret) throws -> String {
        let id = secret.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw ComposeError.invalidProject("build secret id must not be empty")
        }
        let file = secret.file?.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = secret.environment?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let file, !file.isEmpty, let environment, !environment.isEmpty {
            throw ComposeError.invalidProject("build secret '\(id)' cannot define both file and environment")
        }
        if let file, !file.isEmpty {
            return "id=\(id),src=\(file)"
        }
        if let environment, !environment.isEmpty {
            return "id=\(id),env=\(environment)"
        }
        throw ComposeError.invalidProject("build secret '\(id)' must define file or environment")
    }

    /// Applies the Compose `up --pull` policy before starting services.
    func applyPullPolicy(_ policy: String?, project: ComposeProject, services: [ComposeService]) async throws {
        guard let policy, !policy.isEmpty else {
            try await applyServicePullPolicies(services: services)
            return
        }

        switch policy {
        case "always":
            try await pull(project: project, services: services.map(\.name))
        case "missing", "if_not_present":
            try await pullMissingImages(services: services)
        case "never":
            return
        default:
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
        }
    }

    /// Applies `compose create` image preparation before creating containers.
    func applyCreateImagePolicy(_ create: ComposeCreateOptions, project: ComposeProject, services: [ComposeService]) async throws {
        if create.pullPolicy == "build" {
            guard !create.noBuild else {
                return
            }
            try await build(project: project, services: services.map(\.name), noCache: false, quiet: create.quietBuild)
            return
        }

        try await applyPullPolicy(create.pullPolicy, project: project, services: services)

        guard create.build, !create.noBuild else {
            return
        }
        try await build(project: project, services: services.map(\.name), noCache: false, quiet: create.quietBuild)
    }

    /// Returns whether `create` should auto-build a service before container creation.
    func shouldBuildServiceForCreate(_ create: ComposeCreateOptions, service: ComposeService) -> Bool {
        !create.noBuild && !create.build && create.pullPolicy != "build" && service.image == nil && service.build != nil
    }

    /// Returns whether `up` should auto-build a build-only service before start.
    func shouldBuildServiceForUp(_ up: ComposeUpOptions, service: ComposeService) -> Bool {
        !up.noBuild && !up.build && service.image == nil && service.build != nil
    }

    /// Applies service-level `pull_policy` when no global pull override is set.
    func applyServicePullPolicies(services: [ComposeService]) async throws {
        for service in services {
            guard let policy = service.pullPolicy, !policy.isEmpty else {
                continue
            }
            try await applyServicePullPolicy(policy, service: service)
        }
    }

    /// Applies the local-runtime-backed subset of Compose service pull policies.
    func applyServicePullPolicy(_ policy: String, service: ComposeService) async throws {
        guard let image = service.image else {
            return
        }
        switch policy {
        case "always":
            if options.dryRun {
                try await runContainer(["image", "pull", image])
            } else {
                try await imageManager.pullImage(image)
            }
        case "missing", "if_not_present":
            try await pullMissingImage(image)
        case "never":
            return
        default:
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)' for service '\(service.name)'")
        }
    }

    /// Applies `compose run` environment overrides to the copied service model.
    func applyRunEnvironmentOverrides(_ run: ComposeRunOptions, service: inout ComposeService) throws {
        if !run.environment.isEmpty {
            var environment = service.environment ?? [:]
            for override in run.environment {
                let parsed = try parseEnvironmentOverride(override)
                environment[parsed.key] = parsed.value
            }
            service.environment = environment
        }

        if !run.envFiles.isEmpty {
            service.envFiles = (service.envFiles ?? []) + run.envFiles
        }
    }

    /// Applies `compose run` volume overrides to the copied service model.
    func applyRunVolumeOverrides(_ run: ComposeRunOptions, project: inout ComposeProject, service: inout ComposeService) throws {
        guard !run.volumes.isEmpty else {
            return
        }

        var volumes = service.volumes ?? []
        for override in run.volumes {
            let parsed = try parseRunVolumeOverride(override)
            volumes.append(parsed.mount)
            if let name = parsed.namedVolume, project.volumes[name] == nil {
                project.volumes[name] = ComposeVolume(name: name)
            }
        }
        service.volumes = volumes
    }

    /// Parses Docker Compose `run --volume` short syntax.
    func parseRunVolumeOverride(_ override: String) throws -> (mount: ComposeMount, namedVolume: String?) {
        let parts = override.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            let target = parts[0]
            guard !target.isEmpty else {
                throw ComposeError.invalidProject("run --volume requires SOURCE:TARGET[:ro|rw] or TARGET")
            }
            return (ComposeMount(type: "volume", target: target), nil)
        case 2, 3:
            let source = parts[0]
            let target = parts[1]
            guard !source.isEmpty, !target.isEmpty else {
                throw ComposeError.invalidProject("run --volume requires SOURCE:TARGET[:ro|rw] or TARGET")
            }
            let readOnly = try parseRunVolumeMode(parts.count == 3 ? parts[2] : nil)
            if isBindVolumeSource(source) {
                return (ComposeMount(type: "bind", source: source, target: target, readOnly: readOnly), nil)
            }
            return (ComposeMount(type: "volume", source: source, target: target, readOnly: readOnly), source)
        default:
            throw ComposeError.invalidProject("run --volume requires SOURCE:TARGET[:ro|rw] or TARGET")
        }
    }

    /// Parses the optional access mode from `compose run --volume`.
    func parseRunVolumeMode(_ mode: String?) throws -> Bool {
        guard let mode, !mode.isEmpty else {
            return false
        }
        switch mode {
        case "ro", "readonly":
            return true
        case "rw":
            return false
        default:
            throw ComposeError.invalidProject("run --volume mode '\(mode)' is not supported; use ro or rw")
        }
    }

    /// Returns whether a `run --volume` source is a host bind path.
    func isBindVolumeSource(_ source: String) -> Bool {
        source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
    }

    /// Parses a Compose CLI environment override as `NAME` or `NAME=VALUE`.
    func parseEnvironmentOverride(_ override: String) throws -> (key: String, value: String?) {
        if let equalsIndex = override.firstIndex(of: "=") {
            let key = String(override[..<equalsIndex])
            guard !key.isEmpty else {
                throw ComposeError.invalidProject("run --env requires NAME or NAME=VALUE")
            }
            let value = String(override[override.index(after: equalsIndex)...])
            return (key, value)
        }

        guard !override.isEmpty else {
            throw ComposeError.invalidProject("run --env requires NAME or NAME=VALUE")
        }
        return (override, nil)
    }

    /// Parses `compose run --label` overrides while preserving CLI order.
    func parseRunLabelOverrides(_ overrides: [String]) throws -> [ComposeLabelOverride] {
        try overrides.map { override in
            let parsed: ComposeLabelOverride
            if let equalsIndex = override.firstIndex(of: "=") {
                let key = String(override[..<equalsIndex])
                guard !key.isEmpty else {
                    throw ComposeError.invalidProject("run --label requires KEY or KEY=VALUE")
                }
                let value = String(override[override.index(after: equalsIndex)...])
                parsed = ComposeLabelOverride(key: key, value: value)
            } else {
                guard !override.isEmpty else {
                    throw ComposeError.invalidProject("run --label requires KEY or KEY=VALUE")
                }
                parsed = ComposeLabelOverride(key: override, value: nil)
            }

            guard !reservedComposeLabelPrefixes.contains(where: { parsed.key.hasPrefix($0) }) else {
                throw ComposeError.invalidProject("run --label cannot override reserved Compose tracking label '\(parsed.key)'")
            }
            return parsed
        }
    }

    /// Pulls only service images not already present in the local image store.
    func pullMissingImages(services: [ComposeService]) async throws {
        for service in services {
            guard let image = service.image else {
                continue
            }
            try await pullMissingImage(image)
        }
    }

    /// Pulls one image when it is absent from the local image store.
    func pullMissingImage(_ image: String) async throws {
        let inspectArgs = ["image", "inspect", image]
        if options.dryRun {
            try await runContainer(inspectArgs, check: false, emitOutput: false)
            try await runContainer(["image", "pull", image])
        } else {
            try await imageManager.pullMissingImage(image)
        }
    }

    /// Builds the `container run` argument vector for a service.
    private func runArguments(
        project: ComposeProject,
        service: ComposeService,
        options run: RunArgumentOptions = RunArgumentOptions()
    ) throws -> [String] {
        var args = [run.command]
        let runtimeName = run.containerNameOverride.map(slug) ?? containerName(project: project, service: service, oneOff: run.oneOff)
        args.append(contentsOf: ["--name", runtimeName])
        if run.detach {
            args.append("--detach")
        }
        if run.remove {
            args.append("--rm")
        }

        for label in try serviceLabels(project: project, service: service, oneOff: run.oneOff) {
            args.append(contentsOf: ["--label", label])
        }
        let effectiveLabels = try effectiveServiceLabels(project: project, service: service)
        let overriddenLabelKeys = Set(run.labelOverrides.map(\.key))
        for (key, value) in effectiveLabels.sorted(by: { $0.key < $1.key }) where !overriddenLabelKeys.contains(key) {
            args.append(contentsOf: ["--label", "\(key)=\(value)"])
        }
        for label in run.labelOverrides {
            args.append(contentsOf: ["--label", label.rawValue])
        }
        for (key, value) in (service.environment ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let value {
                args.append(contentsOf: ["--env", "\(key)=\(value)"])
            } else {
                args.append(contentsOf: ["--env", key])
            }
        }
        for envFile in service.envFiles ?? [] {
            args.append(contentsOf: ["--env-file", envFile])
        }
        for port in run.publishedPorts ?? service.ports ?? [] {
            try validatePublishedPort(port, serviceName: service.name)
            args.append(contentsOf: ["--publish", port])
        }
        for mount in service.volumes ?? [] {
            try appendMount(mount, project: project, args: &args)
        }
        for tmpfs in service.tmpfs ?? [] {
            args.append(contentsOf: ["--tmpfs", tmpfs])
        }
        if isNoNetworkMode(service.networkMode) {
            args.append(contentsOf: ["--network", "none"])
        } else if let network = (service.networks ?? []).first {
            let networkArgument = try networkAttachmentArgument(project: project, service: service, network: network)
            args.append(contentsOf: ["--network", networkArgument])
        }
        if let platform = service.platform, !platform.isEmpty {
            args.append(contentsOf: ["--platform", platform])
        }
        if let runtime = service.runtime, !runtime.isEmpty {
            args.append(contentsOf: ["--runtime", runtime])
        }
        if let workingDir = service.workingDir {
            args.append(contentsOf: ["--workdir", workingDir])
        }
        if let user = service.user {
            args.append(contentsOf: ["--user", user])
        }
        if service.tty == true {
            args.append("--tty")
        }
        if service.stdinOpen == true {
            args.append("--interactive")
        }
        for cap in service.capAdd ?? [] {
            args.append(contentsOf: ["--cap-add", cap])
        }
        for cap in service.capDrop ?? [] {
            args.append(contentsOf: ["--cap-drop", cap])
        }
        for dns in service.dns ?? [] {
            args.append(contentsOf: ["--dns", dns])
        }
        for dnsSearch in service.dnsSearch ?? [] {
            args.append(contentsOf: ["--dns-search", dnsSearch])
        }
        for dnsOption in service.dnsOptions ?? [] {
            args.append(contentsOf: ["--dns-option", dnsOption])
        }
        if let memLimit = service.memLimit, !memLimit.isEmpty {
            args.append(contentsOf: ["--memory", memLimit])
        }
        if let cpus = service.cpus, !cpus.isEmpty {
            args.append(contentsOf: ["--cpus", cpus])
        }
        if let shmSize = service.shmSize, !shmSize.isEmpty {
            args.append(contentsOf: ["--shm-size", shmSize])
        }
        for ulimit in service.ulimits ?? [] {
            args.append(contentsOf: ["--ulimit", ulimit])
        }
        if let entrypoint = service.entrypoint, !entrypoint.isEmpty {
            args.append(contentsOf: ["--entrypoint", entrypoint.joined(separator: " ")])
        }
        if service.readOnly == true {
            args.append("--read-only")
        }
        if service.initEnabled == true {
            args.append("--init")
        }

        guard let image = serviceImage(project: project, service: service) else {
            throw ComposeError.invalidProject("service '\(service.name)' has no image or build")
        }
        args.append(image)
        args.append(contentsOf: service.command ?? [])
        return args
    }

    /// Rewrites `SERVICE:/path` copy operands to the matching service container.
    private func copyEndpoint(
        _ argument: String,
        project: ComposeProject,
        index: Int,
        includeOneOff: Bool
    ) async throws -> ComposeCopyEndpoint {
        guard let delimiter = argument.firstIndex(of: ":") else {
            return .local(argument)
        }
        let serviceName = String(argument[..<delimiter])
        guard isCopyServiceReference(serviceName) else {
            return .local(argument)
        }
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        let path = String(argument[argument.index(after: delimiter)...])
        guard path.hasPrefix("/") else {
            throw ComposeError.invalidProject("container copy path for service '\(serviceName)' must be absolute")
        }
        if includeOneOff {
            let containers = try await copyTargets(project: project, service: service, path: path, index: index)
            guard !containers.isEmpty else {
                throw ComposeError.invalidProject("no container found for service '\(serviceName)'")
            }
            return .containers(containers)
        }
        let id = try await serviceContainerID(project: project, service: service, index: index)
        return .containers([ComposeCopyContainerTarget(id: id, path: path)])
    }

    /// Returns service and one-off containers that can be targeted by `cp --all`.
    private func copyTargets(project: ComposeProject, service: ComposeService, path: String, index: Int) async throws -> [ComposeCopyContainerTarget] {
        let containers = try await projectContainers(projectName: project.name, all: true)
            .filter { $0.serviceName == service.name }
            .sorted(by: compareCopyTargetContainers)

        if index == 1 {
            return containers.map { ComposeCopyContainerTarget(id: $0.id, path: path) }
        }

        let indexedID = try serviceContainerName(project: project, service: service, index: index)
        guard serviceContainerExists(containers, service: service, id: indexedID) else {
            throw ComposeError.invalidProject("service '\(service.name)' container '\(indexedID)' does not exist")
        }
        return containers
            .filter { $0.id == indexedID || $0.isOneOff }
            .map { ComposeCopyContainerTarget(id: $0.id, path: path) }
    }

    /// Returns whether a copy operand prefix has Compose service-reference shape.
    private func isCopyServiceReference(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && value != "." && value != ".."
    }

    /// Starts dependency services for `compose run` before the one-off container.
    func startDependencyServices(project: ComposeProject, services: [ComposeService]) async throws {
        try await applyServicePullPolicies(services: services)
        for service in services {
            if service.image == nil, service.build != nil {
                try await build(project: project, services: [service.name], noCache: false)
            }

            let name = containerName(project: project, service: service, oneOff: false)
            let existing = try await inspectContainer(name)
            if let existing, existing.configHash == (try configHash(project: project, service: service)) {
                options.emit("compose: reusing existing container \(name)")
                continue
            }
            if existing != nil {
                try await stopContainer(service: service, containerName: name)
                try await deleteContainer(name)
            }

            try await runContainer(
                try runArguments(
                    project: project,
                    service: service,
                    options: RunArgumentOptions {
                        $0.detach = true
                    }
                )
            )
        }
    }

    /// Removes images referenced by services according to `down --rmi`.
    func removeImages(project: ComposeProject, policy: DownImageRemovalPolicy) async throws {
        for image in removableDownImages(project: project, policy: policy) {
            let args = ["image", "delete", "--force", image]
            if options.dryRun {
                try await runContainer(args, check: false)
            } else {
                try await imageManager.deleteImage(image, force: true, emit: options.emit)
            }
        }
    }

    /// Returns deterministic image references affected by `down --rmi`.
    func removableDownImages(project: ComposeProject, policy: DownImageRemovalPolicy) -> [String] {
        let images: [String]
        switch policy {
        case .none:
            images = []
        case .local:
            images = project.services.values.compactMap { generatedBuildImage(project: project, service: $0) }
        case .all:
            images = project.services.values.compactMap { serviceImage(project: project, service: $0) }
        }
        return Array(Set(images)).sorted()
    }

    /// Returns the runtime image reference for a service, including generated build tags.
    func serviceImage(project: ComposeProject, service: ComposeService) -> String? {
        service.image ?? generatedBuildImage(project: project, service: service)
    }

    /// Returns the generated image tag used for services that only declare `build`.
    func generatedBuildImage(project: ComposeProject, service: ComposeService) -> String? {
        guard service.build != nil, service.image == nil else {
            return nil
        }
        return "\(project.name)_\(service.name):latest"
    }

    /// Converts Compose's log tail value to a validated line count.
    func runtimeLogTail(_ tail: String?) throws -> Int? {
        guard let tail, !tail.isEmpty else {
            return nil
        }
        if tail.lowercased() == "all" {
            return nil
        }
        guard let lines = Int(tail), lines >= 0 else {
            throw ComposeError.invalidProject("logs --tail must be 'all' or a non-negative integer")
        }
        return lines
    }

    /// Validates that attach uses only the output stream Apple exposes through logs.
    func validateAttachOptions(_ attach: ComposeAttachOptions) throws {
        if attach.index != 1 {
            throw ComposeError.unsupported("attach --index \(attach.index): service replica attach needs replica-aware log lookup")
        }
        if let detachKeys = attach.detachKeys, !detachKeys.isEmpty {
            throw ComposeError.unsupported("attach --detach-keys: apple/container logs does not expose detach key handling")
        }
        if !attach.noStdin {
            throw ComposeError.unsupported("attach: apple/container logs is output-only; use --no-stdin --sig-proxy=false")
        }
        let sigProxy = attach.sigProxy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sigProxy != "false" {
            throw ComposeError.unsupported("attach --sig-proxy=\(attach.sigProxy): apple/container logs does not proxy signals to service processes; use --sig-proxy=false")
        }
    }

    /// Parses the `compose port` lookup target and protocol.
    func parsePortLookup(privatePort: String, protocolName: String) throws -> (target: String, protocolName: String) {
        let normalizedProtocol = try normalizedPortProtocol(protocolName)
        let parts = privatePort.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let target = parts.first, !target.isEmpty else {
            throw ComposeError.invalidProject("port requires a private container port")
        }
        guard !target.contains("-") else {
            throw ComposeError.invalidProject("port requires a single private container port")
        }
        if parts.count == 2 {
            let requestedProtocol = try normalizedPortProtocol(parts[1])
            guard requestedProtocol == normalizedProtocol else {
                throw ComposeError.invalidProject("port protocol '\(requestedProtocol)' conflicts with --protocol \(normalizedProtocol)")
            }
        }
        return (target, normalizedProtocol)
    }

    /// Finds the host port mapped to the requested single container port.
    func publishedPort(
        in ports: [ComposeContainerPublishedPort],
        target: String,
        protocolName: String
    ) -> ComposeContainerPublishedPort? {
        guard let targetPort = UInt16(target) else {
            return nil
        }
        for port in ports where port.protocolName == protocolName {
            let lowerBound = Int(port.containerPort)
            let upperBound = lowerBound + Int(port.count) - 1
            guard Int(targetPort) >= lowerBound, Int(targetPort) <= upperBound else {
                continue
            }
            let offset = Int(targetPort) - Int(port.containerPort)
            guard let hostPort = UInt16(exactly: Int(port.hostPort) + offset) else {
                return nil
            }
            return ComposeContainerPublishedPort(
                hostAddress: port.hostAddress,
                hostPort: hostPort,
                containerPort: targetPort,
                protocolName: port.protocolName,
                count: 1
            )
        }
        return nil
    }

    /// Emits a dry-run `port` answer from normalized Compose metadata.
    func emitDryRunPort(
        service: ComposeService,
        requested: (target: String, protocolName: String)
    ) throws {
        let ports = try (service.ports ?? []).flatMap {
            try dryRunPublishedPorts(from: $0, serviceName: service.name)
        }
        guard let mapping = publishedPort(in: ports, target: requested.target, protocolName: requested.protocolName) else {
            throw ComposeError.invalidProject("service '\(service.name)' does not publish target port \(requested.target)/\(requested.protocolName)")
        }
        options.emit("\(mapping.hostAddress):\(mapping.hostPort)")
    }

    /// Expands one explicit Compose port mapping for dry-run `port` previews.
    func dryRunPublishedPorts(from value: String, serviceName: String) throws -> [ComposeContainerPublishedPort] {
        let protocolSplit = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let rawBinding = protocolSplit.first, !rawBinding.isEmpty else {
            throw ComposeError.invalidProject("service '\(serviceName)' has an empty port mapping")
        }
        let protocolName = try normalizedPortProtocol(protocolSplit.count == 2 ? protocolSplit[1] : "tcp")
        let parts = rawBinding.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else {
            throw dynamicPortUnsupported(serviceName: serviceName, target: rawBinding, protocolName: protocolName)
        }

        let target = parts[parts.count - 1]
        let published = parts[parts.count - 2]
        let hostParts = parts.dropLast(2)
        let hostAddress = hostParts.isEmpty ? "0.0.0.0" : hostParts.joined(separator: ":")
        let hostRange = try portRange(published, field: "host", mapping: value, serviceName: serviceName)
        let targetRange = try portRange(target, field: "container", mapping: value, serviceName: serviceName)
        guard hostRange.count == targetRange.count else {
            throw ComposeError.invalidProject("service '\(serviceName)' has mismatched port ranges '\(value)'")
        }

        return (0..<hostRange.count).map { offset in
            ComposeContainerPublishedPort(
                hostAddress: hostAddress,
                hostPort: UInt16(hostRange.start + offset),
                containerPort: UInt16(targetRange.start + offset),
                protocolName: protocolName
            )
        }
    }

    /// Parses a single port or inclusive port range in a Compose mapping.
    func portRange(
        _ value: String,
        field: String,
        mapping: String,
        serviceName: String
    ) throws -> (start: Int, count: Int) {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard [1, 2].contains(parts.count),
              let start = parts.first.flatMap({ UInt16($0) }),
              start > 1
        else {
            throw ComposeError.invalidProject("service '\(serviceName)' has invalid \(field) port range '\(mapping)'")
        }
        if parts.count == 1 {
            return (Int(start), 1)
        }
        guard let end = UInt16(parts[1]), end >= start else {
            throw ComposeError.invalidProject("service '\(serviceName)' has invalid \(field) port range '\(mapping)'")
        }
        return (Int(start), Int(end - start + 1))
    }

    /// Normalizes Docker Compose port protocols accepted by `compose port`.
    func normalizedPortProtocol(_ value: String) throws -> String {
        switch value.lowercased() {
        case "tcp", "udp":
            return value.lowercased()
        default:
            throw ComposeError.invalidProject("port --protocol must be tcp or udp")
        }
    }

    /// Appends a Compose mount in the form accepted by `container run`.
    func appendMount(_ mount: ComposeMount, project: ComposeProject, args: inout [String]) throws {
        if mount.type == "tmpfs" {
            guard let target = mount.target else {
                throw ComposeError.invalidProject("tmpfs mount is missing target")
            }
            args.append(contentsOf: ["--tmpfs", target])
            return
        }
        guard let target = mount.target else {
            throw ComposeError.invalidProject("volume mount is missing target")
        }
        let source = mount.source ?? ""
        let mappedSource: String
        if mount.type == "volume", !source.isEmpty {
            mappedSource = volumeRuntimeName(project: project, composeName: source)
        } else if source.isEmpty {
            // Anonymous Compose volumes still need stable names so repeated
            // runs reconcile the same project-scoped container arguments.
            mappedSource = anonymousVolumeRuntimeName(project: project, target: target)
        } else {
            mappedSource = source
        }

        var value = "\(mappedSource):\(target)"
        if mount.readOnly == true {
            value += ":ro"
        }
        args.append(contentsOf: ["--volume", value])
    }

    /// Returns stable runtime names for anonymous volumes attached to services.
    func anonymousVolumeRuntimeNames(project: ComposeProject, services: [ComposeService]) -> [String] {
        let names = services.flatMap { service in
            (service.volumes ?? []).compactMap { mount -> String? in
                guard mount.type == "volume", mount.source?.isEmpty != false, let target = mount.target else {
                    return nil
                }
                return anonymousVolumeRuntimeName(project: project, target: target)
            }
        }
        return Array(Set(names)).sorted()
    }

    /// Returns the project-scoped name used for an anonymous Compose volume.
    func anonymousVolumeRuntimeName(project: ComposeProject, target: String) -> String {
        resourceName(project: project.name, name: "anon-\(stableHash(target).prefix(12))")
    }

    /// Starts a service container through the direct API while preserving
    /// dry-run command rendering.
    func startContainer(containerName: String) async throws {
        let args = ["start", containerName]
        if options.dryRun {
            try await runContainer(args)
        } else {
            try await lifecycleManager.startContainer(id: containerName)
        }
    }

    /// Stops a service container through the direct API while preserving
    /// dry-run command rendering.
    func stopContainer(service: ComposeService, containerName: String, timeout: Int? = nil) async throws {
        let args = stopArguments(service: service, containerName: containerName, timeout: timeout)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await lifecycleManager.stopContainer(
                id: containerName,
                signal: service.stopSignal,
                timeoutInSeconds: timeout ?? service.stopGracePeriodSeconds
            )
        }
    }

    /// Restarts a service container through the direct API.
    func restartContainer(service: ComposeService, containerName: String, timeout: Int? = nil) async throws {
        try await stopContainer(service: service, containerName: containerName, timeout: timeout)
        try await startContainer(containerName: containerName)
    }

    /// Stops a container that may not map to a declared service, such as an
    /// orphan container discovered from project labels.
    func stopContainer(id: String) async throws {
        let args = ["stop", id]
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await lifecycleManager.stopContainer(id: id, signal: nil, timeoutInSeconds: nil)
        }
    }

    /// Deletes a container through the direct API while preserving dry-run
    /// command rendering.
    func deleteContainer(_ id: String, force: Bool = false) async throws {
        var args = ["delete"]
        if force {
            args.append("--force")
        }
        args.append(id)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await lifecycleManager.deleteContainer(id: id, force: force)
        }
    }

    /// Returns the stop command arguments for a service container.
    func stopArguments(service: ComposeService, containerName: String, timeout: Int? = nil) -> [String] {
        var args = ["stop"]
        if let signal = service.stopSignal, !signal.isEmpty {
            args.append(contentsOf: ["--signal", signal])
        }
        if let seconds = timeout ?? service.stopGracePeriodSeconds {
            args.append(contentsOf: ["--time", "\(seconds)"])
        }
        args.append(containerName)
        return args
    }

    /// Returns true when a service asks to restart after a dependency that
    /// changed earlier in the current Compose operation.
    func shouldRestartAfterDependencyChange(service: ComposeService, changedServices: Set<String>) -> Bool {
        guard let dependsOn = service.dependsOn else {
            return false
        }
        return dependsOn.contains { dependency in
            dependency.value.restart && changedServices.contains(dependency.key)
        }
    }

    /// Returns an existing container's Compose metadata, if the container exists.
    func inspectContainer(_ name: String) async throws -> ExistingContainer? {
        if options.dryRun {
            try await runContainer(["inspect", name], check: false, emitOutput: false)
            return nil
        }
        guard let container = try await discoveryManager.getContainer(id: name) else {
            return nil
        }
        return ExistingContainer(configHash: container.configHash)
    }

    /// Removes project-scoped containers that are not in the declared set.
    func removeRemainingProjectContainers(project: ComposeProject, excluding declaredContainers: Set<String>) async throws {
        let args = ["list", "--format", "json", "--all"]
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let remainingContainers = try await projectContainers(projectName: project.name, all: true)
            .map(\.id)
            .filter { !declaredContainers.contains($0) }
            .sorted()
        for container in remainingContainers {
            try await stopContainer(id: container)
            try await deleteContainer(container)
        }
    }

    /// Lists containers scoped to a Compose project through the direct API.
    func projectContainers(projectName: String, all: Bool) async throws -> [ComposeContainerSummary] {
        let containers = try await discoveryManager.listContainers(all: all)
        return filterProjectContainers(projectName: projectName, containers: containers)
    }

    /// Lists project volume records through the direct resource API.
    func composeVolumeRecords(
        project: ComposeProject,
        services: [ComposeService],
        restrictToSelectedServices: Bool
    ) async throws -> [ComposeVolumeRecord] {
        let attachedVolumeNames = serviceAttachedVolumeRuntimeNames(project: project, services: services)
        let volumes = try await resourceManager.listVolumes()
        return volumes
            .filter { volume in
                if restrictToSelectedServices {
                    return attachedVolumeNames.contains(volume.name)
                }
                return volume.labels[projectLabel] == project.name || attachedVolumeNames.contains(volume.name)
            }
            .map { ComposeVolumeRecord(driver: $0.driver, name: $0.name) }
            .sorted { $0.name < $1.name }
    }

    /// Returns existing runtime volume names attached by the selected services.
    func serviceAttachedVolumeRuntimeNames(project: ComposeProject, services: [ComposeService]) -> Set<String> {
        var names = Set<String>()
        for service in services {
            for mount in service.volumes ?? [] where mount.type == "volume" {
                if let source = mount.source, !source.isEmpty {
                    names.insert(volumeRuntimeName(project: project, composeName: source))
                } else if let target = mount.target {
                    names.insert(anonymousVolumeRuntimeName(project: project, target: target))
                }
            }
        }
        return names
    }

    /// Executes one `container` command or prints it in dry-run mode.
    @discardableResult
    func runContainer(
        _ arguments: [String],
        check: Bool = true,
        emitOutput: Bool = true,
        inheritedIO: Bool = false
    ) async throws -> CommandResult {
        if options.dryRun {
            options.emit("+ " + shellQuoted([options.containerBinary] + arguments))
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        let result = try await runner.run(
            options.environmentLauncher,
            [options.containerBinary] + arguments,
            workingDirectory: nil,
            environment: nil,
            io: inheritedIO ? .inherited : .captured(input: nil)
        )
        if emitOutput, !inheritedIO {
            print(result.stdout, terminator: result.stdout.hasSuffix("\n") || result.stdout.isEmpty ? "" : "\n")
            fputs(result.stderr, stderr)
        }
        if check, !result.succeeded {
            throw ComposeError.commandFailed(
                command: shellQuoted([options.containerBinary] + arguments),
                status: result.status,
                stderr: result.stderr
            )
        }
        return result
    }
}

/// Minimal inspect result needed to decide whether an existing service
/// container can be reused.
private struct ExistingContainer {
    var configHash: String?
}

private extension ComposeNetworkOptions {
    /// Names the Compose fields that need runtime attachment support.
    func unsupportedFieldNames() throws -> [String] {
        var fields: [String] = []
        if let driverOpts, driverOpts.contains(where: { !networkMTUDriverOptionKeys.contains($0.key) }) {
            fields.append("driver_opts")
        }
        _ = try networkMTU()
        if let gatewayPriority, gatewayPriority != 0 {
            fields.append("gw_priority")
        }
        if let interfaceName, !interfaceName.isEmpty {
            fields.append("interface_name")
        }
        if let ipv4Address, !ipv4Address.isEmpty {
            fields.append("ipv4_address")
        }
        if let ipv6Address, !ipv6Address.isEmpty {
            fields.append("ipv6_address")
        }
        if let linkLocalIPs, !linkLocalIPs.isEmpty {
            fields.append("link_local_ips")
        }
        if let priority, priority != 0 {
            fields.append("priority")
        }
        return fields
    }

    /// Returns the supported MTU driver option value accepted by Apple `container`.
    func networkMTU() throws -> String? {
        let values = networkMTUDriverOptionKeys.compactMap { key -> (key: String, value: String)? in
            guard let value = driverOpts?[key] else {
                return nil
            }
            return (key, value)
        }
        guard let first = values.first else {
            return nil
        }
        if values.contains(where: { $0.value != first.value }) {
            throw ComposeError.invalidProject("network MTU driver options must not conflict")
        }
        guard let mtu = Int(first.value), mtu > 0 else {
            throw ComposeError.invalidProject("network MTU driver option '\(first.key)' must be a positive integer")
        }
        return String(mtu)
    }
}

/// Stable service/resource snapshot used to derive the recreate config hash.
private struct ServiceConfigFingerprint: Encodable {
    var service: ComposeService
    var networks: [String: String]
    var volumes: [String: String]
}

/// One label override passed to `compose run`.
private struct ComposeLabelOverride {
    var key: String
    var value: String?

    var rawValue: String {
        guard let value else {
            return key
        }
        return "\(key)=\(value)"
    }
}

private let projectLabel = "com.apple.container.compose.project"
private let serviceLabel = "com.apple.container.compose.service"
private let oneOffLabel = "com.apple.container.compose.oneoff"
private let configHashLabel = "com.apple.container.compose.config-hash"
private let workingDirectoryLabel = "com.apple.container.compose.project.working-directory"
private let configFilesLabel = "com.apple.container.compose.project.config-files"
private let configFilesHashLabel = "com.apple.container.compose.project.config-files-hash"
private let reservedComposeLabelPrefix = "com.apple.container.compose."
private let reservedDockerComposeLabelPrefix = "com.docker.compose."
private let reservedComposeLabelPrefixes = [reservedComposeLabelPrefix, reservedDockerComposeLabelPrefix]
private let networkMTUDriverOptionKeys = [
    "com.docker.network.driver.mtu",
    "mtu",
]

private extension ComposeContainerSummary {
    /// Compose project label attached to a runtime container.
    var projectName: String? {
        labels[projectLabel]
    }

    /// Compose service label attached to a runtime container.
    var serviceName: String? {
        labels[serviceLabel]
    }

    /// Whether this container was created by `compose run`.
    var isOneOff: Bool {
        labels[oneOffLabel] == "true"
    }

    /// Compose config hash label used for recreate decisions.
    var configHash: String? {
        labels[configHashLabel]
    }
}

/// Returns whether a service pull policy can be implemented with local runtime primitives.
private func isSupportedServicePullPolicy(_ policy: String) -> Bool {
    ["always", "missing", "if_not_present", "never"].contains(policy)
}

/// Returns the runtime resource name for a project-scoped network or volume.
private func resourceName(project: String, name: String) -> String {
    "\(slug(project))_\(slug(name))"
}

/// Resolves a Compose network reference to the name used by `container`.
private func networkRuntimeName(project: ComposeProject, composeName: String) -> String {
    guard let network = project.networks[composeName] else {
        return resourceName(project: project.name, name: composeName)
    }
    return networkRuntimeName(project: project, composeName: composeName, network: network)
}

/// Builds the single network attachment value accepted by Apple `container`.
private func networkAttachmentArgument(project: ComposeProject, service: ComposeService, network: String) throws -> String {
    var argument = networkRuntimeName(project: project, composeName: network)
    var options: [String] = []
    if let macAddress = networkMACAddress(service: service, network: network) {
        options.append("mac=\(macAddress)")
    }
    if let mtu = try service.networkOptions?[network]?.networkMTU() {
        options.append("mtu=\(mtu)")
    }
    if !options.isEmpty {
        argument += "," + options.joined(separator: ",")
    }
    return argument
}

/// Resolves the effective MAC address for a supported single-network service.
private func networkMACAddress(service: ComposeService, network: String) -> String? {
    nonEmpty(service.networkOptions?[network]?.macAddress) ?? nonEmpty(service.macAddress)
}

/// Returns a string value only when it contains meaningful content.
private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    return value
}

/// Resolves a normalized Compose network definition to its runtime name.
private func networkRuntimeName(project: ComposeProject, composeName: String, network: ComposeNetwork) -> String {
    declaredResourceName(
        projectName: project.name,
        composeName: composeName,
        declaredName: network.name,
        external: network.external == true
    )
}

/// Resolves a Compose volume reference to the name used by `container`.
private func volumeRuntimeName(project: ComposeProject, composeName: String) -> String {
    guard let volume = project.volumes[composeName] else {
        return resourceName(project: project.name, name: composeName)
    }
    return volumeRuntimeName(project: project, composeName: composeName, volume: volume)
}

/// Resolves a normalized Compose volume definition to its runtime name.
private func volumeRuntimeName(project: ComposeProject, composeName: String, volume: ComposeVolume) -> String {
    declaredResourceName(
        projectName: project.name,
        composeName: composeName,
        declaredName: volume.name,
        external: volume.external == true
    )
}

/// Uses normalized runtime resource names while falling back to generated
/// project-scoped names for hand-built test models.
private func declaredResourceName(projectName: String, composeName: String, declaredName: String, external: Bool) -> String {
    let normalizedName = declaredName.isEmpty ? composeName : declaredName
    if external || normalizedName != composeName {
        return slug(normalizedName)
    }
    return resourceName(project: projectName, name: composeName)
}

/// Returns labels shared by all resources in a Compose project.
private func resourceLabels(project: ComposeProject) -> [String] {
    [
        "\(projectLabel)=\(project.name)",
        "com.apple.container.compose.version=1",
        "\(workingDirectoryLabel)=\(project.workingDirectory)",
        "\(configFilesLabel)=\(project.composeFiles.joined(separator: ","))",
        "\(configFilesHashLabel)=\(composeFilesHash(project.composeFiles))",
    ]
}

/// Returns resource labels as a dictionary for direct API calls.
private func resourceLabels(project: ComposeProject, labels: [String: String]?) -> [String: String] {
    var merged = [
        projectLabel: project.name,
        "com.apple.container.compose.version": "1",
        workingDirectoryLabel: project.workingDirectory,
        configFilesLabel: project.composeFiles.joined(separator: ","),
        configFilesHashLabel: composeFilesHash(project.composeFiles),
    ]
    for (key, value) in labels ?? [:] {
        merged[key] = value
    }
    return merged
}

/// Returns labels that identify a service container and its config hash.
private func serviceLabels(project: ComposeProject, service: ComposeService, oneOff: Bool) throws -> [String] {
    var labels = resourceLabels(project: project)
    labels.append("\(serviceLabel)=\(service.name)")
    labels.append("\(oneOffLabel)=\(oneOff)")
    labels.append("\(configHashLabel)=\(try configHash(project: project, service: service))")
    if let firstFile = project.composeFiles.first {
        labels.append("com.apple.container.compose.project.config-file=\(firstFile)")
    }
    return labels
}

/// Hashes the compose file list in a stable order.
private func composeFilesHash(_ composeFiles: [String]) -> String {
    stableHash(composeFiles.sorted().joined(separator: "\n"))
}

/// Hashes the effective service configuration for recreate decisions.
private func configHash(project: ComposeProject, service: ComposeService) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var effectiveService = service
    effectiveService.labels = try effectiveServiceLabels(project: project, service: service)
    effectiveService.labelFiles = nil
    let fingerprint = ServiceConfigFingerprint(
        service: effectiveService,
        networks: serviceNetworkRuntimeNames(project: project, service: service),
        volumes: serviceVolumeRuntimeNames(project: project, service: service)
    )
    guard let data = try? encoder.encode(fingerprint) else {
        return stableHash(service.name)
    }
    return stableHash(String(decoding: data, as: UTF8.self))
}

/// Validates user-supplied service labels and label files before side effects.
private func validateServiceLabels(project: ComposeProject, service: ComposeService) throws {
    _ = try effectiveServiceLabels(project: project, service: service)
}

/// Returns the user labels applied to a service after processing label files.
private func effectiveServiceLabels(project: ComposeProject, service: ComposeService) throws -> [String: String] {
    var labels: [String: String] = [:]
    for file in service.labelFiles ?? [] {
        for (key, value) in try loadLabels(fromLabelFile: file, project: project, service: service) {
            labels[key] = value
        }
    }
    for (key, value) in service.labels ?? [:] {
        try validateUserLabelKey(key, source: "service '\(service.name)' label")
        labels[key] = value
    }
    return labels
}

/// Loads one Compose `label_file` using the env-file-like key-value syntax.
private func loadLabels(fromLabelFile path: String, project: ComposeProject, service: ComposeService) throws -> [String: String] {
    let url = labelFileURL(path, project: project)
    let contents: String
    do {
        contents = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw ComposeError.invalidProject("service '\(service.name)' label_file '\(path)' could not be read")
    }

    var labels: [String: String] = [:]
    for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        guard let label = try parseLabelFileLine(String(line), path: path, lineNumber: offset + 1, service: service) else {
            continue
        }
        labels[label.key] = label.value
    }
    return labels
}

/// Resolves label files relative to the normalized project directory.
private func labelFileURL(_ path: String, project: ComposeProject) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: project.workingDirectory, isDirectory: true)).absoluteURL
}

/// Parses one key-value line from a Compose label file.
private func parseLabelFileLine(
    _ line: String,
    path: String,
    lineNumber: Int,
    service: ComposeService
) throws -> (key: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
        return nil
    }

    let key: String
    let value: String
    if let equals = line.firstIndex(of: "=") {
        key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        key = trimmed
        value = ""
    }
    guard !key.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' label_file '\(path)' line \(lineNumber) has an empty label key")
    }
    try validateUserLabelKey(key, source: "service '\(service.name)' label_file '\(path)'")
    return (key, value)
}

/// Rejects labels that would conflict with Compose tracking metadata.
private func validateUserLabelKey(_ key: String, source: String) throws {
    guard !reservedComposeLabelPrefixes.contains(where: { key.hasPrefix($0) }) else {
        throw ComposeError.invalidProject("\(source) cannot set reserved Compose tracking label '\(key)'")
    }
}

/// Returns runtime network names that affect a service's run arguments.
private func serviceNetworkRuntimeNames(project: ComposeProject, service: ComposeService) -> [String: String] {
    var names: [String: String] = [:]
    for name in service.networks ?? [] {
        names[name] = networkRuntimeName(project: project, composeName: name)
    }
    return names
}

/// Returns runtime volume names that affect a service's run arguments.
private func serviceVolumeRuntimeNames(project: ComposeProject, service: ComposeService) -> [String: String] {
    var names: [String: String] = [:]
    for mount in service.volumes ?? [] where mount.type == "volume" {
        guard let source = mount.source, !source.isEmpty else {
            continue
        }
        names[source] = volumeRuntimeName(project: project, composeName: source)
    }
    return names
}

/// Returns pretty JSON for a filtered direct API container list.
private func containerListJSON(_ containers: [ComposeContainerSummary]) throws -> String {
    let scopedData = try JSONSerialization.data(withJSONObject: containers.map(containerListJSONObject), options: [.prettyPrinted, .sortedKeys])
    return String(decoding: scopedData, as: UTF8.self)
}

/// Builds the legacy `container list --format json` shape used by Compose projections.
private func containerListJSONObject(_ container: ComposeContainerSummary) -> [String: Any] {
    [
        "id": container.id,
        "configuration": [
            "image": [
                "reference": container.imageReference,
                "descriptor": [
                    "digest": container.imageDigest ?? "",
                ],
            ],
            "labels": container.labels,
            "platform": platformJSONObject(container.platform),
        ],
        "status": [
            "state": container.status,
        ],
    ]
}

/// Converts a platform string into the JSON object emitted by `container list`.
private func platformJSONObject(_ value: String) -> [String: String] {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else {
        return [:]
    }
    var object = [
        "os": parts[0],
        "architecture": parts[1],
    ]
    if parts.count >= 3, !parts[2].isEmpty {
        object["variant"] = parts[2]
    }
    return object
}

/// Returns container IDs from a filtered direct API list.
private func containerIdentifiers(_ containers: [ComposeContainerSummary]) -> [String] {
    containers.map(\.id)
}

/// Returns unique service names from a filtered direct API list.
private func containerServiceNames(_ containers: [ComposeContainerSummary]) -> [String] {
    let namesByContainer = containers.compactMap { container -> (identifier: String, service: String)? in
        guard let service = container.serviceName, !service.isEmpty else {
            return nil
        }
        return (container.id, service)
    }
    var seen: Set<String> = []
    var services: [String] = []
    for entry in namesByContainer.sorted(by: { $0.identifier < $1.identifier }) {
        if seen.insert(entry.service).inserted {
            services.append(entry.service)
        }
    }
    return services
}

/// Returns project rows from direct API containers, optionally filtered by project name.
private func composeProjectRecords(containers: [ComposeContainerSummary], nameFilters: [String]) -> [ComposeProjectRecord] {
    let containers = composeLabeledContainers(containers)
    let grouped = Dictionary(grouping: containers) { $0.projectName ?? "" }
    return grouped.keys.sorted().compactMap { projectName in
        guard !projectName.isEmpty, lsProjectNameMatches(projectName, filters: nameFilters) else {
            return nil
        }
        let projectContainers = grouped[projectName] ?? []
        return ComposeProjectRecord(
            name: projectName,
            status: combinedProjectStatus(projectContainers),
            configFiles: combinedProjectConfigFiles(projectContainers)
        )
    }
}

/// Returns direct API containers carrying the labels needed to identify Compose projects.
private func composeLabeledContainers(_ containers: [ComposeContainerSummary]) -> [ComposeContainerSummary] {
    containers.filter { $0.projectName != nil && $0.configHash != nil }
}

/// Combines direct API container states into Docker Compose's `state(count)` form.
private func combinedProjectStatus(_ containers: [ComposeContainerSummary]) -> String {
    let statuses = containers.map { $0.status.lowercased() }
    let counts = Dictionary(grouping: statuses, by: { $0 }).mapValues(\.count)
    return counts.keys.sorted().map { "\($0)(\(counts[$0] ?? 0))" }.joined(separator: ", ")
}

/// Combines config-file labels across direct API containers while preserving first-seen order.
private func combinedProjectConfigFiles(_ containers: [ComposeContainerSummary]) -> String {
    var seen: Set<String> = []
    var files: [String] = []
    for container in containers {
        let values = [
            container.labels[configFilesLabel],
            container.labels["com.apple.container.compose.project.config-file"],
        ].compactMap { $0 }
        for value in values {
            for file in value.split(separator: ",").map(String.init) where !file.isEmpty && seen.insert(file).inserted {
                files.append(file)
            }
        }
    }
    return files.isEmpty ? "N/A" : files.joined(separator: ",")
}

/// Returns image rows from direct API containers scoped by Compose labels.
private func composeImageRecords(containers: [ComposeContainerSummary], selectedServices: Set<String>?) -> [ComposeImageRecord] {
    containers.compactMap { container in
        guard let service = container.serviceName, !service.isEmpty else {
            return nil
        }
        if let selectedServices, !selectedServices.contains(service) {
            return nil
        }
        guard !container.imageReference.isEmpty else {
            return nil
        }
        let reference = splitImageReference(container.imageReference)
        return ComposeImageRecord(
            container: container.id,
            service: service,
            repository: reference.repository,
            tag: reference.tag,
            platform: container.platform,
            imageID: shortImageID(container.imageDigest)
        )
    }
    .sorted { lhs, rhs in
        if lhs.container == rhs.container {
            return lhs.service < rhs.service
        }
        return lhs.container < rhs.container
    }
}

/// Applies status filtering after direct API project scoping.
private func filterContainersByStatus(_ containers: [ComposeContainerSummary], statuses: Set<String>) -> [ComposeContainerSummary] {
    guard !statuses.isEmpty else {
        return containers
    }
    return containers.filter { statuses.contains($0.status.lowercased()) }
}

/// Filters direct API containers by Compose project label.
private func filterProjectContainers(projectName: String, containers: [ComposeContainerSummary]) -> [ComposeContainerSummary] {
    containers.filter { $0.projectName == projectName }
}

/// Returns true when a discovered normal service container matches an ID.
private func serviceContainerExists(_ containers: [ComposeContainerSummary], service: ComposeService, id: String) -> Bool {
    containers.contains { container in
        container.id == id && container.serviceName == service.name && !container.isOneOff
    }
}

/// Orders normal service containers before one-off `run` containers for `cp --all`.
private func compareCopyTargetContainers(_ lhs: ComposeContainerSummary, _ rhs: ComposeContainerSummary) -> Bool {
    if lhs.isOneOff != rhs.isOneOff {
        return !lhs.isOneOff
    }
    return lhs.id < rhs.id
}

/// Validates the `compose ls --format` value.
private func composeLsFormat(_ value: String) throws -> ComposeLsFormat {
    switch value.lowercased() {
    case "table":
        return .table
    case "json":
        return .json
    default:
        throw ComposeError.unsupported("ls --format '\(value)'; supported formats are table and json")
    }
}

/// Output modes supported by `compose ls`.
private enum ComposeLsFormat {
    case table
    case json
}

/// One Docker Compose-style project row derived from labeled containers.
private struct ComposeProjectRecord: Encodable, Equatable {
    let name: String
    let status: String
    let configFiles: String
}

/// Parses `compose ls --filter` values. Docker Compose currently accepts only `name`.
private func lsNameFilters(_ filters: [String]) throws -> [String] {
    try filters.map { filter in
        let parts = filter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw ComposeError.invalidProject("ls --filter must be in KEY=VALUE form")
        }
        let key = String(parts[0])
        let value = String(parts[1])
        guard key == "name" else {
            throw ComposeError.unsupported("ls --filter \(key); supported filter is name")
        }
        guard !value.isEmpty else {
            throw ComposeError.invalidProject("ls --filter name requires a value")
        }
        return value
    }
}

/// Applies Docker Compose's exact-name or regular-expression project name matching.
private func lsProjectNameMatches(_ name: String, filters: [String]) -> Bool {
    guard !filters.isEmpty else {
        return true
    }
    return filters.contains { filter in
        if name == filter {
            return true
        }
        return name.range(of: filter, options: .regularExpression) != nil
    }
}

/// Renders project rows as a compact table.
private func renderComposeProjectTable(_ records: [ComposeProjectRecord]) -> String {
    guard !records.isEmpty else {
        return ""
    }
    let rows = [
        ["NAME", "STATUS", "CONFIG FILES"],
    ] + records.map { [$0.name, $0.status, $0.configFiles] }
    let widths = rows.reduce(Array(repeating: 0, count: rows[0].count)) { current, row in
        zip(current, row).map { max($0, $1.count) }
    }
    return rows.map { row in
        row.enumerated().map { index, value in
            index == row.count - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

/// Renders project rows as deterministic JSON.
private func renderComposeProjectJSON(_ records: [ComposeProjectRecord]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(records)
    return String(decoding: data, as: UTF8.self)
}

/// Validates the `compose images --format` value.
private func composeImagesFormat(_ value: String) throws -> ComposeImagesFormat {
    switch value.lowercased() {
    case "table":
        return .table
    case "json":
        return .json
    default:
        throw ComposeError.unsupported("images --format '\(value)'; supported formats are table and json")
    }
}

/// One Docker Compose-style image row derived from a created project container.
private struct ComposeImageRecord: Encodable, Equatable {
    let container: String
    let service: String
    let repository: String
    let tag: String
    let platform: String
    let imageID: String
}

/// One Docker Compose-style volume row derived from Apple container volumes.
private struct ComposeVolumeRecord: Encodable, Equatable {
    let driver: String
    let name: String
}

/// Renders image rows as a compact table.
private func renderComposeImageTable(_ records: [ComposeImageRecord]) -> String {
    guard !records.isEmpty else {
        return ""
    }
    let rows = [
        ["CONTAINER", "REPOSITORY", "TAG", "IMAGE ID", "PLATFORM"],
    ] + records.map { record in
        [record.container, record.repository, record.tag, record.imageID.isEmpty ? "<none>" : record.imageID, record.platform]
    }
    let widths = rows.reduce(Array(repeating: 0, count: rows[0].count)) { current, row in
        zip(current, row).map { max($0, $1.count) }
    }
    return rows.map { row in
        row.enumerated().map { index, value in
            index == row.count - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

/// Renders image rows as deterministic JSON.
private func renderComposeImageJSON(_ records: [ComposeImageRecord]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(records)
    return String(decoding: data, as: UTF8.self)
}

/// Validates the `compose volumes --format` value.
private func composeVolumesFormat(_ value: String) throws -> ComposeVolumesFormat {
    switch value.lowercased() {
    case "table":
        return .table
    case "json":
        return .json
    default:
        throw ComposeError.unsupported("volumes --format '\(value)'; supported formats are table and json")
    }
}

/// Renders volume rows as a compact table.
private func renderComposeVolumeTable(_ records: [ComposeVolumeRecord]) -> String {
    guard !records.isEmpty else {
        return ""
    }
    let rows = [
        ["DRIVER", "VOLUME NAME"],
    ] + records.map { [$0.driver, $0.name] }
    let widths = rows.reduce(Array(repeating: 0, count: rows[0].count)) { current, row in
        zip(current, row).map { max($0, $1.count) }
    }
    return rows.map { row in
        row.enumerated().map { index, value in
            index == row.count - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

/// Renders volume rows as deterministic JSON.
private func renderComposeVolumeJSON(_ records: [ComposeVolumeRecord]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(records)
    return String(decoding: data, as: UTF8.self)
}

/// Splits a container image reference into repository and tag display fields.
private func splitImageReference(_ reference: String) -> (repository: String, tag: String) {
    let withoutDigest = reference.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? reference
    guard let lastColon = withoutDigest.lastIndex(of: ":") else {
        return (withoutDigest, "<none>")
    }
    if let lastSlash = withoutDigest.lastIndex(of: "/"), lastColon < lastSlash {
        return (withoutDigest, "<none>")
    }
    return (String(withoutDigest[..<lastColon]), String(withoutDigest[withoutDigest.index(after: lastColon)...]))
}

/// Returns the short Docker-style image ID without an algorithm prefix.
private func shortImageID(_ digest: String?) -> String {
    guard var digest, !digest.isEmpty else {
        return ""
    }
    if let colonIndex = digest.firstIndex(of: ":") {
        digest = String(digest[digest.index(after: colonIndex)...])
    }
    return String(digest.prefix(12))
}

/// Combines `ps --status` and `ps --filter status=...` into runtime state values.
private func psStatusFilters(statuses: [String], filters: [String]) throws -> Set<String> {
    var requestedStatuses = statuses
    for filter in filters {
        let parts = filter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw ComposeError.invalidProject("ps --filter must be in KEY=VALUE form")
        }
        let key = String(parts[0])
        let value = String(parts[1])
        guard key == "status" else {
            throw ComposeError.unsupported("ps --filter \(key); supported filter is status")
        }
        guard !value.isEmpty else {
            throw ComposeError.invalidProject("ps --filter status requires a value")
        }
        requestedStatuses.append(value)
    }
    return Set(try requestedStatuses.map(normalizedRuntimeStatus))
}

/// Maps Compose status vocabulary onto states exposed by `apple/container`.
private func normalizedRuntimeStatus(_ status: String) throws -> String {
    switch status.lowercased() {
    case "running", "stopped", "stopping", "unknown":
        return status.lowercased()
    case "exited":
        return "stopped"
    default:
        throw ComposeError.unsupported("ps status '\(status)'; apple/container exposes running, stopped, stopping, and unknown")
    }
}

/// Returns a SHA-256 hex digest for stable names and labels.
private func stableHash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Converts arbitrary Compose names into names accepted by runtime resources.
private func slug(_ value: String) -> String {
    var result = value.map { char -> Character in
        if char.isLetter || char.isNumber || char == "." || char == "_" || char == "-" {
            return char
        }
        return "-"
    }
    while let first = result.first, !(first.isLetter || first.isNumber) {
        result.removeFirst()
    }
    if result.isEmpty {
        return "compose"
    }
    return String(result)
}

/// Quotes a command line for dry-run output and error messages.
private func shellQuoted(_ parts: [String]) -> String {
    parts.map { part in
        if part.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=,".contains($0) }) {
            return part
        }
        return "'" + part.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}
