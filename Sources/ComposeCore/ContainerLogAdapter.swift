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
        emit: @escaping @Sendable (String) -> Void
    ) async throws
}

public extension ContainerLogManaging {
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
}

/// Thin apple/container client wrapper around log API calls.
public struct ContainerLogAPIClient: ContainerLogAPIClienting {
    public typealias Logs = @Sendable (String, ContainerLogOptions) async throws -> [FileHandle]
    public typealias LogRecords = @Sendable (String, ContainerLogOptions) async throws -> [ContainerLogRecord]

    private let logsOperation: Logs
    private let logRecordsOperation: LogRecords

    public init(
        logs: @escaping Logs = { try await ContainerClient().logs(id: $0, options: $1) },
        logRecords: @escaping LogRecords = { try await ContainerClient().logRecords(id: $0, options: $1) }
    ) {
        self.logsOperation = logs
        self.logRecordsOperation = logRecords
    }

    /// Fetches log file handles through `ContainerClient`.
    public func logFileHandles(id: String, options: ContainerLogOptions) async throws -> [FileHandle] {
        try await logsOperation(id, options)
    }

    /// Fetches structured log records through `ContainerClient`.
    public func logRecords(id: String, options: ContainerLogOptions) async throws -> [ContainerLogRecord] {
        try await logRecordsOperation(id, options)
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
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        if timestamps {
            guard !follow else {
                throw ComposeError.unsupported("logs --timestamps --follow: apple/container does not expose timestamped follow streams")
            }
            try await emitTimestampedLogs(id: id, tail: tail, since: since, until: until, emit: emit)
            return
        }

        let options = ContainerLogOptions(
            tail: follow ? nil : tail,
            since: since,
            until: until,
            timestamps: timestamps
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

        try emitExistingLogs(id: id, from: fileHandle, tail: follow ? tail : nil, emit: emit)
        if follow {
            try await followFile(id: id, fileHandle, emit: emit)
        }
    }

    /// Emits timestamped log records exposed by the structured log API.
    private func emitTimestampedLogs(
        id: String,
        tail: Int?,
        since: Date?,
        until: Date?,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        guard tail.map({ $0 > 0 }) ?? true else {
            return
        }

        let options = ContainerLogOptions(since: since, until: until, timestamps: true)
        let records = try await client.logRecords(id: id, options: options)
        let lines = try timestampedLogLines(id: id, records: records)
        let selectedLines = tail.map { Array(lines.suffix($0)) } ?? lines
        emitLogLines(selectedLines, emit: emit)
    }

    /// Converts structured runtime chunks into Compose log lines with timestamps.
    private func timestampedLogLines(id: String, records: [ContainerLogRecord]) throws -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var accumulator = TimestampedLogLineAccumulator()
        var lines: [String] = []
        for record in records {
            guard let output = String(data: record.data, encoding: .utf8) else {
                throw ComposeError.invalidProject("container logs for \(id) are not valid UTF-8")
            }
            for line in accumulator.append(output, timestamp: record.timestamp) {
                lines.append("\(formatter.string(from: line.timestamp)) \(line.text)")
            }
        }
        if let line = accumulator.flush() {
            lines.append("\(formatter.string(from: line.timestamp)) \(line.text)")
        }
        return lines
    }

    /// Emits existing log contents before an optional follow loop starts.
    private func emitExistingLogs(
        id: String,
        from fileHandle: FileHandle,
        tail: Int?,
        emit: @escaping @Sendable (String) -> Void
    ) throws {
        if let tail {
            try emitTail(id: id, from: fileHandle, count: tail, emit: emit)
        } else {
            try emitAll(id: id, from: fileHandle, emit: emit)
        }
    }

    /// Emits all log contents currently available from the file handle.
    private func emitAll(
        id: String,
        from fileHandle: FileHandle,
        emit: @escaping @Sendable (String) -> Void
    ) throws {
        guard let data = try fileHandle.readToEnd() else {
            return
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw ComposeError.invalidProject("container logs for \(id) are not valid UTF-8")
        }
        emitLogLines(recordsForCompleteLogText(output), emit: emit)
    }

    /// Emits the last `count` non-empty log lines.
    private func emitTail(
        id: String,
        from fileHandle: FileHandle,
        count: Int,
        emit: @escaping @Sendable (String) -> Void
    ) throws {
        guard count > 0 else {
            _ = try? fileHandle.seekToEnd()
            return
        }

        var buffer = Data()
        let size = try fileHandle.seekToEnd()
        var offset = size
        var lines: [String] = []

        while offset > 0, lines.count <= count {
            let readSize = min(UInt64(1024), offset)
            offset -= readSize
            try fileHandle.seek(toOffset: offset)
            buffer.insert(contentsOf: fileHandle.readData(ofLength: Int(readSize)), at: 0)

            guard let chunk = String(data: buffer, encoding: .utf8) else {
                throw ComposeError.invalidProject("container logs for \(id) are not valid UTF-8")
            }
            lines = recordsForCompleteLogText(chunk)
        }

        emitLogLines(Array(lines.suffix(count)), emit: emit)
    }

    /// Emits lines appended to the log file until the handle closes.
    private func followFile(
        id: String,
        _ fileHandle: FileHandle,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = try? fileHandle.seekToEnd()
        let accumulator = LogLineAccumulator()
        let stream = AsyncThrowingStream<String, any Error> { continuation in
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
                guard let output = String(data: data, encoding: .utf8) else {
                    handle.readabilityHandler = nil
                    continuation.finish(throwing: ComposeError.invalidProject("container logs for \(id) are not valid UTF-8"))
                    return
                }
                for line in accumulator.append(output) {
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

    /// Emits parsed log records while preserving intentionally blank lines.
    private func emitLogLines(_ lines: [String], emit: @escaping @Sendable (String) -> Void) {
        guard !lines.isEmpty else {
            return
        }
        emit(lines.joined(separator: "\n"))
    }

    /// Splits complete log text into line records without inventing a final blank line.
    private func recordsForCompleteLogText(_ output: String) -> [String] {
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
    private var pending = ""

    /// Appends a chunk and returns the complete log records it contains.
    func append(_ output: String) -> [String] {
        lock.lock()
        defer {
            lock.unlock()
        }

        let result = completeLogRecords(in: pending + output)
        pending = result.remainder
        return result.records
    }

    /// Returns the final unterminated log record, if one exists.
    func flush() -> String? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !pending.isEmpty else {
            return nil
        }
        let output = pending
        pending = ""
        return output
    }
}

/// Complete log records found in a text chunk and any trailing partial line.
private struct LogRecordSplit {
    var records: [String]
    var remainder: String
}

/// One complete timestamped log line reconstructed from runtime chunks.
private struct TimestampedLogLine {
    var timestamp: Date
    var text: String
}

/// Incrementally rebuilds timestamped lines from structured log chunks.
private struct TimestampedLogLineAccumulator {
    private var pending = ""
    private var pendingTimestamp: Date?

    /// Appends one runtime chunk and returns complete timestamped lines.
    mutating func append(_ output: String, timestamp: Date) -> [TimestampedLogLine] {
        var records: [TimestampedLogLine] = []
        var index = output.startIndex

        while index < output.endIndex {
            let character = output[index]
            if character == "\n" {
                records.append(TimestampedLogLine(timestamp: pendingTimestamp ?? timestamp, text: pending))
                resetPending()
                index = output.index(after: index)
            } else if character == "\r" {
                records.append(TimestampedLogLine(timestamp: pendingTimestamp ?? timestamp, text: pending))
                resetPending()
                let next = output.index(after: index)
                if next < output.endIndex, output[next] == "\n" {
                    index = output.index(after: next)
                } else {
                    index = next
                }
            } else {
                if pendingTimestamp == nil {
                    pendingTimestamp = timestamp
                }
                pending.append(character)
                index = output.index(after: index)
            }
        }

        return records
    }

    /// Returns the final unterminated timestamped line, if one exists.
    mutating func flush() -> TimestampedLogLine? {
        guard !pending.isEmpty, let timestamp = pendingTimestamp else {
            return nil
        }
        let line = TimestampedLogLine(timestamp: timestamp, text: pending)
        resetPending()
        return line
    }

    private mutating func resetPending() {
        pending = ""
        pendingTimestamp = nil
    }
}

/// Splits text into complete lines while treating CRLF as one separator.
private func completeLogRecords(in output: String) -> LogRecordSplit {
    var records: [String] = []
    var current = ""
    var index = output.startIndex

    while index < output.endIndex {
        let character = output[index]
        if character == "\n" {
            records.append(current)
            current = ""
            index = output.index(after: index)
        } else if character == "\r" {
            records.append(current)
            current = ""
            let next = output.index(after: index)
            if next < output.endIndex, output[next] == "\n" {
                index = output.index(after: next)
            } else {
                index = next
            }
        } else {
            current.append(character)
            index = output.index(after: index)
        }
    }

    return LogRecordSplit(records: records, remainder: current)
}
