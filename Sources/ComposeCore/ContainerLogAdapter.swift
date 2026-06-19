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

import ContainerAPIClient
import ContainerResource
import Foundation

/// Low-level apple/container log call used by `ContainerClientLogManager`.
public protocol ContainerLogAPIClienting: Sendable {
    /// Returns the log file handles exposed by apple/container for `id`.
    func logFileHandles(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> [FileHandle]

    /// Returns the structured log records exposed by apple/container for `id`.
    func logRecords(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> [ContainerLogRecord]

    /// Returns the active structured log record file exposed by apple/container for `id`.
    func logRecordFile(id: String) async throws -> FileHandle
}

public extension ContainerLogAPIClienting {
    /// Returns unfiltered log file handles exposed by apple/container for `id`.
    func logFileHandles(id: String) async throws -> [FileHandle] {
        try await logFileHandles(id: id, options: .default, replay: .default)
    }

    /// Returns unfiltered structured log records exposed by apple/container for `id`.
    func logRecords(id: String) async throws -> [ContainerLogRecord] {
        try await logRecords(id: id, options: .default, replay: .default)
    }
}

/// Runtime state used to decide when a followed log stream has finished.
public protocol ContainerLogFollowStateProviding: Sendable {
    /// Returns true while container `id` can still append runtime log bytes.
    func isLiveForLogFollow(id: String) async throws -> Bool
}

/// `ContainerClient`-backed live-state provider for followed log streams.
public struct ContainerClientLogFollowStateProvider: ContainerLogFollowStateProviding {
    private let client: ContainerDiscoveryAPIClienting

    public init(client: ContainerDiscoveryAPIClienting = ContainerDiscoveryAPIClient()) {
        self.client = client
    }

    /// Returns true for running or stopping containers.
    public func isLiveForLogFollow(id: String) async throws -> Bool {
        guard let container = try await client.getContainer(id: id) else {
            return false
        }
        return container.status == .running || container.status == .stopping
    }
}

/// Direct apple/container API used for service container logs.
public protocol ContainerLogManaging: Sendable {
    /// Emits logs for container `id`, optionally following appended lines.
    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws
}

public extension ContainerLogManaging {
    /// Emits logs through a string callback for tests and non-binary consumers.
    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        try await logs(
            id: id,
            tail: tail,
            follow: follow,
            since: since,
            until: until,
            timestamps: timestamps,
            emit: { emit(String(decoding: $0, as: UTF8.self)) }
        )
    }

    /// Emits logs without timestamp filters.
    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        try await logs(
            id: id,
            tail: tail,
            follow: follow,
            since: nil,
            until: nil,
            timestamps: false,
            emit: emit
        )
    }

    /// Emits logs without timestamp filters through a byte callback.
    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        try await logs(
            id: id,
            tail: tail,
            follow: follow,
            since: nil,
            until: nil,
            timestamps: false,
            emit: emit
        )
    }
}

/// Thin apple/container client wrapper around log API calls.
public struct ContainerLogAPIClient: ContainerLogAPIClienting {
    public typealias Logs = @Sendable (String, ContainerLogOptions, ContainerLogReplayOptions) async throws -> [FileHandle]
    public typealias LogRecords = @Sendable (String, ContainerLogOptions, ContainerLogReplayOptions) async throws -> [ContainerLogRecord]
    public typealias LogRecordFile = @Sendable (String) async throws -> FileHandle

    private let logsOperation: Logs
    private let logRecordsOperation: LogRecords
    private let logRecordFileOperation: LogRecordFile

    public init(
        logs: @escaping Logs = { try await ContainerClient().logs(id: $0, options: $1, replay: $2) },
        logRecords: @escaping LogRecords = { try await ContainerClient().logRecords(id: $0, options: $1, replay: $2) },
        logRecordFile: @escaping LogRecordFile = { try await ContainerClient().logRecordFile(id: $0) }
    ) {
        self.logsOperation = logs
        self.logRecordsOperation = logRecords
        self.logRecordFileOperation = logRecordFile
    }

    /// Fetches log file handles through `ContainerClient`.
    public func logFileHandles(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> [FileHandle] {
        try await logsOperation(id, options, replay)
    }

    /// Fetches structured log records through `ContainerClient`.
    public func logRecords(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> [ContainerLogRecord] {
        try await logRecordsOperation(id, options, replay)
    }

    /// Fetches the active structured log record file through `ContainerClient`.
    public func logRecordFile(id: String) async throws -> FileHandle {
        try await logRecordFileOperation(id)
    }
}

/// `ContainerClient`-backed log manager for service containers.
public struct ContainerClientLogManager: ContainerLogManaging {
    private let client: ContainerLogAPIClienting
    private let followStateProvider: ContainerLogFollowStateProviding

    public init(
        client: ContainerLogAPIClienting = ContainerLogAPIClient(),
        followStateProvider: ContainerLogFollowStateProviding = ContainerClientLogFollowStateProvider()
    ) {
        self.client = client
        self.followStateProvider = followStateProvider
    }

    /// Emits stdio logs through `ContainerClient.logs(id:)`.
    public func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        if timestamps || since != nil || until != nil {
            if follow {
                try await emitStructuredFollowLogs(
                    id: id,
                    tail: tail,
                    since: since,
                    until: until,
                    timestamps: timestamps,
                    emit: emit
                )
            } else {
                try await emitStructuredLogs(
                    id: id,
                    tail: tail,
                    since: since,
                    until: until,
                    timestamps: timestamps,
                    emit: emit
                )
            }
            return
        }

        if follow {
            try await emitFollowedRotatingLogs(id: id, tail: tail, emit: emit)
            return
        }

        let options = ContainerLogOptions(tail: tail, since: since, until: until)
        let replay = ContainerLogReplayOptions(includeRotated: true)
        let fileHandles = try await client.logFileHandles(id: id, options: options, replay: replay)
        guard let fileHandle = fileHandles.first else {
            throw ComposeError.invalidProject("container logs returned no stdio handle for \(id)")
        }
        defer {
            for handle in fileHandles {
                try? handle.close()
            }
        }

        try emitExistingLogs(from: fileHandle, tail: follow ? tail : nil, emit: emit)
    }

    /// Emits followed structured records when Compose needs runtime timestamps.
    private func emitStructuredFollowLogs(
        id: String,
        tail: Int?,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        let renderer = StructuredLogRecordRenderer(since: since, until: until, timestamps: timestamps)
        if tail != 0 {
            let options = ContainerLogOptions(tail: tail, since: since, until: until)
            let records = try await client.logRecords(
                id: id,
                options: options,
                replay: ContainerLogReplayOptions(includeRotated: true)
            )
            let shouldFinish = emitInitialStructuredRecords(
                records,
                tail: nil,
                renderer: renderer,
                emit: emit
            )
            if shouldFinish {
                return
            }
        }
        if until.map({ $0 <= Date() }) == true {
            emitEachLogLine(renderer.flush(), emit: emit)
            return
        }
        guard try await followStateProvider.isLiveForLogFollow(id: id) else {
            emitEachLogLine(renderer.flush(), emit: emit)
            return
        }

        let recordFile = try await client.logRecordFile(id: id)
        defer {
            try? recordFile.close()
        }
        _ = try? recordFile.seekToEnd()
        try await followStructuredRecordFile(
            id: id,
            recordFile: recordFile,
            renderer: renderer,
            until: until,
            emit: emit
        )
    }

    /// Follows the active structured record file without replaying full merged snapshots.
    private func followStructuredRecordFile(
        id: String,
        recordFile: FileHandle,
        renderer: StructuredLogRecordRenderer,
        until: Date?,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        let decoder = StructuredLogRecordJSONLDecoder()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                return
            }
            if let data = try recordFile.readToEnd(), !data.isEmpty {
                let result = renderer.append(try decoder.append(data))
                let lines = result.shouldFinish ? result.lines + renderer.flush() : result.lines
                emitEachLogLine(lines, emit: emit)
                if result.shouldFinish {
                    return
                }
            }
            if until.map({ $0 <= Date() }) == true {
                emitEachLogLine(renderer.flush(), emit: emit)
                return
            }

            guard try await followStateProvider.isLiveForLogFollow(id: id) else {
                let result = renderer.append(try decoder.flush())
                emitEachLogLine(result.lines + renderer.flush(), emit: emit)
                return
            }
        }
    }

    /// Emits structured log records exposed by the direct log API.
    private func emitStructuredLogs(
        id: String,
        tail: Int?,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        let options = ContainerLogOptions(tail: tail, since: since, until: until)
        let records = try await client.logRecords(
            id: id,
            options: options,
            replay: ContainerLogReplayOptions(includeRotated: true)
        )
        emitLogLines(
            structuredLogLines(records: records, since: nil, until: nil, timestamps: timestamps),
            emit: emit
        )
    }

    /// Emits and follows raw logs through merged rotated replay snapshots.
    private func emitFollowedRotatingLogs(
        id: String,
        tail: Int?,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        let options = ContainerLogOptions()
        let replay = ContainerLogReplayOptions(includeRotated: true)
        let data = try await logDataSnapshot(id: id, options: options, replay: replay)
        guard try await followStateProvider.isLiveForLogFollow(id: id) else {
            emitExistingLogs(from: data, tail: tail, emit: emit)
            return
        }

        let initial = completeLogRecords(in: data)
        emitLogLines(tail.map { Array(initial.records.suffix($0)) } ?? initial.records, emit: emit)
        var cursor = LogDataReplayCursor(snapshot: data)
        let accumulator = LogLineAccumulator(initial: tail == 0 ? Data() : initial.remainder)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                return
            }

            let appended = cursor.appendedData(in: try await logDataSnapshot(id: id, options: options, replay: replay))
            for line in accumulator.append(appended) {
                emit(line)
            }
            guard try await followStateProvider.isLiveForLogFollow(id: id) else {
                if let finalLine = accumulator.flush() {
                    emit(finalLine)
                }
                return
            }
        }
    }

    /// Returns merged raw stdio log bytes from the direct apple/container API.
    private func logDataSnapshot(id: String, options: ContainerLogOptions, replay: ContainerLogReplayOptions) async throws -> Data {
        let fileHandles = try await client.logFileHandles(id: id, options: options, replay: replay)
        defer {
            for handle in fileHandles {
                try? handle.close()
            }
        }
        guard let fileHandle = fileHandles.first else {
            throw ComposeError.invalidProject("container logs returned no stdio handle for \(id)")
        }
        return try fileHandle.readToEnd() ?? Data()
    }

    /// Converts structured runtime chunks into Compose log lines.
    private func structuredLogLines(
        records: [ContainerLogRecord],
        since: Date?,
        until: Date?,
        timestamps: Bool
    ) -> [Data] {
        let renderer = StructuredLogRecordRenderer(since: since, until: until, timestamps: timestamps)
        let result = renderer.append(records)
        return result.lines + renderer.flush()
    }

    /// Emits structured records that already exist in a merged replay snapshot.
    private func emitInitialStructuredRecords(
        _ records: [ContainerLogRecord],
        tail: Int?,
        renderer: StructuredLogRecordRenderer,
        emit: @escaping @Sendable (Data) -> Void
    ) -> Bool {
        guard tail != 0 else {
            return false
        }

        let result = renderer.append(records)
        let lines = result.shouldFinish ? result.lines + renderer.flush() : result.lines
        let selectedLines = tail.map { Array(lines.suffix($0)) } ?? lines
        emitLogLines(selectedLines, emit: emit)
        return result.shouldFinish
    }

    /// Emits existing log contents before an optional follow loop starts.
    private func emitExistingLogs(
        from fileHandle: FileHandle,
        tail: Int?,
        emit: @escaping @Sendable (Data) -> Void
    ) throws {
        if let tail {
            try emitTail(from: fileHandle, count: tail, emit: emit)
        } else {
            try emitAll(from: fileHandle, emit: emit)
        }
    }

    /// Emits all log contents currently available from the file handle.
    private func emitAll(
        from fileHandle: FileHandle,
        emit: @escaping @Sendable (Data) -> Void
    ) throws {
        guard let data = try fileHandle.readToEnd() else {
            return
        }
        emitLogLines(recordsForCompleteLogData(data), emit: emit)
    }

    /// Emits the last `count` log records.
    private func emitTail(
        from fileHandle: FileHandle,
        count: Int,
        emit: @escaping @Sendable (Data) -> Void
    ) throws {
        guard count > 0 else {
            _ = try? fileHandle.seekToEnd()
            return
        }

        var buffer = Data()
        let size = try fileHandle.seekToEnd()
        var offset = size
        var lines: [Data] = []

        while offset > 0, lines.count <= count {
            let readSize = min(UInt64(1024), offset)
            offset -= readSize
            try fileHandle.seek(toOffset: offset)
            buffer.insert(contentsOf: fileHandle.readData(ofLength: Int(readSize)), at: 0)

            lines = recordsForCompleteLogData(buffer)
        }

        emitLogLines(Array(lines.suffix(count)), emit: emit)
    }

    /// Emits existing log contents from a merged replay snapshot.
    private func emitExistingLogs(
        from data: Data,
        tail: Int?,
        emit: @escaping @Sendable (Data) -> Void
    ) {
        let lines = recordsForCompleteLogData(data)
        emitLogLines(tail.map { Array(lines.suffix($0)) } ?? lines, emit: emit)
    }

    /// Emits parsed log records while preserving intentionally blank lines.
    private func emitLogLines(_ lines: [Data], emit: @escaping @Sendable (Data) -> Void) {
        guard !lines.isEmpty else {
            return
        }
        var output = Data()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                output.append(UInt8(ascii: "\n"))
            }
            output.append(line)
        }
        emit(output)
    }

    /// Emits parsed log records as separate callbacks for followed streams.
    private func emitEachLogLine(_ lines: [Data], emit: @escaping @Sendable (Data) -> Void) {
        for line in lines {
            emit(line)
        }
    }

    /// Splits complete log data into line records without inventing a final blank line.
    private func recordsForCompleteLogData(_ output: Data) -> [Data] {
        guard !output.isEmpty else {
            return []
        }
        var result = completeLogRecords(in: output)
        if !result.remainder.isEmpty {
            result.records.append(result.remainder)
        }
        return result.records
    }
}

/// Incrementally splits followed log data into complete log records.
private final class LogLineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    init(initial: Data = Data()) {
        self.pending = initial
    }

    /// Appends a chunk and returns the complete log records it contains.
    func append(_ output: Data) -> [Data] {
        lock.lock()
        defer {
            lock.unlock()
        }

        pending.append(output)
        let result = completeLogRecords(in: pending)
        pending = result.remainder
        return result.records
    }

    /// Returns the final unterminated log record, if one exists.
    func flush() -> Data? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !pending.isEmpty else {
            return nil
        }
        let output = pending
        pending.removeAll()
        return output
    }
}

/// Complete log records found in a byte chunk and any trailing partial line.
private struct LogRecordSplit {
    var records: [Data]
    var remainder: Data
}

/// One complete timestamped log line reconstructed from runtime chunks.
private struct TimestampedLogLine {
    var timestamp: Date
    var data: Data
}

/// Result from rendering structured log records.
private struct StructuredLogRenderResult {
    var lines: [Data]
    var shouldFinish: Bool
}

/// Renders structured runtime records as Compose log lines.
private final class StructuredLogRecordRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let since: Date?
    private let until: Date?
    private let timestamps: Bool
    private let formatter: ISO8601DateFormatter
    private var accumulator = TimestampedLogLineAccumulator()

    init(since: Date?, until: Date?, timestamps: Bool) {
        self.since = since
        self.until = until
        self.timestamps = timestamps
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Appends records and returns complete lines plus whether an `until` bound ended the stream.
    func append(_ records: [ContainerLogRecord]) -> StructuredLogRenderResult {
        lock.lock()
        defer {
            lock.unlock()
        }

        var lines: [Data] = []
        for record in records {
            for line in accumulator.append(record.data, timestamp: record.timestamp) {
                if let until, line.timestamp > until {
                    return StructuredLogRenderResult(lines: lines, shouldFinish: true)
                }
                if let since, line.timestamp < since {
                    continue
                }
                lines.append(format(line))
            }
        }
        return StructuredLogRenderResult(lines: lines, shouldFinish: false)
    }

    /// Returns the final unterminated structured line, if one exists.
    func flush() -> [Data] {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard let line = accumulator.flush() else {
            return []
        }
        if let until, line.timestamp > until {
            return []
        }
        if let since, line.timestamp < since {
            return []
        }
        return [format(line)]
    }

    private func format(_ line: TimestampedLogLine) -> Data {
        guard timestamps else {
            return line.data
        }
        var data = Data("\(formatter.string(from: line.timestamp)) ".utf8)
        data.append(line.data)
        return data
    }
}

/// Incrementally decodes newline-delimited structured log records.
private final class StructuredLogRecordJSONLDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder: JSONDecoder
    private var buffer = Data()

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Appends bytes from the active record file and returns complete records.
    func append(_ data: Data) throws -> [ContainerLogRecord] {
        lock.lock()
        defer {
            lock.unlock()
        }

        buffer.append(data)
        var records: [ContainerLogRecord] = []
        var recordStart = buffer.startIndex
        while let newline = buffer[recordStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[recordStart..<newline]
            recordStart = buffer.index(after: newline)
            guard !line.isEmpty else {
                continue
            }
            records.append(try decoder.decode(ContainerLogRecord.self, from: Data(line)))
        }
        if recordStart > buffer.startIndex {
            buffer.removeSubrange(..<recordStart)
        }
        return records
    }

    /// Decodes a final complete record that was written without a trailing newline.
    func flush() throws -> [ContainerLogRecord] {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !buffer.isEmpty else {
            return []
        }
        let data = buffer
        buffer.removeAll()
        return [try decoder.decode(ContainerLogRecord.self, from: data)]
    }
}

/// Incrementally rebuilds timestamped lines from structured log chunks.
private struct TimestampedLogLineAccumulator {
    private var pending = Data()
    private var pendingTimestamp: Date?

    /// Appends one runtime chunk and returns complete timestamped lines.
    mutating func append(_ output: Data, timestamp: Date) -> [TimestampedLogLine] {
        if !output.isEmpty, pending.isEmpty, pendingTimestamp == nil {
            pendingTimestamp = timestamp
        }
        pending.append(output)
        let result = completeLogRecords(in: pending)
        pending = result.remainder
        var records: [TimestampedLogLine] = []
        for record in result.records {
            records.append(TimestampedLogLine(timestamp: pendingTimestamp ?? timestamp, data: record))
            pendingTimestamp = nil
        }
        if !pending.isEmpty, pendingTimestamp == nil {
            pendingTimestamp = timestamp
        }
        return records
    }

    /// Returns the final unterminated timestamped line, if one exists.
    mutating func flush() -> TimestampedLogLine? {
        guard !pending.isEmpty, let timestamp = pendingTimestamp else {
            return nil
        }
        let line = TimestampedLogLine(timestamp: timestamp, data: pending)
        resetPending()
        return line
    }

    private mutating func resetPending() {
        pending.removeAll()
        pendingTimestamp = nil
    }
}

/// Splits data into complete lines while treating CRLF as one separator.
private func completeLogRecords(in output: Data) -> LogRecordSplit {
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

    return LogRecordSplit(records: records, remainder: current)
}
