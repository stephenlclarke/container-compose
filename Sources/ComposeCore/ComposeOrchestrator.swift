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
    public var services: [String]
    public var build: Bool
    public var detach: Bool
    public var forceRecreate: Bool
    public var noRecreate: Bool
    public var removeOrphans: Bool
    public var pullPolicy: String?

    public init(
        services: [String] = [],
        build: Bool = false,
        detach: Bool = true,
        forceRecreate: Bool = false,
        noRecreate: Bool = false,
        removeOrphans: Bool = false,
        pullPolicy: String? = nil
    ) {
        self.services = services
        self.build = build
        self.detach = detach
        self.forceRecreate = forceRecreate
        self.noRecreate = noRecreate
        self.removeOrphans = removeOrphans
        self.pullPolicy = pullPolicy
    }
}

/// Options for `compose down`.
public struct ComposeDownOptions {
    public var volumes: Bool
    public var removeOrphans: Bool

    public init(volumes: Bool = false, removeOrphans: Bool = false) {
        self.volumes = volumes
        self.removeOrphans = removeOrphans
    }
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
        let services = try orderedServices(project: project, selected: up.services)
        try validatePullPolicy(up.pullPolicy)
        try validateRuntimeSupport(services: services)

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

            try await runContainer(runArguments(project: project, service: service, detach: up.detach, remove: false, oneOff: false))
        }

        if up.removeOrphans {
            let declaredContainers = Set(project.services.values.map { containerName(project: project, service: $0, oneOff: false) })
            try await removeRemainingProjectContainers(project: project, excluding: declaredContainers)
        }
    }

    /// Stops and removes project-scoped resources.
    public func down(project: ComposeProject, options down: ComposeDownOptions) async throws {
        let services = try orderedServices(project: project, selected: [])
        let declaredContainers = Set(services.map { containerName(project: project, service: $0, oneOff: false) })
        for service in services.reversed() {
            let name = containerName(project: project, service: service, oneOff: false)
            try await runContainer(stopArguments(service: service, containerName: name), check: false)
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

    /// Lists containers belonging to the Compose project.
    public func ps(project: ComposeProject, all: Bool) async throws {
        var args = ["list", "--format", "json"]
        if all {
            args.append("--all")
        }
        if options.dryRun {
            try await runContainer(args)
            return
        }
        let result = try await runContainer(args, emitOutput: false)
        options.emit(try projectContainerListJSON(projectName: project.name, output: result.stdout))
    }

    /// Streams or prints logs for selected service containers.
    public func logs(project: ComposeProject, services selected: [String], follow: Bool, tail: Int?) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for service in services {
            var args = ["logs"]
            if follow {
                args.append("--follow")
            }
            if let tail {
                args.append(contentsOf: ["-n", String(tail)])
            }
            args.append(containerName(project: project, service: service, oneOff: false))
            try await runContainer(args)
        }
    }

    /// Executes a command in an existing service container.
    public func exec(project: ComposeProject, serviceName: String, command: [String], interactive: Bool, tty: Bool) async throws {
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        guard !command.isEmpty else {
            throw ComposeError.invalidProject("exec requires a command")
        }
        var args = ["exec"]
        if interactive {
            args.append("--interactive")
        }
        if tty {
            args.append("--tty")
        }
        args.append(containerName(project: project, service: service, oneOff: false))
        args.append(contentsOf: command)
        try await runContainer(args, inheritedIO: interactive || tty)
    }

    /// Runs a one-off container for a service.
    public func run(project: ComposeProject, serviceName: String, command: [String], remove: Bool) async throws {
        guard var service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        if !command.isEmpty {
            service.command = command
        }
        try validateRuntimeSupport(service: service)
        try await applyServicePullPolicies(services: [service])
        try await ensureResources(project: project)
        try await runContainer(
            runArguments(project: project, service: service, detach: false, remove: remove, oneOff: true),
            inheritedIO: service.tty == true || service.stdinOpen == true
        )
    }

    /// Starts selected service containers.
    public func start(project: ComposeProject, services selected: [String]) async throws {
        for service in try selectedServices(project: project, selected: selected) {
            try await runContainer(["start", containerName(project: project, service: service, oneOff: false)])
        }
    }

    /// Stops selected service containers.
    public func stop(project: ComposeProject, services selected: [String]) async throws {
        for service in try selectedServices(project: project, selected: selected) {
            try await runContainer(
                stopArguments(service: service, containerName: containerName(project: project, service: service, oneOff: false)),
                check: false
            )
        }
    }

    /// Restarts selected service containers.
    public func restart(project: ComposeProject, services selected: [String]) async throws {
        try await stop(project: project, services: selected)
        try await start(project: project, services: selected)
    }

    /// Removes selected service containers.
    public func rm(project: ComposeProject, services selected: [String], stopFirst: Bool) async throws {
        let services = try selectedServices(project: project, selected: selected)
        if stopFirst {
            try await stop(project: project, services: services.map(\.name))
        }
        for service in services {
            try await runContainer(["delete", containerName(project: project, service: service, oneOff: false)], check: false)
        }
    }

    /// Returns image names referenced by selected services.
    public func images(project: ComposeProject, services selected: [String]) throws -> [String] {
        try selectedServices(project: project, selected: selected).compactMap(\.image).sorted()
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

    /// Copies files using the underlying container CLI.
    public func copy(arguments: [String]) async throws {
        guard !arguments.isEmpty else {
            throw ComposeError.invalidProject("cp requires source and destination")
        }
        try await runContainer(["cp"] + arguments)
    }

    /// Throws a consistently formatted unsupported-feature error.
    public func unsupported(_ feature: String, reason: String) throws -> Never {
        throw ComposeError.unsupported("\(feature): \(reason)")
    }
}

public extension ComposeOrchestrator {
    /// Returns selected services after their dependencies using a stable
    /// depth-first traversal.
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
            for dependency in (service.dependsOn ?? [:]).keys.sorted() {
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
    func validateRuntimeSupport(service: ComposeService) throws {
        let networks = service.networks ?? []
        if networks.count > 1 {
            throw ComposeError.unsupported("service '\(service.name)' declares multiple networks; Apple container does not expose network connect yet")
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
        if let platform = service.platform, !platform.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses platform '\(platform)'; platform selection needs an apple/container runtime gap PR")
        }
        if let macAddress = service.macAddress, !macAddress.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses mac_address '\(macAddress)'; MAC address support needs an apple/container runtime gap PR")
        }
        if let dependsOn = service.dependsOn {
            for (dependency, condition) in dependsOn where condition != "service_started" && condition != "" {
                throw ComposeError.unsupported("service '\(service.name)' depends on '\(dependency)' with condition '\(condition)'")
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
        if service.privileged == true {
            throw ComposeError.unsupported("service '\(service.name)' uses privileged")
        }
        if let pullPolicy = service.pullPolicy, !pullPolicy.isEmpty, !isSupportedServicePullPolicy(pullPolicy) {
            throw ComposeError.unsupported("service '\(service.name)' uses pull_policy '\(pullPolicy)'; supported values are always, missing, if_not_present, and never")
        }
        if let restart = service.restart, !restart.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses restart policy '\(restart)'; restart policy support needs an apple/container runtime gap PR")
        }
    }

    /// Validates all selected services before any runtime side effects occur.
    func validateRuntimeSupport(services: [ComposeService]) throws {
        for service in services {
            try validateRuntimeSupport(service: service)
        }
    }

    /// Validates the global `up --pull` policy before resources are created.
    func validatePullPolicy(_ policy: String?) throws {
        guard let policy, !policy.isEmpty else {
            return
        }
        if !["always", "missing", "never"].contains(policy) {
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
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
        var args = ["build"]
        let image = service.image ?? "\(project.name)_\(service.name):latest"
        args.append(contentsOf: ["--tag", image])
        if let dockerfile = build.dockerfile, !dockerfile.isEmpty {
            args.append(contentsOf: ["--file", dockerfile])
        }
        if let target = build.target, !target.isEmpty {
            args.append(contentsOf: ["--target", target])
        }
        if noCache {
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
        case "missing":
            try await pullMissingImages(services: services)
        case "never":
            return
        default:
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
        }
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
    func runArguments(project: ComposeProject, service: ComposeService, detach: Bool, remove: Bool, oneOff: Bool) throws -> [String] {
        var args = ["run"]
        args.append(contentsOf: ["--name", containerName(project: project, service: service, oneOff: oneOff)])
        if detach {
            args.append("--detach")
        }
        if remove {
            args.append("--rm")
        }

        for label in serviceLabels(project: project, service: service, oneOff: oneOff) {
            args.append(contentsOf: ["--label", label])
        }
        for (key, value) in (service.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(key)=\(value)"])
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
        for port in service.ports ?? [] {
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

        guard let image = service.image ?? service.build.map({ _ in "\(project.name)_\(service.name):latest" }) else {
            throw ComposeError.invalidProject("service '\(service.name)' has no image or build")
        }
        args.append(image)
        args.append(contentsOf: service.command ?? [])
        return args
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
            mappedSource = resourceName(project: project.name, name: "anon-\(stableHash(target).prefix(12))")
        } else {
            mappedSource = source
        }

        var value = "\(mappedSource):\(target)"
        if mount.readOnly == true {
            value += ":ro"
        }
        args.append(contentsOf: ["--volume", value])
    }

    /// Returns the stop command arguments for a service container.
    func stopArguments(service: ComposeService, containerName: String) -> [String] {
        var args = ["stop"]
        if let signal = service.stopSignal, !signal.isEmpty {
            args.append(contentsOf: ["--signal", signal])
        }
        if let seconds = service.stopGracePeriodSeconds {
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

private struct ExistingContainer {
    var configHash: String?
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

private struct ServiceConfigFingerprint: Encodable {
    var service: ComposeService
    var networks: [String: String]
    var volumes: [String: String]
}

private let projectLabel = "com.apple.container.compose.project"
private let configHashLabel = "com.apple.container.compose.config-hash"
private let workingDirectoryLabel = "com.apple.container.compose.project.working-directory"
private let configFilesHashLabel = "com.apple.container.compose.project.config-files-hash"

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
        "\(configFilesHashLabel)=\(composeFilesHash(project.composeFiles))",
    ]
}

/// Returns labels that identify a service container and its config hash.
private func serviceLabels(project: ComposeProject, service: ComposeService, oneOff: Bool) -> [String] {
    var labels = resourceLabels(project: project)
    labels.append("com.apple.container.compose.service=\(service.name)")
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
    let scopedContainers = try projectContainers(projectName: projectName, output: output)
    let scopedData = try JSONSerialization.data(withJSONObject: scopedContainers, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: scopedData, as: UTF8.self)
}

/// Returns names or IDs for containers scoped to one Compose project.
private func projectContainerIdentifiers(projectName: String, output: String) throws -> [String] {
    try projectContainers(projectName: projectName, output: output).compactMap(containerIdentifier)
}

/// Filters raw `container list --format json` output by Compose project label.
private func projectContainers(projectName: String, output: String) throws -> [Any] {
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

    // `container list` does not currently expose a label filter in the CLI, so
    // Compose project scoping is applied client-side after requesting JSON.
    return containers.filter { inspectLabel(projectLabel, in: $0) == projectName }
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
