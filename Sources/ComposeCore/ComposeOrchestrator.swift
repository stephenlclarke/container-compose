import CryptoKit
import Foundation

public struct ComposeExecutionOptions {
    public var dryRun: Bool
    public var containerBinary: String
    public var emit: @Sendable (String) -> Void

    public init(
        dryRun: Bool = false,
        containerBinary: String = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container",
        emit: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.dryRun = dryRun
        self.containerBinary = containerBinary
        self.emit = emit
    }
}

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

public struct ComposeDownOptions {
    public var volumes: Bool
    public var removeOrphans: Bool

    public init(volumes: Bool = false, removeOrphans: Bool = false) {
        self.volumes = volumes
        self.removeOrphans = removeOrphans
    }
}

public final class ComposeOrchestrator: @unchecked Sendable {
    private let runner: CommandRunning
    private let options: ComposeExecutionOptions

    public init(runner: CommandRunning = ProcessRunner(), options: ComposeExecutionOptions = ComposeExecutionOptions()) {
        self.runner = runner
        self.options = options
    }

    public func config(project: ComposeProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        return String(decoding: data, as: UTF8.self)
    }

    public func up(project: ComposeProject, options up: ComposeUpOptions) async throws {
        try validate(project: project)
        let services = try orderedServices(project: project, selected: up.services)

        for (name, network) in project.networks.sorted(by: { $0.key < $1.key }) where network.external != true {
            try await ensureNetwork(project: project, composeName: name, network: network)
        }
        for (name, volume) in project.volumes.sorted(by: { $0.key < $1.key }) where volume.external != true {
            try await ensureVolume(project: project, composeName: name, volume: volume)
        }

        if up.pullPolicy == "always" {
            try await pull(project: project, services: services.map(\.name))
        }

        if up.build {
            try await build(project: project, services: services.map(\.name), noCache: false)
        }

        for service in services {
            try validateRuntimeSupport(project: project, service: service)
            if service.image == nil, service.build != nil {
                try await build(project: project, services: [service.name], noCache: false)
            }

            let name = containerName(project: project, service: service, oneOff: false)
            let exists = try await containerExists(name)
            if exists {
                if up.noRecreate {
                    options.emit("compose: reusing existing container \(name)")
                    continue
                }
                try await runContainer(["stop", name], check: false)
                try await runContainer(["delete", name], check: false)
            }

            try await runContainer(runArguments(project: project, service: service, detach: up.detach, remove: false, oneOff: false))
        }
    }

    public func down(project: ComposeProject, options down: ComposeDownOptions) async throws {
        let services = try orderedServices(project: project, selected: [])
        for service in services.reversed() {
            let name = containerName(project: project, service: service, oneOff: false)
            try await runContainer(["stop", name], check: false)
            try await runContainer(["delete", name], check: false)
        }

        for (name, network) in project.networks.sorted(by: { $0.key < $1.key }) where network.external != true {
            try await runContainer(["network", "delete", resourceName(project: project.name, name: name)], check: false)
        }

        if down.volumes {
            for (name, volume) in project.volumes.sorted(by: { $0.key < $1.key }) where volume.external != true {
                try await runContainer(["volume", "delete", resourceName(project: project.name, name: name)], check: false)
            }
        }
    }

    public func build(project: ComposeProject, services selected: [String], noCache: Bool) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for service in services where service.build != nil {
            try await buildService(project: project, service: service, noCache: noCache)
        }
    }

    public func pull(project: ComposeProject, services selected: [String]) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for service in services {
            guard let image = service.image else { continue }
            try await runContainer(["image", "pull", image])
        }
    }

    public func push(project: ComposeProject, services selected: [String]) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for service in services {
            guard let image = service.image else { continue }
            try await runContainer(["image", "push", image])
        }
    }

    public func ps(project: ComposeProject, all: Bool) async throws {
        var args = ["list", "--format", "json"]
        if all {
            args.append("--all")
        }
        try await runContainer(args)
    }

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
        try await runContainer(args)
    }

    public func run(project: ComposeProject, serviceName: String, command: [String], remove: Bool) async throws {
        guard var service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        if !command.isEmpty {
            service.command = command
        }
        try validateRuntimeSupport(project: project, service: service)
        try await runContainer(runArguments(project: project, service: service, detach: false, remove: remove, oneOff: true))
    }

    public func start(project: ComposeProject, services selected: [String]) async throws {
        for service in try selectedServices(project: project, selected: selected) {
            try await runContainer(["start", containerName(project: project, service: service, oneOff: false)])
        }
    }

    public func stop(project: ComposeProject, services selected: [String]) async throws {
        for service in try selectedServices(project: project, selected: selected) {
            try await runContainer(["stop", containerName(project: project, service: service, oneOff: false)], check: false)
        }
    }

    public func restart(project: ComposeProject, services selected: [String]) async throws {
        try await stop(project: project, services: selected)
        try await start(project: project, services: selected)
    }

    public func rm(project: ComposeProject, services selected: [String], stopFirst: Bool) async throws {
        let services = try selectedServices(project: project, selected: selected)
        if stopFirst {
            try await stop(project: project, services: services.map(\.name))
        }
        for service in services {
            try await runContainer(["delete", containerName(project: project, service: service, oneOff: false)], check: false)
        }
    }

    public func images(project: ComposeProject, services selected: [String]) throws -> [String] {
        try selectedServices(project: project, selected: selected).compactMap(\.image).sorted()
    }

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

    public func copy(arguments: [String]) async throws {
        guard !arguments.isEmpty else {
            throw ComposeError.invalidProject("cp requires source and destination")
        }
        try await runContainer(["cp"] + arguments)
    }

    public func unsupported(_ feature: String, reason: String) throws -> Never {
        throw ComposeError.unsupported("\(feature): \(reason)")
    }
}

public extension ComposeOrchestrator {
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

    func validate(project: ComposeProject) throws {
        guard !project.name.isEmpty else {
            throw ComposeError.invalidProject("project name is empty")
        }
        guard !project.services.isEmpty else {
            throw ComposeError.invalidProject("no services defined")
        }
    }

    func validateRuntimeSupport(project: ComposeProject, service: ComposeService) throws {
        let networks = service.networks ?? []
        if networks.count > 1 {
            throw ComposeError.unsupported("service '\(service.name)' declares multiple networks; Apple container does not expose network connect yet")
        }
        if let dependsOn = service.dependsOn {
            for (dependency, condition) in dependsOn where condition != "service_started" && condition != "" {
                throw ComposeError.unsupported("service '\(service.name)' depends on '\(dependency)' with condition '\(condition)'")
            }
        }
        if let extraHosts = service.extraHosts, !extraHosts.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses extra_hosts; host-entry support needs an apple/container runtime gap PR")
        }
        if service.privileged == true {
            throw ComposeError.unsupported("service '\(service.name)' uses privileged")
        }
    }

    func ensureNetwork(project: ComposeProject, composeName: String, network: ComposeNetwork) async throws {
        var args = ["network", "create"]
        for label in resourceLabels(project: project.name) {
            args.append(contentsOf: ["--label", label])
        }
        for label in (network.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(label.key)=\(label.value)"])
        }
        args.append(resourceName(project: project.name, name: composeName))
        try await runContainer(args, check: false)
    }

    func ensureVolume(project: ComposeProject, composeName: String, volume: ComposeVolume) async throws {
        var args = ["volume", "create"]
        for label in resourceLabels(project: project.name) {
            args.append(contentsOf: ["--label", label])
        }
        for label in (volume.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(label.key)=\(label.value)"])
        }
        args.append(resourceName(project: project.name, name: composeName))
        try await runContainer(args, check: false)
    }

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
            args.append(contentsOf: ["--network", resourceName(project: project.name, name: network)])
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
        if let entrypoint = service.entrypoint, !entrypoint.isEmpty {
            args.append(contentsOf: ["--entrypoint", entrypoint.joined(separator: " ")])
        }
        if service.readOnly == true {
            args.append("--read-only")
        }
        if service.`init` == true {
            args.append("--init")
        }

        guard let image = service.image ?? service.build.map({ _ in "\(project.name)_\(service.name):latest" }) else {
            throw ComposeError.invalidProject("service '\(service.name)' has no image or build")
        }
        args.append(image)
        args.append(contentsOf: service.command ?? [])
        return args
    }

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
            mappedSource = resourceName(project: project.name, name: source)
        } else if source.isEmpty {
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

    func containerExists(_ name: String) async throws -> Bool {
        let result = try await runContainer(["inspect", name], check: false, emitOutput: false)
        return result.succeeded
    }

    @discardableResult
    func runContainer(_ arguments: [String], check: Bool = true, emitOutput: Bool = true) async throws -> CommandResult {
        if options.dryRun {
            options.emit("+ " + shellQuoted([options.containerBinary] + arguments))
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        let result = try await runner.run("/usr/bin/env", [options.containerBinary] + arguments)
        if emitOutput {
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

private func resourceName(project: String, name: String) -> String {
    "\(slug(project))_\(slug(name))"
}

private func containerName(project: ComposeProject, service: ComposeService, oneOff: Bool) -> String {
    if !oneOff, let containerName = service.containerName, !containerName.isEmpty {
        return slug(containerName)
    }
    let suffix = oneOff ? "run-\(Int(Date().timeIntervalSince1970))" : "1"
    return "\(slug(project.name))-\(slug(service.name))-\(suffix)"
}

private func resourceLabels(project: String) -> [String] {
    [
        "com.apple.container.compose.project=\(project)",
        "com.apple.container.compose.version=1",
    ]
}

private func serviceLabels(project: ComposeProject, service: ComposeService, oneOff: Bool) -> [String] {
    var labels = resourceLabels(project: project.name)
    labels.append("com.apple.container.compose.service=\(service.name)")
    labels.append("com.apple.container.compose.oneoff=\(oneOff)")
    labels.append("com.apple.container.compose.config-hash=\(configHash(service))")
    if let firstFile = project.composeFiles.first {
        labels.append("com.apple.container.compose.project.config-file=\(firstFile)")
    }
    return labels
}

private func configHash(_ service: ComposeService) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(service) else {
        return stableHash(service.name)
    }
    return stableHash(String(decoding: data, as: UTF8.self))
}

private func stableHash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

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

private func shellQuoted(_ parts: [String]) -> String {
    parts.map { part in
        if part.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=,".contains($0) }) {
            return part
        }
        return "'" + part.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}
