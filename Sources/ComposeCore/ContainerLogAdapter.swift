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
    func logFileHandles(id: String, options: ContainerLogOptions) async throws -> [FileHandle]

    /// Returns the structured log records exposed by apple/container for `id`.
    func logRecords(id: String, options: ContainerLogOptions) async throws -> [ContainerLogRecord]

    /// Returns the structured log record file exposed by apple/container for `id`.
    func logRecordFileHandle(id: String) async throws -> FileHandle
}

public extension ContainerLogAPIClienting {
    /// Returns unfiltered log file handles exposed by apple/container for `id`.
    func logFileHandles(id: String) async throws -> [FileHandle] {
        try await logFileHandles(id: id, options: .default)
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
    public typealias Logs = @Sendable (String, ContainerLogOptions) async throws -> [FileHandle]
    public typealias LogRecords = @Sendable (String, ContainerLogOptions) async throws -> [ContainerLogRecord]
    public typealias LogRecordFile = @Sendable (String) async throws -> FileHandle

    private let logsOperation: Logs
    private let logRecordsOperation: LogRecords
    private let logRecordFileOperation: LogRecordFile

    public init(
        logs: @escaping Logs = { try await ContainerClient().logs(id: $0, options: $1) },
        logRecords: @escaping LogRecords = { try await ContainerClient().logRecords(id: $0, options: $1) },
        logRecordFile: @escaping LogRecordFile = { try await ContainerClient().logRecordFile(id: $0) }
    ) {
        self.logsOperation = logs
        self.logRecordsOperation = logRecords
        self.logRecordFileOperation = logRecordFile
    }

    /// Fetches log file handles through `ContainerClient`.
    public func logFileHandles(id: String, options: ContainerLogOptions) async throws -> [FileHandle] {
        try await logsOperation(id, options)
    }

    /// Fetches structured log records through `ContainerClient`.
    public func logRecords(id: String, options: ContainerLogOptions) async throws -> [ContainerLogRecord] {
        try await logRecordsOperation(id, options)
    }

    /// Fetches the structured log record file through `ContainerClient`.
    public func logRecordFileHandle(id: String) async throws -> FileHandle {
        try await logRecordFileOperation(id)
    }
}

/// `ContainerClient`-backed log manager for service containers.
public struct ContainerClientLogManager: ContainerLogManaging {
    private let client: ContainerLogAPIClienting

    public init(client: ContainerLogAPIClienting = ContainerLogAPIClient()) {
        self.client = client
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
        if follow && (timestamps || since != nil || until != nil) {
            try await emitStructuredFollowLogs(
                id: id,
                tail: tail,
                since: since,
                until: until,
                timestamps: timestamps,
                emit: emit
            )
            return
        }

        if timestamps {
            try await emitTimestampedLogs(id: id, tail: tail, since: since, until: until, emit: emit)
            return
        }

        let options = ContainerLogOptions(
            tail: follow ? nil : tail,
            since: since,
            until: until,
            timestamps: timestamps,
            includeRotated: !follow
        )
        let fileHandles = try await client.logFileHandles(id: id, options: options)
        guard let fileHandle = fileHandles.first else {
            throw ComposeError.invalidProject("container logs returned no stdio handle for \(id)")
        }
        defer {
            for handle in fileHandles {
                try? handle.close()
            }
        }

        try emitExistingLogs(from: fileHandle, tail: follow ? tail : nil, emit: emit)
        if follow {
            try await followFile(fileHandle, emit: emit)
        }
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
        let fileHandle = try await client.logRecordFileHandle(id: id)
        defer {
            try? fileHandle.close()
        }
        let decoder = LogRecordJSONLDecoder()
        let renderer = StructuredLogRecordRenderer(since: since, until: until, timestamps: timestamps)
        let shouldFinish = try emitInitialStructuredRecordFile(
            from: fileHandle,
            tail: tail,
            decoder: decoder,
            renderer: renderer,
            emit: emit
        )
        if shouldFinish || until.map({ $0 <= Date() }) == true {
            return
        }

        try await followLogRecordFile(
            fileHandle,
            decoder: decoder,
            renderer: renderer,
            until: until,
            emit: emit
        )
    }

    /// Emits timestamped log records exposed by the structured log API.
    private func emitTimestampedLogs(
        id: String,
        tail: Int?,
        since: Date?,
        until: Date?,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        guard tail.map({ $0 > 0 }) ?? true else {
            return
        }

        let options = ContainerLogOptions(since: since, until: until, timestamps: true, includeRotated: true)
        let records = try await client.logRecords(id: id, options: options)
        let lines = structuredLogLines(records: records, timestamps: true)
        let selectedLines = tail.map { Array(lines.suffix($0)) } ?? lines
        emitLogLines(selectedLines, emit: emit)
    }

    /// Converts structured runtime chunks into Compose log lines.
    private func structuredLogLines(
        records: [ContainerLogRecord],
        timestamps: Bool
    ) -> [Data] {
        let renderer = StructuredLogRecordRenderer(since: nil, until: nil, timestamps: timestamps)
        let result = renderer.append(records)
        return result.lines + renderer.flush()
    }

    /// Emits structured records that already exist in a seekable record file.
    private func emitInitialStructuredRecordFile(
        from fileHandle: FileHandle,
        tail: Int?,
        decoder: LogRecordJSONLDecoder,
        renderer: StructuredLogRecordRenderer,
        emit: @escaping @Sendable (Data) -> Void
    ) throws -> Bool {
        guard tail != 0 else {
            _ = try? fileHandle.seekToEnd()
            return false
        }
        guard let size = try? fileHandle.seekToEnd() else {
            return false
        }
        try fileHandle.seek(toOffset: 0)
        guard size > 0 else {
            return false
        }
        guard size <= UInt64(Int.max) else {
            throw ComposeError.invalidProject("container structured log file is too large to replay")
        }

        let records = try decoder.append(fileHandle.readData(ofLength: Int(size)))
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

    /// Emits lines appended to the log file until the handle closes.
    private func followFile(
        _ fileHandle: FileHandle,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        _ = try? fileHandle.seekToEnd()
        let accumulator = LogLineAccumulator()
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    do {
                        _ = try handle.seekToEnd()
                    } catch {
                        if let pending = accumulator.flush() {
                            continuation.yield(pending)
                        }
                        handle.readabilityHandler = nil
                        continuation.finish()
                    }
                    return
                }
                for line in accumulator.append(data) {
                    continuation.yield(line)
                }
            }
        }
        defer {
            fileHandle.readabilityHandler = nil
        }

        for try await line in stream {
            emit(line)
        }
    }

    /// Emits structured records appended to the JSONL log file until the handle closes.
    private func followLogRecordFile(
        _ fileHandle: FileHandle,
        decoder: LogRecordJSONLDecoder,
        renderer: StructuredLogRecordRenderer,
        until: Date?,
        emit: @escaping @Sendable (Data) -> Void
    ) async throws {
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            let coordinator = StructuredLogFollowCoordinator(
                fileHandle: fileHandle,
                decoder: decoder,
                renderer: renderer,
                continuation: continuation
            )
            let deadlineTask = until.map { deadline in
                Task {
                    if let nanoseconds = Self.followDeadlineNanoseconds(until: deadline) {
                        try? await Task.sleep(nanoseconds: nanoseconds)
                    }
                    if !Task.isCancelled {
                        coordinator.finish(flushDecoder: false)
                    }
                }
            }
            continuation.onTermination = { _ in
                deadlineTask?.cancel()
                coordinator.cancel()
            }
            fileHandle.readabilityHandler = { handle in
                coordinator.handleAvailableData(from: handle)
            }
        }
        defer {
            fileHandle.readabilityHandler = nil
        }

        for try await line in stream {
            emit(line)
        }
    }

    /// Returns a positive sleep duration for a future `--until` deadline.
    private static func followDeadlineNanoseconds(until deadline: Date) -> UInt64? {
        let seconds = deadline.timeIntervalSinceNow
        guard seconds > 0 else {
            return nil
        }
        return UInt64(seconds * 1_000_000_000)
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

/// Outcome from reading or finishing a structured log follow stream.
private enum StructuredLogFollowEvent {
    case none
    case yield([Data])
    case finish([Data])
    case fail(any Error)

    func emit(to continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        switch self {
        case .none:
            return
        case .yield(let lines):
            for line in lines {
                continuation.yield(line)
            }
        case .finish(let lines):
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        case .fail(let error):
            continuation.finish(throwing: error)
        }
    }
}

/// Coordinates structured log file readability callbacks and deadline completion.
private final class StructuredLogFollowCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle
    private let decoder: LogRecordJSONLDecoder
    private let renderer: StructuredLogRecordRenderer
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var finished = false

    init(
        fileHandle: FileHandle,
        decoder: LogRecordJSONLDecoder,
        renderer: StructuredLogRecordRenderer,
        continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        self.fileHandle = fileHandle
        self.decoder = decoder
        self.renderer = renderer
        self.continuation = continuation
    }

    /// Consumes data made available by the followed structured log record file.
    func handleAvailableData(from handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else {
            do {
                _ = try handle.seekToEnd()
            } catch {
                finish(flushDecoder: true)
            }
            return
        }

        event(for: data).emit(to: continuation)
    }

    /// Finishes the stream, optionally decoding a final unterminated JSONL record.
    func finish(flushDecoder: Bool) {
        finishEvent(flushDecoder: flushDecoder).emit(to: continuation)
    }

    /// Cancels follow callbacks without finishing the already terminated stream.
    func cancel() {
        lock.lock()
        defer {
            lock.unlock()
        }
        finished = true
        fileHandle.readabilityHandler = nil
    }

    private func event(for data: Data) -> StructuredLogFollowEvent {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !finished else {
            return .none
        }

        do {
            let records = try decoder.append(data)
            let result = renderer.append(records)
            if result.shouldFinish {
                finished = true
                fileHandle.readabilityHandler = nil
                return .finish(result.lines + renderer.flush())
            }
            return .yield(result.lines)
        } catch {
            finished = true
            fileHandle.readabilityHandler = nil
            return .fail(error)
        }
    }

    private func finishEvent(flushDecoder: Bool) -> StructuredLogFollowEvent {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !finished else {
            return .none
        }

        do {
            let records = flushDecoder ? try decoder.flush() : []
            let result = renderer.append(records)
            finished = true
            fileHandle.readabilityHandler = nil
            return .finish(result.lines + renderer.flush())
        } catch {
            finished = true
            fileHandle.readabilityHandler = nil
            return .fail(error)
        }
    }
}

/// Incrementally decodes newline-delimited structured log records.
private final class LogRecordJSONLDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder: JSONDecoder
    private var buffer = Data()

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Appends a JSONL byte chunk and returns every complete record.
    func append(_ data: Data) throws -> [ContainerLogRecord] {
        lock.lock()
        defer {
            lock.unlock()
        }

        buffer.append(data)
        var records: [ContainerLogRecord] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else {
                continue
            }
            records.append(try decoder.decode(ContainerLogRecord.self, from: Data(line)))
        }
        return records
    }

    /// Decodes the final unterminated JSONL record, if one exists.
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
            if let until, record.timestamp > until {
                return StructuredLogRenderResult(lines: lines, shouldFinish: true)
            }
            if let since, record.timestamp < since {
                continue
            }
            for line in accumulator.append(record.data, timestamp: record.timestamp) {
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
