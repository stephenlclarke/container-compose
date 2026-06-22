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
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ContainerResource
import Foundation

/// Runtime settings used while translating Compose operations to `container`.
public struct ComposeExecutionOptions {
    public static let defaultEnvironmentLauncher = ["", "usr", "bin", "env"].joined(separator: "/")

    /// Runtime hooks that make orchestration deterministic and testable.
    public struct RuntimeHooks {
        public var oneOffIdentifier: @Sendable () -> String
        public var currentDate: @Sendable () -> Date
        public var hostPortAllocator: @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16
        public var sleep: @Sendable (Duration) async throws -> Void
        public var emit: @Sendable (String) -> Void
        public var emitData: (@Sendable (Data) -> Void)?

        public init(
            oneOffIdentifier: @escaping @Sendable () -> String = ComposeExecutionOptions.defaultOneOffIdentifier,
            currentDate: @escaping @Sendable () -> Date = Date.init,
            hostPortAllocator: @escaping @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16 = ComposeExecutionOptions.defaultHostPortAllocator,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            emit: @escaping @Sendable (String) -> Void = { print($0) },
            emitData: (@Sendable (Data) -> Void)? = nil
        ) {
            self.oneOffIdentifier = oneOffIdentifier
            self.currentDate = currentDate
            self.hostPortAllocator = hostPortAllocator
            self.sleep = sleep
            self.emit = emit
            self.emitData = emitData
        }
    }

    public var dryRun: Bool
    public var containerBinary: String
    public var environmentLauncher: String
    public var oneOffIdentifier: @Sendable () -> String
    public var currentDate: @Sendable () -> Date
    public var hostPortAllocator: @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16
    public var watchPollInterval: Duration
    public var sleep: @Sendable (Duration) async throws -> Void
    public var emit: @Sendable (String) -> Void
    public var emitData: @Sendable (Data) -> Void

    public init(
        dryRun: Bool = false,
        containerBinary: String = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container",
        environmentLauncher: String = ComposeExecutionOptions.defaultEnvironmentLauncher,
        watchPollInterval: Duration = .seconds(1),
        runtimeHooks: RuntimeHooks = RuntimeHooks()
    ) {
        self.dryRun = dryRun
        self.containerBinary = containerBinary
        self.environmentLauncher = environmentLauncher
        self.oneOffIdentifier = runtimeHooks.oneOffIdentifier
        self.currentDate = runtimeHooks.currentDate
        self.hostPortAllocator = runtimeHooks.hostPortAllocator
        self.watchPollInterval = watchPollInterval
        self.sleep = runtimeHooks.sleep
        self.emit = runtimeHooks.emit
        self.emitData = runtimeHooks.emitData ?? ComposeExecutionOptions.defaultLogDataEmitter
    }

    public init(dryRun: Bool = false, emit: @escaping @Sendable (String) -> Void) {
        self.init(dryRun: dryRun, runtimeHooks: RuntimeHooks(emit: emit, emitData: { emit(String(decoding: $0, as: UTF8.self)) }))
    }

    public init(hostPortAllocator: @escaping @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16) {
        self.init(runtimeHooks: RuntimeHooks(hostPortAllocator: hostPortAllocator))
    }

    public init(currentDate: @escaping @Sendable () -> Date) {
        self.init(runtimeHooks: RuntimeHooks(currentDate: currentDate))
    }

    public init(environmentLauncher: String) {
        self.init(environmentLauncher: environmentLauncher, runtimeHooks: RuntimeHooks())
    }

    public init(oneOffIdentifier: @escaping @Sendable () -> String) {
        self.init(runtimeHooks: RuntimeHooks(oneOffIdentifier: oneOffIdentifier))
    }

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.init(runtimeHooks: RuntimeHooks(sleep: sleep))
    }

    public init(
        watchPollInterval: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.init(
            watchPollInterval: watchPollInterval,
            runtimeHooks: RuntimeHooks(sleep: sleep)
        )
    }

    public init(
        dryRun: Bool,
        containerBinary: String,
        emit: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            dryRun: dryRun,
            containerBinary: containerBinary,
            runtimeHooks: RuntimeHooks(emit: emit, emitData: { emit(String(decoding: $0, as: UTF8.self)) })
        )
    }

    public init(
        dryRun: Bool,
        hostPortAllocator: @escaping @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16,
        emit: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            dryRun: dryRun,
            runtimeHooks: RuntimeHooks(hostPortAllocator: hostPortAllocator, emit: emit, emitData: { emit(String(decoding: $0, as: UTF8.self)) })
        )
    }

    public static func defaultOneOffIdentifier() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    /// Writes log bytes directly so container output can preserve non-UTF-8 payloads.
    public static func defaultLogDataEmitter(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([UInt8(ascii: "\n")]))
    }

    /// Allocates an ephemeral host port compatible with apple/container's
    /// explicit `--publish` requirement.
    public static func defaultHostPortAllocator(hostAddress: String?, protocolName: String) throws -> UInt16 {
        try HostPortAllocator(hostAddress: hostAddress, protocolName: protocolName).allocate()
    }
}

/// Allocates ephemeral host ports for Compose target-only published ports.
private struct HostPortAllocator {
    var hostAddress: String?
    var protocolName: String

    func allocate() throws -> UInt16 {
        let socketKind = try socketKind()
        if normalizedHostAddress.contains(":") {
            return try allocateIPv6(socketKind: socketKind)
        }
        return try allocateIPv4(socketKind: socketKind)
    }

    private var normalizedHostAddress: String {
        let value = hostAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.hasPrefix("["), value.hasSuffix("]") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private func socketKind() throws -> Int32 {
        switch protocolName.lowercased() {
        case "tcp":
            return SOCK_STREAM
        case "udp":
            return SOCK_DGRAM
        default:
            throw ComposeError.invalidProject("dynamic host-port allocation supports tcp and udp protocols, got '\(protocolName)'")
        }
    }

    private func allocateIPv4(socketKind: Int32) throws -> UInt16 {
        let descriptor = socket(AF_INET, socketKind, 0)
        guard descriptor >= 0 else {
            throw allocationError("socket")
        }
        defer {
            close(descriptor)
        }

        var address = sockaddr_in()
#if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        if normalizedHostAddress.isEmpty {
            address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        } else {
            guard inet_pton(AF_INET, normalizedHostAddress, &address.sin_addr) == 1 else {
                throw ComposeError.invalidProject("dynamic host-port allocation requires an IPv4 or IPv6 literal host address, got '\(normalizedHostAddress)'")
            }
        }

        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                guard bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw allocationError("bind")
                }
            }
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &bound) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                guard getsockname(descriptor, rebound, &length) == 0 else {
                    throw allocationError("getsockname")
                }
            }
        }
        return UInt16(bigEndian: bound.sin_port)
    }

    private func allocateIPv6(socketKind: Int32) throws -> UInt16 {
        let descriptor = socket(AF_INET6, socketKind, 0)
        guard descriptor >= 0 else {
            throw allocationError("socket")
        }
        defer {
            close(descriptor)
        }

        var address = sockaddr_in6()
#if canImport(Darwin)
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
#endif
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        if normalizedHostAddress.isEmpty {
            address.sin6_addr = in6addr_any
        } else {
            guard inet_pton(AF_INET6, normalizedHostAddress, &address.sin6_addr) == 1 else {
                throw ComposeError.invalidProject("dynamic host-port allocation requires an IPv4 or IPv6 literal host address, got '\(normalizedHostAddress)'")
            }
        }

        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                guard bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 else {
                    throw allocationError("bind")
                }
            }
        }

        var bound = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        try withUnsafeMutablePointer(to: &bound) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                guard getsockname(descriptor, rebound, &length) == 0 else {
                    throw allocationError("getsockname")
                }
            }
        }
        return UInt16(bigEndian: bound.sin6_port)
    }

    private func allocationError(_ operation: String) -> ComposeError {
        ComposeError.invalidProject("failed to allocate dynamic host port during \(operation): \(String(cString: strerror(errno)))")
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
    public var pullMetadataStore: ComposePullMetadataStoring

    public init(
        commands: ComposeOrchestratorCommandDependencies = ComposeOrchestratorCommandDependencies(),
        runtime: ComposeOrchestratorRuntimeDependencies = ComposeOrchestratorRuntimeDependencies(),
        imageManager: ContainerImageManaging = ContainerClientImageManager(),
        pullMetadataStore: ComposePullMetadataStoring = FileComposePullMetadataStore()
    ) {
        self.commands = commands
        self.runtime = runtime
        self.imageManager = imageManager
        self.pullMetadataStore = pullMetadataStore
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
    public var alwaysRecreateDeps = false
    public var noRecreate = false
    public var removeOrphans = false
    public var pullPolicy: String?
    public var scales: [String] = []
    public var noDeps = false
    public var noStart = false
    public var quietBuild = false
    public var quietPull = false
    public var timeout: Int?

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
    public var quietPull = false

    public init() {
        // Stored property defaults represent Docker Compose's default create behavior.
    }

    public init(_ configure: (inout ComposeCreateOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose scale`.
public struct ComposeScaleOptions {
    public var scales: [String] = []
    public var noDeps = false

    public init() {
        // Stored property defaults represent Docker Compose's default scale behavior.
    }

    public init(_ configure: (inout ComposeScaleOptions) -> Void) {
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

/// Options for `compose logs`.
public struct ComposeLogsOptions: Sendable {
    public var follow = false
    public var tail: String?
    public var index: Int?
    public var since: String?
    public var until: String?
    public var timestamps = false
    public var noLogPrefix = false
    public var colorPrefixes = false

    public init() {
        // Stored property defaults represent Docker Compose's default logs behavior.
    }

    public init(_ configure: (inout ComposeLogsOptions) -> Void) {
        configure(&self)
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

/// Options for `compose wait` commands.
public struct ComposeWaitOptions {
    public var services: [String]
    public var downProject: Bool

    public init(services: [String] = [], downProject: Bool = false) {
        self.services = services
        self.downProject = downProject
    }
}

/// Options for `compose watch` commands.
public struct ComposeWatchOptions {
    public var services: [String]
    public var noUp: Bool
    public var prune: Bool
    public var quiet: Bool

    public init(services: [String] = [], noUp: Bool = false, prune: Bool = true, quiet: Bool = false) {
        self.services = services
        self.noUp = noUp
        self.prune = prune
        self.quiet = quiet
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
    public var capAdd: [String] = []
    public var capDrop: [String] = []

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
    var containerIndex: Int?
    var replicaCount: Int?
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

private struct MountRenderContext {
    var project: ComposeProject
    var service: ComposeService
    var containerIndex: Int?
    var replicaCount: Int?
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

private struct ParsedPublishedPortMapping {
    var hostAddress: String?
    var hostRange: (start: Int, count: Int)?
    var targetRange: (start: Int, count: Int)
    var protocolName: String

    var usesDynamicHostPorts: Bool {
        hostRange == nil
    }
}

private enum ComposeVolumesFormat {
    case table
    case json
}

private enum RuntimeHealthCheckCommand {
    case disabled
    case command(String)
}

private struct ComposeCopyContainerTarget {
    var id: String
    var path: String

    var runtimeArgument: String {
        "\(id):\(path)"
    }
}

private struct ServiceContainerTarget {
    var service: ComposeService
    var index: Int
    var name: String
}

private struct ServiceContainerWaitResult {
    var exitCode: Int32
}

private struct ServiceContainerReconcileRequest {
    var name: String
    var runOptions: RunArgumentOptions
    var externalVolumeMounts: ExternalVolumeMounts = [:]
    var forceRecreate: Bool
    var noRecreate: Bool
    var dependencyRecreateServices: Set<String>
    var recreateTimeout: Int?
    var delayBeforeRecreate: Bool = false
}

private enum ServiceContainerReconcileOutcome {
    case unchanged
    case created
    case recreated

    var changed: Bool {
        self != .unchanged
    }

    var recreated: Bool {
        self == .recreated
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

private typealias ExternalVolumeMounts = [String: [ComposeMount]]

/// Compose provider lifecycle command.
private enum ComposeProviderAction: String {
    case up
    case down
    case stop
}

/// JSON message emitted by a Compose provider command.
private struct ComposeProviderMessage: Decodable {
    var type: String
    var message: String
}

/// Optional provider command metadata emitted by `compose metadata`.
private struct ComposeProviderMetadata: Decodable {
    var description: String? = nil
    var up: ComposeProviderCommandMetadata? = nil
    var down: ComposeProviderCommandMetadata? = nil
    var stop: ComposeProviderCommandMetadata? = nil

    var isEmpty: Bool {
        (description?.isEmpty ?? true) &&
            up?.parameters == nil &&
            down?.parameters == nil
    }

    func commandMetadata(for action: ComposeProviderAction) -> ComposeProviderCommandMetadata? {
        switch action {
        case .up:
            up
        case .down:
            down
        case .stop:
            stop
        }
    }
}

/// Parameter metadata for one provider lifecycle command.
private struct ComposeProviderCommandMetadata: Decodable {
    var parameters: [ComposeProviderParameterMetadata]?

    func parameter(named name: String) -> ComposeProviderParameterMetadata? {
        (parameters ?? []).first { $0.name == name }
    }
}

/// One provider command parameter advertised by provider metadata.
private struct ComposeProviderParameterMetadata: Decodable {
    var name: String
    var required: Bool?
}

/// Source of a parsed service-scoped `volumes_from` reference.
private enum ParsedVolumesFromSource {
    case service(String)
    case externalContainer(String)
}

/// Service-scoped `volumes_from` reference after parsing access mode.
private struct ParsedVolumesFromReference {
    var source: ParsedVolumesFromSource
    var readOnly: Bool?
    var rawValue: String
}

/// External `volumes_from` container reference that needs runtime inspection.
private struct ExternalVolumesFromReference {
    var serviceName: String
    var rawValue: String
    var containerName: String
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
    private let pullMetadataStore: ComposePullMetadataStoring
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
        self.pullMetadataStore = dependencies.pullMetadataStore
        self.resourceManager = dependencies.resourceManager
        self.statsManager = dependencies.statsManager
    }

    /// Returns whether a service declares `post_start` hooks.
    func hasPostStartHooks(_ service: ComposeService) -> Bool {
        !(service.postStart ?? []).isEmpty
    }

    /// Returns whether a service declares `pre_stop` hooks.
    func hasPreStopHooks(_ service: ComposeService) -> Bool {
        !(service.preStop ?? []).isEmpty
    }

    /// Returns whether a service declares any lifecycle hooks.
    func hasLifecycleHooks(_ service: ComposeService) -> Bool {
        hasPostStartHooks(service) || hasPreStopHooks(service)
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
            try await create(
                project: project,
                options: createOptions(from: up),
                alwaysRecreateDeps: up.alwaysRecreateDeps,
                recreateTimeout: up.timeout
            )
            return
        }
        var workingProject = project
        let services = try up.noDeps && !up.services.isEmpty
            ? selectedServices(project: project, selected: up.services)
            : orderedServices(project: project, selected: up.services)
        let scaleOverrides = try parseScaleOverrides(project: project, scales: up.scales)
        let dependencyRecreateServices = try servicesToRecreateBecauseDependencies(
            project: project,
            selected: up.services,
            noDeps: up.noDeps,
            alwaysRecreateDeps: up.alwaysRecreateDeps,
            services: services
        )
        let validateDependencies = !(up.noDeps && !up.services.isEmpty)
        try validatePullPolicy(up.pullPolicy)
        try validateRuntimeSupport(services: services, project: project, validateDependencies: validateDependencies)
        let externalVolumeMounts = try await resolveExternalVolumeMounts(project: project, services: services)
        try validatePublishedPorts(services: services)
        try validateReplicaSupport(services: services, scaleOverrides: scaleOverrides)
        let attachedForegroundService = try foregroundServiceTarget(project: project, services: services, scaleOverrides: scaleOverrides, detach: up.detach)
        try validateAttachedPostStartSupport(target: attachedForegroundService)

        try await ensureResources(project: project)

        try await applyPullPolicy(
            up.pullPolicy,
            project: project,
            services: services,
            quiet: up.quietPull,
            quietBuild: up.quietBuild,
            allowBuild: !up.noBuild && !up.build
        )

        if up.build {
            try await build(project: project, services: services.map(\.name), noCache: false, quiet: up.quietBuild)
        }

        var changedServices = Set<String>()
        for serviceReference in services {
            let service = workingProject.services[serviceReference.name] ?? serviceReference
            if validateDependencies {
                try await waitForDependencyConditions(project: workingProject, service: service)
            }
            if service.provider != nil {
                let variables = try await runProvider(project: workingProject, service: service, action: .up)
                if !variables.isEmpty {
                    workingProject = projectByInjectingProviderEnvironment(
                        project: workingProject,
                        providerServiceName: service.name,
                        variables: variables
                    )
                }
                changedServices.insert(service.name)
                continue
            }

            if shouldBuildServiceForUp(up, service: service) {
                try await build(project: workingProject, services: [service.name], noCache: false, quiet: up.quietBuild)
            }

            let replicaCount = try serviceReplicaCount(service, scaleOverrides: scaleOverrides)
            var serviceChanged = false
            if replicaCount > 0 {
                var priorReplicaRecreated = false
                for replicaIndex in 1...replicaCount {
                    let name = try serviceContainerName(project: workingProject, service: service, index: replicaIndex)
                    let reconcileOutcome = try await reconcileServiceContainer(
                        project: workingProject,
                        service: service,
                        request: ServiceContainerReconcileRequest(
                            name: name,
                            runOptions: RunArgumentOptions {
                                $0.detach = up.detach || attachedForegroundService?.name != name
                                $0.containerIndex = replicaIndex
                                $0.replicaCount = replicaCount
                            },
                            externalVolumeMounts: externalVolumeMounts,
                            forceRecreate: up.forceRecreate,
                            noRecreate: up.noRecreate,
                            dependencyRecreateServices: dependencyRecreateServices,
                            recreateTimeout: up.timeout,
                            delayBeforeRecreate: priorReplicaRecreated
                        )
                    )
                    serviceChanged = serviceChanged || reconcileOutcome.changed
                    if reconcileOutcome.recreated {
                        priorReplicaRecreated = true
                    }
                }
            }
            if shouldPruneServiceReplicas(service, scaleOverrides: scaleOverrides) {
                try await removeServiceReplicasAbove(project: project, service: service, desiredCount: replicaCount, timeout: up.timeout)
            }

            if serviceChanged {
                changedServices.insert(service.name)
                continue
            }
            if shouldRestartAfterDependencyChange(service: service, changedServices: changedServices) {
                let targets = try await serviceContainerTargets(project: project, services: [service])
                for target in targets {
                    try await restartContainer(service: service, containerName: target.name, timeout: up.timeout)
                }
                if !targets.isEmpty {
                    changedServices.insert(service.name)
                }
            }
        }

        if up.removeOrphans {
            let declaredContainers = try declaredServiceContainerNames(project: project, scaleOverrides: scaleOverrides)
            let preservedServices = orphanProtectedServiceNames(project: project, scaleOverrides: scaleOverrides)
            try await removeRemainingProjectContainers(
                project: project,
                excluding: declaredContainers,
                preservingServices: preservedServices,
                timeout: up.timeout
            )
        }
    }

    /// Reuses or recreates one deterministic service container.
    private func reconcileServiceContainer(
        project: ComposeProject,
        service: ComposeService,
        request: ServiceContainerReconcileRequest
    ) async throws -> ServiceContainerReconcileOutcome {
        let name = request.name
        let existing = try await inspectContainer(name)
        var didRecreate = false
        if let existing {
            if request.noRecreate {
                options.emit("compose: reusing existing container \(name)")
                return .unchanged
            }
            if !request.forceRecreate,
               !request.dependencyRecreateServices.contains(service.name),
               existing.configHash == (try configHash(
                   project: project,
                   service: service,
                   externalVolumeMounts: request.externalVolumeMounts
               )) {
                options.emit("compose: reusing existing container \(name)")
                return .unchanged
            }
            try await sleepBeforeDeployUpdateIfNeeded(service: service, enabled: request.delayBeforeRecreate)
            try await stopContainer(service: service, containerName: name, timeout: request.recreateTimeout)
            try await deleteContainer(name)
            didRecreate = true
        }

        try await runContainer(try runArguments(
            project: project,
            service: service,
            options: request.runOptions,
            externalVolumeMounts: request.externalVolumeMounts
        ))
        if request.runOptions.command == "run" {
            try await runPostStartHooks(service: service, containerID: name)
        }
        return didRecreate ? .recreated : .created
    }

    /// Applies a supported stop-first deploy update delay before the next local replica replacement.
    private func sleepBeforeDeployUpdateIfNeeded(service: ComposeService, enabled: Bool) async throws {
        guard enabled,
              !options.dryRun,
              let nanoseconds = service.deployUpdateDelayNanoseconds,
              nanoseconds > 0 else {
            return
        }
        try await options.sleep(.nanoseconds(nanoseconds))
    }

    /// Creates project resources and selected service containers without starting them.
    public func create(project: ComposeProject, options createOptions: ComposeCreateOptions) async throws {
        try await create(project: project, options: createOptions, alwaysRecreateDeps: false, recreateTimeout: nil)
    }

    /// Scales selected services through the detached `up` reconciliation path.
    public func scale(project: ComposeProject, options scale: ComposeScaleOptions) async throws {
        guard !scale.scales.isEmpty else {
            throw ComposeError.invalidProject("scale requires at least one SERVICE=REPLICAS argument")
        }
        let scaleOverrides = try parseScaleOverrides(project: project, scales: scale.scales)
        try await up(
            project: project,
            options: ComposeUpOptions {
                $0.services = scaleOverrides.keys.sorted()
                $0.scales = scale.scales
                $0.detach = true
                $0.noDeps = scale.noDeps
            }
        )
    }

    /// Creates project resources and selected service containers without starting them.
    private func create(
        project: ComposeProject,
        options create: ComposeCreateOptions,
        alwaysRecreateDeps: Bool,
        recreateTimeout: Int?
    ) async throws {
        try validate(project: project)
        try validateCreateOptions(create)
        let services = try create.noDeps && !create.services.isEmpty
            ? selectedServices(project: project, selected: create.services)
            : orderedServices(project: project, selected: create.services)
        let scaleOverrides = try parseScaleOverrides(project: project, scales: create.scales)
        let dependencyRecreateServices = try servicesToRecreateBecauseDependencies(
            project: project,
            selected: create.services,
            noDeps: create.noDeps,
            alwaysRecreateDeps: alwaysRecreateDeps,
            services: services
        )
        let validateDependencies = !(create.noDeps && !create.services.isEmpty)
        try validateCreatePullPolicy(create.pullPolicy)
        try validateRuntimeSupport(services: services, project: project, validateDependencies: validateDependencies)
        let externalVolumeMounts = try await resolveExternalVolumeMounts(project: project, services: services)
        try validatePublishedPorts(services: services)
        try validateReplicaSupport(services: services, scaleOverrides: scaleOverrides)

        try await ensureResources(project: project)

        try await applyCreateImagePolicy(create, project: project, services: services)

        for service in services {
            if shouldBuildServiceForCreate(create, service: service) {
                try await build(project: project, services: [service.name], noCache: false, quiet: create.quietBuild)
            }

            let replicaCount = try serviceReplicaCount(service, scaleOverrides: scaleOverrides)
            if replicaCount > 0 {
                var priorReplicaRecreated = false
                for replicaIndex in 1...replicaCount {
                    let name = try serviceContainerName(project: project, service: service, index: replicaIndex)
                    let reconcileOutcome = try await reconcileServiceContainer(
                        project: project,
                        service: service,
                        request: ServiceContainerReconcileRequest(
                            name: name,
                            runOptions: RunArgumentOptions {
                                $0.command = "create"
                                $0.containerIndex = replicaIndex
                                $0.replicaCount = replicaCount
                            },
                            externalVolumeMounts: externalVolumeMounts,
                            forceRecreate: create.forceRecreate,
                            noRecreate: create.noRecreate,
                            dependencyRecreateServices: dependencyRecreateServices,
                            recreateTimeout: recreateTimeout,
                            delayBeforeRecreate: priorReplicaRecreated
                        )
                    )
                    if reconcileOutcome.recreated {
                        priorReplicaRecreated = true
                    }
                }
            }
            if shouldPruneServiceReplicas(service, scaleOverrides: scaleOverrides) {
                try await removeServiceReplicasAbove(project: project, service: service, desiredCount: replicaCount, timeout: recreateTimeout)
            }
        }

        if create.removeOrphans {
            let declaredContainers = try declaredServiceContainerNames(project: project, scaleOverrides: scaleOverrides)
            let preservedServices = orphanProtectedServiceNames(project: project, scaleOverrides: scaleOverrides)
            try await removeRemainingProjectContainers(
                project: project,
                excluding: declaredContainers,
                preservingServices: preservedServices,
                timeout: recreateTimeout
            )
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
            $0.quietPull = up.quietPull
        }
    }

    /// Stops and removes project-scoped resources.
    public func down(project: ComposeProject, options down: ComposeDownOptions) async throws {
        try validateTimeoutSeconds(down.timeout, command: "down")
        let imageRemovalPolicy = try downImageRemovalPolicy(down.rmi)
        let services = try orderedServices(project: project, selected: [])
        let declaredContainers = try declaredServiceContainerNames(project: project, scaleOverrides: [:])
        let targets = try await serviceContainerTargets(project: project, services: services)
        for service in services.reversed() {
            if service.provider != nil {
                _ = try await runProvider(project: project, service: service, action: .down)
                continue
            }
            for target in targets.filter({ $0.service.name == service.name }).reversed() {
                try await stopContainer(service: service, containerName: target.name, timeout: down.timeout)
                try await deleteContainer(target.name)
            }
        }
        if down.removeOrphans {
            try await removeRemainingProjectContainers(project: project, excluding: declaredContainers, timeout: down.timeout)
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
            for volume in try anonymousVolumeRuntimeNames(project: project, targets: targets) {
                let args = ["volume", "delete", volume]
                if options.dryRun {
                    try await runContainer(args, check: false)
                } else {
                    try await resourceManager.deleteVolume(name: volume)
                }
            }
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
                    try await pullMissingImage(image, quiet: pull.quiet)
                } else {
                    try await pullImage(image, quiet: pull.quiet)
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
            emit = { _ in
                // `push --quiet` intentionally suppresses per-image status lines.
            }
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
    public func logs(
        project: ComposeProject,
        services selected: [String],
        options logOptions: ComposeLogsOptions = ComposeLogsOptions()
    ) async throws {
        let services = try selectedServices(project: project, selected: selected)
        let runtimeTail = try runtimeLogTail(logOptions.tail)
        let runtimeSince = try runtimeLogTimestamp(logOptions.since)
        let runtimeUntil = try runtimeLogTimestamp(logOptions.until)
        let targets = try await logTargets(project: project, services: services, index: logOptions.index)
        if options.dryRun {
            for target in targets {
                let args = logRuntimeArguments(
                    id: target.name,
                    follow: logOptions.follow,
                    tail: runtimeTail,
                    since: logOptions.since,
                    until: logOptions.until,
                    timestamps: logOptions.timestamps
                )
                try await runContainer(args)
            }
            return
        }
        if logOptions.follow, targets.count > 1 {
            try await followLogTargets(
                targets,
                tail: runtimeTail,
                since: runtimeSince,
                until: runtimeUntil,
                timestamps: logOptions.timestamps,
                noLogPrefix: logOptions.noLogPrefix,
                colorPrefixes: logOptions.colorPrefixes
            )
            return
        }
        for target in targets {
            try await emitLogs(
                for: target,
                follow: logOptions.follow,
                tail: runtimeTail,
                since: runtimeSince,
                until: runtimeUntil,
                timestamps: logOptions.timestamps,
                noLogPrefix: logOptions.noLogPrefix,
                colorPrefixes: logOptions.colorPrefixes
            )
        }
    }

    /// Renders direct runtime arguments for log dry-run output.
    private func logRuntimeArguments(id: String, follow: Bool, tail: Int?, since: String?, until: String?, timestamps: Bool) -> [String] {
        var args = ["logs"]
        if follow {
            args.append("--follow")
        }
        if let tail {
            args.append(contentsOf: ["-n", String(tail)])
        }
        if let since {
            args.append(contentsOf: ["--since", since])
        }
        if let until {
            args.append(contentsOf: ["--until", until])
        }
        if timestamps {
            args.append("--timestamps")
        }
        args.append(id)
        return args
    }

    /// Follows all selected log targets concurrently.
    private func followLogTargets(
        _ targets: [ServiceContainerTarget],
        tail: Int?,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        noLogPrefix: Bool,
        colorPrefixes: Bool
    ) async throws {
        let logManager = logManager
        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in targets {
                let containerID = target.name
                let emit = logEmitter(for: target, noLogPrefix: noLogPrefix, colorPrefixes: colorPrefixes)
                group.addTask { [containerID, emit, logManager, since, tail, timestamps, until] in
                    try await logManager.logs(
                        id: containerID,
                        tail: tail,
                        follow: true,
                        since: since,
                        until: until,
                        timestamps: timestamps,
                        emit: emit
                    )
                }
            }
            while try await group.next() != nil {}
        }
    }

    /// Emits static or single-target followed logs.
    private func emitLogs(
        for target: ServiceContainerTarget,
        follow: Bool,
        tail: Int?,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        noLogPrefix: Bool,
        colorPrefixes: Bool
    ) async throws {
        try await logManager.logs(
            id: target.name,
            tail: tail,
            follow: follow,
            since: since,
            until: until,
            timestamps: timestamps,
            emit: logEmitter(for: target, noLogPrefix: noLogPrefix, colorPrefixes: colorPrefixes)
        )
    }

    /// Returns the user-facing log emitter for a selected service target.
    private func logEmitter(
        for target: ServiceContainerTarget,
        noLogPrefix: Bool,
        colorPrefixes: Bool
    ) -> @Sendable (Data) -> Void {
        let emit = options.emitData
        guard !noLogPrefix else {
            return emit
        }
        let prefix = colorPrefixes ? colorizedLogPrefix(for: target) : logPrefix(for: target)
        let prefixData = Data("\(prefix) | ".utf8)
        return { output in
            let lines = recordsForCompleteLogData(output)
            var prefixed = Data()
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    prefixed.append(UInt8(ascii: "\n"))
                }
                prefixed.append(prefixData)
                prefixed.append(line)
            }
            emit(prefixed)
        }
    }

    /// Returns the ANSI-colored Compose log prefix for a selected service target.
    private func colorizedLogPrefix(for target: ServiceContainerTarget) -> String {
        let prefix = logPrefix(for: target)
        let code = logColorCode(for: target)
        return "\u{001B}[\(code)m\(prefix)\u{001B}[0m"
    }

    /// Returns the Compose log prefix for a selected service target.
    private func logPrefix(for target: ServiceContainerTarget) -> String {
        if let containerName = target.service.containerName, !containerName.isEmpty {
            return containerName
        }
        guard target.index != Int.max else {
            return target.name
        }
        return "\(target.service.name)-\(target.index)"
    }

    /// Returns a deterministic ANSI foreground color code for a log target.
    private func logColorCode(for target: ServiceContainerTarget) -> String {
        let palette = ["36", "32", "33", "35", "34", "31"]
        let replicaSeed = target.index == Int.max ? 0 : target.index
        let seed = target.service.name.unicodeScalars.reduce(replicaSeed) { partial, scalar in
            partial + Int(scalar.value)
        }
        return palette[seed % palette.count]
    }

    /// Runs `compose watch` by applying initial syncs and polling watched paths
    /// for Compose Develop Specification actions.
    public func watch(project: ComposeProject, options watch: ComposeWatchOptions = ComposeWatchOptions()) async throws {
        let services = try selectedServices(project: project, selected: watch.services)
        let watchServices = services.filter { service in
            guard let triggers = service.develop?.watch else {
                return false
            }
            return !triggers.isEmpty
        }
        guard !watchServices.isEmpty else {
            let selected = watch.services.isEmpty ? "project" : "selected services"
            throw ComposeError.invalidProject("\(selected) does not declare develop.watch triggers")
        }
        try validateWatchTriggers(services: watchServices)
        if options.dryRun {
            emitWatchDryRunPlan(project: project, services: watchServices, watch: watch)
            return
        }

        let runtimeProject = projectWithoutDevelopMetadata(project)
        let runtimeServices = try watchServices.map { service in
            guard let runtimeService = runtimeProject.services[service.name] else {
                throw ComposeError.invalidProject("unknown service '\(service.name)'")
            }
            return runtimeService
        }
        if !watch.noUp {
            try await up(
                project: runtimeProject,
                options: ComposeUpOptions {
                    $0.services = runtimeServices.map(\.name)
                    $0.detach = true
                    $0.quietBuild = watch.quiet
                    $0.quietPull = watch.quiet
                }
            )
        }

        var plans = try watchPlans(project: project, services: watchServices)
        try await performInitialWatchSync(project: runtimeProject, plans: plans, quiet: watch.quiet)
        do {
            try await runWatchLoop(project: runtimeProject, plans: &plans, options: watch)
        } catch is CancellationError {
            if !watch.quiet {
                options.emit("compose: watch stopped")
            }
        }
    }

    /// Attaches to service output using the apple/container log stream.
    public func attach(project: ComposeProject, serviceName: String, options attach: ComposeAttachOptions) async throws {
        try validateAttachOptions(attach)
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        let id = try await serviceContainerID(project: project, service: service, index: attach.index)
        let args = ["logs", "--follow", id]
        if options.dryRun {
            try await runContainer(args)
        } else {
            try await logManager.logs(
                id: id,
                tail: nil,
                follow: true,
                since: nil,
                until: nil,
                timestamps: false,
                emit: options.emit
            )
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
        try applyRunCapabilityOverrides(run, service: &service)
        try applyRunVolumeOverrides(run, project: &runProject, service: &service)
        runProject.services[serviceName] = service
        try validateProjectNetworks(runProject)
        let labelOverrides = try parseRunLabelOverrides(run.labels)
        try validateRunLabelOverridesAgainstAnnotations(labelOverrides, service: service)
        try validatePullPolicy(run.pullPolicy)
        let dependencyServices = try run.noDeps
            ? []
            : orderedServices(project: runProject, selected: [serviceName]).filter { $0.name != serviceName }
        try validateRuntimeSupport(services: dependencyServices + [service], project: runProject, validateDependencies: !run.noDeps)
        try validateOneOffRunLifecycleHooks(service: service, options: run)
        try validatePublishedPorts(services: dependencyServices)
        let publishedPorts = (run.servicePorts ? service.ports ?? [] : []) + run.publish
        try validatePublishedPorts(publishedPorts, serviceName: service.name)
        let externalVolumeMounts = try await resolveExternalVolumeMounts(
            project: runProject,
            services: dependencyServices + [service]
        )
        try await applyPullPolicy(run.pullPolicy, project: runProject, services: [service])
        try await ensureResources(project: runProject)
        runProject = try await startDependencyServices(
            project: runProject,
            services: dependencyServices,
            externalVolumeMounts: externalVolumeMounts
        )
        service = runProject.services[serviceName] ?? service
        if !run.noDeps {
            try await waitForDependencyConditions(project: runProject, service: service)
        }
        let containerName = oneOffRunContainerName(project: runProject, service: service, requestedName: run.containerName)
        try await runContainer(
            try runArguments(
                project: runProject,
                service: service,
                options: RunArgumentOptions {
                    $0.detach = run.detach
                    $0.remove = run.remove
                    $0.oneOff = true
                    $0.publishedPorts = publishedPorts
                    $0.containerNameOverride = containerName
                    $0.labelOverrides = labelOverrides
                },
                externalVolumeMounts: externalVolumeMounts
            ),
            inheritedIO: !run.detach && (service.tty == true || service.stdinOpen == true)
        )
        if run.detach {
            try await runPostStartHooks(service: service, containerID: containerName)
        }
    }

    /// Starts selected service containers.
    public func start(project: ComposeProject, services selected: [String]) async throws {
        let services = try selectedServices(project: project, selected: selected)
        for target in try await serviceContainerTargets(project: project, services: services) {
            try await startContainer(service: target.service, containerName: target.name)
        }
    }

    /// Stops selected service containers.
    public func stop(project: ComposeProject, services selected: [String], timeout: Int? = nil) async throws {
        try validateTimeoutSeconds(timeout, command: "stop")
        let services = try selectedServices(project: project, selected: selected)
        for service in services.reversed() where service.provider != nil {
            _ = try await runProvider(project: project, service: service, action: .stop)
        }
        for target in try await serviceContainerTargets(project: project, services: services) {
            try await stopContainer(service: target.service, containerName: target.name, timeout: timeout)
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
        let targets = try await serviceContainerTargets(project: project, services: services)
        for target in targets {
            try await deleteContainer(target.name, force: force)
        }
        if volumes {
            for volume in try anonymousVolumeRuntimeNames(project: project, targets: targets) {
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
        let services = try selectedServices(project: project, selected: selected)
        for target in try await serviceContainerTargets(project: project, services: services) {
            var args = ["kill"]
            if let signal {
                args.append(contentsOf: ["--signal", signal])
            }
            let containerID = target.name
            args.append(containerID)
            if options.dryRun {
                try await runContainer(args, check: false)
                continue
            }
            try await lifecycleManager.killContainer(id: containerID, signal: signal ?? "KILL")
        }
    }

    /// Waits for selected service containers to exit and prints their exit codes.
    public func wait(project: ComposeProject, options wait: ComposeWaitOptions = ComposeWaitOptions()) async throws {
        let services = try selectedServices(project: project, selected: wait.services)
        let targets = try await serviceContainerTargets(project: project, services: services)
        if wait.downProject {
            try await waitThenDownProject(project: project, targets: targets)
            return
        }
        for target in targets {
            let containerID = target.name
            if options.dryRun {
                try await runContainer(["wait", containerID])
                continue
            }
            let exitCode: Int32
            if let stoppedExitCode = try await stoppedWaitExitCode(target) {
                exitCode = stoppedExitCode
            } else {
                exitCode = try await lifecycleManager.waitContainer(id: containerID)
            }
            options.emit(String(exitCode))
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
            try emitDryRunPort(service: service, requested: requested, index: index)
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
            for (dependency, metadata) in serviceDependencies(service) {
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

    /// Returns services that are dependencies of explicitly selected services
    /// and should be recreated even when their config hash still matches.
    func servicesToRecreateBecauseDependencies(
        project: ComposeProject,
        selected: [String],
        noDeps: Bool,
        alwaysRecreateDeps: Bool,
        services: [ComposeService]
    ) throws -> Set<String> {
        guard alwaysRecreateDeps, !noDeps, !selected.isEmpty else {
            return []
        }
        let selectedNames = Set(try selectedServices(project: project, selected: selected).map(\.name))
        return Set(services.map(\.name)).subtracting(selectedNames)
    }

    /// Returns the deterministic container name for a service or one-off run.
    func containerName(project: ComposeProject, service: ComposeService, oneOff: Bool) -> String {
        if !oneOff, let containerName = service.containerName, !containerName.isEmpty {
            return slug(containerName)
        }
        let suffix = oneOff ? "run-\(slug(options.oneOffIdentifier()))" : "1"
        return "\(slug(project.name))-\(slug(service.name))-\(suffix)"
    }

    /// Returns the one-off container name requested by the CLI or generated
    /// from the configured identifier source.
    func oneOffRunContainerName(project: ComposeProject, service: ComposeService, requestedName: String?) -> String {
        guard let requestedName else {
            return containerName(project: project, service: service, oneOff: true)
        }
        return slug(requestedName)
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

    /// Returns desired deterministic container names for declared services.
    func declaredServiceContainerNames(project: ComposeProject, scaleOverrides: [String: Int]) throws -> Set<String> {
        var names = Set<String>()
        for service in project.services.values {
            let replicaCount = try serviceReplicaCount(service, scaleOverrides: scaleOverrides)
            guard replicaCount > 0 else {
                continue
            }
            for index in 1...replicaCount {
                names.insert(try serviceContainerName(project: project, service: service, index: index))
            }
        }
        return names
    }

    /// Resolves service containers from direct API state, falling back to deterministic names.
    func serviceContainerTargets(project: ComposeProject, services: [ComposeService]) async throws -> [ServiceContainerTarget] {
        if options.dryRun {
            return try configuredServiceContainerTargets(project: project, services: services)
        }

        let containers = try await projectContainers(projectName: project.name, all: true)
        return try services.flatMap { service in
            let matches = containers
                .filter { $0.serviceName == service.name && !$0.isOneOff }
                .sorted(by: serviceContainerSummaryOrder(project: project, service: service))
            guard !matches.isEmpty else {
                guard service.provider == nil else {
                    return [ServiceContainerTarget]()
                }
                return [
                    ServiceContainerTarget(
                        service: service,
                        index: 1,
                        name: try serviceContainerName(project: project, service: service, index: 1)
                    ),
                ]
            }
            return matches.map { container in
                ServiceContainerTarget(
                    service: service,
                    index: serviceContainerIndex(project: project, service: service, containerID: container.id) ?? Int.max,
                    name: container.id
                )
            }
        }
    }

    /// Resolves service container targets for `compose logs`.
    func logTargets(project: ComposeProject, services: [ComposeService], index: Int?) async throws -> [ServiceContainerTarget] {
        guard let index else {
            return try await serviceContainerTargets(project: project, services: services)
        }
        var targets: [ServiceContainerTarget] = []
        for service in services {
            let name = try await serviceContainerID(project: project, service: service, index: index)
            targets.append(ServiceContainerTarget(
                service: service,
                index: index,
                name: name
            ))
        }
        return targets
    }

    /// Returns configured service targets for dry-run rendering.
    func configuredServiceContainerTargets(project: ComposeProject, services: [ComposeService]) throws -> [ServiceContainerTarget] {
        try services.flatMap { service in
            let replicaCount = try serviceReplicaCount(service, scaleOverrides: [:])
            guard replicaCount > 0 else {
                return [ServiceContainerTarget]()
            }
            return try (1...replicaCount).map { index in
                ServiceContainerTarget(
                    service: service,
                    index: index,
                    name: try serviceContainerName(project: project, service: service, index: index)
                )
            }
        }
    }

    /// Removes service replicas above the desired count during scale-down.
    func removeServiceReplicasAbove(project: ComposeProject, service: ComposeService, desiredCount: Int, timeout: Int?) async throws {
        guard !options.dryRun else {
            return
        }
        let containers = try await projectContainers(projectName: project.name, all: true)
            .filter { $0.serviceName == service.name && !$0.isOneOff }
            .sorted(by: serviceContainerSummaryOrder(project: project, service: service))
        for container in containers {
            let index = serviceContainerIndex(project: project, service: service, containerID: container.id)
            guard desiredCount == 0 || (index.map { $0 > desiredCount } ?? false) else {
                continue
            }
            try await stopContainer(service: service, containerName: container.id, timeout: timeout)
            try await deleteContainer(container.id)
        }
    }

    /// Returns a stable ordering for service container discovery.
    func serviceContainerSummaryOrder(project: ComposeProject, service: ComposeService) -> (ComposeContainerSummary, ComposeContainerSummary) -> Bool {
        { [self] lhs, rhs in
            let lhsIndex = self.serviceContainerIndex(project: project, service: service, containerID: lhs.id) ?? Int.max
            let rhsIndex = self.serviceContainerIndex(project: project, service: service, containerID: rhs.id) ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.id < rhs.id
        }
    }

    /// Infers a Compose-managed replica index from a runtime container ID.
    func serviceContainerIndex(project: ComposeProject, service: ComposeService, containerID: String) -> Int? {
        if containerID == containerName(project: project, service: service, oneOff: false) {
            return 1
        }
        guard service.containerName?.isEmpty ?? true else {
            return nil
        }
        let prefix = "\(slug(project.name))-\(slug(service.name))-"
        guard containerID.hasPrefix(prefix) else {
            return nil
        }
        let suffix = String(containerID.dropFirst(prefix.count))
        guard let index = Int(suffix), index >= 1 else {
            return nil
        }
        return index
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
        try validateProviderAndModelSupport(service: service)
        try validateLifecycleHookSupport(service: service)
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
            throw ComposeError.unsupported("service '\(service.name)' uses blkio_config; block I/O controls need apple/container runtime resource primitives for blkio weight and throttling")
        }
        if let gap = unsupportedUserAndSecurityOptionFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName) '\(gap.value)'; \(gap.reason)")
        }
        if let gap = unsupportedDeviceAccessFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        if let scale = service.scale, scale < 0 {
            throw ComposeError.invalidProject("service '\(service.name)' scale must be a non-negative integer")
        }
        if let gap = unsupportedServiceMetadataAndLoggingFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        try validateServiceLabels(project: project, service: service)
        try validateVolumesFromSupport(service: service, project: project)
        if let gap = unsupportedServiceVolumeShortcutFields(service: service).first {
            throw ComposeError.unsupported("service '\(service.name)' uses \(gap.composeName); \(gap.reason)")
        }
        if let fields = try unsupportedServiceMountFields(service: service, project: project) {
            if fields == ["volume.subpath"] {
                throw ComposeError.unsupported("service '\(service.name)' uses volume.subpath; volume subpath mounts need an apple/container mount primitive gap PR")
            }
            let fieldList = fields.joined(separator: ", ")
            throw ComposeError.unsupported("service '\(service.name)' uses unsupported volume fields \(fieldList); advanced service volume options need an apple/container mount primitive gap PR")
        }
        if service.useAPISocket == true {
            throw ComposeError.unsupported("service '\(service.name)' uses use_api_socket; Docker-compatible API socket and credential handoff need an apple/container runtime boundary")
        }
        try validateNetworkMACAddressSupport(service: service, networks: networks)
        if validateDependencies, let dependsOn = service.dependsOn {
            for (dependency, metadata) in dependsOn.sorted(by: { $0.key < $1.key }) {
                if metadata.required == false, project.services[dependency] == nil {
                    continue
                }
                let condition = metadata.condition
                if condition != "service_started" && condition != "" && condition != "service_completed_successfully" && condition != "service_healthy" {
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
        _ = try runtimeHealthCheckArguments(service: service)
        _ = try serviceConfigSecretMounts(project: project, service: service)
        if let pullPolicy = service.pullPolicy, !pullPolicy.isEmpty, !isSupportedServicePullPolicy(pullPolicy) {
            throw ComposeError.unsupported("service '\(service.name)' uses pull_policy '\(pullPolicy)'; supported values are always, missing, if_not_present, never, build, daily, weekly, and every_<duration>")
        }
        _ = try runtimeRestartPolicyArgument(service: service)
    }

    /// Rejects project network fields that are not mapped to apple/container network creation.
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

    /// Allows MAC addresses only for the single-network attachment that apple/container
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

    /// Rejects build fields that apple/container `container build` cannot represent yet.
    func validateBuildSupport(service: ComposeService) throws {
        guard let fields = service.build?.unsupportedFields, !fields.isEmpty else {
            return
        }
        let fieldList = fields.joined(separator: ", ")
        throw ComposeError.unsupported("service '\(service.name)' uses unsupported build fields \(fieldList); advanced build fields need Docker Compose compatible apple/container build primitives")
    }

    /// Rejects deploy fields that are not part of the supported local subset.
    func validateDeploySupport(service: ComposeService) throws {
        guard let fields = service.unsupportedDeployFields, !fields.isEmpty else {
            return
        }
        if fields.contains("endpoint_mode") {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.endpoint_mode; service endpoint mode support needs an apple/container networking gap PR")
        }
        if fields.contains("update_config.order.start-first") {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.update_config.order: start-first; start-first updates need an apple/container container rename or service alias handoff primitive")
        }
        if let mode = unsupportedDeployJobModeField(in: fields) {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.mode '\(mode)'; deploy job modes need apple/container completion metadata and job lifecycle primitives")
        }
        if fields.contains("mode") {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.mode; deploy modes outside local replicated/global behavior need apple/container scheduler or job lifecycle primitives")
        }
        if fields.contains("update_config.order") {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.update_config.order; unsupported update orders need Docker Compose compatible apple/container update orchestration primitives")
        }
        if let field = unsupportedDeployResourceLimitField(in: fields) {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.\(field); apple/container exposes local deploy CPU and memory limits but not this deploy resource limit yet")
        }
        if let field = unsupportedDeployResourceReservationField(in: fields) {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.\(field); resource reservations need an apple/container scheduler/resource reservation gap PR")
        }
        let fieldList = fields.joined(separator: ", ")
        throw ComposeError.unsupported("service '\(service.name)' uses unsupported deploy fields \(fieldList); remaining Compose Deploy Specification fields need Docker Compose compatible apple/container deploy or runtime primitives")
    }

    /// Returns a Compose Deploy job mode that needs completion semantics.
    func unsupportedDeployJobModeField(in fields: [String]) -> String? {
        fields.first { $0.hasPrefix("mode.") }?.replacingOccurrences(of: "mode.", with: "")
    }

    /// Returns unsupported deploy resource limits that need apple/container runtime support.
    func unsupportedDeployResourceLimitField(in fields: [String]) -> String? {
        fields.first { $0.hasPrefix("resources.limits.") }
    }

    /// Returns unsupported deploy resource reservations that need scheduler support.
    func unsupportedDeployResourceReservationField(in fields: [String]) -> String? {
        fields.first { $0.hasPrefix("resources.reservations.") }
    }

    /// Rejects service extension points that need explicit orchestration design.
    func validateProviderAndModelSupport(service: ComposeService) throws {
        if let provider = service.provider {
            let type = provider.type.trimmingCharacters(in: .whitespacesAndNewlines)
            if type.isEmpty {
                throw ComposeError.invalidProject("service '\(service.name)' provider.type must not be empty")
            }
            if type == "compose" {
                throw ComposeError.invalidProject("service '\(service.name)' provider.type 'compose' is reserved")
            }
        }
        if let models = service.models, !models.isEmpty {
            throw ComposeError.unsupported("service '\(service.name)' uses models; Compose model bindings need a model-runner backend and endpoint injection primitive that is not available through apple/container yet")
        }
    }

    /// Runs a provider-backed service lifecycle command.
    func runProvider(
        project: ComposeProject,
        service: ComposeService,
        action: ComposeProviderAction
    ) async throws -> [String: String] {
        guard let provider = service.provider else {
            return [:]
        }
        let executable = options.dryRun
            ? provider.type
            : try providerExecutablePath(provider.type, project: project)

        let metadata = options.dryRun
            ? ComposeProviderMetadata()
            : await providerMetadata(executable: executable, project: project)
        if action == .stop && metadata.commandMetadata(for: .stop) == nil && !options.dryRun {
            return [:]
        }
        if !metadata.isEmpty {
            try validateProviderOptions(provider: provider, metadata: metadata, action: action)
        }

        let arguments = providerArguments(
            project: project,
            service: service,
            provider: provider,
            action: action,
            metadata: metadata
        )
        if options.dryRun {
            options.emit("+ " + shellQuoted([executable] + arguments))
            return [:]
        }

        let result = try await runner.run(
            executable,
            arguments,
            workingDirectory: URL(fileURLWithPath: project.workingDirectory, isDirectory: true),
            environment: nil,
            io: .captured(input: nil)
        )
        let variables = try parseProviderOutput(result.stdout, service: service, action: action)
        if !result.succeeded {
            throw ComposeError.commandFailed(
                command: shellQuoted([executable] + arguments),
                status: result.status,
                stderr: result.stderr
            )
        }
        return action == .stop ? [:] : variables
    }

    /// Reads optional provider metadata. Metadata failures intentionally fall
    /// back to the protocol's no-metadata behavior for backward compatibility.
    func providerMetadata(executable: String, project: ComposeProject) async -> ComposeProviderMetadata {
        do {
            let result = try await runner.run(
                executable,
                ["compose", "metadata"],
                workingDirectory: URL(fileURLWithPath: project.workingDirectory, isDirectory: true),
                environment: nil,
                io: .captured(input: nil)
            )
            guard result.succeeded,
                  let data = result.stdout.data(using: .utf8),
                  !data.isEmpty else {
                return ComposeProviderMetadata()
            }
            return (try? JSONDecoder().decode(ComposeProviderMetadata.self, from: data)) ?? ComposeProviderMetadata()
        } catch {
            return ComposeProviderMetadata()
        }
    }

    /// Builds the provider command arguments for one lifecycle action.
    func providerArguments(
        project: ComposeProject,
        service: ComposeService,
        provider: ComposeProvider,
        action: ComposeProviderAction,
        metadata: ComposeProviderMetadata
    ) -> [String] {
        let commandMetadata = metadata.commandMetadata(for: action)
        let hasMetadata = !metadata.isEmpty
        var arguments = ["compose", "--project-name=\(project.name)", action.rawValue]
        for (key, values) in (provider.options ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !hasMetadata || commandMetadata?.parameter(named: key) != nil else {
                continue
            }
            for value in values {
                arguments.append("--\(key)=\(value)")
            }
        }
        arguments.append(service.name)
        return arguments
    }

    /// Validates required provider options declared by metadata.
    func validateProviderOptions(
        provider: ComposeProvider,
        metadata: ComposeProviderMetadata,
        action: ComposeProviderAction
    ) throws {
        guard let commandMetadata = metadata.commandMetadata(for: action) else {
            return
        }
        for parameter in commandMetadata.parameters ?? [] where parameter.required == true {
            if (provider.options?[parameter.name] ?? []).isEmpty {
                throw ComposeError.invalidProject("required parameter '\(parameter.name)' is missing from provider '\(provider.type)' definition")
            }
        }
    }

    /// Decodes newline-delimited provider JSON messages.
    func parseProviderOutput(
        _ output: String,
        service: ComposeService,
        action: ComposeProviderAction
    ) throws -> [String: String] {
        var variables: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            guard let data = text.data(using: .utf8),
                  let message = try? JSONDecoder().decode(ComposeProviderMessage.self, from: data) else {
                throw ComposeError.invalidProject("invalid response from provider service '\(service.name)': \(text)")
            }
            switch message.type {
            case "info":
                options.emit("compose: provider \(service.name): \(message.message)")
            case "debug":
                continue
            case "error":
                throw ComposeError.invalidProject("provider service '\(service.name)' failed during \(action.rawValue): \(message.message)")
            case "setenv":
                let parts = message.message.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw ComposeError.invalidProject("invalid setenv response from provider service '\(service.name)': \(message.message)")
                }
                variables[String(parts[0])] = String(parts[1])
            default:
                throw ComposeError.invalidProject("invalid response type '\(message.type)' from provider service '\(service.name)'")
            }
        }
        return variables
    }

    /// Injects provider variables into services that directly depend on it.
    func projectByInjectingProviderEnvironment(
        project: ComposeProject,
        providerServiceName: String,
        variables: [String: String]
    ) -> ComposeProject {
        var updatedProject = project
        let prefix = providerServiceName.uppercased() + "_"
        for entry in project.services.sorted(by: { $0.key < $1.key }) {
            let name = entry.key
            var service = entry.value
            guard service.dependsOn?[providerServiceName] != nil else {
                continue
            }
            var environment = service.environment ?? [:]
            for (key, value) in variables.sorted(by: { $0.key < $1.key }) {
                environment[prefix + key] = value
            }
            service.environment = environment
            updatedProject.services[name] = service
        }
        return updatedProject
    }

    /// Resolves the provider executable path using Compose-compatible rules.
    func providerExecutablePath(_ rawType: String, project: ComposeProject) throws -> String {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "compose" {
            throw ComposeError.invalidProject("provider.type 'compose' is reserved")
        }
        if type.contains("/") {
            let url = type.hasPrefix("/")
                ? URL(fileURLWithPath: type)
                : URL(fileURLWithPath: project.workingDirectory, isDirectory: true)
                    .appendingPathComponent(type)
                    .standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ComposeError.invalidProject("provider executable '\(type)' was not found or is not executable")
            }
            return url.path
        }
        let candidates = type.hasPrefix("docker-") ? [type] : ["docker-\(type)", type]
        for candidate in candidates {
            if let path = findExecutable(named: candidate) {
                return path
            }
        }
        throw ComposeError.invalidProject("provider executable '\(type)' was not found in PATH")
    }

    /// Finds an executable in PATH.
    func findExecutable(named name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directoryPath = directory.isEmpty ? "." : String(directory)
            let candidate = URL(fileURLWithPath: directoryPath, isDirectory: true)
                .appendingPathComponent(name)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Validates lifecycle hook metadata before runtime side effects.
    func validateLifecycleHookSupport(service: ComposeService) throws {
        let hookSets: [(composeName: String, hooks: [ComposeServiceHook]?)] = [
            ("post_start", service.postStart),
            ("pre_stop", service.preStop),
        ]
        for hookSet in hookSets {
            for (index, hook) in (hookSet.hooks ?? []).enumerated() {
                if hook.privileged == true {
                    throw ComposeError.unsupported("service '\(service.name)' uses \(hookSet.composeName)[\(index)].privileged; apple/container exec does not expose privileged process execution")
                }
                guard let command = hook.command, !command.isEmpty else {
                    throw ComposeError.invalidProject("service '\(service.name)' \(hookSet.composeName)[\(index)] requires a command")
                }
            }
        }
    }

    /// Rejects foreground `up` when `post_start` would otherwise run too late.
    func validateAttachedPostStartSupport(target: ServiceContainerTarget?) throws {
        guard let service = target?.service, hasPostStartHooks(service) else {
            return
        }
        throw ComposeError.unsupported("service '\(service.name)' uses post_start; attached up cannot run lifecycle hooks before foreground attach because apple/container does not expose reattaching to the init process after a hookable detached start, use --detach")
    }

    /// Validates lifecycle hooks for one-off containers.
    func validateOneOffRunLifecycleHooks(service: ComposeService, options run: ComposeRunOptions) throws {
        if hasPreStopHooks(service), !run.detach {
            throw ComposeError.unsupported("service '\(service.name)' uses pre_stop; foreground compose run cannot execute pre_stop before the one-off init process exits because apple/container does not expose an interceptable foreground stop boundary")
        }
        guard hasPostStartHooks(service), !run.detach else {
            return
        }
        throw ComposeError.unsupported("service '\(service.name)' uses post_start; foreground compose run cannot execute post_start before attach because apple/container does not expose reattaching to the init process after a hookable detached start, use --detach")
    }

    /// Validates normalized develop.watch trigger metadata for command-level
    /// `watch` execution.
    func validateWatchTriggers(services: [ComposeService]) throws {
        for service in services {
            guard let triggers = service.develop?.watch else {
                continue
            }
            for trigger in triggers {
                try validateWatchTrigger(trigger, service: service)
            }
        }
    }

    /// Validates one develop.watch trigger before runtime watch execution.
    func validateWatchTrigger(_ trigger: ComposeDevelopWatch, service: ComposeService) throws {
        guard nonEmpty(trigger.path) != nil else {
            throw ComposeError.invalidProject("service '\(service.name)' has a develop.watch trigger without a path")
        }
        let action = trigger.action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' has a develop.watch trigger without an action")
        }
        let supportedActions = ["rebuild", "restart", "sync", "sync+restart", "sync+exec"]
        guard supportedActions.contains(action) else {
            let supportedActionList = supportedActions.joined(separator: ", ")
            throw ComposeError.unsupported(
                "service '\(service.name)' uses develop.watch action '\(trigger.action)'; supported Compose watch actions are \(supportedActionList)"
            )
        }
        if action.contains("sync"), nonEmpty(trigger.target) == nil {
            throw ComposeError.invalidProject("service '\(service.name)' develop.watch action '\(action)' requires a target")
        }
        if action == "sync+exec" {
            _ = try watchExecHook(trigger: trigger, service: service)
        }
    }

    /// Emits the validated watch plan without starting the file-watcher loop.
    func emitWatchDryRunPlan(project: ComposeProject, services: [ComposeService], watch: ComposeWatchOptions) {
        let serviceNames = services.map(\.name).joined(separator: ",")
        options.emit("compose: watch project \(project.name) services \(serviceNames)")
        options.emit("compose: watch initial-up \(watch.noUp ? "disabled" : "enabled")")
        options.emit("compose: watch prune \(watch.prune ? "enabled" : "disabled")")
        options.emit("compose: watch quiet \(watch.quiet ? "enabled" : "disabled")")
        for service in services {
            for trigger in service.develop?.watch ?? [] {
                options.emit(watchDryRunLine(service: service, trigger: trigger))
            }
        }
    }

    /// Formats one validated `develop.watch` trigger for dry-run output.
    func watchDryRunLine(service: ComposeService, trigger: ComposeDevelopWatch) -> String {
        let action = trigger.action.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = ["compose: watch", service.name, action, "path=\(trigger.path)"]
        if let target = nonEmpty(trigger.target) {
            fields.append("target=\(target)")
        }
        if let include = trigger.include, !include.isEmpty {
            fields.append("include=\(include.joined(separator: ","))")
        }
        if let ignore = trigger.ignore, !ignore.isEmpty {
            fields.append("ignore=\(ignore.joined(separator: ","))")
        }
        if trigger.initialSync == true {
            fields.append("initial-sync=true")
        }
        if let execCommand = trigger.exec?.command, !execCommand.isEmpty {
            fields.append("exec=\(shellQuoted(execCommand))")
        }
        return fields.joined(separator: " ")
    }

    /// Creates executable watch plans with an initial filesystem snapshot.
    func watchPlans(project: ComposeProject, services: [ComposeService]) throws -> [ComposeWatchPlan] {
        try services.flatMap { service in
            try (service.develop?.watch ?? []).map { trigger in
                ComposeWatchPlan(
                    service: service,
                    trigger: trigger,
                    snapshot: try watchSnapshot(project: project, trigger: trigger)
                )
            }
        }
    }

    /// Applies `initial_sync` for sync-oriented watch triggers before polling.
    func performInitialWatchSync(project: ComposeProject, plans: [ComposeWatchPlan], quiet: Bool) async throws {
        for plan in plans where plan.trigger.initialSync == true && plan.action.hasPrefix("sync") {
            guard !plan.snapshot.isEmpty else {
                continue
            }
            try await syncWatchEntries(
                project: project,
                service: plan.service,
                trigger: plan.trigger,
                entries: Array(plan.snapshot.values).sorted(by: { $0.relativePath < $1.relativePath }),
                quiet: quiet
            )
        }
    }

    /// Polls watched paths until the task is cancelled.
    func runWatchLoop(project: ComposeProject, plans: inout [ComposeWatchPlan], options watch: ComposeWatchOptions) async throws {
        if !watch.quiet {
            options.emit("compose: watch started")
        }
        while !Task.isCancelled {
            try await options.sleep(options.watchPollInterval)
            for index in plans.indices {
                let latest = try watchSnapshot(project: project, trigger: plans[index].trigger)
                let changes = watchChanges(previous: plans[index].snapshot, latest: latest)
                plans[index].snapshot = latest
                guard !changes.isEmpty else {
                    continue
                }
                try await performWatchAction(
                    project: project,
                    service: plans[index].service,
                    trigger: plans[index].trigger,
                    changes: changes,
                    options: watch
                )
            }
        }
    }

    /// Executes one Compose watch action against the matching service containers.
    func performWatchAction(
        project: ComposeProject,
        service: ComposeService,
        trigger: ComposeDevelopWatch,
        changes: [ComposeWatchChange],
        options watch: ComposeWatchOptions
    ) async throws {
        switch trigger.action.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "sync":
            try await syncWatchChanges(project: project, service: service, trigger: trigger, changes: changes, quiet: watch.quiet)
        case "sync+restart":
            try await syncWatchChanges(project: project, service: service, trigger: trigger, changes: changes, quiet: watch.quiet)
            try await restartWatchService(project: project, service: service, quiet: watch.quiet)
        case "sync+exec":
            try await syncWatchChanges(project: project, service: service, trigger: trigger, changes: changes, quiet: watch.quiet)
            try await execWatchHook(project: project, service: service, trigger: trigger, quiet: watch.quiet)
        case "restart":
            try await restartWatchService(project: project, service: service, quiet: watch.quiet)
        case "rebuild":
            try await rebuildWatchService(project: project, service: service, options: watch)
        default:
            try validateWatchTrigger(trigger, service: service)
        }
    }

    /// Copies changed files and removes deleted files for a sync action.
    func syncWatchChanges(
        project: ComposeProject,
        service: ComposeService,
        trigger: ComposeDevelopWatch,
        changes: [ComposeWatchChange],
        quiet: Bool
    ) async throws {
        let upserts = changes.compactMap(\.entry)
        if !upserts.isEmpty {
            try await syncWatchEntries(project: project, service: service, trigger: trigger, entries: upserts, quiet: quiet)
        }
        let deletes = changes.compactMap(\.deletedRelativePath)
        if !deletes.isEmpty {
            try await deleteWatchEntries(project: project, service: service, trigger: trigger, relativePaths: deletes, quiet: quiet)
        }
    }

    /// Copies local watch entries into every running service replica.
    func syncWatchEntries(
        project: ComposeProject,
        service: ComposeService,
        trigger: ComposeDevelopWatch,
        entries: [ComposeWatchEntry],
        quiet: Bool
    ) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [service])
        for target in targets {
            for entry in entries {
                let destination = try watchTargetPath(trigger: trigger, relativePath: entry.relativePath)
                if !quiet {
                    options.emit("compose: watch sync \(service.name)[\(target.index)] \(entry.sourcePath) -> \(destination)")
                }
                try await copier.copyIntoContainer(id: target.name, source: entry.sourcePath, destination: destination)
            }
        }
    }

    /// Removes deleted watched paths from service replicas through direct exec.
    func deleteWatchEntries(
        project: ComposeProject,
        service: ComposeService,
        trigger: ComposeDevelopWatch,
        relativePaths: [String],
        quiet: Bool
    ) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [service])
        for target in targets {
            for relativePath in relativePaths.sorted() {
                let destination = try watchTargetPath(trigger: trigger, relativePath: relativePath)
                if !quiet {
                    options.emit("compose: watch delete \(service.name)[\(target.index)] \(destination)")
                }
                try await runWatchExec(
                    service: service,
                    containerID: target.name,
                    command: ["sh", "-c", "rm -rf -- \(shellQuoted([destination]))"],
                    user: nil,
                    workingDirectory: nil,
                    environment: []
                )
            }
        }
    }

    /// Restarts every service replica affected by a watch trigger.
    func restartWatchService(project: ComposeProject, service: ComposeService, quiet: Bool) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [service])
        for target in targets {
            if !quiet {
                options.emit("compose: watch restart \(service.name)[\(target.index)]")
            }
            try await restartContainer(service: service, containerName: target.name)
        }
    }

    /// Rebuilds and recreates a service after a rebuild watch trigger.
    func rebuildWatchService(project: ComposeProject, service: ComposeService, options watch: ComposeWatchOptions) async throws {
        if !watch.quiet {
            self.options.emit("compose: watch rebuild \(service.name)")
        }
        try await up(
            project: project,
            options: ComposeUpOptions {
                $0.services = [service.name]
                $0.build = true
                $0.detach = true
                $0.forceRecreate = true
                $0.quietBuild = watch.quiet
            }
        )
        if watch.prune {
            try await runContainer(["image", "prune"])
        }
    }

    /// Runs the command attached to a `sync+exec` trigger on each service replica.
    func execWatchHook(project: ComposeProject, service: ComposeService, trigger: ComposeDevelopWatch, quiet: Bool) async throws {
        let hook = try watchExecHook(trigger: trigger, service: service)
        let targets = try await serviceContainerTargets(project: project, services: [service])
        for target in targets {
            if !quiet {
                options.emit("compose: watch exec \(service.name)[\(target.index)] \(shellQuoted(hook.command))")
            }
            try await runWatchExec(
                service: service,
                containerID: target.name,
                command: hook.command,
                user: hook.user,
                workingDirectory: hook.workingDirectory,
                environment: hook.environment
            )
        }
    }

    /// Resolves and validates sync+exec hook metadata.
    func watchExecHook(trigger: ComposeDevelopWatch, service: ComposeService) throws -> ComposeWatchExecHook {
        guard let exec = trigger.exec else {
            throw ComposeError.invalidProject("service '\(service.name)' develop.watch action 'sync+exec' requires exec metadata")
        }
        guard exec.privileged != true else {
            throw ComposeError.unsupported("service '\(service.name)' develop.watch sync+exec uses privileged; apple/container exec does not expose privileged process execution")
        }
        guard let command = exec.command, !command.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' develop.watch action 'sync+exec' requires an exec command")
        }
        return ComposeWatchExecHook(
            command: command,
            user: nonEmpty(exec.user),
            workingDirectory: nonEmpty(exec.workingDir),
            environment: environmentArguments(exec.environment ?? [:])
        )
    }

    /// Runs a non-interactive direct exec request for watch actions.
    func runWatchExec(
        service: ComposeService,
        containerID: String,
        command: [String],
        user: String?,
        workingDirectory: String?,
        environment: [String]
    ) async throws {
        let status = try await execManager.execAttached(
            request: ContainerAttachedExecRequest(
                id: containerID,
                command: command,
                environment: environment,
                user: user,
                workingDirectory: workingDirectory,
                interactive: false,
                tty: false
            )
        )
        if status != 0 {
            throw ComposeError.commandFailed(
                command: shellQuoted(command),
                status: status,
                stderr: "watch exec failed for service '\(service.name)'"
            )
        }
    }

    /// Runs all `post_start` hooks for a service container.
    func runPostStartHooks(service: ComposeService, containerID: String) async throws {
        try await runLifecycleHooks(service: service, containerID: containerID, hooks: service.postStart ?? [], composeName: "post_start")
    }

    /// Runs all `pre_stop` hooks for a service container.
    func runPreStopHooks(service: ComposeService, containerID: String) async throws {
        try await runLifecycleHooks(service: service, containerID: containerID, hooks: service.preStop ?? [], composeName: "pre_stop")
    }

    /// Executes Compose service lifecycle hooks with the direct exec API.
    func runLifecycleHooks(
        service: ComposeService,
        containerID: String,
        hooks: [ComposeServiceHook],
        composeName: String
    ) async throws {
        for (index, hook) in hooks.enumerated() {
            if hook.privileged == true {
                throw ComposeError.unsupported("service '\(service.name)' uses \(composeName)[\(index)].privileged; apple/container exec does not expose privileged process execution")
            }
            guard let command = hook.command, !command.isEmpty else {
                throw ComposeError.invalidProject("service '\(service.name)' \(composeName)[\(index)] requires a command")
            }
            let environment = environmentArguments(hook.environment ?? [:])
            let args = lifecycleHookExecArguments(
                containerID: containerID,
                command: command,
                user: nonEmpty(hook.user),
                workingDirectory: nonEmpty(hook.workingDir),
                environment: environment
            )
            if options.dryRun {
                try await runContainer(args)
                continue
            }
            let status = try await execManager.execAttached(
                request: ContainerAttachedExecRequest(
                    id: containerID,
                    command: command,
                    environment: environment,
                    user: nonEmpty(hook.user),
                    workingDirectory: nonEmpty(hook.workingDir),
                    interactive: false,
                    tty: false
                )
            )
            if status != 0 {
                throw ComposeError.commandFailed(
                    command: shellQuoted([options.containerBinary] + args),
                    status: status,
                    stderr: "\(composeName) hook failed for service '\(service.name)'"
                )
            }
        }
    }

    /// Builds a dry-run `container exec` command for service lifecycle hooks.
    func lifecycleHookExecArguments(
        containerID: String,
        command: [String],
        user: String?,
        workingDirectory: String?,
        environment: [String]
    ) -> [String] {
        var args = ["exec"]
        for value in environment {
            args.append(contentsOf: ["--env", value])
        }
        if let user {
            args.append(contentsOf: ["--user", user])
        }
        if let workingDirectory {
            args.append(contentsOf: ["--workdir", workingDirectory])
        }
        args.append(containerID)
        args.append(contentsOf: command)
        return args
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
            "health status support requires apple/container healthcheck runtime support"
        case "service_completed_successfully":
            "exit code and completion time need an apple/container runtime gap PR"
        default:
            "dependency condition support needs an apple/container runtime gap PR"
        }
    }

    /// Returns logging and storage fields that need apple/container runtime primitives.
    func unsupportedServiceMetadataAndLoggingFields(service: ComposeService) -> [(composeName: String, reason: String)] {
        var fields: [(composeName: String, reason: String)] = []
        let loggingReason = "service logging driver/options need an apple/container runtime gap PR"
        if !isSupportedRuntimeLogging(service.logging) {
            fields.append(("logging", loggingReason))
        }
        if let logDriver = service.logDriver,
           !logDriver.isEmpty,
           !isSupportedRuntimeLogDriver(logDriver) {
            fields.append(("log_driver", loggingReason))
        }
        if !isSupportedLegacyRuntimeLogOptions(service: service) {
            fields.append(("log_opt", loggingReason))
        }
        if let storageOptions = service.storageOptions, !storageOptions.isEmpty {
            fields.append(("storage_opt", "per-container storage options need an apple/container rootfs storage runtime gap PR"))
        }
        return fields
    }

    /// Returns whether Compose logging maps to an apple/container runtime log policy.
    func isSupportedRuntimeLogging(_ logging: ComposeValue?) -> Bool {
        guard let logging else {
            return true
        }
        switch logging {
        case .null:
            return true
        case .object(let fields):
            let knownKeys = Set(["driver", "options"])
            guard fields.keys.allSatisfy({ knownKeys.contains($0) }) else {
                return false
            }
            let driver = fields["driver"]?.stringValue
            let options = fields["options"]
            return isSupportedRuntimeLogDriver(driver) && isSupportedRuntimeLogOptions(options, driver: driver)
        default:
            return false
        }
    }

    /// Returns whether a logging driver can be represented by apple/container.
    func isSupportedRuntimeLogDriver(_ driver: String?) -> Bool {
        driver == nil || driver == "json-file" || driver == "local" || driver == "none"
    }

    /// Returns whether Compose logging options map to local apple/container options.
    func isSupportedRuntimeLogOptions(_ options: ComposeValue?, driver: String?) -> Bool {
        guard let options else {
            return true
        }
        switch options {
        case .null:
            return true
        case .object(let fields):
            if fields.isEmpty {
                return true
            }
            guard driver != "none" else {
                return false
            }
            return fields.allSatisfy { key, value in
                isSupportedRuntimeLogOptionKey(key) && value.stringValue != nil
            }
        default:
            return false
        }
    }

    /// Returns whether legacy Compose log options map to local apple/container options.
    func isSupportedLegacyRuntimeLogOptions(service: ComposeService) -> Bool {
        guard let logOptions = service.logOptions, !logOptions.isEmpty else {
            return true
        }
        guard isSupportedRuntimeLogDriver(service.logDriver), service.logDriver != "none" else {
            return false
        }
        return logOptions.keys.allSatisfy(isSupportedRuntimeLogOptionKey)
    }

    /// Returns whether an option key is supported by apple/container local logging.
    func isSupportedRuntimeLogOptionKey(_ key: String) -> Bool {
        key == "max-size" || key == "max-file"
    }

    /// Returns the runtime log driver override needed for non-default Compose logging.
    func runtimeLogDriverArgument(service: ComposeService) -> String? {
        if case .object(let fields)? = service.logging,
           let driver = fields["driver"]?.stringValue {
            return driver == "none" ? "none" : nil
        }
        return service.logDriver == "none" ? "none" : nil
    }

    /// Returns local apple/container logging options for service create/run.
    func runtimeLogOptionArguments(service: ComposeService) -> [String] {
        var options: [String: String] = [:]
        if case .object(let fields)? = service.logging,
           case .object(let logOptions)? = fields["options"] {
            for (key, value) in logOptions {
                if let stringValue = value.stringValue {
                    options[key] = stringValue
                }
            }
        }
        for (key, value) in service.logOptions ?? [:] {
            options[key] = value
        }
        return options.sorted(by: { $0.key < $1.key }).flatMap { key, value in
            ["--log-opt", "\(key)=\(value)"]
        }
    }

    /// Returns the Docker-compatible apple/container restart policy argument
    /// for service containers. Compose Deploy restart policy takes precedence
    /// over the service-level `restart` key, matching Docker Compose.
    func runtimeRestartPolicyArgument(service: ComposeService) throws -> String? {
        if let policy = service.deployRestartPolicy {
            return try runtimeDeployRestartPolicyArgument(service: service, policy: policy)
        }
        return try runtimeServiceRestartPolicyArgument(service: service)
    }

    /// Returns the runtime restart argument for a Compose Deploy restart policy.
    func runtimeDeployRestartPolicyArgument(
        service: ComposeService,
        policy: ComposeDeployRestartPolicy
    ) throws -> String {
        let condition = policy.condition?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let restartCondition = condition.flatMap { $0.isEmpty ? nil : $0 } ?? "any"

        switch restartCondition {
        case "none":
            try validateDeployRestartPolicyTiming(service: service, policy: policy)
            if policy.maxAttempts != nil {
                throw ComposeError.unsupported("service '\(service.name)' uses deploy.restart_policy.max_attempts with condition 'none'; apple/container retry limits are only available for on-failure restart policies")
            }
            return "no"
        case "any":
            try validateDeployRestartPolicyTiming(service: service, policy: policy)
            if policy.maxAttempts != nil {
                throw ComposeError.unsupported("service '\(service.name)' uses deploy.restart_policy.max_attempts with condition 'any'; apple/container retry limits are only available for on-failure restart policies")
            }
            return "always"
        case "on-failure":
            try validateDeployRestartPolicyTiming(service: service, policy: policy)
            guard let maxAttempts = policy.maxAttempts else {
                return "on-failure"
            }
            guard maxAttempts <= UInt64(UInt32.max) else {
                throw ComposeError.invalidProject("service '\(service.name)' deploy.restart_policy.max_attempts must be between 0 and \(UInt32.max)")
            }
            return "on-failure:\(maxAttempts)"
        default:
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.restart_policy.condition '\(restartCondition)'; supported values are none, on-failure, and any")
        }
    }

    /// Rejects Deploy restart timing fields until apple/container exposes
    /// restart delay/window primitives compatible with Docker Compose.
    func validateDeployRestartPolicyTiming(
        service: ComposeService,
        policy: ComposeDeployRestartPolicy
    ) throws {
        if let delay = policy.delayNanoseconds, delay > 0 {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.restart_policy.delay; apple/container restart policies do not expose configurable restart delay yet")
        }
        if let window = policy.windowNanoseconds, window > 0 {
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.restart_policy.window; apple/container restart policies do not expose configurable success window yet")
        }
    }

    /// Returns the runtime restart argument for the service-level `restart` key.
    func runtimeServiceRestartPolicyArgument(service: ComposeService) throws -> String? {
        guard let restart = service.restart?.trimmingCharacters(in: .whitespacesAndNewlines),
              !restart.isEmpty else {
            return nil
        }

        let parts = restart.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let mode = parts.first, !mode.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' has invalid restart policy '\(restart)'")
        }

        switch mode {
        case "no", "always", "unless-stopped":
            guard parts.count == 1 else {
                throw ComposeError.invalidProject("service '\(service.name)' restart retry count is only supported with on-failure")
            }
        case "on-failure":
            if parts.count == 2 {
                let retryValue = String(parts[1])
                guard !retryValue.isEmpty, UInt32(retryValue) != nil else {
                    throw ComposeError.invalidProject("service '\(service.name)' has invalid restart policy '\(restart)'")
                }
            }
        default:
            throw ComposeError.unsupported("service '\(service.name)' uses restart policy '\(restart)'; supported values are no, always, on-failure[:max-retries], and unless-stopped")
        }

        return restart
    }

    /// Returns Docker-compatible apple/container healthcheck arguments for
    /// service create/run.
    func runtimeHealthCheckArguments(service: ComposeService) throws -> [String] {
        guard let healthcheck = service.healthcheck else {
            return []
        }
        guard case .object(let fields) = healthcheck else {
            throw ComposeError.invalidProject("service '\(service.name)' healthcheck must be an object")
        }
        guard fields.keys.allSatisfy({ supportedHealthCheckKeys.contains($0) }) else {
            let unsupported = fields.keys.filter { !supportedHealthCheckKeys.contains($0) }.sorted().joined(separator: ", ")
            throw ComposeError.unsupported("service '\(service.name)' uses unsupported healthcheck fields \(unsupported)")
        }
        if fields["disable"]?.boolValue == true {
            return ["--no-healthcheck"]
        }
        guard let test = fields["test"] else {
            if fields.isEmpty || fields.keys.allSatisfy({ $0 == "disable" }) {
                return []
            }
            throw ComposeError.unsupported("service '\(service.name)' tunes an image healthcheck; apple/container image healthcheck metadata is not exposed yet")
        }

        var args: [String]
        switch try runtimeHealthCheckCommand(test: test, serviceName: service.name) {
        case .disabled:
            args = ["--no-healthcheck"]
        case .command(let command):
            args = ["--health-cmd", command]
        }

        for field in healthCheckDurationFields {
            if let value = fields[field.composeName] {
                let duration = try healthCheckDuration(value, field: field.composeName, serviceName: service.name)
                args.append(contentsOf: [field.runtimeName, duration])
            }
        }

        if let retries = fields["retries"] {
            let value = try healthCheckRetries(retries, serviceName: service.name)
            args.append(contentsOf: ["--health-retries", String(value)])
        }

        return args
    }

    /// Converts Compose healthcheck `test` to the container CLI command form.
    func runtimeHealthCheckCommand(test: ComposeValue, serviceName: String) throws -> RuntimeHealthCheckCommand {
        switch test {
        case .string(let command):
            return .command(command)
        case .array(let values):
            let parts = try values.map { value -> String in
                guard let string = value.stringValue else {
                    throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test entries must be strings")
                }
                return string
            }
            guard let directive = parts.first else {
                throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test cannot be empty")
            }
            switch directive {
            case "NONE":
                return .disabled
            case "CMD-SHELL":
                let command = parts.dropFirst().joined(separator: " ")
                guard !command.isEmpty else {
                    throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test CMD-SHELL requires a command")
                }
                return .command(command)
            case "CMD":
                let command = Array(parts.dropFirst())
                guard !command.isEmpty else {
                    throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test CMD requires a command")
                }
                return .command(shellQuoted(command))
            default:
                throw ComposeError.unsupported("service '\(serviceName)' healthcheck.test uses unsupported directive '\(directive)'")
            }
        default:
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test must be a string or list")
        }
    }

    /// Returns a healthcheck duration string accepted by apple/container.
    func healthCheckDuration(_ value: ComposeValue, field: String, serviceName: String) throws -> String {
        guard let duration = value.stringValue,
              ContainerLogTimestampParser.parseDuration(duration) != nil else {
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.\(field) must be a Compose duration")
        }
        return duration
    }

    /// Returns the Compose healthcheck retry count.
    func healthCheckRetries(_ value: ComposeValue, serviceName: String) throws -> Int {
        guard let retries = value.intValue, retries >= 0 else {
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.retries must be a non-negative integer")
        }
        return retries
    }

    /// Returns the service replica that should inherit foreground IO for `up`.
    func foregroundServiceTarget(
        project: ComposeProject,
        services: [ComposeService],
        scaleOverrides: [String: Int],
        detach: Bool
    ) throws -> ServiceContainerTarget? {
        guard !detach else {
            return nil
        }
        guard let service = try services.reversed().first(where: { service in
            guard service.attach != false else {
                return false
            }
            return try serviceReplicaCount(service, scaleOverrides: scaleOverrides) > 0
        }) else {
            return nil
        }
        return ServiceContainerTarget(
            service: service,
            index: 1,
            name: try serviceContainerName(project: project, service: service, index: 1)
        )
    }

    /// Returns unsupported service-level volume driver fields.
    func unsupportedServiceVolumeShortcutFields(service: ComposeService) -> [(composeName: String, reason: String)] {
        var fields: [(composeName: String, reason: String)] = []
        if let volumeDriver = service.volumeDriver, !volumeDriver.isEmpty, volumeDriver.lowercased() != "local" {
            fields.append(("volume_driver", "non-local service volume drivers need an apple/container volume driver runtime gap PR"))
        }
        return fields
    }

    /// Validates service-to-service volume inheritance before side effects.
    func validateVolumesFromSupport(service: ComposeService, project: ComposeProject) throws {
        _ = try volumesFromReferences(service: service, project: project)
    }

    /// Resolves external `volumes_from` references through direct container
    /// inspection before any runtime resources are created.
    func resolveExternalVolumeMounts(project: ComposeProject, services: [ComposeService]) async throws -> ExternalVolumeMounts {
        var resolved: ExternalVolumeMounts = [:]
        let references = try externalVolumesFromReferences(project: project, services: services)
        for reference in references.sorted(by: { $0.containerName < $1.containerName }) where resolved[reference.containerName] == nil {
            guard let container = try await discoveryManager.getContainer(id: reference.containerName) else {
                throw ComposeError.invalidProject("service '\(reference.serviceName)' volumes_from '\(reference.rawValue)' references missing external container '\(reference.containerName)'")
            }
            try validateExternalVolumeMounts(container, reference: reference)
            resolved[reference.containerName] = container.mounts
        }
        return resolved
    }

    /// Rejects external mounts that cannot be represented by apple/container
    /// create/run volume arguments.
    func validateExternalVolumeMounts(_ container: ComposeContainerSummary, reference: ExternalVolumesFromReference) throws {
        for mount in container.mounts {
            let fields = (mount.unsupportedFields ?? []).filter { $0 != "volume.nocopy" }
            guard fields.isEmpty else {
                let fieldList = fields.joined(separator: ", ")
                throw ComposeError.unsupported("service '\(reference.serviceName)' uses volumes_from '\(reference.rawValue)'; external container '\(reference.containerName)' has unsupported mount fields \(fieldList)")
            }
        }
    }

    /// Returns unsupported long-form service mount fields that cannot be
    /// represented by the current apple/container `container --volume/--tmpfs` mapping.
    func unsupportedServiceMountFields(service: ComposeService, project: ComposeProject) throws -> [String]? {
        var seen = Set<String>()
        let fields = try effectiveServiceVolumes(project: project, service: service)
            .flatMap { $0.unsupportedFields ?? [] }
            .filter { $0 != "volume.nocopy" }
            .filter { field in
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
        try validateTimeoutSeconds(options.timeout, command: "up")
        if options.build, options.noBuild {
            throw ComposeError.invalidProject("--build and --no-build are incompatible")
        }
        if options.forceRecreate, options.noRecreate {
            throw ComposeError.invalidProject("--force-recreate and --no-recreate are incompatible")
        }
        if options.alwaysRecreateDeps, options.noRecreate {
            throw ComposeError.invalidProject("--always-recreate-deps and --no-recreate are incompatible")
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
    }

    /// Parses Docker Compose `--scale SERVICE=NUM` overrides.
    func parseScaleOverrides(project: ComposeProject, scales: [String]) throws -> [String: Int] {
        var overrides: [String: Int] = [:]
        for scale in scales {
            let parts = scale.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ComposeError.invalidProject("--scale requires SERVICE=NUM")
            }
            let serviceName = parts[0]
            guard project.services[serviceName] != nil else {
                throw ComposeError.invalidProject("unknown service '\(serviceName)'")
            }
            guard let count = Int(parts[1]), count >= 0 else {
                throw ComposeError.invalidProject("--scale for service '\(serviceName)' must be a non-negative integer")
            }
            overrides[serviceName] = count
        }
        return overrides
    }

    /// Returns the desired replica count for a service after CLI overrides.
    func serviceReplicaCount(_ service: ComposeService, scaleOverrides: [String: Int]) throws -> Int {
        if service.provider != nil {
            return 0
        }
        let count = scaleOverrides[service.name] ?? service.scale ?? 1
        guard count >= 0 else {
            throw ComposeError.invalidProject("service '\(service.name)' scale must be a non-negative integer")
        }
        return count
    }

    /// Returns whether a service has an explicit scale source that should prune extra replicas.
    func shouldPruneServiceReplicas(_ service: ComposeService, scaleOverrides: [String: Int]) -> Bool {
        scaleOverrides[service.name] != nil || service.scale != nil
    }

    /// Returns declared services whose existing replicas should not be treated as orphans.
    func orphanProtectedServiceNames(project: ComposeProject, scaleOverrides: [String: Int]) -> Set<String> {
        Set(project.services.values.filter { service in
            !shouldPruneServiceReplicas(service, scaleOverrides: scaleOverrides)
        }.map(\.name))
    }

    /// Validates scaled services that would collide under current local runtime primitives.
    func validateReplicaSupport(
        services: [ComposeService],
        scaleOverrides: [String: Int]
    ) throws {
        for service in services {
            let replicaCount = try serviceReplicaCount(service, scaleOverrides: scaleOverrides)
            guard replicaCount > 1 else {
                continue
            }
            if let containerName = service.containerName, !containerName.isEmpty {
                throw ComposeError.invalidProject("service '\(service.name)' uses container_name; scale greater than 1 requires Compose-managed replica names")
            }
            if let ports = service.ports, !ports.isEmpty {
                try validateScaledPublishedPorts(ports, serviceName: service.name, replicaCount: replicaCount)
            }
            if hasExplicitMACAddress(service) {
                throw ComposeError.unsupported("service '\(service.name)' uses mac_address; scaled MAC addresses would collide across replicas")
            }
        }
    }

    /// Returns true when a service sets a fixed MAC address on itself or a network.
    func hasExplicitMACAddress(_ service: ComposeService) -> Bool {
        if nonEmpty(service.macAddress) != nil {
            return true
        }
        return (service.networkOptions ?? [:]).values.contains { nonEmpty($0.macAddress) != nil }
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

    /// Validates one service's port mappings before they reach apple/container.
    func validatePublishedPorts(_ ports: [String], serviceName: String) throws {
        for port in ports {
            try validatePublishedPort(port, serviceName: serviceName)
        }
    }

    /// Validates one Docker Compose published port mapping.
    func validatePublishedPort(_ value: String, serviceName: String) throws {
        _ = try parsePublishedPortMapping(value, serviceName: serviceName)
    }

    /// Validates that a scaled service has enough explicit host ports for every replica.
    func validateScaledPublishedPorts(_ ports: [String], serviceName: String, replicaCount: Int) throws {
        guard replicaCount > 1 else {
            return
        }
        for port in ports {
            let mapping = try parsePublishedPortMapping(port, serviceName: serviceName)
            guard let hostRange = mapping.hostRange else {
                continue
            }
            let requiredHostPorts = mapping.targetRange.count * replicaCount
            guard hostRange.count >= requiredHostPorts else {
                throw ComposeError.unsupported("service '\(serviceName)' publishes '\(port)'; scaled published ports require at least \(requiredHostPorts) explicit host ports for \(replicaCount) replicas")
            }
        }
    }

    /// Parses one Compose port mapping with explicit or dynamic host ports.
    func parsePublishedPortMapping(_ value: String, serviceName: String) throws -> ParsedPublishedPortMapping {
        let protocolSplit = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let rawBinding = protocolSplit.first, !rawBinding.isEmpty else {
            throw ComposeError.invalidProject("service '\(serviceName)' has an empty port mapping")
        }
        let protocolName = try normalizedPortProtocol(protocolSplit.count == 2 ? protocolSplit[1] : "tcp")
        let parts = rawBinding.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 1 || parts.last?.isEmpty == false else {
            throw ComposeError.invalidProject("service '\(serviceName)' has invalid port mapping '\(value)'")
        }
        let target = parts[parts.count - 1]
        let targetRange = try portRange(target, field: "container", mapping: value, serviceName: serviceName)
        guard parts.count >= 2 else {
            return ParsedPublishedPortMapping(
                hostAddress: nil,
                hostRange: nil,
                targetRange: targetRange,
                protocolName: protocolName
            )
        }

        let published = parts[parts.count - 2]
        let hostParts = parts.dropLast(2)
        let hostAddress = hostParts.isEmpty ? nil : hostParts.joined(separator: ":")
        guard !published.isEmpty else {
            return ParsedPublishedPortMapping(
                hostAddress: hostAddress,
                hostRange: nil,
                targetRange: targetRange,
                protocolName: protocolName
            )
        }
        guard isExplicitHostPort(published) else {
            throw ComposeError.invalidProject("service '\(serviceName)' has invalid host port range '\(value)'")
        }
        return ParsedPublishedPortMapping(
            hostAddress: hostAddress,
            hostRange: try portRange(published, field: "host", mapping: value, serviceName: serviceName),
            targetRange: targetRange,
            protocolName: protocolName
        )
    }

    /// Returns concrete apple/container `--publish` arguments for a service replica.
    func publishedPortArguments(
        ports: [String],
        serviceName: String,
        replicaIndex: Int?,
        replicaCount: Int?
    ) throws -> [String] {
        guard let replicaIndex,
              let replicaCount,
              replicaCount > 1
        else {
            for port in ports {
                try validatePublishedPort(port, serviceName: serviceName)
            }
            return try ports.flatMap {
                try publishedPortArguments(port: $0, serviceName: serviceName)
            }
        }
        guard replicaIndex >= 1, replicaIndex <= replicaCount else {
            throw ComposeError.invalidProject("container index must be between 1 and \(replicaCount)")
        }
        return try ports.flatMap { port in
            try publishedPortArguments(
                port: port,
                serviceName: serviceName,
                replicaIndex: replicaIndex,
                replicaCount: replicaCount
            )
        }
    }

    /// Expands one Compose port mapping into concrete apple/container `--publish` values.
    func publishedPortArguments(port: String, serviceName: String) throws -> [String] {
        let mapping = try parsePublishedPortMapping(port, serviceName: serviceName)
        guard let hostRange = mapping.hostRange else {
            return try dynamicPublishedPortArguments(mapping)
        }
        guard hostRange.count == mapping.targetRange.count else {
            throw ComposeError.invalidProject("service '\(serviceName)' has mismatched port ranges '\(port)'")
        }
        return (0..<mapping.targetRange.count).map { offset in
            formatPublishedPort(
                hostAddress: mapping.hostAddress,
                hostPort: hostRange.start + offset,
                targetPort: mapping.targetRange.start + offset,
                protocolName: mapping.protocolName
            )
        }
    }

    /// Splits one scaled Compose port range into this replica's concrete mappings.
    func publishedPortArguments(
        port: String,
        serviceName: String,
        replicaIndex: Int,
        replicaCount: Int
    ) throws -> [String] {
        let mapping = try parsePublishedPortMapping(port, serviceName: serviceName)
        guard let hostRange = mapping.hostRange else {
            return try dynamicPublishedPortArguments(mapping)
        }
        let targetCount = mapping.targetRange.count
        let requiredHostPorts = targetCount * replicaCount
        guard hostRange.count >= requiredHostPorts else {
            throw ComposeError.unsupported("service '\(serviceName)' publishes '\(port)'; scaled published ports require at least \(requiredHostPorts) explicit host ports for \(replicaCount) replicas")
        }

        let replicaOffset = (replicaIndex - 1) * targetCount
        return (0..<targetCount).map { offset in
            formatPublishedPort(
                hostAddress: mapping.hostAddress,
                hostPort: hostRange.start + replicaOffset + offset,
                targetPort: mapping.targetRange.start + offset,
                protocolName: mapping.protocolName
            )
        }
    }

    /// Allocates concrete host ports for a dynamic Compose port mapping.
    func dynamicPublishedPortArguments(_ mapping: ParsedPublishedPortMapping) throws -> [String] {
        try (0..<mapping.targetRange.count).map { offset in
            let hostPort = try options.hostPortAllocator(mapping.hostAddress, mapping.protocolName)
            return formatPublishedPort(
                hostAddress: mapping.hostAddress,
                hostPort: Int(hostPort),
                targetPort: mapping.targetRange.start + offset,
                protocolName: mapping.protocolName
            )
        }
    }

    /// Formats a normalized published-port mapping for apple/container.
    func formatPublishedPort(hostAddress: String?, hostPort: Int, targetPort: Int, protocolName: String) -> String {
        var value = "\(hostPort):\(targetPort)"
        if let hostAddress, !hostAddress.isEmpty {
            value = "\(formatPublishedPortHostAddress(hostAddress)):\(value)"
        }
        if protocolName != "tcp" {
            value += "/\(protocolName)"
        }
        return value
    }

    /// Brackets IPv6 host literals so colon-delimited publish strings remain parseable.
    func formatPublishedPortHostAddress(_ hostAddress: String) -> String {
        let value = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains(":"), !value.hasPrefix("[") else {
            return value
        }
        return "[\(value)]"
    }

    /// Returns true when a publish field names concrete apple/container host ports.
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
        let driverOpts = volume.driverOpts ?? [:]
        for option in driverOpts.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--opt", "\(option.key)=\(option.value)"])
        }
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
            try await resourceManager.createVolume(ComposeVolumeCreateRequest(
                name: runtimeName,
                driver: volume.driver,
                driverOpts: driverOpts,
                labels: resourceLabels(project: project, labels: volume.labels)
            ))
        }
    }

    /// Translates one Compose build section into a `container build` command.
    func buildService(project: ComposeProject, service: ComposeService, options buildOptions: ComposeBuildOptions) async throws {
        guard let build = service.build else {
            return
        }
        try validateBuildSupport(service: service)
        var inlineDockerfileDirectory: URL?
        defer {
            if let inlineDockerfileDirectory {
                try? FileManager.default.removeItem(at: inlineDockerfileDirectory)
            }
        }
        var args = ["build"]
        guard let image = serviceImage(project: project, service: service) else {
            throw ComposeError.invalidProject("service '\(service.name)' has no image or build")
        }
        args.append(contentsOf: ["--tag", image])
        for tag in build.tags ?? [] where !tag.isEmpty && tag != image {
            args.append(contentsOf: ["--tag", tag])
        }
        if let dockerfile = nonEmpty(build.dockerfile) {
            if nonEmpty(build.dockerfileInline) != nil {
                throw ComposeError.invalidProject("service '\(service.name)' cannot define both dockerfile and dockerfile_inline")
            }
            args.append(contentsOf: ["--file", dockerfile])
        } else if let dockerfileInline = nonEmpty(build.dockerfileInline) {
            let dockerfileURL = try materializeInlineDockerfile(project: project, service: service, contents: dockerfileInline)
            inlineDockerfileDirectory = dockerfileURL.deletingLastPathComponent()
            args.append(contentsOf: ["--file", dockerfileURL.path])
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

    /// Writes Compose `dockerfile_inline` content to a temporary Dockerfile for apple/container build.
    func materializeInlineDockerfile(project: ComposeProject, service: ComposeService, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-\(project.name)-\(service.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dockerfile = directory.appendingPathComponent("Dockerfile", isDirectory: false)
        try contents.write(to: dockerfile, atomically: true, encoding: .utf8)
        return dockerfile
    }

    /// Encodes one Compose build secret for apple/container `container build --secret`.
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
    func applyPullPolicy(
        _ policy: String?,
        project: ComposeProject,
        services: [ComposeService],
        quiet: Bool = false,
        quietBuild: Bool = false,
        allowBuild: Bool = true
    ) async throws {
        guard let policy, !policy.isEmpty else {
            try await applyServicePullPolicies(
                project: project,
                services: services,
                quiet: quiet,
                quietBuild: quietBuild,
                allowBuild: allowBuild
            )
            return
        }

        switch policy {
        case "always":
            try await pull(
                project: project,
                options: ComposePullOptions {
                    $0.services = services.map(\.name)
                    $0.quiet = quiet
                }
            )
        case "missing", "if_not_present":
            try await pullMissingImages(services: services, quiet: quiet)
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

        try await applyPullPolicy(
            create.pullPolicy,
            project: project,
            services: services,
            quiet: create.quietPull,
            quietBuild: create.quietBuild,
            allowBuild: !create.noBuild && !create.build
        )

        guard create.build, !create.noBuild else {
            return
        }
        try await build(project: project, services: services.map(\.name), noCache: false, quiet: create.quietBuild)
    }

    /// Returns whether `create` should auto-build a service before container creation.
    func shouldBuildServiceForCreate(_ create: ComposeCreateOptions, service: ComposeService) -> Bool {
        !create.noBuild && !create.build && create.pullPolicy != "build" && service.pullPolicy != "build" && service.image == nil && service.build != nil
    }

    /// Returns whether `up` should auto-build a build-only service before start.
    func shouldBuildServiceForUp(_ up: ComposeUpOptions, service: ComposeService) -> Bool {
        !up.noBuild && !up.build && service.pullPolicy != "build" && service.image == nil && service.build != nil
    }

    /// Applies service-level `pull_policy` when no global pull override is set.
    func applyServicePullPolicies(
        project: ComposeProject,
        services: [ComposeService],
        quiet: Bool = false,
        quietBuild: Bool = false,
        allowBuild: Bool = true
    ) async throws {
        for service in services {
            guard let policy = service.pullPolicy, !policy.isEmpty else {
                continue
            }
            try await applyServicePullPolicy(
                policy,
                project: project,
                service: service,
                quiet: quiet,
                quietBuild: quietBuild,
                allowBuild: allowBuild
            )
        }
    }

    /// Applies the local-runtime-backed subset of Compose service pull policies.
    func applyServicePullPolicy(
        _ policy: String,
        project: ComposeProject,
        service: ComposeService,
        quiet: Bool = false,
        quietBuild: Bool = false,
        allowBuild: Bool = true
    ) async throws {
        guard let image = service.image else {
            if policy == "build", allowBuild, service.build != nil {
                try await build(project: project, services: [service.name], noCache: false, quiet: quietBuild)
            }
            return
        }
        switch policy {
        case "always":
            try await pullImage(image, quiet: quiet)
        case "missing", "if_not_present":
            try await pullMissingImage(image, quiet: quiet)
        case "never":
            return
        case "build":
            if allowBuild, service.build != nil {
                try await build(project: project, services: [service.name], noCache: false, quiet: quietBuild)
            }
        default:
            if let interval = stalePullPolicyInterval(policy) {
                try await pullImageIfStale(image, interval: interval, quiet: quiet)
                return
            }
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

    /// Applies `compose run` Linux capability overrides to the copied service
    /// model.
    func applyRunCapabilityOverrides(_ run: ComposeRunOptions, service: inout ComposeService) throws {
        try validateRunCapabilities(run.capAdd, optionName: "--cap-add")
        try validateRunCapabilities(run.capDrop, optionName: "--cap-drop")
        if !run.capAdd.isEmpty {
            service.capAdd = (service.capAdd ?? []) + run.capAdd
        }
        if !run.capDrop.isEmpty {
            service.capDrop = (service.capDrop ?? []) + run.capDrop
        }
    }

    /// Validates `compose run` capability override option values.
    func validateRunCapabilities(_ capabilities: [String], optionName: String) throws {
        if capabilities.contains(where: { $0.isEmpty }) {
            throw ComposeError.invalidProject("run \(optionName) requires a capability name")
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

    /// Rejects one-off labels that would overwrite annotation metadata.
    func validateRunLabelOverridesAgainstAnnotations(_ overrides: [ComposeLabelOverride], service: ComposeService) throws {
        _ = try effectiveServiceAnnotations(
            service: service,
            conflictingLabelKeys: [],
            conflictingOverrideKeys: Set(overrides.map(\.key))
        )
    }

    /// Pulls only service images not already present in the local image store.
    func pullMissingImages(services: [ComposeService], quiet: Bool = false) async throws {
        for service in services {
            guard let image = service.image else {
                continue
            }
            try await pullMissingImage(image, quiet: quiet)
        }
    }

    /// Pulls one image when it is absent from the local image store.
    func pullMissingImage(_ image: String, quiet: Bool = false) async throws {
        let inspectArgs = ["image", "inspect", image]
        if options.dryRun {
            try await runContainer(inspectArgs, check: false, emitOutput: false)
            try await runContainer(imagePullArguments(image, quiet: quiet))
        } else {
            try await imageManager.pullMissingImage(image)
        }
    }

    /// Pulls one image and records its successful pull timestamp.
    func pullImage(_ image: String, quiet: Bool = false) async throws {
        if options.dryRun {
            try await runContainer(imagePullArguments(image, quiet: quiet))
            return
        }
        try await imageManager.pullImage(image)
        try await pullMetadataStore.recordPullDate(options.currentDate(), for: image)
    }

    /// Pulls an image when absent or older than a Compose time-window policy.
    func pullImageIfStale(_ image: String, interval: TimeInterval, quiet: Bool = false) async throws {
        if options.dryRun {
            try await runContainer(["image", "inspect", image], check: false, emitOutput: false)
            try await runContainer(imagePullArguments(image, quiet: quiet))
            return
        }
        let exists = try await imageManager.imageExists(image)
        if !exists {
            try await pullImage(image, quiet: quiet)
            return
        }
        guard let lastPull = try await pullMetadataStore.lastPullDate(for: image) else {
            try await pullImage(image, quiet: quiet)
            return
        }
        if options.currentDate().timeIntervalSince(lastPull) >= interval {
            try await pullImage(image, quiet: quiet)
        }
    }

    /// Builds the apple/container `container image pull` dry-run arguments.
    func imagePullArguments(_ image: String, quiet: Bool) -> [String] {
        var args = ["image", "pull"]
        if quiet {
            args.append(contentsOf: ["--progress", "none"])
        }
        args.append(image)
        return args
    }

    /// Builds the `container run` argument vector for a service.
    private func runArguments(
        project: ComposeProject,
        service: ComposeService,
        options run: RunArgumentOptions = RunArgumentOptions(),
        externalVolumeMounts: ExternalVolumeMounts = [:]
    ) throws -> [String] {
        var args = [run.command]
        let runtimeName: String
        if let containerNameOverride = run.containerNameOverride {
            runtimeName = slug(containerNameOverride)
        } else if let containerIndex = run.containerIndex {
            runtimeName = try serviceContainerName(project: project, service: service, index: containerIndex)
        } else {
            runtimeName = containerName(project: project, service: service, oneOff: run.oneOff)
        }
        args.append(contentsOf: ["--name", runtimeName])
        if run.detach {
            args.append("--detach")
        }
        if run.remove {
            args.append("--rm")
        }

        for label in try serviceLabels(
            project: project,
            service: service,
            oneOff: run.oneOff,
            externalVolumeMounts: externalVolumeMounts
        ) {
            args.append(contentsOf: ["--label", label])
        }
        let effectiveLabels = try effectiveServiceLabels(project: project, service: service)
        let overriddenLabelKeys = Set(run.labelOverrides.map(\.key))
        let effectiveAnnotations = try effectiveServiceAnnotations(
            service: service,
            conflictingLabelKeys: Set(effectiveLabels.keys),
            conflictingOverrideKeys: overriddenLabelKeys
        )
        for (key, value) in effectiveLabels.sorted(by: { $0.key < $1.key }) where !overriddenLabelKeys.contains(key) {
            args.append(contentsOf: ["--label", "\(key)=\(value)"])
        }
        for (key, value) in effectiveAnnotations.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(key)=\(value)"])
        }
        for label in run.labelOverrides {
            args.append(contentsOf: ["--label", label.rawValue])
        }
        if let logDriver = runtimeLogDriverArgument(service: service) {
            args.append(contentsOf: ["--log-driver", logDriver])
        }
        args.append(contentsOf: runtimeLogOptionArguments(service: service))
        args.append(contentsOf: try runtimeHealthCheckArguments(service: service))
        if !run.oneOff, let restartPolicy = try runtimeRestartPolicyArgument(service: service) {
            args.append(contentsOf: ["--restart", restartPolicy])
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
        let publishedPorts = try publishedPortArguments(
            ports: run.publishedPorts ?? service.ports ?? [],
            serviceName: service.name,
            replicaIndex: run.containerIndex,
            replicaCount: run.replicaCount
        )
        for port in publishedPorts {
            args.append(contentsOf: ["--publish", port])
        }
        let mountContext = MountRenderContext(
            project: project,
            service: service,
            containerIndex: run.containerIndex,
            replicaCount: run.replicaCount
        )
        for mount in try effectiveServiceVolumes(
            project: project,
            service: service,
            externalVolumeMounts: externalVolumeMounts
        ) {
            try appendMount(mount, context: mountContext, args: &args)
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
    func startDependencyServices(
        project: ComposeProject,
        services: [ComposeService],
        externalVolumeMounts: ExternalVolumeMounts = [:]
    ) async throws -> ComposeProject {
        var workingProject = project
        try await applyServicePullPolicies(project: workingProject, services: services)
        for serviceReference in services {
            let service = workingProject.services[serviceReference.name] ?? serviceReference
            if service.provider != nil {
                let variables = try await runProvider(project: workingProject, service: service, action: .up)
                if !variables.isEmpty {
                    workingProject = projectByInjectingProviderEnvironment(
                        project: workingProject,
                        providerServiceName: service.name,
                        variables: variables
                    )
                }
                continue
            }

            if service.image == nil, service.pullPolicy != "build", service.build != nil {
                try await build(project: workingProject, services: [service.name], noCache: false)
            }

            let name = containerName(project: workingProject, service: service, oneOff: false)
            let existing = try await inspectContainer(name)
            if let existing, existing.configHash == (try configHash(
                project: workingProject,
                service: service,
                externalVolumeMounts: externalVolumeMounts
            )) {
                options.emit("compose: reusing existing container \(name)")
                continue
            }
            if existing != nil {
                try await stopContainer(service: service, containerName: name)
                try await deleteContainer(name)
            }

            try await runContainer(
                try runArguments(
                    project: workingProject,
                    service: service,
                    options: RunArgumentOptions {
                        $0.detach = true
                    },
                    externalVolumeMounts: externalVolumeMounts
                )
            )
            try await runPostStartHooks(service: service, containerID: name)
        }
        return workingProject
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

    /// Converts Compose log timestamp filters to absolute dates.
    func runtimeLogTimestamp(_ value: String?) throws -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        if let date = ContainerLogTimestampParser.parse(value, relativeTo: options.currentDate()) {
            return date
        }
        throw ComposeError.invalidProject("logs time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations")
    }

    /// Waits for Compose dependency conditions that require runtime state.
    func waitForDependencyConditions(project: ComposeProject, service: ComposeService) async throws {
        for (dependencyName, metadata) in serviceDependencies(service) {
            if metadata.required == false, project.services[dependencyName] == nil {
                continue
            }
            guard let dependency = project.services[dependencyName] else {
                throw ComposeError.invalidProject("service '\(service.name)' depends on unknown service '\(dependencyName)'")
            }
            switch metadata.condition {
            case "service_completed_successfully":
                try await waitForCompletedDependency(project: project, service: service, dependency: dependency)
            case "service_healthy":
                try await waitForHealthyDependency(project: project, service: service, dependency: dependency)
            default:
                continue
            }
        }
    }

    /// Waits for every target container of a dependency service to finish
    /// successfully before starting the dependent service.
    func waitForCompletedDependency(
        project: ComposeProject,
        service: ComposeService,
        dependency: ComposeService
    ) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [dependency])
        guard !targets.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' dependency '\(dependency.name)' has no containers")
        }
        for target in targets {
            let exitCode = try await completedDependencyExitCode(for: target, dependentService: service)
            guard exitCode == 0 else {
                throw ComposeError.invalidProject("service '\(service.name)' dependency '\(dependency.name)' container '\(target.name)' exited with status \(exitCode)")
            }
        }
    }

    /// Resolves a dependency target's exit code, using stored exit metadata
    /// for stopped containers and runtime wait for live containers.
    func completedDependencyExitCode(
        for target: ServiceContainerTarget,
        dependentService: ComposeService
    ) async throws -> Int32 {
        if options.dryRun {
            try await runContainer(["wait", target.name])
            return 0
        }
        guard let container = try await discoveryManager.getContainer(id: target.name) else {
            throw ComposeError.invalidProject("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' does not exist")
        }
        switch container.status.lowercased() {
        case "stopped":
            guard let exitCode = container.exitCode else {
                throw ComposeError.unsupported("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' is stopped but has no stored exit code")
            }
            return exitCode
        case "running", "stopping":
            return try await lifecycleManager.waitContainer(id: target.name)
        default:
            throw ComposeError.unsupported("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' is \(container.status)")
        }
    }

    /// Waits for every target container of a dependency service to report a
    /// healthy status before starting the dependent service.
    func waitForHealthyDependency(
        project: ComposeProject,
        service: ComposeService,
        dependency: ComposeService
    ) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [dependency])
        guard !targets.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' dependency '\(dependency.name)' has no containers")
        }
        for target in targets {
            try await waitForHealthyDependencyTarget(target, dependentService: service)
        }
    }

    /// Waits for one dependency target to transition from starting to healthy.
    func waitForHealthyDependencyTarget(
        _ target: ServiceContainerTarget,
        dependentService: ComposeService
    ) async throws {
        if options.dryRun {
            try await runContainer(["inspect", target.name])
            return
        }
        while true {
            guard let container = try await discoveryManager.getContainer(id: target.name) else {
                throw ComposeError.invalidProject("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' does not exist")
            }
            switch container.health {
            case "healthy":
                return
            case "starting":
                try await options.sleep(.milliseconds(250))
            case "unhealthy":
                throw ComposeError.invalidProject("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' is unhealthy")
            case "none", nil:
                throw ComposeError.unsupported("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' has no health status")
            case let health?:
                throw ComposeError.unsupported("service '\(dependentService.name)' dependency '\(target.service.name)' container '\(target.name)' has unsupported health status '\(health)'")
            }
        }
    }

    /// Validates that attach stays on the output-only log-follow path apple/container exposes today.
    func validateAttachOptions(_ attach: ComposeAttachOptions) throws {
        if let detachKeys = attach.detachKeys, !detachKeys.isEmpty {
            throw ComposeError.unsupported("attach --detach-keys: apple/container does not expose detach-key handling for interactive attach")
        }
        if !attach.noStdin {
            throw ComposeError.unsupported("attach: apple/container does not expose stdin/stdout/stderr reattach for already-running service containers; use --no-stdin --sig-proxy=false for output-only logs")
        }
        let sigProxy = attach.sigProxy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sigProxy != "false" {
            throw ComposeError.unsupported("attach --sig-proxy=\(attach.sigProxy): apple/container does not expose signal proxying for interactive attach; use --sig-proxy=false with --no-stdin")
        }
    }

    /// Returns a stopped container's stored exit code, or nil when the target
    /// is live and should be waited through apple/container.
    func stoppedWaitExitCode(_ target: ServiceContainerTarget) async throws -> Int32? {
        guard let container = try await discoveryManager.getContainer(id: target.name) else {
            throw ComposeError.invalidProject("service '\(target.service.name)' container '\(target.name)' does not exist")
        }
        return try stoppedWaitExitCode(container, service: target.service)
    }

    /// Returns a stopped container's stored exit code, or nil when the target
    /// is live and should be waited through apple/container.
    func stoppedWaitExitCode(_ container: ComposeContainerSummary, service: ComposeService) throws -> Int32? {
        let status = container.status.lowercased()
        switch status {
        case "stopped":
            guard let exitCode = container.exitCode else {
                throw ComposeError.unsupported("wait: service '\(service.name)' container '\(container.id)' is stopped but has no stored exit code")
            }
            return exitCode
        case "running", "stopping":
            return nil
        default:
            throw ComposeError.unsupported("wait: service '\(service.name)' container '\(container.id)' is \(container.status)")
        }
    }

    /// Waits for the first selected service container to exit, then drops the project.
    func waitThenDownProject(project: ComposeProject, targets: [ServiceContainerTarget]) async throws {
        if options.dryRun {
            for target in targets {
                try await runContainer(["wait", target.name])
            }
            try await down(project: project, options: ComposeDownOptions())
            return
        }
        for target in targets {
            if let exitCode = try await stoppedWaitExitCode(target) {
                options.emit(String(exitCode))
                try await down(project: project, options: ComposeDownOptions())
                return
            }
        }
        let result = try await waitForFirstServiceContainerExit(targets)
        options.emit(String(result.exitCode))
        try await down(project: project, options: ComposeDownOptions())
    }

    /// Races service container waits so `--down-project` can clean up after
    /// the first selected service container exits.
    func waitForFirstServiceContainerExit(_ targets: [ServiceContainerTarget]) async throws -> ServiceContainerWaitResult {
        let lifecycleManager = lifecycleManager
        let waitTasks = targets.map(\.name).map { containerID in
            Task {
                ServiceContainerWaitResult(
                    exitCode: try await lifecycleManager.waitContainer(id: containerID)
                )
            }
        }
        defer {
            waitTasks.forEach { $0.cancel() }
        }
        return try await withThrowingTaskGroup(of: ServiceContainerWaitResult.self) { group in
            for waitTask in waitTasks {
                group.addTask {
                    try await waitTask.value
                }
            }
            guard let result = try await group.next() else {
                throw ComposeError.invalidProject("wait requires at least one service container")
            }
            group.cancelAll()
            return result
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
        requested: (target: String, protocolName: String),
        index: Int
    ) throws {
        guard index >= 1 else {
            throw ComposeError.invalidProject("container index must be greater than zero")
        }
        let replicaCount = max(service.scale ?? 1, index)
        let ports = try dryRunPublishedPorts(service: service, replicaIndex: index, replicaCount: replicaCount)
        guard let mapping = publishedPort(in: ports, target: requested.target, protocolName: requested.protocolName) else {
            throw ComposeError.invalidProject("service '\(service.name)' does not publish target port \(requested.target)/\(requested.protocolName)")
        }
        options.emit("\(mapping.hostAddress):\(mapping.hostPort)")
    }

    /// Expands Compose metadata into dry-run published ports for one service replica.
    func dryRunPublishedPorts(service: ComposeService, replicaIndex: Int, replicaCount: Int) throws -> [ComposeContainerPublishedPort] {
        let portArguments = try publishedPortArguments(
            ports: service.ports ?? [],
            serviceName: service.name,
            replicaIndex: replicaCount > 1 ? replicaIndex : nil,
            replicaCount: replicaCount > 1 ? replicaCount : nil
        )
        return try portArguments.flatMap {
            try dryRunPublishedPorts(from: $0, serviceName: service.name)
        }
    }

    /// Expands one explicit Compose port mapping for dry-run `port` previews.
    func dryRunPublishedPorts(from value: String, serviceName: String) throws -> [ComposeContainerPublishedPort] {
        let mapping = try parsePublishedPortMapping(value, serviceName: serviceName)
        if mapping.usesDynamicHostPorts {
            return try dynamicPublishedPortArguments(mapping).flatMap {
                try dryRunPublishedPorts(from: $0, serviceName: serviceName)
            }
        }
        guard let hostRange = mapping.hostRange,
              hostRange.count == mapping.targetRange.count
        else {
            throw ComposeError.invalidProject("service '\(serviceName)' has mismatched port ranges '\(value)'")
        }

        return (0..<hostRange.count).map { offset in
            ComposeContainerPublishedPort(
                hostAddress: mapping.hostAddress ?? "0.0.0.0",
                hostPort: UInt16(hostRange.start + offset),
                containerPort: UInt16(mapping.targetRange.start + offset),
                protocolName: mapping.protocolName
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
    func appendMount(_ mount: ComposeMount, context: MountRenderContext, args: inout [String]) throws {
        if mount.type == "tmpfs" {
            guard let target = mount.target else {
                throw ComposeError.invalidProject("tmpfs mount is missing target")
            }
            if mountRequiresTypedTmpfsArgument(mount) {
                args.append(contentsOf: ["--mount", typedTmpfsMountArgument(mount, target: target)])
            } else {
                args.append(contentsOf: ["--tmpfs", target])
            }
            return
        }
        guard let target = mount.target else {
            throw ComposeError.invalidProject("volume mount is missing target")
        }
        let source = mount.source ?? ""
        let mappedSource: String
        if mount.type == "volume", !source.isEmpty {
            mappedSource = volumeRuntimeName(project: context.project, composeName: source)
        } else if source.isEmpty {
            mappedSource = anonymousVolumeRuntimeName(context: context, target: target)
        } else {
            mappedSource = source
        }

        var value = "\(mappedSource):\(target)"
        if mount.readOnly == true {
            value += ":ro"
        }
        args.append(contentsOf: ["--volume", value])
    }

    /// Returns whether a tmpfs mount needs the typed `--mount` form.
    func mountRequiresTypedTmpfsArgument(_ mount: ComposeMount) -> Bool {
        mount.readOnly == true || nonEmpty(mount.tmpfsSize) != nil || nonEmpty(mount.tmpfsMode) != nil
    }

    /// Builds a typed apple/container `container --mount` value for long-form tmpfs options.
    func typedTmpfsMountArgument(_ mount: ComposeMount, target: String) -> String {
        var fields = [
            "type=tmpfs",
            "destination=\(target)",
        ]
        if mount.readOnly == true {
            fields.append("readonly")
        }
        if let size = nonEmpty(mount.tmpfsSize) {
            fields.append("size=\(size)")
        }
        if let mode = nonEmpty(mount.tmpfsMode) {
            fields.append("mode=\(mode)")
        }
        return fields.joined(separator: ",")
    }

    /// Returns stable runtime names for anonymous volumes attached to service
    /// container targets.
    func anonymousVolumeRuntimeNames(project: ComposeProject, targets: [ServiceContainerTarget]) throws -> [String] {
        let targetCounts = Dictionary(grouping: targets, by: { $0.service.name }).mapValues(\.count)
        let names = try targets.flatMap { serviceTarget in
            try effectiveServiceVolumes(project: project, service: serviceTarget.service).compactMap { mount -> String? in
                guard mount.type == "volume", mount.source?.isEmpty != false, let mountTarget = mount.target else {
                    return nil
                }
                let replicaCount = targetCounts[serviceTarget.service.name] ?? 1
                return anonymousVolumeRuntimeName(
                    project: project,
                    service: serviceTarget.service,
                    target: mountTarget,
                    containerIndex: serviceTarget.index,
                    replicaCount: replicaCount
                )
            }
        }
        return Array(Set(names)).sorted()
    }

    /// Returns the project-scoped name used for an anonymous Compose service
    /// volume.
    func anonymousVolumeRuntimeName(context: MountRenderContext, target: String) -> String {
        anonymousVolumeRuntimeName(
            project: context.project,
            service: context.service,
            target: target,
            containerIndex: context.containerIndex,
            replicaCount: context.replicaCount
        )
    }

    /// Returns the project-scoped name used for an anonymous Compose service
    /// volume.
    func anonymousVolumeRuntimeName(
        project: ComposeProject,
        service: ComposeService,
        target: String,
        containerIndex: Int?,
        replicaCount: Int?
    ) -> String {
        guard let containerIndex, containerIndex >= 1, (replicaCount ?? 1) > 1 else {
            return anonymousVolumeRuntimeName(project: project, target: target)
        }
        return resourceName(project: project.name, name: "anon-\(slug(service.name))-\(containerIndex)-\(stableHash(target).prefix(12))")
    }

    /// Returns the project-scoped name used for an anonymous Compose volume.
    func anonymousVolumeRuntimeName(project: ComposeProject, target: String) -> String {
        resourceName(project: project.name, name: "anon-\(stableHash(target).prefix(12))")
    }

    /// Starts a service container and runs `post_start` hooks while preserving
    /// dry-run command rendering.
    func startContainer(service: ComposeService, containerName: String) async throws {
        try validateLifecycleHookSupport(service: service)
        let args = ["start", containerName]
        if options.dryRun {
            try await runContainer(args)
        } else {
            try await lifecycleManager.startContainer(id: containerName)
        }
        try await runPostStartHooks(service: service, containerID: containerName)
    }

    /// Stops a service container through the direct API while preserving
    /// dry-run command rendering.
    func stopContainer(service: ComposeService, containerName: String, timeout: Int? = nil) async throws {
        try validateLifecycleHookSupport(service: service)
        try await runPreStopHooks(service: service, containerID: containerName)
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
        try await startContainer(service: service, containerName: containerName)
    }

    /// Stops a container that may not map to a declared service, such as an
    /// orphan container discovered from project labels.
    func stopContainer(id: String, timeout: Int? = nil) async throws {
        var args = ["stop"]
        if let timeout {
            args.append(contentsOf: ["--time", "\(timeout)"])
        }
        args.append(id)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await lifecycleManager.stopContainer(id: id, signal: nil, timeoutInSeconds: timeout)
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
    func removeRemainingProjectContainers(
        project: ComposeProject,
        excluding declaredContainers: Set<String>,
        preservingServices serviceNames: Set<String> = [],
        timeout: Int? = nil
    ) async throws {
        let args = ["list", "--format", "json", "--all"]
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let remainingContainers = try await projectContainers(projectName: project.name, all: true)
            .filter { container in
                guard !declaredContainers.contains(container.id) else {
                    return false
                }
                let isPreservedService = container.serviceName.map { serviceNames.contains($0) } ?? false
                return container.isOneOff || !isPreservedService
            }
            .sorted { $0.id < $1.id }
        for container in remainingContainers {
            try await stopRemainingProjectContainer(project: project, container: container, timeout: timeout)
            try await deleteContainer(container.id)
        }
    }

    /// Stops a project-scoped cleanup target with service hooks when its
    /// Compose service still exists in the current model.
    func stopRemainingProjectContainer(
        project: ComposeProject,
        container: ComposeContainerSummary,
        timeout: Int? = nil
    ) async throws {
        guard let serviceName = container.serviceName,
              let service = project.services[serviceName] else {
            try await stopContainer(id: container.id, timeout: timeout)
            return
        }
        try await stopContainer(service: service, containerName: container.id, timeout: timeout)
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
        let attachedVolumeNames = try serviceAttachedVolumeRuntimeNames(project: project, services: services)
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
    func serviceAttachedVolumeRuntimeNames(project: ComposeProject, services: [ComposeService]) throws -> Set<String> {
        var names = Set<String>()
        for service in services {
            for mount in try effectiveServiceVolumes(project: project, service: service) where mount.type == "volume" {
                if let source = mount.source, !source.isEmpty {
                    names.insert(volumeRuntimeName(project: project, composeName: source))
                } else if let target = mount.target {
                    names.insert(anonymousVolumeRuntimeName(project: project, target: target))
                    let replicaCount = try serviceReplicaCount(service, scaleOverrides: [:])
                    if replicaCount > 1 {
                        for index in 1...replicaCount {
                            names.insert(
                                anonymousVolumeRuntimeName(
                                    project: project,
                                    service: service,
                                    target: target,
                                    containerIndex: index,
                                    replicaCount: replicaCount
                                )
                            )
                        }
                    }
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

    /// Returns the supported MTU driver option value accepted by apple/container.
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
private let supportedHealthCheckKeys = Set([
    "disable",
    "interval",
    "retries",
    "start_interval",
    "start_period",
    "test",
    "timeout",
])
private let healthCheckDurationFields = [
    (composeName: "interval", runtimeName: "--health-interval"),
    (composeName: "timeout", runtimeName: "--health-timeout"),
    (composeName: "start_period", runtimeName: "--health-start-period"),
    (composeName: "start_interval", runtimeName: "--health-start-interval"),
]
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
    ["always", "missing", "if_not_present", "never", "build"].contains(policy) || stalePullPolicyInterval(policy) != nil
}

/// Returns the refresh interval for Compose time-window pull policies.
private func stalePullPolicyInterval(_ policy: String) -> TimeInterval? {
    switch policy {
    case "daily":
        return 24 * 60 * 60
    case "weekly":
        return 7 * 24 * 60 * 60
    default:
        guard policy.hasPrefix("every_") else {
            return nil
        }
        return parsePullPolicyDuration(String(policy.dropFirst("every_".count))).map(TimeInterval.init)
    }
}

/// Parses Compose duration suffixes such as `1h30m` into seconds.
private func parsePullPolicyDuration(_ value: String) -> Int? {
    guard !value.isEmpty else {
        return nil
    }
    var index = value.startIndex
    var total = 0
    while index < value.endIndex {
        let digitStart = index
        while index < value.endIndex, value[index].isNumber {
            index = value.index(after: index)
        }
        guard digitStart < index,
              let amount = Int(value[digitStart..<index]),
              index < value.endIndex,
              let multiplier = pullPolicyDurationMultiplier(value[index]) else {
            return nil
        }
        total += amount * multiplier
        index = value.index(after: index)
    }
    return total > 0 ? total : nil
}

/// Returns the seconds represented by one Compose pull-policy duration unit.
private func pullPolicyDurationMultiplier(_ unit: Character) -> Int? {
    switch unit {
    case "w":
        return 7 * 24 * 60 * 60
    case "d":
        return 24 * 60 * 60
    case "h":
        return 60 * 60
    case "m":
        return 60
    case "s":
        return 1
    default:
        return nil
    }
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

/// Builds the single network attachment value accepted by apple/container.
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

/// Config or secret kind used by service file-grant mount rendering.
private enum ComposeFileMountKind {
    case config
    case secret

    var singularName: String {
        switch self {
        case .config:
            "config"
        case .secret:
            "secret"
        }
    }

    var pluralName: String {
        switch self {
        case .config:
            "configs"
        case .secret:
            "secrets"
        }
    }

    func targetPath(source: String, target: String?) -> String {
        guard let target = nonEmpty(target?.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            switch self {
            case .config:
                return "/\(source)"
            case .secret:
                return "/run/secrets/\(source)"
            }
        }
        if target.hasPrefix("/") {
            return target
        }
        switch self {
        case .config:
            return "/\(target)"
        case .secret:
            return "/run/secrets/\(target)"
        }
    }
}

/// Service-level config or secret grant after reading Compose's short or long
/// syntax from the normalized JSON model.
private struct ComposeFileGrant {
    var source: String
    var target: String?
}

private extension ComposeValue {
    var boolValue: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            let number = NSDecimalNumber(decimal: value)
            guard number.decimalValue == value else {
                return nil
            }
            let int = number.intValue
            return Decimal(int) == value ? int : nil
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }
}

/// Resolves a project-relative file path the same way Compose paths are loaded.
private func resolvedProjectPath(_ path: String, project: ComposeProject) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    return URL(
        fileURLWithPath: expanded,
        relativeTo: URL(fileURLWithPath: project.workingDirectory, isDirectory: true)
    ).standardizedFileURL.path
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

/// Returns Compose service dependencies, including service-scoped
/// `volumes_from` references that Compose-go treats as implicit dependencies.
private func serviceDependencies(
    _ service: ComposeService
) -> [(key: String, value: ComposeDependency)] {
    var dependencies = service.dependsOn ?? [:]
    for name in serviceVolumesFromDependencyNames(service) where dependencies[name] == nil {
        dependencies[name] = ComposeDependency(condition: "service_started")
    }
    return dependencies.sorted(by: { $0.key < $1.key })
}

/// Returns service names referenced by `volumes_from`, ignoring external
/// container references that should not affect project service ordering.
private func serviceVolumesFromDependencyNames(_ service: ComposeService) -> [String] {
    (service.volumesFrom ?? []).compactMap { reference in
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("container:") else {
            return nil
        }
        return trimmed.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init)
    }
}

/// Returns external containers referenced through `volumes_from`.
private func externalVolumesFromReferences(
    project: ComposeProject,
    services: [ComposeService]
) throws -> [ExternalVolumesFromReference] {
    try services.flatMap {
        try externalVolumesFromReferences(project: project, service: $0, stack: [])
    }
}

/// Recursively collects external inherited volume sources from a service and
/// any same-project services it inherits from.
private func externalVolumesFromReferences(
    project: ComposeProject,
    service: ComposeService,
    stack: [String]
) throws -> [ExternalVolumesFromReference] {
    if stack.contains(service.name) {
        let cycle = (stack + [service.name]).joined(separator: " -> ")
        throw ComposeError.invalidProject("volume inheritance cycle involving \(cycle)")
    }

    var references: [ExternalVolumesFromReference] = []
    for reference in try volumesFromReferences(service: service, project: project) {
        switch reference.source {
        case .service(let serviceName):
            guard let sourceService = project.services[serviceName] else {
                throw ComposeError.invalidProject("service '\(service.name)' volumes_from references unknown service '\(serviceName)'")
            }
            references.append(contentsOf: try externalVolumesFromReferences(
                project: project,
                service: sourceService,
                stack: stack + [service.name]
            ))
        case .externalContainer(let containerName):
            references.append(ExternalVolumesFromReference(
                serviceName: service.name,
                rawValue: reference.rawValue,
                containerName: containerName
            ))
        }
    }
    return references
}

/// Expands `volumes_from` references into concrete mounts.
private func effectiveServiceVolumes(
    project: ComposeProject,
    service: ComposeService,
    externalVolumeMounts: ExternalVolumeMounts? = nil
) throws -> [ComposeMount] {
    try effectiveServiceVolumes(
        project: project,
        service: service,
        externalVolumeMounts: externalVolumeMounts,
        stack: []
    )
}

/// Recursively resolves inherited service mounts while detecting cycles in
/// hand-built test models that did not pass through Compose-go validation.
private func effectiveServiceVolumes(
    project: ComposeProject,
    service: ComposeService,
    externalVolumeMounts: ExternalVolumeMounts?,
    stack: [String]
) throws -> [ComposeMount] {
    if stack.contains(service.name) {
        let cycle = (stack + [service.name]).joined(separator: " -> ")
        throw ComposeError.invalidProject("volume inheritance cycle involving \(cycle)")
    }

    var volumes: [ComposeMount] = []
    for reference in try volumesFromReferences(service: service, project: project) {
        switch reference.source {
        case .service(let serviceName):
            guard let sourceService = project.services[serviceName] else {
                throw ComposeError.invalidProject("service '\(service.name)' volumes_from references unknown service '\(serviceName)'")
            }
            let inherited = try effectiveServiceVolumes(
                project: project,
                service: sourceService,
                externalVolumeMounts: externalVolumeMounts,
                stack: stack + [service.name]
            )
            volumes.append(contentsOf: inherited.map {
                mount($0, applyingVolumesFromReadOnly: reference.readOnly)
            })
        case .externalContainer(let containerName):
            guard let externalVolumeMounts else {
                continue
            }
            guard let inherited = externalVolumeMounts[containerName] else {
                throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(reference.rawValue)' references missing external container '\(containerName)'")
            }
            volumes.append(contentsOf: inherited.map {
                mount($0, applyingVolumesFromReadOnly: reference.readOnly)
            })
        }
    }
    volumes.append(contentsOf: service.volumes ?? [])
    volumes.append(contentsOf: try serviceConfigSecretMounts(project: project, service: service))
    return volumes
}

/// Converts supported file-backed service configs and secrets into read-only
/// bind mounts accepted by apple/container `container --volume`.
private func serviceConfigSecretMounts(project: ComposeProject, service: ComposeService) throws -> [ComposeMount] {
    try serviceConfigSecretMounts(
        project: project,
        service: service,
        kind: .config,
        grants: service.configs ?? [],
        definitions: project.configs ?? [:]
    ) + serviceConfigSecretMounts(
        project: project,
        service: service,
        kind: .secret,
        grants: service.secrets ?? [],
        definitions: project.secrets ?? [:]
    )
}

/// Converts one config or secret grant list into bind mounts.
private func serviceConfigSecretMounts(
    project: ComposeProject,
    service: ComposeService,
    kind: ComposeFileMountKind,
    grants: [ComposeValue],
    definitions: [String: ComposeValue]
) throws -> [ComposeMount] {
    try grants.map { value in
        let grant = try parseComposeFileGrant(value, kind: kind, service: service)
        let source = try composeFileGrantSourcePath(
            grant: grant,
            definitions: definitions,
            project: project,
            service: service,
            kind: kind
        )
        return ComposeMount(
            type: "bind",
            source: source,
            target: kind.targetPath(source: grant.source, target: grant.target),
            readOnly: true
        )
    }
}

/// Parses one normalized service config or secret reference.
private func parseComposeFileGrant(
    _ value: ComposeValue,
    kind: ComposeFileMountKind,
    service: ComposeService
) throws -> ComposeFileGrant {
    switch value {
    case .string(let source):
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' \(kind.singularName) reference must not be empty")
        }
        return ComposeFileGrant(source: source)
    case .object(let fields):
        guard let source = fields["source"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' \(kind.singularName) reference is missing source")
        }
        return ComposeFileGrant(
            source: source,
            target: fields["target"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    default:
        throw ComposeError.invalidProject("service '\(service.name)' \(kind.singularName) reference must be a string or object")
    }
}

/// Resolves the top-level file source for one service config or secret grant.
private func composeFileGrantSourcePath(
    grant: ComposeFileGrant,
    definitions: [String: ComposeValue],
    project: ComposeProject,
    service: ComposeService,
    kind: ComposeFileMountKind
) throws -> String {
    guard let definition = definitions[grant.source] else {
        throw ComposeError.invalidProject("service '\(service.name)' references undefined \(kind.singularName) '\(grant.source)'")
    }
    guard case .object(let fields) = definition else {
        throw ComposeError.invalidProject("\(kind.singularName.capitalized) '\(grant.source)' definition must be an object")
    }
    if fields["external"]?.boolValue == true {
        throw ComposeError.unsupported("service '\(service.name)' uses external \(kind.singularName) '\(grant.source)'; external \(kind.pluralName) need an apple/container \(kind.singularName) store primitive")
    }
    if let file = fields["file"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !file.isEmpty {
        return resolvedProjectPath(file, project: project)
    }
    if fields["environment"]?.stringValue != nil {
        throw ComposeError.unsupported("service '\(service.name)' uses environment-backed \(kind.singularName) '\(grant.source)'; environment-backed \(kind.pluralName) need an apple/container \(kind.singularName) materialization primitive")
    }
    if fields["content"]?.stringValue != nil {
        throw ComposeError.unsupported("service '\(service.name)' uses content-backed \(kind.singularName) '\(grant.source)'; inline \(kind.pluralName) need an apple/container \(kind.singularName) materialization primitive")
    }
    throw ComposeError.invalidProject("\(kind.singularName.capitalized) '\(grant.source)' must define file for runtime mounting")
}

/// Parses and validates supported `volumes_from` references.
private func volumesFromReferences(
    service: ComposeService,
    project: ComposeProject
) throws -> [ParsedVolumesFromReference] {
    try (service.volumesFrom ?? []).map {
        try parseVolumesFromReference($0, service: service, project: project)
    }
}

/// Parses one `volumes_from` entry.
private func parseVolumesFromReference(
    _ rawValue: String,
    service: ComposeService,
    project: ComposeProject
) throws -> ParsedVolumesFromReference {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from contains an empty reference")
    }

    if trimmed.hasPrefix("container:") {
        let containerReference = String(trimmed.dropFirst("container:".count))
        let parts = containerReference.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let containerName = parts.first ?? ""
        guard parts.count <= 2 else {
            throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' must use SERVICE[:ro|rw] or container:NAME[:ro|rw]")
        }
        let readOnly = try volumesFromReadOnlyMode(parts.count == 2 ? parts[1] : nil, rawValue: rawValue, service: service)
        guard !containerName.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' is missing an external container name")
        }
        return ParsedVolumesFromReference(
            source: .externalContainer(containerName),
            readOnly: readOnly,
            rawValue: rawValue
        )
    }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard let sourceName = parts.first, !sourceName.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' is missing a source service")
    }
    guard parts.count <= 2 else {
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' must use SERVICE[:ro|rw] or container:NAME[:ro|rw]")
    }
    guard project.services[sourceName] != nil else {
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' references unknown service '\(sourceName)'")
    }
    let readOnly = try volumesFromReadOnlyMode(parts.count == 2 ? parts[1] : nil, rawValue: rawValue, service: service)
    return ParsedVolumesFromReference(source: .service(sourceName), readOnly: readOnly, rawValue: rawValue)
}

/// Converts `volumes_from` access mode into the inherited mount readonly flag.
private func volumesFromReadOnlyMode(
    _ mode: String?,
    rawValue: String,
    service: ComposeService
) throws -> Bool? {
    guard let mode, !mode.isEmpty else {
        return nil
    }
    switch mode {
    case "ro", "readonly":
        return true
    case "rw":
        return false
    default:
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' mode must be ro or rw")
    }
}

/// Applies a `volumes_from` readonly override to an inherited mount.
private func mount(_ mount: ComposeMount, applyingVolumesFromReadOnly readOnly: Bool?) -> ComposeMount {
    guard let readOnly else {
        return mount
    }
    var inherited = mount
    inherited.readOnly = readOnly
    return inherited
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
private func serviceLabels(
    project: ComposeProject,
    service: ComposeService,
    oneOff: Bool,
    externalVolumeMounts: ExternalVolumeMounts = [:]
) throws -> [String] {
    var labels = resourceLabels(project: project)
    labels.append("\(serviceLabel)=\(service.name)")
    labels.append("\(oneOffLabel)=\(oneOff)")
    let serviceConfigHash = try configHash(
        project: project,
        service: service,
        externalVolumeMounts: externalVolumeMounts
    )
    labels.append("\(configHashLabel)=\(serviceConfigHash)")
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
private func configHash(
    project: ComposeProject,
    service: ComposeService,
    externalVolumeMounts: ExternalVolumeMounts = [:]
) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var effectiveService = service
    effectiveService.labels = try effectiveServiceLabels(project: project, service: service)
    effectiveService.labelFiles = nil
    effectiveService.deployLabels = nil
    effectiveService.volumes = try effectiveServiceVolumes(
        project: project,
        service: service,
        externalVolumeMounts: externalVolumeMounts
    )
    let fingerprint = ServiceConfigFingerprint(
        service: effectiveService,
        networks: serviceNetworkRuntimeNames(project: project, service: service),
        volumes: try serviceVolumeRuntimeNames(
            project: project,
            service: service,
            externalVolumeMounts: externalVolumeMounts
        )
    )
    guard let data = try? encoder.encode(fingerprint) else {
        return stableHash(service.name)
    }
    return stableHash(String(decoding: data, as: UTF8.self))
}

/// Validates user-supplied service labels and label files before side effects.
private func validateServiceLabels(project: ComposeProject, service: ComposeService) throws {
    let labels = try effectiveServiceLabels(project: project, service: service)
    _ = try effectiveServiceAnnotations(service: service, conflictingLabelKeys: Set(labels.keys))
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

/// Returns Compose service annotations mapped to apple/container runtime metadata labels.
private func effectiveServiceAnnotations(
    service: ComposeService,
    conflictingLabelKeys: Set<String>,
    conflictingOverrideKeys: Set<String> = []
) throws -> [String: String] {
    var annotations: [String: String] = [:]
    for (key, value) in service.annotations ?? [:] {
        try validateUserLabelKey(key, source: "service '\(service.name)' annotation")
        if conflictingLabelKeys.contains(key) {
            throw ComposeError.invalidProject("service '\(service.name)' annotation '\(key)' conflicts with a service label mapped to the same runtime metadata key")
        }
        if conflictingOverrideKeys.contains(key) {
            throw ComposeError.invalidProject("run --label cannot override service '\(service.name)' annotation '\(key)' because annotations map to runtime metadata labels")
        }
        annotations[key] = value
    }
    return annotations
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
private func serviceVolumeRuntimeNames(
    project: ComposeProject,
    service: ComposeService,
    externalVolumeMounts: ExternalVolumeMounts = [:]
) throws -> [String: String] {
    var names: [String: String] = [:]
    for mount in try effectiveServiceVolumes(
        project: project,
        service: service,
        externalVolumeMounts: externalVolumeMounts
    ) where mount.type == "volume" {
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

/// One Docker Compose-style volume row derived from apple/container volumes.
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

/// One service trigger and its last observed filesystem state.
private struct ComposeWatchPlan {
    var service: ComposeService
    var trigger: ComposeDevelopWatch
    var snapshot: [String: ComposeWatchEntry]

    var action: String {
        trigger.action.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A host file tracked by a `develop.watch` trigger.
private struct ComposeWatchEntry: Equatable {
    var relativePath: String
    var sourcePath: String
    var modifiedAt: Date?
    var size: UInt64?
}

/// A host-side change that must be reflected into service containers.
private enum ComposeWatchChange {
    case upsert(ComposeWatchEntry)
    case delete(relativePath: String)

    var entry: ComposeWatchEntry? {
        guard case .upsert(let entry) = self else {
            return nil
        }
        return entry
    }

    var deletedRelativePath: String? {
        guard case .delete(let relativePath) = self else {
            return nil
        }
        return relativePath
    }
}

/// Validated `sync+exec` hook settings.
private struct ComposeWatchExecHook {
    var command: [String]
    var user: String?
    var workingDirectory: String?
    var environment: [String]
}

/// Returns a project suitable for ordinary runtime orchestration while
/// `compose watch` owns the Develop Specification behavior.
private func projectWithoutDevelopMetadata(_ project: ComposeProject) -> ComposeProject {
    var copy = project
    for (name, service) in copy.services {
        var runtimeService = service
        runtimeService.develop = nil
        copy.services[name] = runtimeService
    }
    return copy
}

/// Captures the current files matched by one watch trigger.
private func watchSnapshot(project: ComposeProject, trigger: ComposeDevelopWatch) throws -> [String: ComposeWatchEntry] {
    let rootURL = resolvedWatchURL(project: project, path: trigger.path)
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
        throw ComposeError.invalidProject("develop.watch path does not exist: \(trigger.path)")
    }

    if !isDirectory.boolValue {
        let matchPath = rootURL.lastPathComponent
        guard watchPathIncluded(matchPath, trigger: trigger) else {
            return [:]
        }
        return [".": try watchEntry(url: rootURL, relativePath: ".")]
    }

    let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
    guard let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants]
    ) else {
        return [:]
    }

    var snapshot: [String: ComposeWatchEntry] = [:]
    for case let url as URL in enumerator {
        let relativePath = watchRelativePath(rootURL: rootURL, url: url)
        let values = try url.resourceValues(forKeys: Set(keys))
        if values.isDirectory == true {
            if watchPathIgnored(relativePath, trigger: trigger) {
                enumerator.skipDescendants()
            }
            continue
        }
        guard watchPathIncluded(relativePath, trigger: trigger) else {
            continue
        }
        snapshot[relativePath] = ComposeWatchEntry(
            relativePath: relativePath,
            sourcePath: url.path,
            modifiedAt: values.contentModificationDate,
            size: values.fileSize.map(UInt64.init)
        )
    }
    return snapshot
}

/// Resolves relative Compose watch paths from the project directory.
private func resolvedWatchURL(project: ComposeProject, path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: project.workingDirectory)).standardizedFileURL
}

/// Builds a stable relative path with POSIX separators for matching.
private func watchRelativePath(rootURL: URL, url: URL) -> String {
    let root = rootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard path.hasPrefix(prefix) else {
        return url.lastPathComponent
    }
    return String(path.dropFirst(prefix.count))
}

/// Creates a watch entry from a host file URL.
private func watchEntry(url: URL, relativePath: String) throws -> ComposeWatchEntry {
    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return ComposeWatchEntry(
        relativePath: relativePath,
        sourcePath: url.path,
        modifiedAt: values.contentModificationDate,
        size: values.fileSize.map(UInt64.init)
    )
}

/// Diffs two snapshots into deterministic upsert/delete changes.
private func watchChanges(
    previous: [String: ComposeWatchEntry],
    latest: [String: ComposeWatchEntry]
) -> [ComposeWatchChange] {
    let upserts = latest.keys.sorted().compactMap { key -> ComposeWatchChange? in
        guard previous[key] != latest[key], let entry = latest[key] else {
            return nil
        }
        return .upsert(entry)
    }
    let deletes = previous.keys
        .filter { latest[$0] == nil }
        .sorted()
        .map { ComposeWatchChange.delete(relativePath: $0) }
    return upserts + deletes
}

/// Returns the target path for a watched file relative to the trigger target.
private func watchTargetPath(trigger: ComposeDevelopWatch, relativePath: String) throws -> String {
    guard let target = nonEmpty(trigger.target) else {
        throw ComposeError.invalidProject("develop.watch action '\(trigger.action)' requires a target")
    }
    guard relativePath != "." && !relativePath.isEmpty else {
        return target
    }
    return target.hasSuffix("/") ? target + relativePath : target + "/" + relativePath
}

/// Converts Compose key/value environment metadata to exec arguments.
private func environmentArguments(_ values: [String: String?]) -> [String] {
    values.keys.sorted().map { key in
        guard let value = values[key] ?? nil else {
            return key
        }
        return "\(key)=\(value)"
    }
}

/// Applies include and ignore rules to a normalized relative path.
private func watchPathIncluded(_ relativePath: String, trigger: ComposeDevelopWatch) -> Bool {
    guard !watchPathIgnored(relativePath, trigger: trigger) else {
        return false
    }
    guard let include = trigger.include, !include.isEmpty else {
        return true
    }
    return include.contains { watchPattern($0, matches: relativePath) }
}

/// Returns true when any ignore pattern excludes the path.
private func watchPathIgnored(_ relativePath: String, trigger: ComposeDevelopWatch) -> Bool {
    guard let ignore = trigger.ignore, !ignore.isEmpty else {
        return false
    }
    return ignore.contains { watchPattern($0, matches: relativePath) }
}

/// Matches Compose watch glob patterns against relative paths or basenames.
private func watchPattern(_ rawPattern: String, matches rawRelativePath: String) -> Bool {
    let pattern = normalizedWatchPath(rawPattern)
    let relativePath = normalizedWatchPath(rawRelativePath)
    guard !pattern.isEmpty else {
        return false
    }
    if pattern.hasSuffix("/") {
        let directory = String(pattern.dropLast())
        return relativePath == directory || relativePath.hasPrefix(directory + "/")
    }
    if pattern.contains("/") {
        return glob(pattern, matches: relativePath)
    }
    return glob(pattern, matches: (relativePath as NSString).lastPathComponent)
}

/// Normalizes watch paths to POSIX separators for deterministic matching.
private func normalizedWatchPath(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "/")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

/// Minimal glob matching for Compose watch include/ignore filters.
private func glob(_ pattern: String, matches value: String) -> Bool {
    var regex = "^"
    for character in pattern {
        switch character {
        case "*":
            regex += ".*"
        case "?":
            regex += "."
        case ".", "+", "(", ")", "^", "$", "|", "{", "}", "[", "]", "\\":
            regex += "\\\(character)"
        default:
            regex.append(character)
        }
    }
    regex += "$"
    return value.range(of: regex, options: .regularExpression) != nil
}

/// Splits log output bytes into records without requiring UTF-8 decoding.
private func recordsForCompleteLogData(_ output: Data) -> [Data] {
    guard !output.isEmpty else {
        return []
    }

    var records: [Data] = []
    var current = Data()
    var index = output.startIndex
    while index < output.endIndex {
        let byte = output[index]
        if byte == UInt8(ascii: "\n") {
            records.append(current)
            current.removeAll()
            index = output.index(after: index)
        } else if byte == UInt8(ascii: "\r") {
            records.append(current)
            current.removeAll()
            let next = output.index(after: index)
            if next < output.endIndex, output[next] == UInt8(ascii: "\n") {
                index = output.index(after: next)
            } else {
                index = next
            }
        } else {
            current.append(byte)
            index = output.index(after: index)
        }
    }
    if !current.isEmpty {
        records.append(current)
    }
    return records
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
