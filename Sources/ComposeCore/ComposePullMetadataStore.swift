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

import Foundation

/// Stores successful image pull timestamps for time-window pull policies.
public protocol ComposePullMetadataStoring: Sendable {
    /// Returns the last successful pull date recorded for `reference`.
    func lastPullDate(for reference: String) async throws -> Date?

    /// Records a successful pull date for `reference`.
    func recordPullDate(_ date: Date, for reference: String) async throws
}

/// File-backed pull metadata used to emulate Docker Compose time-window pulls.
public actor FileComposePullMetadataStore: ComposePullMetadataStoring {
    private struct Contents: Codable {
        var version: Int
        var images: [String: Date]
    }

    private let fileURL: URL

    public init(fileURL: URL = FileComposePullMetadataStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Returns the default per-user pull metadata file.
    public static func defaultFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".container-compose", isDirectory: true)
            .appendingPathComponent("pull-metadata.json", isDirectory: false)
    }

    /// Returns the last successful pull date recorded for `reference`.
    public func lastPullDate(for reference: String) async throws -> Date? {
        try load().images[reference]
    }

    /// Records a successful pull date for `reference`.
    public func recordPullDate(_ date: Date, for reference: String) async throws {
        var contents = try load()
        contents.images[reference] = date
        try save(contents)
    }

    private func load() throws -> Contents {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Contents(version: 1, images: [:])
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Contents.self, from: data)
    }

    private func save(_ contents: Contents) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(contents)
        try data.write(to: fileURL, options: .atomic)
    }
}
