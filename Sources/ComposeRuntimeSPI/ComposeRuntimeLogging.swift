//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

/// Stable process-output stream identity used by historical reads and attach.
public enum ComposeLogStream: String, Codable, Equatable, Sendable {
    case stdout
    case stderr
}

/// Docker-compatible partial-record metadata for split long or incomplete lines.
public struct ComposeLogPartialMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var ordinal: Int
    public var last: Bool

    public init(id: String, ordinal: Int, last: Bool) {
        self.id = id
        self.ordinal = ordinal
        self.last = last
    }
}

/// One driver-neutral record emitted by a historical reader or live attach.
public struct ComposeLogRecord: Codable, Equatable, Sendable {
    public var stream: ComposeLogStream
    public var payload: Data
    public var timestamp: Date?
    public var attributes: [String: String]
    public var terminal: Bool
    public var partial: ComposeLogPartialMetadata?

    public init(
        stream: ComposeLogStream,
        payload: Data,
        timestamp: Date? = nil,
        attributes: [String: String] = [:],
        terminal: Bool = false,
        partial: ComposeLogPartialMetadata? = nil,
    ) {
        self.stream = stream
        self.payload = payload
        self.timestamp = timestamp
        self.attributes = attributes
        self.terminal = terminal
        self.partial = partial
    }
}

/// Runtime-neutral historical log query.
public struct ComposeLogReadRequest: Codable, Equatable, Sendable {
    public var stdout: Bool
    public var stderr: Bool
    public var follow: Bool
    public var tail: Int?
    public var since: Date?
    public var until: Date?
    public var timestamps: Bool
    public var details: Bool

    public init(
        stdout: Bool = true,
        stderr: Bool = true,
        follow: Bool = false,
        tail: Int? = nil,
        since: Date? = nil,
        until: Date? = nil,
        timestamps: Bool = false,
        details: Bool = false,
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.follow = follow
        self.tail = tail
        self.since = since
        self.until = until
        self.timestamps = timestamps
        self.details = details
    }
}

/// Historical record reads supplied by a runtime driver or its local cache.
public protocol ComposeRuntimeLogRecordManaging: Sendable {
    func readLogs(
        id: String,
        request: ComposeLogReadRequest,
        emit: @escaping @Sendable (ComposeLogRecord) -> Void,
    ) async throws
}

/// Live process output attachment, deliberately independent of log storage.
public protocol ComposeRuntimeAttachManaging: Sendable {
    func attachOutput(
        id: String,
        stdout: Bool,
        stderr: Bool,
        emit: @escaping @Sendable (ComposeLogRecord) -> Void,
    ) async throws
}
