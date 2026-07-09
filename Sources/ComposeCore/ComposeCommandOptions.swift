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

import ContainerResource
import Foundation

/// Options for `compose up`.
public struct ComposeUpOptions {
    public var services: [String] = []
    public var abortOnContainerExit = false
    public var abortOnContainerFailure = false
    public var attach: [String] = []
    public var attachDependencies = false
    public var exitCodeFrom: String?
    public var noAttach: [String] = []
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
    public var wait = false
    public var waitTimeout: Int?
    public var renewAnonymousVolumes = false
    public var assumeYes = false
    public var timestamps = false
    public var noLogPrefix = false
    public var colorPrefixes = false
    public var menu = false
    public var menuWatch = false

    public init() {
        services = []
        abortOnContainerExit = false
        abortOnContainerFailure = false
        attach = []
        attachDependencies = false
        exitCodeFrom = nil
        noAttach = []
        build = false
        noBuild = false
        detach = false
        forceRecreate = false
        alwaysRecreateDeps = false
        noRecreate = false
        removeOrphans = false
        pullPolicy = nil
        scales = []
        noDeps = false
        noStart = false
        quietBuild = false
        quietPull = false
        timeout = nil
        wait = false
        waitTimeout = nil
        renewAnonymousVolumes = false
        assumeYes = false
        timestamps = false
        noLogPrefix = false
        colorPrefixes = false
        menu = false
        menuWatch = false
    }

    public init(_ configure: (inout ComposeUpOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose start`.
public struct ComposeStartOptions {
    public var services: [String] = []
    public var wait = false
    public var waitTimeout: Int?

    public init() {
        services = []
        wait = false
        waitTimeout = nil
    }

    public init(_ configure: (inout ComposeStartOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose restart`.
public struct ComposeRestartOptions {
    public var services: [String] = []
    public var noDeps = false
    public var timeout: Int?

    public init() {
        services = []
        noDeps = false
        timeout = nil
    }

    public init(_ configure: (inout ComposeRestartOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose config`.
public struct ComposeConfigOptions {
    public var commandName = "config"
    public var services: [String] = []
    public var environment = false
    public var format: String?
    public var hash: String?
    public var images = false
    public var lockImageDigests = false
    public var models = false
    public var networks = false
    public var profiles = false
    public var quiet = false
    public var resolveImageDigests = false
    public var servicesOnly = false
    public var variables: [ComposeVariable]?
    public var volumes = false

    public init() {
        commandName = "config"
        services = []
        environment = false
        format = nil
        hash = nil
        images = false
        lockImageDigests = false
        models = false
        networks = false
        profiles = false
        quiet = false
        resolveImageDigests = false
        servicesOnly = false
        variables = nil
        volumes = false
    }

    public init(_ configure: (inout ComposeConfigOptions) -> Void) {
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
    public var renewAnonymousVolumes = false
    public var assumeYes = false

    public init() {
        services = []
        build = false
        noBuild = false
        forceRecreate = false
        noRecreate = false
        removeOrphans = false
        pullPolicy = nil
        scales = []
        noDeps = false
        quietBuild = false
        quietPull = false
        renewAnonymousVolumes = false
        assumeYes = false
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
        scales = []
        noDeps = false
    }

    public init(_ configure: (inout ComposeScaleOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose down`.
public struct ComposeDownOptions {
    public var services: [String]
    public var volumes: Bool
    public var removeOrphans: Bool
    public var timeout: Int?
    public var rmi: String?

    public init(
        services: [String] = [],
        volumes: Bool = false,
        removeOrphans: Bool = false,
        timeout: Int? = nil,
        rmi: String? = nil,
    ) {
        self.services = services
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
        follow = false
        tail = nil
        index = nil
        since = nil
        until = nil
        timestamps = false
        noLogPrefix = false
        colorPrefixes = false
    }

    public init(_ configure: (inout ComposeLogsOptions) -> Void) {
        configure(&self)
    }
}

/// Options for `compose build`.
public struct ComposeBuildOptions {
    public var services: [String] = []
    public var buildArguments: [String] = []
    public var builder: String?
    public var check = false
    public var memory: String?
    public var noCache = false
    public var printBake = false
    public var pull = false
    public var push = false
    public var quiet = false
    public var provenance: String?
    public var sbom: String?
    public var ssh: [String] = []
    public var withDependencies = false

    public init() {
        services = []
        buildArguments = []
        builder = nil
        check = false
        memory = nil
        noCache = false
        printBake = false
        pull = false
        push = false
        quiet = false
        provenance = nil
        sbom = nil
        ssh = []
        withDependencies = false
    }

    public init(_ configure: (inout ComposeBuildOptions) -> Void) {
        configure(&self)
    }
}

struct ComposeBuildBakeFile: Encodable {
    var group: [String: ComposeBuildBakeGroup]
    var target: [String: ComposeBuildBakeTarget]
}

struct ComposeBuildBakeGroup: Encodable {
    var targets: [String]
}

struct ComposeBuildBakeTargetEntry {
    var name: String
    var target: ComposeBuildBakeTarget
}

struct ComposeBuildBakeTarget: Encodable {
    var context: String
    var dockerfile: String?
    var dockerfileInline: String?
    var args: [String: String]?
    var labels: [String: String]?
    var contexts: [String: String]?
    var entitlements: [String]?
    var extraHosts: [String]?
    var network: String?
    var privileged: Bool?
    var shmSize: String?
    var ulimits: [String]?
    var tags: [String]
    var target: String?
    var secrets: [String]?
    var ssh: [String]?
    var cacheFrom: [String]?
    var cacheTo: [String]?
    var platforms: [String]?
    var attest: [String]?
    var pull: Bool?
    var noCache: Bool?
    var output: [String]?
    var call: String?

    enum CodingKeys: String, CodingKey {
        case context
        case dockerfile
        case dockerfileInline = "dockerfile-inline"
        case args
        case labels
        case contexts
        case entitlements
        case extraHosts = "extra-hosts"
        case network
        case privileged
        case shmSize = "shm-size"
        case ulimits
        case tags
        case target
        case secrets = "secret"
        case ssh
        case cacheFrom = "cache-from"
        case cacheTo = "cache-to"
        case platforms
        case attest
        case pull
        case noCache = "no-cache"
        case output
        case call
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
        services = []
        ignoreBuildable = false
        ignorePullFailures = false
        includeDependencies = false
        policy = nil
        quiet = false
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
        services = []
        ignorePushFailures = false
        includeDependencies = false
        quiet = false
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

/// Options for `compose top`.
public struct ComposeTopOptions {
    public var services: [String]

    public init(services: [String] = []) {
        self.services = services
    }
}

/// Options for `compose events`.
public struct ComposeEventsOptions {
    public var services: [String]
    public var json: Bool
    public var since: String?
    public var until: String?

    public init(services: [String] = [], json: Bool = false, since: String? = nil, until: String? = nil) {
        self.services = services
        self.json = json
        self.since = since
        self.until = until
    }

    public var outputFormat: ComposeEventsOutputFormat {
        json ? .json : .text
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
    public var initialUpOptions: ComposeUpOptions?

    public init(
        services: [String] = [],
        noUp: Bool = false,
        prune: Bool = true,
        quiet: Bool = false,
        initialUpOptions: ComposeUpOptions? = nil,
    ) {
        self.services = services
        self.noUp = noUp
        self.prune = prune
        self.quiet = quiet
        self.initialUpOptions = initialUpOptions
    }
}

/// Options for `compose attach` commands.
public struct ComposeAttachOptions {
    public var noStdin = false
    public var detachKeys: String?
    public var index = 1
    public var sigProxy = "true"

    public init() {
        noStdin = false
        detachKeys = nil
        index = 1
        sigProxy = "true"
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
        command = []
        interactive = true
        tty = true
        detach = false
        environment = []
        index = 1
        privileged = false
        user = nil
        workingDirectory = nil
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
        arguments = []
        all = false
        archive = false
        followLink = false
        index = 1
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

/// Options for `compose ps`.
public struct ComposePsOptions: Sendable {
    public var all: Bool
    public var quiet: Bool
    public var services: Bool
    public var selectedServices: [String]
    public var statuses: [String]
    public var filters: [String]
    public var format: String
    public var noTrunc: Bool
    public var orphans: Bool

    public init() {
        all = false
        quiet = false
        services = false
        selectedServices = []
        statuses = []
        filters = []
        format = "json"
        noTrunc = false
        orphans = true
    }

    public init(_ configure: (inout ComposePsOptions) -> Void) {
        self.init()
        configure(&self)
    }
}

/// Options for `compose run` one-off containers.
public struct ComposeRunOptions {
    public var command: [String] = []
    public var build = false
    public var remove = false
    public var detach = false
    public var interactive = false
    public var noTty = false
    public var noDeps = false
    public var servicePorts = false
    public var publish: [String] = []
    public var pullPolicy: String?
    public var quietBuild = false
    public var quietPull = false
    public var quiet = false
    public var removeOrphans = false
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
    public var useAliases = false

    public init() {
        command = []
        build = false
        remove = false
        detach = false
        interactive = false
        noTty = false
        noDeps = false
        servicePorts = false
        publish = []
        pullPolicy = nil
        quietBuild = false
        quietPull = false
        quiet = false
        removeOrphans = false
        containerName = nil
        entrypoint = nil
        workingDirectory = nil
        user = nil
        environment = []
        envFiles = []
        labels = []
        volumes = []
        capAdd = []
        capDrop = []
        useAliases = false
    }

    public init(_ configure: (inout ComposeRunOptions) -> Void) {
        configure(&self)
    }
}

struct RunArgumentOptions {
    var command = "run"
    var detach = false
    var remove = false
    var oneOff = false
    var containerIndex: Int?
    var replicaCount: Int?
    var publishedPorts: [String]?
    var containerNameOverride: String?
    var labelOverrides: [ComposeLabelOverride] = []
    var envFiles: [String] = []

    init() {
        command = "run"
        detach = false
        remove = false
        oneOff = false
        containerIndex = nil
        replicaCount = nil
        publishedPorts = nil
        containerNameOverride = nil
        labelOverrides = []
        envFiles = []
    }

    init(_ configure: (inout RunArgumentOptions) -> Void) {
        configure(&self)
    }
}

struct RuntimeRestartPolicyArguments {
    var policy: String
    var delayNanoseconds: Int64?
    var windowNanoseconds: Int64?

    var arguments: [String] {
        var result = ["--restart", policy]
        if let delayNanoseconds, policy != "no" {
            result.append(contentsOf: ["--restart-delay", runtimeDurationArgument(delayNanoseconds)])
        }
        if let windowNanoseconds, policy != "no" {
            result.append(contentsOf: ["--restart-window", runtimeDurationArgument(windowNanoseconds)])
        }
        return result
    }

    func restartPolicy() throws -> ContainerRestartPolicy {
        let components = policy.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let modeValue = components.first,
              let mode = ContainerRestartPolicy.Mode(rawValue: String(modeValue))
        else {
            throw ComposeError.invalidProject("invalid restart policy '\(policy)'")
        }

        let retryCount: UInt32?
        if components.count == 2 {
            guard mode == .onFailure,
                  !components[1].isEmpty,
                  let parsedRetryCount = UInt32(components[1])
            else {
                throw ComposeError.invalidProject("invalid restart policy '\(policy)'")
            }
            retryCount = parsedRetryCount
        } else {
            retryCount = nil
        }

        return try ContainerRestartPolicy(
            mode: mode,
            maximumRetryCount: retryCount,
            retryDelayInNanoseconds: unsignedNanoseconds(delayNanoseconds, field: "restart delay"),
            successfulRunDurationInNanoseconds: unsignedNanoseconds(windowNanoseconds, field: "restart window"),
        )
    }

    private func unsignedNanoseconds(_ value: Int64?, field: String) throws -> UInt64? {
        guard let value else {
            return nil
        }
        guard value >= 0 else {
            throw ComposeError.invalidProject("\(field) must be non-negative")
        }
        return UInt64(value)
    }
}

actor ComposeImageHealthCheckCache {
    private var storage: [String: ComposeImageHealthCheck?] = [:]

    /// Returns cached image healthcheck metadata for one image/platform pair.
    func healthCheck(
        reference: String,
        platform: String?,
        imageManager: ContainerImageManaging,
    ) async throws -> ComposeImageHealthCheck? {
        let key = "\(reference)|\(platform ?? "")"
        if storage.keys.contains(key) {
            return storage[key] ?? nil
        }
        let healthCheck = try await imageManager.imageHealthCheck(reference, platform: platform)
        storage[key] = healthCheck
        return healthCheck
    }
}

func runtimeDurationArgument(_ nanoseconds: Int64) -> String {
    let seconds = nanoseconds / 1_000_000_000
    let remainder = nanoseconds % 1_000_000_000
    guard remainder != 0 else {
        return "\(seconds)s"
    }
    let paddedRemainder = String(format: "%09d", remainder)
    let trimmedRemainder = dropTrailingZeros(from: paddedRemainder)
    return "\(seconds).\(trimmedRemainder)s"
}

func dropTrailingZeros(from value: String) -> Substring {
    var end = value.endIndex
    while end > value.startIndex, value[value.index(before: end)] == "0" {
        end = value.index(before: end)
    }
    return value[..<end]
}

struct MountRenderContext {
    var project: ComposeProject
    var service: ComposeService
    var containerIndex: Int?
    var replicaCount: Int?
}

enum DownImageRemovalPolicy {
    case none
    case local
    case all
}

enum ComposeImagesFormat {
    case table
    case json
}

struct ParsedPublishedPortMapping {
    var hostAddress: String?
    var hostRange: (start: Int, count: Int)?
    var targetRange: (start: Int, count: Int)
    var protocolName: String

    var usesDynamicHostPorts: Bool {
        hostRange == nil
    }
}

enum ComposeVolumesFormat {
    case table
    case json
    case template(String, table: Bool)
}

enum RuntimeHealthCheckCommand {
    case disabled
    case command(String)
}

struct ComposeCopyContainerTarget {
    var id: String
    var path: String

    var runtimeArgument: String {
        "\(id):\(path)"
    }
}

struct ServiceContainerTarget {
    var service: ComposeService
    var index: Int
    var name: String
    var status: String?
}

struct RuntimeLogOptions {
    var tail: Int?
    var since: Date?
    var until: Date?
    var timestamps: Bool
    var noLogPrefix: Bool
    var colorPrefixes: Bool
}

struct RuntimeLogRequest {
    var id: String
    var follow: Bool
    var tail: Int?
    var since: Date?
    var until: Date?
    var timestamps: Bool
    var emit: @Sendable (Data) -> Void
}

struct ServiceContainerWaitResult {
    var containerName: String
    var exitCode: Int32
}

struct ServiceContainerReconcileRequest {
    var name: String
    var runOptions: RunArgumentOptions
    var externalVolumeMounts: ExternalVolumeMounts = [:]
    var imageHealthCheckCache: ComposeImageHealthCheckCache?
    var forceRecreate: Bool
    var noRecreate: Bool
    var renewAnonymousVolumes: Bool
    var dependencyRecreateServices: Set<String>
    var recreateTimeout: Int?
    var delayBeforeRecreate: Bool = false
}

enum ServiceContainerReconcileOutcome {
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

enum ComposeCopyEndpoint {
    case local(String)
    case containers([ComposeCopyContainerTarget])

    var runtimeArgument: String {
        switch self {
        case let .local(path):
            path
        case let .containers(containers):
            containers.first?.runtimeArgument ?? ""
        }
    }
}

typealias ExternalVolumeMounts = [String: [ComposeMount]]

/// Compose provider lifecycle command.
enum ComposeProviderAction: String {
    case up
    case down
    case stop
}

/// JSON message emitted by a Compose provider command.
struct ComposeProviderMessage: Decodable {
    var type: String
    var message: String
}

/// Optional provider command metadata emitted by `compose metadata`.
struct ComposeProviderMetadata: Decodable {
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
struct ComposeProviderCommandMetadata: Decodable {
    var parameters: [ComposeProviderParameterMetadata]?

    func parameter(named name: String) -> ComposeProviderParameterMetadata? {
        (parameters ?? []).first { $0.name == name }
    }
}

/// One provider command parameter advertised by provider metadata.
struct ComposeProviderParameterMetadata: Decodable {
    var name: String
    var required: Bool?
}

/// Source of a parsed service-scoped `volumes_from` reference.
enum ParsedVolumesFromSource {
    case service(String)
    case externalContainer(String)
}

/// Service-scoped `volumes_from` reference after parsing access mode.
struct ParsedVolumesFromReference {
    var source: ParsedVolumesFromSource
    var readOnly: Bool?
    var rawValue: String
}

/// One Compose legacy link reference after validation.
struct ComposeLinkReference {
    var serviceName: String
    var alias: String
}

/// One Compose external link reference after validation.
struct ComposeExternalLinkReference {
    var containerName: String
    var alias: String
}

/// One legacy-link alias projected onto a target service attachment.
struct ComposeProjectedLinkAlias {
    var serviceName: String
    var network: String
    var alias: String
}

/// External `volumes_from` container reference that needs runtime inspection.
struct ExternalVolumesFromReference {
    var serviceName: String
    var rawValue: String
    var containerName: String
}
