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

    private let logsOperation: Logs

    public init(logs: @escaping Logs = { try await ContainerClient().logs(id: $0, options: $1) }) {
        self.logsOperation = logs
    }

    /// Fetches log file handles through `ContainerClient`.
    public func logFileHandles(id: String, options: ContainerLogOptions) async throws -> [FileHandle] {
        try await logsOperation(id, options)
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
