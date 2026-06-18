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
import Foundation

/// Low-level Apple container log call used by `ContainerClientLogManager`.
public protocol ContainerLogAPIClienting: Sendable {
    /// Returns the log file handles exposed by Apple container for `id`.
    func logFileHandles(id: String) async throws -> [FileHandle]
}

/// Direct Apple container API used for service container logs.
public protocol ContainerLogManaging: Sendable {
    /// Emits logs for container `id`, optionally following appended lines.
    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws
}

/// Thin Apple `container` client wrapper around log API calls.
public struct ContainerLogAPIClient: ContainerLogAPIClienting {
    public typealias Logs = @Sendable (String) async throws -> [FileHandle]

    private let logsOperation: Logs

    public init(logs: @escaping Logs = { try await ContainerClient().logs(id: $0) }) {
        self.logsOperation = logs
    }

    /// Fetches log file handles through `ContainerClient`.
    public func logFileHandles(id: String) async throws -> [FileHandle] {
        try await logsOperation(id)
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
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        let fileHandles = try await client.logFileHandles(id: id)
        guard let fileHandle = fileHandles.first else {
            throw ComposeError.invalidProject("container logs returned no stdio handle for \(id)")
        }
        defer {
            for handle in fileHandles {
                try? handle.close()
            }
        }

        try emitExistingLogs(id: id, from: fileHandle, tail: tail, emit: emit)
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
        let trimmed = output.trimmingCharacters(in: .newlines)
        if !trimmed.isEmpty {
            emit(trimmed)
        }
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

        while offset > 0, lines.count < count {
            let readSize = min(UInt64(1024), offset)
            offset -= readSize
            try fileHandle.seek(toOffset: offset)
            buffer.insert(contentsOf: fileHandle.readData(ofLength: Int(readSize)), at: 0)

            guard let chunk = String(data: buffer, encoding: .utf8) else {
                throw ComposeError.invalidProject("container logs for \(id) are not valid UTF-8")
            }
            lines = chunk.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }

        let output = lines.suffix(count).joined(separator: "\n")
        if !output.isEmpty {
            emit(output)
        }
    }

    /// Emits lines appended to the log file until the handle closes.
    private func followFile(
        id: String,
        _ fileHandle: FileHandle,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = try? fileHandle.seekToEnd()
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    do {
                        _ = try handle.seekToEnd()
                    } catch {
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
                for line in output.components(separatedBy: .newlines) where !line.isEmpty {
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
}
