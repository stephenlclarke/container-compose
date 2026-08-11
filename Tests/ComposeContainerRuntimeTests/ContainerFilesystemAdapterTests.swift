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

@testable import ComposeContainerRuntime
import ComposeRuntimeSPI
import Foundation
import Testing

@Suite("Container filesystem adapter")
struct ContainerFilesystemAdapterTests {
    @Test
    func `export staging is private and cleaned after provider failure`() async throws {
        let sharedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-export-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sharedRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o777],
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: sharedRoot.path)
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let recorder = ExportPermissionRecorder()
        let exporter = ContainerClientExporter(temporaryDirectory: sharedRoot) { _, archive, _, _ in
            try recorder.record(archive: archive)
            throw ExportFailure.expected
        }

        await #expect(throws: ExportFailure.self) {
            try await exporter.exportContainer(id: "demo-api-1", output: "unused.tar", live: false, noFreeze: false)
        }

        #expect(recorder.directoryPermissions == 0o700)
        #expect(recorder.filePermissions == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sharedRoot.path).isEmpty)
    }

    @Test
    func `export restores private archive permissions before moving output`() async throws {
        let sharedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-export-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sharedRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o777],
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: sharedRoot.path)
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let output = sharedRoot.appendingPathComponent("output.tar")
        let exporter = ContainerClientExporter(temporaryDirectory: sharedRoot) { _, archive, _, _ in
            try Data("archive\n".utf8).write(to: archive)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archive.path)
        }

        try await exporter.exportContainer(id: "demo-api-1", output: output.path, live: false, noFreeze: false)

        #expect(try Data(contentsOf: output) == Data("archive\n".utf8))
        #expect(try permissions(at: output) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sharedRoot.path) == ["output.tar"])
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `copy fallback stages archive through path copy operations`() async throws {
        let recorder = StagedCopyRecorder()
        let copier = ContainerClientCopier(
            copyInto: { id, source, destination, options in
                try await recorder.recordInto(
                    id: id,
                    data: Data(contentsOf: URL(fileURLWithPath: source)),
                    destination: destination,
                    options: options,
                )
            },
            copyFrom: { id, source, destination, options in
                let output = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                try Data("staged payload\n".utf8).write(to: output)
                await recorder.recordFrom(
                    id: id,
                    source: source,
                    options: options,
                )
            },
        )

        try await copier.copyBetweenContainers(
            sourceID: "demo-api-1",
            source: "/tmp/report.txt",
            destinationID: "demo-worker-1",
            destination: "/var/lib/reports",
            options: ContainerCopyTransferOptions(
                followSymlink: true,
                preserveOwnership: false,
            ),
        )

        #expect(await recorder.from == [
            .init(
                id: "demo-api-1",
                source: "/tmp/report.txt",
                options: ContainerCopyTransferOptions(
                    followSymlink: true,
                    preserveOwnership: false,
                ),
            ),
        ])
        #expect(await recorder.into == [
            .init(
                id: "demo-worker-1",
                data: Data("staged payload\n".utf8),
                destination: "/var/lib/reports",
                options: ContainerCopyTransferOptions(preserveOwnership: false),
            ),
        ])
    }
}

private enum ExportFailure: Error {
    case expected
}

private final class ExportPermissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var directoryStorage: Int?
    private var fileStorage: Int?

    var directoryPermissions: Int? {
        lock.withLock { directoryStorage }
    }

    var filePermissions: Int? {
        lock.withLock { fileStorage }
    }

    func record(archive: URL) throws {
        let directory = try permissions(at: archive.deletingLastPathComponent())
        let file = try permissions(at: archive)
        lock.withLock {
            directoryStorage = directory
            fileStorage = file
        }
    }
}

private actor StagedCopyRecorder {
    struct From: Equatable, Sendable {
        let id: String
        let source: String
        let options: ContainerCopyTransferOptions
    }

    struct Into: Equatable, Sendable {
        let id: String
        let data: Data
        let destination: String
        let options: ContainerCopyTransferOptions
    }

    private(set) var from: [From] = []
    private(set) var into: [Into] = []

    func recordFrom(id: String, source: String, options: ContainerCopyTransferOptions) {
        from.append(.init(id: id, source: source, options: options))
    }

    func recordInto(
        id: String,
        data: Data,
        destination: String,
        options: ContainerCopyTransferOptions,
    ) {
        into.append(.init(id: id, data: data, destination: destination, options: options))
    }
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
        throw ExportFailure.expected
    }
    return permissions.intValue & 0o777
}
