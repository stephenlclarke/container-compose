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
import ComposeTestStorage
import Foundation
import Testing

// Concrete provider API fixtures are deliberately enhanced-only.

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

func logRecords(from data: Data) throws -> [ContainerLogRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data.split(separator: UInt8(ascii: "\n")).map { line in
        try decoder.decode(ContainerLogRecord.self, from: Data(line))
    }
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
        enableIPv4: Bool = true,
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

actor RecordingContainerDiscoveryAPIClient: ContainerDiscoveryAPIClienting {
    private let listResponse: [ContainerSnapshot]
    private let getResponse: ContainerSnapshot?
    private let lifecycleViewsResponse: [ContainerLifecycleViewV2]
    private let getError: (any Error)?
    private let lifecycleViewsError: (any Error)?
    private var filters: [ContainerListFilters] = []
    private var lifecycleFilters: [ContainerListFilters] = []
    private var gets: [String] = []

    init(
        listResponse: [ContainerSnapshot] = [],
        getResponse: ContainerSnapshot? = nil,
        lifecycleViewsResponse: [ContainerLifecycleViewV2] = [],
        getError: (any Error)? = nil,
        lifecycleViewsError: (any Error)? = nil
    ) {
        self.listResponse = listResponse
        self.getResponse = getResponse
        self.lifecycleViewsResponse = lifecycleViewsResponse
        self.getError = getError
        self.lifecycleViewsError = lifecycleViewsError
    }

    var listFilters: [ContainerListFilters] {
        filters
    }

    var getRequests: [String] {
        gets
    }

    var lifecycleViewFilters: [ContainerListFilters] {
        lifecycleFilters
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

    func listLifecycleViews(filters: ContainerListFilters) async throws -> [ContainerLifecycleViewV2] {
        lifecycleFilters.append(filters)
        if let lifecycleViewsError {
            throw lifecycleViewsError
        }
        return lifecycleViewsResponse
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

actor RecordingContainerLogAPIClient: ContainerLogAPIClienting {
    private let fileHandles: [FileHandle]
    private let records: [ContainerLogRecord]
    private let error: (any Error)?
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

    init(
        fileHandles: [FileHandle] = [],
        records: [ContainerLogRecord] = [],
        error: (any Error)? = nil
    ) {
        self.fileHandles = fileHandles
        self.records = records
        self.error = error
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
        if let error {
            throw error
        }
        return fileHandles
    }

    func logRecords(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> [ContainerLogRecord] {
        recordStorage.append(id)
        recordOptionsStorage.append(options)
        recordReplayStorage.append(replay)
        if let error {
            throw error
        }
        return applyLogOptions(to: records, options: options)
    }

    func followLogs(id: String, options: ContainerLogOptions) async throws -> FileHandle {
        followStorage.append(id)
        followOptionsStorage.append(options)
        if let error {
            throw error
        }
        if let fileHandle = fileHandles.first {
            return fileHandle
        }
        return try temporaryLogFileHandle(data: Data())
    }

    func followLogRecords(id: String, options: ContainerLogOptions) async throws -> FileHandle {
        followRecordStorage.append(id)
        followRecordOptionsStorage.append(options)
        if let error {
            throw error
        }
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
    for length in stride(from: min(previous.count, current.count), through: 1, by: -1)
        where Array(previous.suffix(length)) == Array(current.prefix(length))
    {
        return length
    }
    return 0
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
        let output: String? = if deleteOutputs.keys.contains(reference) {
            deleteOutputs[reference] ?? nil
        } else {
            reference
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

    func restartContainer(id: String, options: ContainerStopOptions) async throws {
        storage.append(.restart(
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
            enableIPv4: configuration.enableIPv4,
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
