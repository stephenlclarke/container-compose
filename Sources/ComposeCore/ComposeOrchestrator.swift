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

/// Options for `compose up`.
public struct ComposeUpOptions {
    public var services: [String] = []
    public var build = false
    public var detach = false
    public var forceRecreate = false
    public var noRecreate = false
    public var removeOrphans = false
    public var pullPolicy: String?
    public var scales: [String] = []
    public var noDeps = false

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

/// Options for `compose images`.
public struct ComposeImagesOptions {
    public var quiet: Bool
    public var format: String

    public init(quiet: Bool = false, format: String = "table") {
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

/// Converts a normalized Compose project into deterministic `container`
/// commands.
public final class ComposeOrchestrator: @unchecked Sendable {
    private let runner: CommandRunning
    private let options: ComposeExecutionOptions

    public init(runner: CommandRunning = ProcessRunner(), options: ComposeExecutionOptions = ComposeExecutionOptions()) {
        self.runner = runner
        self.options = options
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
        let services = try up.noDeps && !up.services.isEmpty
            ? selectedServices(project: project, selected: up.services)
            : orderedServices(project: project, selected: up.services)
        let validateDependencies = !(up.noDeps && !up.services.isEmpty)
        try validatePullPolicy(up.pullPolicy)
        try validateRuntimeSupport(services: services, project: project, validateDependencies: validateDependencies)

        try await ensureResources(project: project)

        try await applyPullPolicy(up.pullPolicy, project: project, services: services)

        if up.build {
            try await build(project: project, services: services.map(\.name), noCache: false)
        }

        for service in services {
            if !up.build, service.image == nil, service.build != nil {
                try await build(project: project, services: [service.name], noCache: false)
            }

            let name = containerName(project: project, service: service, oneOff: false)
            let existing = try await inspectContainer(name)
            if let existing {
                // Reuse containers only when the Compose-derived service hash
                // still matches, unless the caller chose an explicit recreate
                // policy.
                if up.noRecreate {
                    options.emit("compose: reusing existing container \(name)")
                    continue
                }
                if !up.forceRecreate, existing.configHash == configHash(project: project, service: service) {
                    options.emit("compose: reusing existing container \(name)")
                    continue
                }
                try await runContainer(stopArguments(service: service, containerName: name), check: false)
                try await runContainer(["delete", name], check: false)
            }

            try await runContainer(
                runArguments(
                    project: project,
                    service: service,
                    options: RunArgumentOptions {
                        $0.detach = up.detach
                    }
                )
            )
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
        let services = try orderedServices(project: project, selected: create.services)
        try validateCreatePullPolicy(create.pullPolicy)
        try validateRuntimeSupport(services: services, project: project)

        try await ensureResources(project: project)

        try await applyCreateImagePolicy(create, project: project, services: services)

        for service in services {
            if shouldBuildServiceForCreate(create, service: service) {
                try await build(project: project, services: [service.name], noCache: false)
            }

            let name = containerName(project: project, service: service, oneOff: false)
            let existing = try await inspectContainer(name)
            if let existing {
                if create.noRecreate {
                    options.emit("compose: reusing existing container \(name)")
                    continue
                }
                if !create.forceRecreate, existing.configHash == configHash(project: project, service: service) {
                    options.emit("compose: reusing existing container \(name)")
                    continue
                }
                try await runContainer(stopArguments(service: service, containerName: name), check: false)
                try await runContainer(["delete", name], check: false)
            }

            try await runContainer(
                runArguments(
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

    /// Stops and removes project-scoped resources.
    public func down(project: ComposeProject, options down: ComposeDownOptions) async throws {
        try validateTimeoutSeconds(down.timeout, command: "down")
        let imageRemovalPolicy = try downImageRemovalPolicy(down.rmi)
        let services = try orderedServices(project: project, selected: [])
        let declaredContainers = Set(services.map { containerName(project: project, service: $0, oneOff: false) })
        for service in services.reversed() {
            let name = containerName(project: project, service: service, oneOff: false)
            try await runContainer(stopArguments(service: service, containerName: name, timeout: down.timeout), check: false)
            try await runContainer(["delete", name], check: false)
        }
        if down.removeOrphans {
            try await removeRemainingProjectContainers(project: project, excluding: declaredContainers)
        }

        for (name, network) in project.networks.sorted(by: { $0.key < $1.key }) where network.external != true {
            try await runContainer(["network", "delete", networkRuntimeName(project: project, composeName: name, network: network)], check: false)
        }

        if down.volumes {
            for (name, volume) in project.volumes.sorted(by: { $0.key < $1.key }) where volume.external != true {
                try await runContainer(["volume", "delete", volumeRuntimeName(project: project, composeName: name, volume: volume)], check: false)
            }
        }

        try await removeImages(project: project, policy: imageRemovalPolicy)
    }

    /// Builds images for services that declare a build section.
    public func build(project: ComposeProject, services selected: [String], noCache: Bool) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for service in services where service.build != nil {
            try await buildService(project: project, service: service, noCache: noCache)
        }
    }

    /// Pulls images for selected services.
    public func pull(project: ComposeProject, services selected: [String]) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for service in services {
            guard let image = service.image else { continue }
            try await runContainer(["image", "pull", image])
        }
    }

    /// Pushes images for selected services.
    public func push(project: ComposeProject, services selected: [String]) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for service in services {
            guard let image = service.image else { continue }
            try await runContainer(["image", "push", image])
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

        let result = try await runContainer(args, emitOutput: false)
        let records = try composeProjectRecords(output: result.stdout, nameFilters: nameFilters)
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
        let result = try await runContainer(args, emitOutput: false)
        let containers = try projectContainers(projectName: project.name, output: result.stdout)
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
                args.append(contentsOf: ["-n", runtimeTail])
            }
            args.append(containerName(project: project, service: service, oneOff: false))
            try await runContainer(args)
        }
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
        args.append(containerName(project: project, service: service, oneOff: false))
        args.append(contentsOf: exec.command)
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
        let labelOverrides = try parseRunLabelOverrides(run.labels)
        try validatePullPolicy(run.pullPolicy)
        let dependencyServices = try run.noDeps
            ? []
            : orderedServices(project: runProject, selected: [serviceName]).filter { $0.name != serviceName }
        try validateRuntimeSupport(services: dependencyServices + [service], project: runProject, validateDependencies: !run.noDeps)
        try await applyPullPolicy(run.pullPolicy, project: runProject, services: [service])
        try await ensureResources(project: runProject)
        try await startDependencyServices(project: runProject, services: dependencyServices)
        let publishedPorts = (run.servicePorts ? service.ports ?? [] : []) + run.publish
        try await runContainer(
            runArguments(
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
            try await runContainer(["start", containerName(project: project, service: service, oneOff: false)])
        }
    }

    /// Stops selected service containers.
    public func stop(project: ComposeProject, services selected: [String], timeout: Int? = nil) async throws {
        try validateTimeoutSeconds(timeout, command: "stop")
        for service in try selectedServices(project: project, selected: selected) {
            try await runContainer(
                stopArguments(service: service, containerName: containerName(project: project, service: service, oneOff: false), timeout: timeout),
                check: false
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
            var args = ["delete"]
            if force {
                args.append("--force")
            }
            args.append(containerName(project: project, service: service, oneOff: false))
            try await runContainer(args, check: false)
        }
        if volumes {
            for volume in anonymousVolumeRuntimeNames(project: project, services: services) {
                try await runContainer(["volume", "delete", volume], check: false)
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

        let result = try await runContainer(args, emitOutput: false)
        let records = try composeImageRecords(projectName: project.name, output: result.stdout, selectedServices: selectedServiceNames)
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
        args.append(contentsOf: services.map { containerName(project: project, service: $0, oneOff: false) })
        try await runContainer(args)
    }

    /// Sends a signal to selected service containers.
    public func kill(project: ComposeProject, services selected: [String], signal: String?) async throws {
        for service in try selectedServices(project: project, selected: selected) {
            var args = ["kill"]
            if let signal {
                args.append(contentsOf: ["--signal", signal])
            }
            args.append(containerName(project: project, service: service, oneOff: false))
            try await runContainer(args, check: false)
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
        let mappedArguments = try copy.arguments.map { try copyArgument($0, project: project) }
        try await runContainer(["cp"] + mappedArguments)
    }

    /// Prints the public address for a statically published service port.
    public func port(
        project: ComposeProject,
        serviceName: String,
        privatePort: String,
        protocolName: String,
        index: Int
    ) throws {
        guard index == 1 else {
            throw ComposeError.unsupported("port --index \(index): replica-aware published port lookup needs richer inspect output")
        }
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }

        let requested = try parsePortLookup(privatePort: privatePort, protocolName: protocolName)
        let mappings = try (service.ports ?? []).map { try parsePublishedPort($0, serviceName: service.name) }

        guard let mapping = mappings.first(where: { $0.target == requested.target && $0.protocolName == requested.protocolName && $0.published != nil }),
              let published = mapping.published
        else {
            if mappings.contains(where: { $0.target == requested.target && $0.protocolName == requested.protocolName && $0.published == nil }) {
                throw ComposeError.unsupported("service '\(service.name)' publishes target port \(requested.target)/\(requested.protocolName) dynamically; published port lookup needs richer inspect output")
            }
            throw ComposeError.invalidProject("service '\(service.name)' does not publish target port \(requested.target)/\(requested.protocolName)")
        }
        options.emit("\(mapping.hostIP ?? "0.0.0.0"):\(published)")
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

    /// Validates project-level invariants before runtime orchestration starts.
    func validate(project: ComposeProject) throws {
        guard !project.name.isEmpty else {
            throw ComposeError.invalidProject("project name is empty")
        }
        guard !project.services.isEmpty else {
            throw ComposeError.invalidProject("no services defined")
        }
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
                let fields = options.unsupportedFieldNames()
                if !fields.isEmpty {
                    let fieldList = fields.joined(separator: ", ")
                    throw ComposeError.unsupported("service '\(service.name)' uses network attachment options \(fieldList) on network '\(network)'; network attachment options need an apple/container runtime gap PR")
                }
            }
        }
        if let networkMode = service.networkMode, !networkMode.isEmpty {
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
        if let gap = unsupportedServiceVolumeShortcutFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        if service.useAPISocket == true {
            throw ComposeError.unsupported("service '\(service.name)' uses use_api_socket; API socket mounting is not implemented by container-compose yet")
        }
        if let macAddress = service.macAddress, !macAddress.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses mac_address '\(macAddress)'; MAC address support needs an apple/container runtime gap PR")
        }
        if validateDependencies, let dependsOn = service.dependsOn {
            for (dependency, metadata) in dependsOn.sorted(by: { $0.key < $1.key }) {
                if metadata.restart {
                    throw ComposeError.unsupported("service '\(service.name)' depends on '\(dependency)' with restart true; dependency restart propagation is not implemented by container-compose yet")
                }
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
        if let dnsOptions = service.dnsOptions, !dnsOptions.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses dns_opt; DNS option support needs an apple/container runtime gap PR")
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
        if let labelFiles = service.labelFiles, !labelFiles.isEmpty {
            fields.append(("label_file", "label file support is not implemented by container-compose yet"))
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

    /// Validates command-level `compose up` option combinations before runtime side effects.
    func validateUpOptions(_ options: ComposeUpOptions) throws {
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
        if options.services.count > 1 {
            throw ComposeError.invalidProject("stats accepts at most one service")
        }
        if options.all {
            throw ComposeError.unsupported("stats --all: apple/container stats only reports running containers")
        }
        if options.noTrunc {
            throw ComposeError.unsupported("stats --no-trunc: apple/container stats does not expose truncation control")
        }
        if !["table", "json"].contains(options.format) {
            throw ComposeError.unsupported("stats --format '\(options.format)': apple/container stats supports table and json output")
        }
    }

    /// Validates `compose exec` options before invoking runtime exec.
    func validateExecOptions(_ options: ComposeExecOptions) throws {
        if options.index != 1 {
            throw ComposeError.unsupported("exec --index: service replica exec needs replica-aware container lookup")
        }
        if options.privileged {
            throw ComposeError.unsupported("exec --privileged: apple/container exec does not expose privileged process execution")
        }
    }

    /// Validates `compose cp` options before invoking runtime copy.
    func validateCopyOptions(_ options: ComposeCopyOptions) throws {
        if options.all {
            throw ComposeError.unsupported("cp --all: copying from one-off run containers is not implemented by container-compose yet")
        }
        if options.archive {
            throw ComposeError.unsupported("cp --archive: apple/container cp does not expose archive mode")
        }
        if options.followLink {
            throw ComposeError.unsupported("cp --follow-link: apple/container cp does not expose follow-link mode")
        }
        if options.index != 1 {
            throw ComposeError.unsupported("cp --index \(options.index): service replica copy needs replica-aware container lookup")
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
        for label in resourceLabels(project: project) {
            args.append(contentsOf: ["--label", label])
        }
        for label in (network.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(label.key)=\(label.value)"])
        }
        args.append(networkRuntimeName(project: project, composeName: composeName, network: network))
        try await runContainer(args, check: false)
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
        args.append(volumeRuntimeName(project: project, composeName: composeName, volume: volume))
        try await runContainer(args, check: false)
    }

    /// Translates one Compose build section into a `container build` command.
    func buildService(project: ComposeProject, service: ComposeService, noCache: Bool) async throws {
        guard let build = service.build else {
            return
        }
        try validateBuildSupport(service: service)
        var args = ["build"]
        guard let image = serviceImage(project: project, service: service) else {
            throw ComposeError.invalidProject("service '\(service.name)' has no image or build")
        }
        args.append(contentsOf: ["--tag", image])
        if let dockerfile = build.dockerfile, !dockerfile.isEmpty {
            args.append(contentsOf: ["--file", dockerfile])
        }
        if let target = build.target, !target.isEmpty {
            args.append(contentsOf: ["--target", target])
        }
        if noCache || build.noCache == true {
            args.append("--no-cache")
        }
        for (key, value) in (build.args ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--build-arg", "\(key)=\(value)"])
        }
        args.append(build.context ?? ".")
        try await runContainer(args)
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
            try await build(project: project, services: services.map(\.name), noCache: false)
            return
        }

        try await applyPullPolicy(create.pullPolicy, project: project, services: services)

        guard create.build, !create.noBuild else {
            return
        }
        try await build(project: project, services: services.map(\.name), noCache: false)
    }

    /// Returns whether `create` should auto-build a service before container creation.
    func shouldBuildServiceForCreate(_ create: ComposeCreateOptions, service: ComposeService) -> Bool {
        !create.noBuild && !create.build && create.pullPolicy != "build" && service.image == nil && service.build != nil
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
            try await runContainer(["image", "pull", image])
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

            guard !parsed.key.hasPrefix(reservedComposeLabelPrefix) else {
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
        let inspect = try await runContainer(["image", "inspect", image], check: false, emitOutput: false)
        if options.dryRun || !inspect.succeeded {
            try await runContainer(["image", "pull", image])
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

        for label in serviceLabels(project: project, service: service, oneOff: run.oneOff) {
            args.append(contentsOf: ["--label", label])
        }
        let overriddenLabelKeys = Set(run.labelOverrides.map(\.key))
        for (key, value) in (service.labels ?? [:]).sorted(by: { $0.key < $1.key }) where !overriddenLabelKeys.contains(key) {
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
            args.append(contentsOf: ["--publish", port])
        }
        for mount in service.volumes ?? [] {
            try appendMount(mount, project: project, args: &args)
        }
        for tmpfs in service.tmpfs ?? [] {
            args.append(contentsOf: ["--tmpfs", tmpfs])
        }
        if let network = (service.networks ?? []).first {
            args.append(contentsOf: ["--network", networkRuntimeName(project: project, composeName: network)])
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

    /// Rewrites `SERVICE:path` copy operands to the matching service container.
    func copyArgument(_ argument: String, project: ComposeProject) throws -> String {
        guard let delimiter = argument.firstIndex(of: ":") else {
            return argument
        }
        let serviceName = String(argument[..<delimiter])
        guard isCopyServiceReference(serviceName) else {
            return argument
        }
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        return containerName(project: project, service: service, oneOff: false) + String(argument[delimiter...])
    }

    /// Returns whether a copy operand prefix has Compose service-reference shape.
    func isCopyServiceReference(_ value: String) -> Bool {
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
            if let existing, existing.configHash == configHash(project: project, service: service) {
                options.emit("compose: reusing existing container \(name)")
                continue
            }
            if existing != nil {
                try await runContainer(stopArguments(service: service, containerName: name), check: false)
                try await runContainer(["delete", name], check: false)
            }

            try await runContainer(
                runArguments(
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
            try await runContainer(["image", "delete", "--force", image], check: false)
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

    /// Converts Compose's log tail value to the runtime CLI value.
    func runtimeLogTail(_ tail: String?) throws -> String? {
        guard let tail, !tail.isEmpty else {
            return nil
        }
        if tail.lowercased() == "all" {
            return nil
        }
        guard let lines = Int(tail), lines >= 0 else {
            throw ComposeError.invalidProject("logs --tail must be 'all' or a non-negative integer")
        }
        return String(lines)
    }

    /// Parses the `compose port` lookup target and protocol.
    func parsePortLookup(privatePort: String, protocolName: String) throws -> (target: String, protocolName: String) {
        let normalizedProtocol = try normalizedPortProtocol(protocolName)
        let parts = privatePort.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let target = parts.first, !target.isEmpty else {
            throw ComposeError.invalidProject("port requires a private container port")
        }
        guard !target.contains("-") else {
            throw ComposeError.unsupported("port ranges need richer inspect output")
        }
        if parts.count == 2 {
            let requestedProtocol = try normalizedPortProtocol(parts[1])
            guard requestedProtocol == normalizedProtocol else {
                throw ComposeError.invalidProject("port protocol '\(requestedProtocol)' conflicts with --protocol \(normalizedProtocol)")
            }
        }
        return (target, normalizedProtocol)
    }

    /// Parses one normalized Compose port mapping.
    func parsePublishedPort(_ value: String, serviceName: String) throws -> ComposePublishedPort {
        let protocolSplit = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let rawBinding = protocolSplit.first, !rawBinding.isEmpty else {
            throw ComposeError.invalidProject("service '\(serviceName)' has an empty port mapping")
        }
        let protocolName = try normalizedPortProtocol(protocolSplit.count == 2 ? protocolSplit[1] : "tcp")
        let parts = rawBinding.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        switch parts.count {
        case 1:
            guard !parts[0].contains("-") else {
                throw ComposeError.unsupported("service '\(serviceName)' uses port range '\(value)'; port range lookup needs richer inspect output")
            }
            return ComposePublishedPort(hostIP: nil, published: nil, target: parts[0], protocolName: protocolName)
        case 2...:
            let target = parts[parts.count - 1]
            let published = parts[parts.count - 2]
            let hostParts = parts.dropLast(2)
            let hostIP = hostParts.isEmpty ? nil : hostParts.joined(separator: ":")
            guard !target.isEmpty, !published.isEmpty else {
                throw ComposeError.invalidProject("service '\(serviceName)' has unsupported port mapping '\(value)'")
            }
            guard !target.contains("-"), !published.contains("-") else {
                throw ComposeError.unsupported("service '\(serviceName)' uses port range '\(value)'; port range lookup needs richer inspect output")
            }
            return ComposePublishedPort(hostIP: hostIP?.isEmpty == true ? nil : hostIP, published: published, target: target, protocolName: protocolName)
        default:
            throw ComposeError.invalidProject("service '\(serviceName)' has unsupported port mapping '\(value)'")
        }
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

    /// Returns an existing container's Compose metadata, if the container exists.
    func inspectContainer(_ name: String) async throws -> ExistingContainer? {
        let result = try await runContainer(["inspect", name], check: false, emitOutput: false)
        if options.dryRun {
            return nil
        }
        guard result.succeeded else {
            return nil
        }
        return ExistingContainer(configHash: inspectConfigHash(from: result.stdout))
    }

    /// Removes project-scoped containers that are not in the declared set.
    func removeRemainingProjectContainers(project: ComposeProject, excluding declaredContainers: Set<String>) async throws {
        let args = ["list", "--format", "json", "--all"]
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let result = try await runContainer(args, emitOutput: false)
        let remainingContainers = try projectContainerIdentifiers(projectName: project.name, output: result.stdout)
            .filter { !declaredContainers.contains($0) }
            .sorted()
        for container in remainingContainers {
            try await runContainer(["stop", container], check: false)
            try await runContainer(["delete", container], check: false)
        }
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

/// Parsed representation of a Compose port mapping for static `port` lookups.
private struct ComposePublishedPort {
    var hostIP: String?
    var published: String?
    var target: String
    var protocolName: String
}

private extension ComposeNetworkOptions {
    /// Names the Compose fields that need runtime attachment support.
    func unsupportedFieldNames() -> [String] {
        var fields: [String] = []
        if let driverOpts, !driverOpts.isEmpty {
            fields.append("driver_opts")
        }
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
        if let macAddress, !macAddress.isEmpty {
            fields.append("mac_address")
        }
        if let priority, priority != 0 {
            fields.append("priority")
        }
        return fields
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
private let configHashLabel = "com.apple.container.compose.config-hash"
private let workingDirectoryLabel = "com.apple.container.compose.project.working-directory"
private let configFilesLabel = "com.apple.container.compose.project.config-files"
private let configFilesHashLabel = "com.apple.container.compose.project.config-files-hash"
private let reservedComposeLabelPrefix = "com.apple.container.compose."

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

/// Returns labels that identify a service container and its config hash.
private func serviceLabels(project: ComposeProject, service: ComposeService, oneOff: Bool) -> [String] {
    var labels = resourceLabels(project: project)
    labels.append("\(serviceLabel)=\(service.name)")
    labels.append("com.apple.container.compose.oneoff=\(oneOff)")
    labels.append("\(configHashLabel)=\(configHash(project: project, service: service))")
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
private func configHash(project: ComposeProject, service: ComposeService) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let fingerprint = ServiceConfigFingerprint(
        service: service,
        networks: serviceNetworkRuntimeNames(project: project, service: service),
        volumes: serviceVolumeRuntimeNames(project: project, service: service)
    )
    guard let data = try? encoder.encode(fingerprint) else {
        return stableHash(service.name)
    }
    return stableHash(String(decoding: data, as: UTF8.self))
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

/// Extracts the Compose config hash label from `container inspect` JSON.
private func inspectConfigHash(from output: String) -> String? {
    guard let data = output.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data)
    else {
        return nil
    }
    return inspectLabel(configHashLabel, in: json)
}

/// Recursively searches common inspect JSON shapes for one label value.
private func inspectLabel(_ key: String, in value: Any) -> String? {
    if let values = value as? [Any] {
        return values.lazy.compactMap { inspectLabel(key, in: $0) }.first
    }
    guard let object = value as? [String: Any] else {
        return nil
    }
    if let value = labelValue(key, in: object["labels"]) ?? labelValue(key, in: object["Labels"]) {
        return value
    }
    for nestedKey in ["configuration", "Config", "config"] {
        if let nested = object[nestedKey], let value = inspectLabel(key, in: nested) {
            return value
        }
    }
    return nil
}

/// Reads a label value from a JSON object when labels are map-shaped.
private func labelValue(_ key: String, in value: Any?) -> String? {
    guard let labels = value as? [String: Any] else {
        return nil
    }
    return labels[key] as? String
}

/// Returns pretty JSON for containers scoped to one Compose project.
private func projectContainerListJSON(projectName: String, output: String) throws -> String {
    try containerListJSON(projectContainers(projectName: projectName, output: output))
}

/// Returns pretty JSON for a filtered container list.
private func containerListJSON(_ containers: [Any]) throws -> String {
    let scopedData = try JSONSerialization.data(withJSONObject: containers, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: scopedData, as: UTF8.self)
}

/// Returns names or IDs for containers scoped to one Compose project.
private func projectContainerIdentifiers(projectName: String, output: String) throws -> [String] {
    try containerIdentifiers(projectContainers(projectName: projectName, output: output))
}

/// Returns names or IDs from a filtered container list.
private func containerIdentifiers(_ containers: [Any]) -> [String] {
    containers.compactMap(containerIdentifier)
}

/// Returns unique service names for containers scoped to one Compose project.
private func projectContainerServiceNames(projectName: String, output: String) throws -> [String] {
    try containerServiceNames(projectContainers(projectName: projectName, output: output))
}

/// Returns unique service names from a filtered container list.
private func containerServiceNames(_ containers: [Any]) -> [String] {
    let namesByContainer = containers.compactMap { container -> (identifier: String, service: String)? in
        guard let service = inspectLabel(serviceLabel, in: container), !service.isEmpty else {
            return nil
        }
        return (containerIdentifier(container) ?? service, service)
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

/// Returns project rows from `container list --format json`, optionally filtered by project name.
private func composeProjectRecords(output: String, nameFilters: [String]) throws -> [ComposeProjectRecord] {
    let containers = try composeLabeledContainers(output: output)
    let grouped = Dictionary(grouping: containers) { inspectLabel(projectLabel, in: $0) ?? "" }
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

/// Returns all containers carrying the labels needed to identify Compose projects.
private func composeLabeledContainers(output: String) throws -> [Any] {
    try listedContainers(output: output).filter {
        inspectLabel(projectLabel, in: $0) != nil && inspectLabel(configHashLabel, in: $0) != nil
    }
}

/// Parses raw `container list --format json` output into container JSON objects.
private func listedContainers(output: String) throws -> [Any] {
    guard let data = output.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data)
    else {
        throw ComposeError.invalidProject("container list returned invalid JSON")
    }

    let containers: [Any]
    if let values = json as? [Any] {
        containers = values
    } else if let value = json as? [String: Any] {
        containers = [value]
    } else {
        throw ComposeError.invalidProject("container list returned invalid JSON")
    }
    return containers
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

/// Combines per-container states into the `state(count)` form used by Docker Compose.
private func combinedProjectStatus(_ containers: [Any]) -> String {
    let statuses = containers.map { (containerRuntimeState($0) ?? "unknown").lowercased() }
    let counts = Dictionary(grouping: statuses, by: { $0 }).mapValues(\.count)
    return counts.keys.sorted().map { "\($0)(\(counts[$0] ?? 0))" }.joined(separator: ", ")
}

/// Combines config-file labels across project containers while preserving first-seen order.
private func combinedProjectConfigFiles(_ containers: [Any]) -> String {
    var seen: Set<String> = []
    var files: [String] = []
    for container in containers {
        let values = [
            inspectLabel(configFilesLabel, in: container),
            inspectLabel("com.apple.container.compose.project.config-file", in: container),
        ].compactMap { $0 }
        for value in values {
            for file in value.split(separator: ",").map(String.init) where !file.isEmpty && seen.insert(file).inserted {
                files.append(file)
            }
        }
    }
    return files.isEmpty ? "N/A" : files.joined(separator: ",")
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

/// Returns image rows from `container list --format json` scoped by Compose labels.
private func composeImageRecords(projectName: String, output: String, selectedServices: Set<String>?) throws -> [ComposeImageRecord] {
    try projectContainers(projectName: projectName, output: output).compactMap { container in
        guard let service = inspectLabel(serviceLabel, in: container), !service.isEmpty else {
            return nil
        }
        if let selectedServices, !selectedServices.contains(service) {
            return nil
        }
        guard let imageReference = containerImageReference(container), !imageReference.isEmpty else {
            return nil
        }
        let reference = splitImageReference(imageReference)
        return ComposeImageRecord(
            container: containerIdentifier(container) ?? service,
            service: service,
            repository: reference.repository,
            tag: reference.tag,
            platform: containerPlatform(container),
            imageID: shortImageID(containerImageDigest(container))
        )
    }
    .sorted { lhs, rhs in
        if lhs.container == rhs.container {
            return lhs.service < rhs.service
        }
        return lhs.container < rhs.container
    }
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

/// Extracts a container image reference from common `container list` JSON shapes.
private func containerImageReference(_ value: Any) -> String? {
    for path in [
        ["configuration", "image", "reference"],
        ["configuration", "image", "name"],
        ["Config", "Image"],
        ["config", "image"],
        ["Image"],
        ["image"],
    ] {
        if let value = stringValue(at: path, in: value), !value.isEmpty {
            return value
        }
    }
    return nil
}

/// Extracts an image digest from common `container list` JSON shapes.
private func containerImageDigest(_ value: Any) -> String? {
    for path in [
        ["configuration", "image", "descriptor", "digest"],
        ["configuration", "image", "digest"],
        ["Config", "ImageID"],
        ["ImageID"],
        ["imageID"],
        ["imageId"],
    ] {
        if let value = stringValue(at: path, in: value), !value.isEmpty {
            return value
        }
    }
    return nil
}

/// Extracts a platform string from common `container list` JSON shapes.
private func containerPlatform(_ value: Any) -> String {
    for path in [
        ["configuration", "platform"],
        ["Config", "Platform"],
        ["Platform"],
        ["platform"],
    ] {
        guard let platform = nestedValue(at: path, in: value) as? [String: Any] else {
            continue
        }
        let os = platform["os"] as? String ?? platform["OS"] as? String
        let architecture = platform["architecture"] as? String ?? platform["Architecture"] as? String
        let variant = platform["variant"] as? String ?? platform["Variant"] as? String
        guard let os, let architecture, !os.isEmpty, !architecture.isEmpty else {
            continue
        }
        if let variant, !variant.isEmpty {
            return "\(os)/\(architecture)/\(variant)"
        }
        return "\(os)/\(architecture)"
    }
    return ""
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

/// Reads a string from a nested JSON object path.
private func stringValue(at path: [String], in value: Any) -> String? {
    nestedValue(at: path, in: value) as? String
}

/// Reads a value from a nested JSON object path.
private func nestedValue(at path: [String], in value: Any) -> Any? {
    var current = value
    for key in path {
        guard let object = current as? [String: Any], let next = object[key] else {
            return nil
        }
        current = next
    }
    return current
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

/// Applies status filtering after project scoping.
private func filterContainersByStatus(_ containers: [Any], statuses: Set<String>) -> [Any] {
    guard !statuses.isEmpty else {
        return containers
    }
    return containers.filter { container in
        guard let state = containerRuntimeState(container) else {
            return false
        }
        return statuses.contains(state.lowercased())
    }
}

/// Filters raw `container list --format json` output by Compose project label.
private func projectContainers(projectName: String, output: String) throws -> [Any] {
    // `container list` does not currently expose a label filter in the CLI, so
    // Compose project scoping is applied client-side after requesting JSON.
    return try listedContainers(output: output).filter { inspectLabel(projectLabel, in: $0) == projectName }
}

/// Extracts the runtime state from common `container list --format json` shapes.
private func containerRuntimeState(_ value: Any) -> String? {
    guard let object = value as? [String: Any] else {
        return nil
    }
    for key in ["state", "State", "status", "Status"] {
        if let state = object[key] as? String {
            return state
        }
    }
    for nestedKey in ["state", "State", "status", "Status"] {
        if let nested = object[nestedKey], let state = containerRuntimeState(nested) {
            return state
        }
    }
    return nil
}

/// Extracts the most useful identifier from one container list object.
private func containerIdentifier(_ value: Any) -> String? {
    guard let object = value as? [String: Any] else {
        return nil
    }
    for key in ["id", "ID", "Id", "name", "Name"] {
        if let value = object[key] as? String, !value.isEmpty {
            return value
        }
    }
    if let names = object["Names"] as? [String] {
        return names.first { !$0.isEmpty }
    }
    return nil
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
