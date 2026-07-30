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

func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = value.contains(".")
        ? [.withInternetDateTime, .withFractionalSeconds]
        : [.withInternetDateTime]
    return formatter.date(from: value)!
}

func localDate(_ value: String, format: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = format
    return formatter.date(from: value)!
}

func bridgeTransformerArchiveData() throws -> Data {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("compose-bridge-archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let archive = directory.appendingPathComponent("rootfs.tar")
    let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: archive)

    func writeDirectory(_ path: String) throws {
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .directory
        entry.permissions = 0o755
        entry.size = 0
        try writer.writeEntry(entry: entry, data: nil)
    }

    func writeFile(_ path: String, contents: String) throws {
        let data = Data(contents.utf8)
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .regular
        entry.permissions = 0o644
        entry.size = Int64(data.count)
        try writer.writeEntry(entry: entry, data: data)
    }

    try writeDirectory("templates/")
    try writeFile("templates/service.tmpl", contents: "service template")
    try writeDirectory("etc/")
    try writeFile("etc/ignored", contents: "not a template")
    try writer.finishEncoding()
    return try Data(contentsOf: archive)
}

func rootfsArchiveData(contents: String = "committed") throws -> Data {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("rootfs.tar")
    let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: archive)
    let data = Data(contents.utf8)
    let entry = WriteEntry()
    entry.path = "committed.txt"
    entry.fileType = .regular
    entry.permissions = 0o644
    entry.size = Int64(data.count)
    try writer.writeEntry(entry: entry, data: data)
    try writer.finishEncoding()
    return try Data(contentsOf: archive)
}

struct CommitArchiveIndex: Decodable {
    var manifests: [Descriptor]
}

struct CommitArchiveManifest: Decodable {
    var config: Descriptor
}

struct CommitArchiveImageConfig: Decodable {
    struct Config: Decodable {
        var user: String?
        var env: [String]?
        var entrypoint: [String]?
        var cmd: [String]?
        var workingDir: String?
        var labels: [String: String]?
        var exposedPorts: [String: [String: String]]?
        var stopSignal: String?
        var healthCheck: HealthCheck?
        var volumes: [String: [String: String]]?
        var onBuild: [String]?

        struct HealthCheck: Decodable, Equatable {
            var test: [String]?
            var intervalInNanoseconds: Int64?
            var timeoutInNanoseconds: Int64?
            var startPeriodInNanoseconds: Int64?
            var startIntervalInNanoseconds: Int64?
            var retries: Int?

            enum CodingKeys: String, CodingKey {
                case test = "Test"
                case intervalInNanoseconds = "Interval"
                case timeoutInNanoseconds = "Timeout"
                case startPeriodInNanoseconds = "StartPeriod"
                case startIntervalInNanoseconds = "StartInterval"
                case retries = "Retries"
            }
        }

        enum CodingKeys: String, CodingKey {
            case user = "User"
            case env = "Env"
            case entrypoint = "Entrypoint"
            case cmd = "Cmd"
            case workingDir = "WorkingDir"
            case labels = "Labels"
            case exposedPorts = "ExposedPorts"
            case stopSignal = "StopSignal"
            case healthCheck = "Healthcheck"
            case volumes = "Volumes"
            case onBuild = "OnBuild"
        }
    }

    var author: String?
    var config: Config
}

func commitArchiveConfig(from archive: URL) throws -> CommitArchiveImageConfig {
    let indexData = try ArchiveReader(file: archive).extractFile(path: "index.json").1
    let index = try JSONDecoder().decode(CommitArchiveIndex.self, from: indexData)
    let manifestDigest = try #require(index.manifests.first?.digest)
    let manifestData = try ArchiveReader(file: archive).extractFile(path: blobPath(for: manifestDigest)).1
    let manifest = try JSONDecoder().decode(CommitArchiveManifest.self, from: manifestData)
    let configData = try ArchiveReader(file: archive).extractFile(path: blobPath(for: manifest.config.digest)).1
    return try JSONDecoder().decode(CommitArchiveImageConfig.self, from: configData)
}

func blobPath(for digest: String) throws -> String {
    guard digest.hasPrefix("sha256:") else {
        throw ComposeError.invalidProject("unexpected digest \(digest)")
    }
    return "blobs/sha256/\(digest.dropFirst("sha256:".count))"
}

func composeTextEventTimestamp(_ value: String) -> String {
    let eventDate = date(value)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second, .nanosecond],
        from: eventDate
    )
    let microseconds = (components.nanosecond ?? 0) / 1000
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

func composeService(
    name: String,
    image: String? = nil,
    configure: (inout ComposeService) -> Void = { _ in }
) -> ComposeService {
    var service = ComposeService(name: name, image: image)
    configure(&service)
    return service
}

func composeProject(
    name: String,
    services: [String: ComposeService],
    configure: (inout ComposeProject) -> Void = { _ in }
) -> ComposeProject {
    var project = ComposeProject(name: name, services: services)
    configure(&project)
    return project
}

func orchestratorReadOnlyVolumeSource(target: String, in arguments: [String]) -> String? {
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

func anonymousVolumeSource(target: String, in arguments: [String]) -> String? {
    let suffix = ":\(target)"
    for index in arguments.indices where arguments[index] == "--volume" {
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            continue
        }
        let value = arguments[valueIndex]
        guard value.hasPrefix("demo_anon-"), value.hasSuffix(suffix) else {
            continue
        }
        return String(value.dropLast(suffix.count))
    }
    return nil
}

func orchestratorPosixPermissions(at path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}

final class LockedStringRecorder: @unchecked Sendable {
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

func progressReportingOptions(recordingTo recorder: LockedStringRecorder) -> ComposeExecutionOptions {
    ComposeExecutionOptions(progress: ComposeProgressReporter(
        style: .plain,
        emitData: { recorder.append(String(decoding: $0, as: UTF8.self)) }
    ))
}

func composeRunOptions(
    command: [String] = [],
    configure: (inout ComposeRunOptions) -> Void = { _ in }
) -> ComposeRunOptions {
    var options = ComposeRunOptions()
    options.command = command
    configure(&options)
    return options
}

func projectWithRuntimeResources(networkName: String, volumeName: String) -> ComposeProject {
    composeProject(
        name: "demo",
        services: [
            "api": composeService(name: "api", image: "alpine") {
                $0.networks = ["shared"]
                $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
            },
        ]
    ) {
        $0.networks = ["shared": ComposeNetwork(name: networkName, options: ComposeNetwork.Options(external: true))]
        $0.volumes = ["cache": ComposeVolume(name: volumeName, external: true)]
    }
}

func projectWithBackendNetwork(serviceName: String, image: String) -> ComposeProject {
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

func projectWithCacheVolume(serviceName: String, image: String) -> ComposeProject {
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

func composeProjectWithInheritedVolume(target: String) -> ComposeProject {
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

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func archiveWithFile(named name: String, contents: String, in directory: URL) throws -> URL {
    let source = directory.appendingPathComponent("archive-source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try contents.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)

    let archive = directory.appendingPathComponent("payload.tar")
    let writer = try ArchiveWriter(format: .pax, filter: .none, file: archive)
    try writer.archiveDirectory(source)
    try writer.finishEncoding()
    return archive
}

func temporaryExecutable(name: String = "provider") throws -> URL {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent(name)
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}

final class InlineDockerfileRunner: CommandRunning, @unchecked Sendable {
    private(set) var commands: [[String]] = []
    private(set) var dockerfileContents: [String] = []
    private(set) var dockerfileDirectoryPermissions: [Int] = []
    private(set) var dockerfilePermissions: [Int] = []

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
           arguments.indices.contains(fileIndex + 1)
        {
            let dockerfileURL = URL(fileURLWithPath: arguments[fileIndex + 1])
            if FileManager.default.fileExists(atPath: dockerfileURL.path) {
                try dockerfileContents.append(String(contentsOf: dockerfileURL, encoding: .utf8))
                try dockerfileDirectoryPermissions.append(
                    orchestratorPosixPermissions(at: dockerfileURL.deletingLastPathComponent().path),
                )
                try dockerfilePermissions.append(orchestratorPosixPermissions(at: dockerfileURL.path))
            }
        }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

final class BuildSecretInspectingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let result: CommandResult
    private var commandStorage: [[String]] = []
    private var secretContentsStorage: [Data] = []
    private var secretPermissionsStorage: [Int] = []
    private var secretURLsStorage: [URL] = []

    var commands: [[String]] {
        lock.withLock { commandStorage }
    }

    var secretContents: [Data] {
        lock.withLock { secretContentsStorage }
    }

    var secretPermissions: [Int] {
        lock.withLock { secretPermissionsStorage }
    }

    var secretURLs: [URL] {
        lock.withLock { secretURLsStorage }
    }

    init(result: CommandResult = .success) {
        self.result = result
    }

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
        var contents: [Data] = []
        var permissions: [Int] = []
        var urls: [URL] = []
        for index in arguments.indices where arguments[index] == "--secret" {
            let valueIndex = arguments.index(after: index)
            guard arguments.indices.contains(valueIndex) else {
                continue
            }
            let fields = arguments[valueIndex].split(separator: ",").map(String.init)
            guard let source = fields.first(where: { $0.hasPrefix("src=") }) else {
                continue
            }
            let url = URL(fileURLWithPath: String(source.dropFirst("src=".count)))
            urls.append(url)
            try contents.append(Data(contentsOf: url))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            permissions.append((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1)
        }
        lock.withLock {
            commandStorage.append(arguments)
            secretContentsStorage.append(contentsOf: contents)
            secretPermissionsStorage.append(contentsOf: permissions)
            secretURLsStorage.append(contentsOf: urls)
        }
        return result
    }
}

actor BuildSecretFixtureReader: ComposeRuntimeSecretReading {
    private let secrets: [String: Data]
    private var requestStorage: [String] = []

    init(secrets: [String: Data]) {
        self.secrets = secrets
    }

    var requests: [String] {
        requestStorage
    }

    func readSecret(name: String) async throws -> Data {
        requestStorage.append(name)
        guard let contents = secrets[name] else {
            throw NSError(
                domain: "BuildSecretFixtureReader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing build secret fixture '\(name)'"],
            )
        }
        return contents
    }
}

final class ProgressAssertingRunner: CommandRunning, @unchecked Sendable {
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

struct BridgeRecordedCommand: Equatable {
    var arguments: [String]
    var io: CommandIO
}

final class BridgeInputInspectingRunner: CommandRunning, @unchecked Sendable {
    private(set) var commands: [BridgeRecordedCommand] = []
    private(set) var inputComposeFiles: [String] = []
    private(set) var inputDirectoryPermissions: [Int] = []
    private(set) var inputFilePermissions: [Int] = []
    var responses: [CommandResult]

    init(responses: [CommandResult] = []) {
        self.responses = responses
    }

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
        commands.append(BridgeRecordedCommand(arguments: arguments, io: io))
        if let input = bridgeInputDirectory(in: arguments) {
            let composeFile = URL(fileURLWithPath: input, isDirectory: true)
                .appendingPathComponent("compose.yaml")
            if FileManager.default.fileExists(atPath: composeFile.path),
               let text = try? String(contentsOf: composeFile, encoding: .utf8)
            {
                inputComposeFiles.append(text)
                let directoryAttributes = try? FileManager.default.attributesOfItem(atPath: input)
                let fileAttributes = try? FileManager.default.attributesOfItem(atPath: composeFile.path)
                inputDirectoryPermissions.append((directoryAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1)
                inputFilePermissions.append((fileAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1)
            }
        }
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }

    private func bridgeInputDirectory(in arguments: [String]) -> String? {
        for index in arguments.indices where arguments[index] == "--volume" {
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                continue
            }
            let volume = arguments[valueIndex]
            guard volume.hasSuffix(":/in") else {
                continue
            }
            return String(volume.dropLast(":/in".count))
        }
        return nil
    }
}

func orchestratorDependencies(
    configure: (inout ComposeOrchestratorDependencies) -> Void
) -> ComposeOrchestratorDependencies {
    var dependencies = ComposeOrchestratorDependencies()
    dependencies.archiveManager = ContainerArchiveManager()
    dependencies.copier = RecordingContainerCopier()
    dependencies.discoveryManager = RecordingContainerDiscoveryManager()
    dependencies.eventsManager = RecordingContainerEventsManager()
    dependencies.execManager = RecordingContainerExecManager()
    dependencies.exporter = RecordingContainerExporter()
    dependencies.imageManager = RecordingContainerImageManager()
    dependencies.imageVolumeInitializer = RecordingContainerImageVolumeInitializer()
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

func expectSameInstance<T: AnyObject>(_ actual: Any, _ expected: T, _ name: String) {
    guard let actual = actual as? T else {
        Issue.record("Expected \(name) to use \(T.self)")
        return
    }
    #expect(actual === expected)
}

extension ComposeOrchestrator {
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


extension CommandResult {
    static let success = CommandResult(status: 0, stdout: "", stderr: "")
    static let failure = CommandResult(status: 1, stdout: "", stderr: "")
}

let composeConfigHashLabel = "com.apple.container.compose.config-hash"
let composeOneOffLabel = "com.apple.container.compose.oneoff"
let composeProjectLabel = "com.apple.container.compose.project"
let composeServiceLabel = "com.apple.container.compose.service"
let composeProjectConfigFilesLabel = "com.apple.container.compose.project.config-files"

struct UnsupportedRuntimeStringFieldCase: Sendable {
    let composeName: String
    let value: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; \(reason)"
    }
}

func unsupportedRuntimeStringFieldCases() -> [UnsupportedRuntimeStringFieldCase] {
    [
        UnsupportedRuntimeStringFieldCase(
            composeName: "isolation",
            value: "default",
            reason: "isolation support needs an apple/container runtime gap PR",
            configure: { $0.isolation = "default" }
        ),
    ]
}

struct UnsupportedCPUResourceFieldCase: Sendable {
    let composeName: String
    let value: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; advanced CPU resource support needs an apple/container runtime gap PR"
    }
}

func unsupportedCPUResourceFieldCases() -> [UnsupportedCPUResourceFieldCase] {
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
            composeName: "cpu_rt_period",
            value: "950000",
            configure: { $0.cpuRealtimePeriod = 950_000 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_rt_runtime",
            value: "900000",
            configure: { $0.cpuRealtimeRuntime = 900_000 }
        ),
    ]
}

struct UnsupportedMemoryAndProcessResourceFieldCase: Sendable {
    let composeName: String
    let value: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; memory, OOM, and process resource support needs an apple/container runtime gap PR"
    }
}

func unsupportedMemoryAndProcessResourceFieldCases() -> [UnsupportedMemoryAndProcessResourceFieldCase] {
    [
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
    ]
}

struct UnsupportedUserAndSecurityOptionFieldCase: Sendable {
    let composeName: String
    let value: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; \(reason)"
    }
}

func unsupportedUserAndSecurityOptionFieldCases() -> [UnsupportedUserAndSecurityOptionFieldCase] {
    [
        UnsupportedUserAndSecurityOptionFieldCase(
            composeName: "security_opt",
            value: "label=type:container_t",
            reason: "only no-new-privileges (with optional :true|false or =true|false), systempaths=unconfined|systempaths:unconfined, seccomp=unconfined|seccomp:unconfined, apparmor=unconfined|apparmor:unconfined, or label=disable|label:disable is supported",
            configure: { $0.securityOpt = ["label=type:container_t"] }
        ),
    ]
}

struct UnsupportedDeviceAccessFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

func unsupportedDeviceAccessFieldCases() -> [UnsupportedDeviceAccessFieldCase] {
    [
        UnsupportedDeviceAccessFieldCase(
            composeName: "credential_spec",
            reason: "credential spec support needs an apple/container runtime gap PR",
            configure: { $0.credentialSpec = .object(["file": .string("credential-spec.json")]) }
        ),
    ]
}

struct UnsupportedModelFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

func unsupportedModelFieldCases() -> [UnsupportedModelFieldCase] {
    [
        UnsupportedModelFieldCase(
            composeName: "models",
            reason: "Compose model bindings need a model-runner backend and endpoint injection primitive that is not available through apple/container yet",
            configure: { $0.models = ["llm": ComposeServiceModelBinding(endpointVariable: "MODEL_URL", modelVariable: "MODEL")] }
        ),
    ]
}

struct UnsupportedServiceMetadataAndLoggingFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

struct SupportedServiceLoggingFieldCase: Sendable {
    let configure: @Sendable (inout ComposeService) -> Void
}

struct SupportedServiceLoggingOptionCase: Sendable {
    let configure: @Sendable (inout ComposeService) -> Void
    let expectedOptions: [String]
}

struct DisabledServiceLoggingFieldCase: Sendable {
    let configure: @Sendable (inout ComposeService) -> Void
}

func supportedLocalServiceLoggingFieldCases() -> [SupportedServiceLoggingFieldCase] {
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

func supportedLocalServiceLoggingOptionCases() -> [SupportedServiceLoggingOptionCase] {
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

func disabledServiceLoggingFieldCases() -> [DisabledServiceLoggingFieldCase] {
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

func unsupportedServiceMetadataAndLoggingFieldCases() -> [UnsupportedServiceMetadataAndLoggingFieldCase] {
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

struct UnsupportedServiceVolumeShortcutFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

func unsupportedServiceVolumeShortcutFieldCases() -> [UnsupportedServiceVolumeShortcutFieldCase] {
    [
        UnsupportedServiceVolumeShortcutFieldCase(
            composeName: "volume_driver",
            reason: "non-local service volume drivers need an apple/container volume driver runtime gap PR",
            configure: { $0.volumeDriver = "nfs" }
        ),
    ]
}

func composeConfigHash(in arguments: [String]) -> String? {
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

func discoveredContainers() -> [ComposeContainerSummary] {
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
            status: "exited",
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

func discoveredServiceContainer(
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

func pausedDiscoveredContainers() -> [ComposeContainerSummary] {
    discoveredContainers() + [
        ComposeContainerSummary(id: "demo-paused-1", status: "paused", labels: [
            composeProjectLabel: "demo",
            composeServiceLabel: "paused",
        ]),
    ]
}

func containerSnapshot(
    id: String,
    status: RuntimeStatus,
    labels: [String: String] = [:],
    imageReference: String,
    imageDigest: String,
    platform: String,
    publishedPorts: [PublishPort] = [],
    mounts: [Filesystem] = [],
    networks: [ContainerResource.Attachment] = [],
    startedDate: Date? = nil,
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
        startedDate: startedDate,
        exitCode: exitCode,
        exitedDate: exitedDate,
        health: health
    )
}

func managedContainerJSON(_ snapshots: [ContainerSnapshot]) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshots.map(ManagedContainer.init))
    return String(decoding: data, as: UTF8.self)
}

func ociPlatform(_ value: String) throws -> Platform {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else {
        throw ComposeError.invalidProject("invalid platform fixture '\(value)'")
    }
    let variant = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
    return Platform(arch: parts[1], os: parts[0], variant: variant)
}

func temporaryLogFileHandle(contents: String) throws -> FileHandle {
    try temporaryLogFileHandle(data: Data(contents.utf8))
}

func temporaryLogFileHandle(data: Data) throws -> FileHandle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("log")
    try data.write(to: url)
    let handle = try FileHandle(forReadingFrom: url)
    try? FileManager.default.removeItem(at: url)
    return handle
}

final class TemporaryLogFile: @unchecked Sendable {
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

func logRecordData(_ records: [ContainerLogRecord]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = Data()
    for record in records {
        try data.append(encoder.encode(record))
        data.append(UInt8(ascii: "\n"))
    }
    return data
}

func containerEventData(_ events: [ContainerEvent], trailingNewline: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = Data()
    for event in events {
        try data.append(encoder.encode(event))
        data.append(UInt8(ascii: "\n"))
    }
    if !trailingNewline, data.last == UInt8(ascii: "\n") {
        data.removeLast()
    }
    return data
}

func composeEventAttributes(extra: [String: String] = [:]) -> [String: String] {
    var attributes = [
        composeProjectLabel: "demo",
        composeServiceLabel: "api",
        composeOneOffLabel: "false",
        "image": "example/api",
        "status": "stopped",
    ]
    attributes.merge(extra) { _, additional in additional }
    return attributes
}

func logRecords(from data: Data) throws -> [ContainerLogRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data.split(separator: UInt8(ascii: "\n")).map { line in
        try decoder.decode(ContainerLogRecord.self, from: Data(line))
    }
}

func waitForMessages(_ expected: [String], in recorder: MessageRecorder) async throws {
    for _ in 0 ..< 100 {
        if recorder.messages == expected {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

func waitForData(_ expected: [Data], in recorder: DataRecorder) async throws {
    for _ in 0 ..< 100 {
        if recorder.data == expected {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

func containerStats(
    id: String,
    cpuUsageUsec: UInt64?,
    memoryUsageBytes: UInt64? = 1_048_576,
    memoryLimitBytes: UInt64? = 2_097_152,
    networkRxBytes: UInt64? = 1024,
    networkTxBytes: UInt64? = 2048,
    blockReadBytes: UInt64? = 4096,
    blockWriteBytes: UInt64? = 8192,
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

struct ListedContainer: Decodable {
    var id: String
}

func listedContainerIDs(from output: String) throws -> [String] {
    try JSONDecoder().decode([ListedContainer].self, from: Data(output.utf8)).map(\.id)
}

struct ContainerExportRequest: Equatable {
    var id: String
    var output: String?
    var live: Bool = false
    var noFreeze: Bool = false
}

enum ContainerCopyRequest: Equatable {
    case into(id: String, source: String, destination: String)
    case from(id: String, source: String, destination: String)
    case between(sourceID: String, source: String, destinationID: String, destination: String)
    case archiveInto(id: String, destination: String, data: Data)
    case archiveFrom(id: String, source: String, copyContents: Bool)
}

struct CopyStreamTestError: Error {}

enum ContainerLifecycleRequest: Equatable {
    case start(id: String)
    case kill(id: String, signal: String)
    case stop(id: String, signal: String?, timeoutInSeconds: Int?)
    case pause(id: String)
    case unpause(id: String)
    case wait(id: String)
    case get(id: String)
    case delete(id: String, force: Bool)
}

struct ContainerLogRequest: Equatable {
    var id: String
    var tail: Int?
    var follow: Bool
    var since: Date? = nil
    var until: Date? = nil
    var timestamps = false
}

struct ComposeUpMenuConfigurationSnapshot: Equatable {
    var projectName: String
    var watchEnabled: Bool
    var watchAvailable: Bool
    var colorEnabled: Bool
}

enum ComposeUpMenuTestAction {
    case gracefulStop
    case forceStop
    case toggleWatch
}

struct ContainerExecProcessRequest: Equatable {
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

struct ContainerAttachedExecProcessRequest: Equatable {
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

struct ContainerStatsRequest: Equatable {
    var ids: [String]
    var format: String
    var noStream: Bool
    var noTrunc: Bool
    var includeStopped: Bool
}

struct ContainerTopRequest: Equatable {
    var targets: [ComposeTopTarget]
}

enum ContainerImageRequest: Equatable {
    case exists(String)
    case digest(String)
    case healthCheck(reference: String, platform: String?)
    case availableMetadata(reference: String, platform: String?)
    case volumeTargets(reference: String, platform: String?)
    case metadata(String)
    case bridgeTransformers
    case pull(String)
    case pullMissing(String)
    case push(String)
    case delete(reference: String, force: Bool)
    case load(String)
}

struct ImageHealthCheckRequestKey: Hashable {
    var reference: String
    var platform: String?
}

struct ImageMetadataRequestKey: Hashable {
    var reference: String
    var platform: String?
}

struct ImageVolumeTargetRequestKey: Hashable {
    var reference: String
    var platform: String?
}

enum ContainerResourceRequest: Equatable {
    case createNetwork(ComposeNetworkCreateRequest)
    case deleteNetwork(id: String)
    case createVolume(ComposeVolumeCreateRequest)
    case listVolumes
    case deleteVolume(name: String)

    var name: String {
        switch self {
        case let .createNetwork(request):
            request.name
        case let .createVolume(request):
            request.name
        case let .deleteVolume(name):
            name
        case .listVolumes:
            ""
        case let .deleteNetwork(id):
            id
        }
    }

    var labels: [String: String] {
        switch self {
        case let .createNetwork(request):
            request.labels
        case let .createVolume(request):
            request.labels
        case .deleteNetwork, .listVolumes, .deleteVolume:
            [:]
        }
    }
}

enum ContainerResourceAPIRequest: Equatable {
    case createNetwork(
        name: String,
        mode: NetworkMode,
        plugin: String,
        ipv4Subnet: String?,
        ipv4Gateway: String?,
        ipv4AllocationRange: String?,
        ipv6Subnet: String?,
        ipv6Gateway: String? = nil,
        enableIPv6: Bool,
        options: [String: String],
        labels: [String: String]
    )
    case networkExists(id: String)
    case deleteNetwork(id: String)
    case createVolume(ComposeVolumeCreateRequest)
    case listVolumes
    case deleteVolume(name: String)
}

actor RecordingComposeSignalProxy: ComposeSignalProxying {
    private let forwardedSignals: [String]
    private let runsOperation: Bool
    private var storage: [[String]] = []

    init(
        forwardedSignals: [String] = [],
        runsOperation: Bool = true
    ) {
        self.forwardedSignals = forwardedSignals
        self.runsOperation = runsOperation
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
        if runsOperation {
            try await operation()
        }
    }
}

actor RecordingComposeUpMenuController: ComposeUpMenuControlling {
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

actor RecordingContainerCopier: ComposeRuntimeArchiveCopying {
    private var storage: [ContainerCopyRequest] = []
    private var optionStorage: [ContainerCopyTransferOptions] = []
    private var archiveHandles: [FileHandle] = []

    var requests: [ContainerCopyRequest] {
        storage
    }

    var options: [ContainerCopyTransferOptions] {
        optionStorage
    }

    var archiveHandlesAreClosed: Bool {
        for archive in archiveHandles {
            do {
                _ = try archive.offset()
                return false
            } catch {}
        }
        return true
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

    func copyArchiveIntoContainer(
        id: String,
        archive: FileHandle,
        destination: String,
        options: ContainerCopyTransferOptions,
    ) async throws {
        storage.append(.archiveInto(id: id, destination: destination, data: archive.readDataToEndOfFile()))
        optionStorage.append(options)
        archiveHandles.append(archive)
    }

    func copyFromContainerAsArchive(
        id: String,
        source: String,
        archive _: FileHandle,
        copyContents: Bool,
        options: ContainerCopyTransferOptions,
    ) async throws {
        storage.append(.archiveFrom(id: id, source: source, copyContents: copyContents))
        optionStorage.append(options)
    }
}

actor ArchiveProducingContainerCopier: ComposeRuntimeArchiveCopying {
    private let archiveData: Data
    private var storage: [ContainerCopyRequest] = []

    init(archiveData: Data) {
        self.archiveData = archiveData
    }

    var requests: [ContainerCopyRequest] {
        storage
    }

    func copyIntoContainer(id: String, source: String, destination: String, options _: ContainerCopyTransferOptions) async throws {
        storage.append(.into(id: id, source: source, destination: destination))
    }

    func copyFromContainer(id: String, source: String, destination: String, options _: ContainerCopyTransferOptions) async throws {
        storage.append(.from(id: id, source: source, destination: destination))
    }

    func copyBetweenContainers(sourceID: String, source: String, destinationID: String, destination: String, options _: ContainerCopyTransferOptions) async throws {
        storage.append(.between(sourceID: sourceID, source: source, destinationID: destinationID, destination: destination))
    }

    func copyArchiveIntoContainer(
        id: String,
        archive: FileHandle,
        destination: String,
        options _: ContainerCopyTransferOptions,
    ) async throws {
        storage.append(.archiveInto(id: id, destination: destination, data: archive.readDataToEndOfFile()))
    }

    func copyFromContainerAsArchive(
        id: String,
        source: String,
        archive: FileHandle,
        copyContents: Bool,
        options _: ContainerCopyTransferOptions,
    ) async throws {
        storage.append(.archiveFrom(id: id, source: source, copyContents: copyContents))
        archive.write(archiveData)
    }
}

actor PathOnlyRecordingContainerCopier: ContainerCopying {
    private var storage: [ContainerCopyRequest] = []

    var requests: [ContainerCopyRequest] {
        storage
    }

    func copyIntoContainer(
        id: String,
        source: String,
        destination: String,
        options _: ContainerCopyTransferOptions,
    ) async throws {
        storage.append(.into(id: id, source: source, destination: destination))
    }

    func copyFromContainer(
        id: String,
        source: String,
        destination: String,
        options _: ContainerCopyTransferOptions,
    ) async throws {
        storage.append(.from(id: id, source: source, destination: destination))
        let root = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = (source as NSString).lastPathComponent
        try Data("from container\n".utf8).write(to: root.appendingPathComponent(name))
    }

    func copyBetweenContainers(
        sourceID: String,
        source: String,
        destinationID: String,
        destination: String,
        options _: ContainerCopyTransferOptions,
    ) async throws {
        storage.append(.between(
            sourceID: sourceID,
            source: source,
            destinationID: destinationID,
            destination: destination,
        ))
    }
}

struct TemporaryPathSnapshot: Equatable {
    var path: String
    var isDirectory: Bool
    var permissions: Int
}

actor TemporaryPathSnapshottingContainerCopier: ContainerCopying {
    private let root: URL
    private var storage: [TemporaryPathSnapshot] = []

    init(root: URL) {
        self.root = root
    }

    var snapshots: [TemporaryPathSnapshot] {
        storage
    }

    func copyIntoContainer(
        id _: String,
        source _: String,
        destination _: String,
        options _: ContainerCopyTransferOptions,
    ) async throws {
        storage = try Self.snapshot(root: root)
        throw ComposeError.invalidProject("intentional copy failure")
    }

    func copyFromContainer(
        id _: String,
        source _: String,
        destination _: String,
        options _: ContainerCopyTransferOptions,
    ) async throws {
        throw ComposeError.invalidProject("unexpected copy-from operation")
    }

    func copyBetweenContainers(
        sourceID _: String,
        source _: String,
        destinationID _: String,
        destination _: String,
        options _: ContainerCopyTransferOptions,
    ) async throws {
        throw ComposeError.invalidProject("unexpected container-to-container copy")
    }

    fileprivate static func snapshot(root: URL) throws -> [TemporaryPathSnapshot] {
        let fileManager = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
        ) else {
            return []
        }
        return try enumerator.compactMap { item -> TemporaryPathSnapshot? in
            guard let url = item as? URL else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let components = url.pathComponents
            guard let rootIndex = components.lastIndex(of: root.lastPathComponent) else {
                return nil
            }
            return TemporaryPathSnapshot(
                path: components.suffix(from: rootIndex + 1).joined(separator: "/"),
                isDirectory: values.isDirectory == true,
                permissions: try orchestratorPosixPermissions(at: url.path),
            )
        }
        .sorted { $0.path < $1.path }
    }
}

actor TemporaryPathSnapshottingExporter: ContainerExporting {
    private let root: URL
    private var storage: [TemporaryPathSnapshot] = []

    init(root: URL) {
        self.root = root
    }

    var snapshots: [TemporaryPathSnapshot] {
        storage
    }

    func exportContainer(id _: String, output _: String?, live _: Bool, noFreeze _: Bool) async throws {
        storage = try TemporaryPathSnapshottingContainerCopier.snapshot(root: root)
        throw ComposeError.invalidProject("intentional export failure")
    }
}

actor RecordingContainerCopyOperations {
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

    nonisolated func copyArchiveInto(
        id: String,
        archive: FileHandle,
        destination: String,
        options: ContainerCopyTransferOptions,
    ) async throws {
        let data = archive.readDataToEndOfFile()
        await recordArchiveInto(id: id, destination: destination, data: data, options: options)
    }

    nonisolated func copyArchiveFrom(
        id: String,
        source: String,
        archive: FileHandle,
        copyContents: Bool,
        options: ContainerCopyTransferOptions,
    ) async throws {
        await recordArchiveFrom(
            id: id,
            source: source,
            copyContents: copyContents,
            options: options,
        )
        archive.write(Data("streamed".utf8))
    }

    private func recordArchiveInto(
        id: String,
        destination: String,
        data: Data,
        options: ContainerCopyTransferOptions,
    ) {
        storage.append(.archiveInto(id: id, destination: destination, data: data))
        optionStorage.append(options)
    }

    private func recordArchiveFrom(
        id: String,
        source: String,
        copyContents: Bool,
        options: ContainerCopyTransferOptions,
    ) {
        storage.append(.archiveFrom(id: id, source: source, copyContents: copyContents))
        optionStorage.append(options)
    }
}

actor RecordingContainerLifecycleManager: ContainerLifecycleManaging {
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

actor RecordingContainerDiscoveryManager: ContainerDiscoveryManaging {
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

actor RecordingContainerDiscoveryAPIClient: ContainerDiscoveryAPIClienting {
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

actor RecordingContainerLogManager: ContainerLogManaging {
    private let outputs: [String]
    private let delay: Duration?
    private let error: (any Error)?
    private var storage: [ContainerLogRequest] = []

    init(outputs: [String] = [], delay: Duration? = nil, error: (any Error)? = nil) {
        self.outputs = outputs
        self.delay = delay
        self.error = error
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
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let error {
            throw error
        }
        for output in outputs {
            emit(Data(output.utf8))
        }
    }
}

actor RecordingContainerLogFollowStateProvider: ContainerLogFollowStateProviding {
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

actor BlockingContainerLogManager: ContainerLogManaging {
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
        emit _: @escaping @Sendable (Data) -> Void
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
        for _ in 0 ..< 100 {
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

actor RecordingContainerLogAPIClient: ContainerLogAPIClienting {
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

actor RotatingContainerLogAPIClient: ContainerLogAPIClienting {
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
        return try [temporaryLogFileHandle(data: nextLogSnapshot())]
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
        try suppressBrokenPipeSignal(for: writer)
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
        try suppressBrokenPipeSignal(for: writer)
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

func suppressBrokenPipeSignal(for fileHandle: FileHandle) throws {
    #if canImport(Darwin)
        guard Darwin.fcntl(fileHandle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    #else
        _ = fileHandle
    #endif
}

func applyLogOptions(
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

func appendedLogRecords(
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

func logRecordOverlapLength(previous: [ContainerLogRecord], current: [ContainerLogRecord]) -> Int {
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

actor RecordingContainerExecManager: ContainerExecManaging {
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

actor RecordingContainerExecAPIClient: ContainerExecAPIClienting {
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

actor RecordingContainerStatsManager: ContainerStatsManaging {
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

actor RecordingContainerStatsDataManager: ComposeRuntimeStatsDataManaging {
    private let output: Data
    private var storage: [ContainerStatsRequest] = []

    init(output: Data) {
        self.output = output
    }

    var requests: [ContainerStatsRequest] {
        storage
    }

    func stats(
        ids _: [String],
        format _: String,
        noStream _: Bool,
        noTrunc _: Bool,
        includeStopped _: Bool,
        emit _: @escaping @Sendable (String) -> Void
    ) async throws {}

    func stats(
        ids: [String],
        format: String,
        noStream: Bool,
        noTrunc: Bool,
        includeStopped: Bool,
        emit _: @escaping @Sendable (String) -> Void,
        emitData: @escaping @Sendable (Data) -> Void
    ) async throws {
        storage.append(ContainerStatsRequest(
            ids: ids,
            format: format,
            noStream: noStream,
            noTrunc: noTrunc,
            includeStopped: includeStopped
        ))
        emitData(output)
    }
}

actor InterruptibleStatsManager: ContainerStatsManaging {
    private(set) var cancelled = false

    func stats(
        ids _: [String],
        format _: String,
        noStream _: Bool,
        noTrunc _: Bool,
        includeStopped _: Bool,
        emit _: @escaping @Sendable (String) -> Void
    ) async throws {
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }
}

actor RecordingContainerTopManager: ContainerTopManaging {
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

struct ComposeEventsRequest: Equatable {
    var projectName: String
    var services: [String]
    var format: ComposeEventsOutputFormat
    var since: Date? = nil
    var until: Date? = nil
}

actor RecordingContainerEventsManager: ContainerEventsManaging {
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

actor RecordingContainerEventsAPIClient: ContainerEventsAPIClienting {
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

actor RecordingContainerStatsAPIClient: ContainerStatsAPIClienting {
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

actor RecordingContainerTopAPIClient: ContainerTopAPIClienting {
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

actor RecordingContainerImageManager: ContainerImageManaging {
    private var storage: [ContainerImageRequest] = []
    private var archivedImageData: [Data] = []
    private var existingReferences: Set<String>
    private var digests: [String: String]
    private var healthChecks: [ImageHealthCheckRequestKey: ComposeImageHealthCheck]
    private var imageVolumeTargets: [ImageVolumeTargetRequestKey: [String]]
    private var imageMetadata: [String: ComposeImageMetadata]
    private var platformImageMetadata: [ImageMetadataRequestKey: ComposeImageMetadata]
    private let unavailablePlatformImageMetadataRequests: Set<ImageMetadataRequestKey>
    private var transformers: [ComposeBridgeTransformer]
    private let pullFailures: Set<String>
    private let pullMissingFailures: Set<String>
    private let onPullImage: @Sendable (String) async -> Void
    private let onPushImage: @Sendable (String) async -> Void
    private var pushOutputs: [String: String]
    private let pushFailures: Set<String>
    private var deleteOutputs: [String: String?]
    private var loadOutputs: [String: [String]]
    private let failure: ComposeError?

    init(
        existingReferences: Set<String> = [],
        digests: [String: String] = [:],
        healthChecks: [String: ComposeImageHealthCheck] = [:],
        platformHealthChecks: [ImageHealthCheckRequestKey: ComposeImageHealthCheck] = [:],
        imageVolumeTargets: [String: [String]] = [:],
        platformImageVolumeTargets: [ImageVolumeTargetRequestKey: [String]] = [:],
        imageMetadata: [String: ComposeImageMetadata] = [:],
        platformImageMetadata: [ImageMetadataRequestKey: ComposeImageMetadata] = [:],
        unavailablePlatformImageMetadataRequests: Set<ImageMetadataRequestKey> = [],
        transformers: [ComposeBridgeTransformer] = [],
        pullFailures: Set<String> = [],
        pullMissingFailures: Set<String> = [],
        onPullImage: @escaping @Sendable (String) async -> Void = { _ in },
        onPushImage: @escaping @Sendable (String) async -> Void = { _ in },
        pushOutputs: [String: String] = [:],
        pushFailures: Set<String> = [],
        deleteOutputs: [String: String?] = [:],
        loadOutputs: [String: [String]] = [:],
        failure: ComposeError? = nil
    ) {
        self.existingReferences = existingReferences
        self.digests = digests
        var mappedHealthChecks = platformHealthChecks
        for (reference, healthCheck) in healthChecks {
            mappedHealthChecks[ImageHealthCheckRequestKey(reference: reference, platform: nil)] = healthCheck
        }
        self.healthChecks = mappedHealthChecks
        var mappedImageVolumeTargets = platformImageVolumeTargets
        for (reference, targets) in imageVolumeTargets {
            mappedImageVolumeTargets[ImageVolumeTargetRequestKey(reference: reference, platform: nil)] = targets
        }
        self.imageVolumeTargets = mappedImageVolumeTargets
        self.imageMetadata = imageMetadata
        self.platformImageMetadata = platformImageMetadata
        self.unavailablePlatformImageMetadataRequests = unavailablePlatformImageMetadataRequests
        self.transformers = transformers
        self.pullFailures = pullFailures
        self.pullMissingFailures = pullMissingFailures
        self.onPullImage = onPullImage
        self.onPushImage = onPushImage
        self.pushOutputs = pushOutputs
        self.pushFailures = pushFailures
        self.deleteOutputs = deleteOutputs
        self.loadOutputs = loadOutputs
        self.failure = failure
    }

    var requests: [ContainerImageRequest] {
        storage
    }

    var loadedArchiveData: [Data] {
        archivedImageData
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

    func imageDeclaredVolumeTargets(_ reference: String, platform: String?) async throws -> [String] {
        if let failure {
            throw failure
        }
        let key = ImageVolumeTargetRequestKey(reference: reference, platform: platform)
        guard let targets = imageVolumeTargets[key] else {
            return []
        }
        storage.append(.volumeTargets(reference: reference, platform: platform))
        return targets
    }

    func imageMetadataIfAvailable(_ reference: String, platform: String?) async throws -> ComposeImageMetadata? {
        if let failure {
            throw failure
        }
        let key = ImageMetadataRequestKey(reference: reference, platform: platform)
        storage.append(.availableMetadata(reference: reference, platform: platform))
        if unavailablePlatformImageMetadataRequests.contains(key) {
            return nil
        }
        return platformImageMetadata[key]
            ?? imageMetadata[reference]
            ?? ComposeImageMetadata(reference: reference)
    }

    func imageMetadata(_ reference: String) async throws -> ComposeImageMetadata {
        if let failure {
            throw failure
        }
        storage.append(.metadata(reference))
        return imageMetadata[reference] ?? ComposeImageMetadata(reference: reference)
    }

    func bridgeTransformers() async throws -> [ComposeBridgeTransformer] {
        if let failure {
            throw failure
        }
        storage.append(.bridgeTransformers)
        return transformers
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
        await onPushImage(reference)
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

    func loadImageArchive(_ path: String, emit: @escaping @Sendable (String) -> Void) async throws {
        if let failure {
            throw failure
        }
        storage.append(.load(path))
        if let archiveData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            archivedImageData.append(archiveData)
        }
        for reference in loadOutputs[path] ?? ["loaded:latest"] {
            emit(reference)
        }
    }
}

actor RecordingContainerImageAPIClient: ContainerImageAPIClienting {
    private var existingReferences: Set<String>
    private var digests: [String: String]
    private var healthChecks: [ImageHealthCheckRequestKey: ComposeImageHealthCheck]
    private var imageVolumeTargets: [ImageVolumeTargetRequestKey: [String]]
    private var imageMetadata: [String: ComposeImageMetadata]
    private var platformImageMetadata: [ImageMetadataRequestKey: ComposeImageMetadata]
    private let unavailablePlatformImageMetadataRequests: Set<ImageMetadataRequestKey>
    private var transformers: [ComposeBridgeTransformer]
    private var pushOutputs: [String: String]
    private var deleteOutputs: [String: String?]
    private var loadOutputs: [String: [String]]
    private var pullErrors: [String: [ContainerizationError]]
    private var storage: [ContainerImageRequest] = []

    init(
        existingReferences: Set<String> = [],
        digests: [String: String] = [:],
        healthChecks: [String: ComposeImageHealthCheck] = [:],
        platformHealthChecks: [ImageHealthCheckRequestKey: ComposeImageHealthCheck] = [:],
        imageVolumeTargets: [String: [String]] = [:],
        platformImageVolumeTargets: [ImageVolumeTargetRequestKey: [String]] = [:],
        imageMetadata: [String: ComposeImageMetadata] = [:],
        platformImageMetadata: [ImageMetadataRequestKey: ComposeImageMetadata] = [:],
        unavailablePlatformImageMetadataRequests: Set<ImageMetadataRequestKey> = [],
        transformers: [ComposeBridgeTransformer] = [],
        pushOutputs: [String: String] = [:],
        deleteOutputs: [String: String?] = [:],
        loadOutputs: [String: [String]] = [:],
        pullErrors: [String: [ContainerizationError]] = [:]
    ) {
        self.existingReferences = existingReferences
        self.digests = digests
        var mappedHealthChecks = platformHealthChecks
        for (reference, healthCheck) in healthChecks {
            mappedHealthChecks[ImageHealthCheckRequestKey(reference: reference, platform: nil)] = healthCheck
        }
        self.healthChecks = mappedHealthChecks
        var mappedImageVolumeTargets = platformImageVolumeTargets
        for (reference, targets) in imageVolumeTargets {
            mappedImageVolumeTargets[ImageVolumeTargetRequestKey(reference: reference, platform: nil)] = targets
        }
        self.imageVolumeTargets = mappedImageVolumeTargets
        self.imageMetadata = imageMetadata
        self.platformImageMetadata = platformImageMetadata
        self.unavailablePlatformImageMetadataRequests = unavailablePlatformImageMetadataRequests
        self.transformers = transformers
        self.pushOutputs = pushOutputs
        self.deleteOutputs = deleteOutputs
        self.loadOutputs = loadOutputs
        self.pullErrors = pullErrors
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

    func imageDeclaredVolumeTargets(reference: String, platform: String?) async throws -> [String] {
        let key = ImageVolumeTargetRequestKey(reference: reference, platform: platform)
        guard let targets = imageVolumeTargets[key] else {
            return []
        }
        storage.append(.volumeTargets(reference: reference, platform: platform))
        return targets
    }

    func imageMetadataIfAvailable(reference: String, platform: String?) async throws -> ComposeImageMetadata? {
        let key = ImageMetadataRequestKey(reference: reference, platform: platform)
        storage.append(.availableMetadata(reference: reference, platform: platform))
        if unavailablePlatformImageMetadataRequests.contains(key) {
            return nil
        }
        return platformImageMetadata[key]
            ?? imageMetadata[reference]
            ?? ComposeImageMetadata(reference: reference)
    }

    func imageMetadata(reference: String) async throws -> ComposeImageMetadata {
        storage.append(.metadata(reference))
        return imageMetadata[reference] ?? ComposeImageMetadata(reference: reference)
    }

    func bridgeTransformers() async throws -> [ComposeBridgeTransformer] {
        storage.append(.bridgeTransformers)
        return transformers
    }

    func pullImage(reference: String) async throws {
        storage.append(.pull(reference))
        if var errors = pullErrors[reference], !errors.isEmpty {
            let error = errors.removeFirst()
            pullErrors[reference] = errors
            throw error
        }
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

    func loadImageArchive(path: String) async throws -> [String] {
        storage.append(.load(path))
        return loadOutputs[path] ?? ["loaded:latest"]
    }
}

actor RecordingPullMetadataStore: ComposePullMetadataStoring {
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

actor ThrowingSleeper {
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

actor FileMutationSleeper {
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

actor FileDeletionSleeper {
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

actor RecordingContainerLifecycleAPIClient: ContainerLifecycleAPIClienting {
    private let waitExitCodes: [String: Int32]
    private let snapshots: [String: ContainerSnapshot]
    private var storage: [ContainerLifecycleRequest] = []

    init(waitExitCodes: [String: Int32] = [:], snapshots: [String: ContainerSnapshot] = [:]) {
        self.waitExitCodes = waitExitCodes
        self.snapshots = snapshots
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
            timeoutInSeconds: options.timeoutInSeconds.map(Int.init)
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

    func getContainer(id: String) async throws -> ContainerSnapshot {
        storage.append(.get(id: id))
        guard let snapshot = snapshots[id] else {
            throw ComposeError.invalidProject("missing container fixture '\(id)'")
        }
        return snapshot
    }

    func deleteContainer(id: String, force: Bool) async throws {
        storage.append(.delete(id: id, force: force))
    }
}

actor RecordingContainerResourceAPIClient: ContainerResourceAPIClienting {
    private let existingNetworks: Set<String>
    private let volumes: [ComposeVolumeSummary]
    private let networkCreateError: (any Error)?
    private let networkDeleteError: (any Error)?
    private let volumeCreateError: (any Error)?
    private let volumeDeleteError: (any Error)?
    private var storage: [ContainerResourceAPIRequest] = []

    init(
        existingNetworks: Set<String> = ["demo_default"],
        volumes: [ComposeVolumeSummary] = [],
        networkCreateError: (any Error)? = nil,
        networkDeleteError: (any Error)? = nil,
        volumeCreateError: (any Error)? = nil,
        volumeDeleteError: (any Error)? = nil
    ) {
        self.existingNetworks = existingNetworks
        self.volumes = volumes
        self.networkCreateError = networkCreateError
        self.networkDeleteError = networkDeleteError
        self.volumeCreateError = volumeCreateError
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
            ipv4Gateway: configuration.ipv4Gateway?.description,
            ipv4AllocationRange: configuration.ipv4AllocationRange?.description,
            ipv6Subnet: configuration.ipv6Subnet?.description,
            ipv6Gateway: configuration.ipv6Gateway?.description,
            enableIPv6: configuration.enableIPv6,
            options: configuration.options,
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

actor RecordingContainerResourceManager: ContainerResourceManaging {
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

actor RecordingContainerImageVolumeInitializer: ComposeRuntimeImageVolumeInitializing {
    private var storage: [ComposeImageVolumeInitializationRequest] = []

    var requests: [ComposeImageVolumeInitializationRequest] {
        storage
    }

    func initializeImageVolume(_ request: ComposeImageVolumeInitializationRequest) async throws {
        storage.append(request)
    }
}

actor RecordingContainerExporter: ContainerExporting {
    private var storage: [ContainerExportRequest] = []
    private let archiveData: Data?
    private let failure: ComposeError?

    init(archiveData: Data? = nil, failure: ComposeError? = nil) {
        self.archiveData = archiveData
        self.failure = failure
    }

    var requests: [ContainerExportRequest] {
        storage
    }

    func exportContainer(id: String, output: String?, live: Bool, noFreeze: Bool) async throws {
        storage.append(ContainerExportRequest(id: id, output: output, live: live, noFreeze: noFreeze))
        if let failure {
            throw failure
        }
        if let archiveData, let output {
            try archiveData.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}

actor DurationRecorder {
    private var storage: [Duration] = []

    var durations: [Duration] {
        storage
    }

    func sleep(_ duration: Duration) async throws {
        storage.append(duration)
    }
}

func bakeJSON(_ output: String) throws -> [String: Any] {
    guard let data = output.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw ComposeError.invalidProject("build --print emitted malformed bake JSON")
    }
    return object
}

func bakeGroupTargets(_ bake: [String: Any]) throws -> [String] {
    guard let groups = bake["group"] as? [String: Any],
          let defaultGroup = groups["default"] as? [String: Any],
          let targets = defaultGroup["targets"] as? [String]
    else {
        throw ComposeError.invalidProject("build --print emitted malformed bake group")
    }
    return targets
}

func bakeTarget(_ bake: [String: Any], name: String) throws -> [String: Any] {
    guard let targets = bake["target"] as? [String: Any],
          let target = targets[name] as? [String: Any]
    else {
        throw ComposeError.invalidProject("build --print emitted no bake target named '\(name)'")
    }
    return target
}

final class MessageRecorder: @unchecked Sendable {
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

actor OperationConcurrencyRecorder {
    private var activeOperations = 0
    private var maximum = 0
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    var maximumActiveOperations: Int {
        maximum
    }

    func recordOperation() async {
        activeOperations += 1
        maximum = max(maximum, activeOperations)
        try? await Task.sleep(for: delay)
        activeOperations -= 1
    }
}

actor DelayedBuildRunner: CommandRunning {
    private let delay: Duration
    private var activeOperations = 0
    private var maximum = 0
    private var storedCommands: [[String]] = []

    init(delay: Duration) {
        self.delay = delay
    }

    var commands: [[String]] {
        storedCommands
    }

    var maximumActiveOperations: Int {
        maximum
    }

    func run(
        _: String,
        _ arguments: [String],
        workingDirectory _: URL?,
        environment _: [String: String]?,
        io _: CommandIO
    ) async throws -> CommandResult {
        activeOperations += 1
        maximum = max(maximum, activeOperations)
        try? await Task.sleep(for: delay)
        storedCommands.append(arguments)
        activeOperations -= 1
        return .success
    }
}

final class DataRecorder: @unchecked Sendable {
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

final class OneOffIdentifierSource: @unchecked Sendable {
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

struct HostPortAllocationRequest: Equatable {
    var hostAddress: String?
    var protocolName: String
}

final class HostPortSource: @unchecked Sendable {
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

extension Array where Element == String {
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
