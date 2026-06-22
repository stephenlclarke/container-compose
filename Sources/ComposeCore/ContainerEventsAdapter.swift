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

/// Event output formats supported by `compose events`.
public enum ComposeEventsOutputFormat: Sendable, Equatable {
    case text
    case json
}

/// One Docker Compose-style event rendered by `compose events --json`.
public struct ComposeEventRecord: Sendable, Equatable, Codable {
    public var time: Date
    public var type: String
    public var service: String
    public var id: String
    public var action: String
    public var attributes: [String: String]

    public init(
        time: Date,
        type: String,
        service: String,
        id: String,
        action: String,
        attributes: [String: String]
    ) {
        self.time = time
        self.type = type
        self.service = service
        self.id = id
        self.action = action
        self.attributes = attributes
    }
}

/// Low-level apple/container event stream used by `ContainerClientEventsManager`.
public protocol ContainerEventsAPIClienting: Sendable {
    /// Returns the newline-delimited `ContainerEvent` stream.
    func events(options: ContainerEventOptions) async throws -> FileHandle
}

/// Direct apple/container API used for Compose project events.
public protocol ContainerEventsManaging: Sendable {
    /// Emits Docker Compose-style event records for selected services.
    func events(
        projectName: String,
        services: [String],
        format: ComposeEventsOutputFormat,
        since: Date?,
        until: Date?,
        emit: @escaping @Sendable (String) -> Void
    ) async throws
}

/// Thin apple/container client wrapper around the event stream API.
public struct ContainerEventsAPIClient: ContainerEventsAPIClienting {
    public typealias Events = @Sendable (ContainerEventOptions) async throws -> FileHandle

    private let eventsOperation: Events

    public init(events: @escaping Events = { try await ContainerClient().events(options: $0) }) {
        self.eventsOperation = events
    }

    /// Opens the runtime event stream through `ContainerClient`.
    public func events(options: ContainerEventOptions = .default) async throws -> FileHandle {
        try await eventsOperation(options)
    }
}

/// `ContainerClient`-backed event manager for Compose project events.
public struct ContainerClientEventsManager: ContainerEventsManaging {
    private let client: ContainerEventsAPIClienting

    public init(client: ContainerEventsAPIClienting = ContainerEventsAPIClient()) {
        self.client = client
    }

    /// Filters runtime lifecycle events to the current Compose project and renders JSON Lines.
    public func events(
        projectName: String,
        services: [String],
        format: ComposeEventsOutputFormat,
        since: Date?,
        until: Date?,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        let eventStream = try await client.events(
            options: ContainerEventOptions(since: since, until: until)
        )
        defer {
            try? eventStream.close()
        }

        let decoder = ContainerEventJSONLDecoder()
        let renderer = ComposeEventRenderer(projectName: projectName, services: services, format: format)
        for try await chunk in eventChunks(eventStream) {
            for event in try decoder.append(chunk) {
                if let line = try renderer.render(event) {
                    emit(line)
                }
            }
        }

        for event in try decoder.flush() {
            if let line = try renderer.render(event) {
                emit(line)
            }
        }
    }

    /// Converts the runtime event file handle into async data chunks.
    private func eventChunks(_ eventStream: FileHandle) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            eventStream.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }

            continuation.onTermination = { _ in
                eventStream.readabilityHandler = nil
            }
        }
    }
}

/// Applies Docker Compose's project/service event filtering policy.
private struct ComposeEventRenderer {
    var projectName: String
    var selectedServices: Set<String>
    var format: ComposeEventsOutputFormat

    init(projectName: String, services: [String], format: ComposeEventsOutputFormat) {
        self.projectName = projectName
        self.selectedServices = Set(services)
        self.format = format
    }

    /// Returns one output line when the runtime event belongs to the selected Compose services.
    func render(_ event: ContainerEvent) throws -> String? {
        guard event.type == "container" else {
            return nil
        }
        guard event.attributes[projectLabel] == projectName else {
            return nil
        }
        guard event.attributes[oneOffLabel]?.lowercased() != "true" else {
            return nil
        }
        guard let service = event.attributes[serviceLabel], !service.isEmpty else {
            return nil
        }
        guard selectedServices.isEmpty || selectedServices.contains(service) else {
            return nil
        }

        let record = ComposeEventRecord(
            time: event.time,
            type: event.type,
            service: service,
            id: event.id,
            action: event.action,
            attributes: publicAttributes(event.attributes)
        )
        switch format {
        case .json:
            return try encode(record)
        case .text:
            return renderText(record)
        }
    }

    /// Removes Compose-private tracking labels from the public event payload.
    private func publicAttributes(_ attributes: [String: String]) -> [String: String] {
        attributes.filter { key, _ in
            !key.hasPrefix(reservedComposeLabelPrefix) &&
                !key.hasPrefix(reservedDockerComposeLabelPrefix)
        }
    }

    /// Encodes one Compose event record as a stable JSON object string.
    private func encode(_ record: ComposeEventRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    /// Renders Docker Compose's default text event shape without embedding a trailing newline.
    private func renderText(_ record: ComposeEventRecord) -> String {
        let attributes = record.attributes
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { key, value in "\(key)=\(value)" }
            .joined(separator: ", ")
        return "\(formattedTimestamp(record.time)) container \(record.action) \(record.id) (\(attributes))"
    }

    /// Formats the event timestamp like Docker Compose's `api.Event.String()`.
    private func formattedTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let microseconds = (components.nanosecond ?? 0) / 1_000
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
}

/// Incrementally decodes newline-delimited `ContainerEvent` records.
private final class ContainerEventJSONLDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder: JSONDecoder
    private var buffer = Data()

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Appends bytes from the event stream and returns complete events.
    func append(_ data: Data) throws -> [ContainerEvent] {
        lock.lock()
        defer {
            lock.unlock()
        }

        buffer.append(data)
        var events: [ContainerEvent] = []
        var recordStart = buffer.startIndex
        while let newline = buffer[recordStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[recordStart..<newline]
            recordStart = buffer.index(after: newline)
            guard !line.isEmpty else {
                continue
            }
            events.append(try decoder.decode(ContainerEvent.self, from: Data(line)))
        }
        if recordStart > buffer.startIndex {
            buffer.removeSubrange(..<recordStart)
        }
        return events
    }

    /// Decodes a final complete event written without a trailing newline.
    func flush() throws -> [ContainerEvent] {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !buffer.isEmpty else {
            return []
        }
        let data = buffer
        buffer.removeAll()
        return [try decoder.decode(ContainerEvent.self, from: data)]
    }
}
