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

import ContainerizationArchive
import Foundation

/// Compose archive behavior layered over a runtime-neutral copy provider.
public extension ComposeRuntimeCopying {
    /// Extracts a caller-provided tar stream and copies each top-level member into `destination` inside container `id`.
    func copyArchiveIntoContainer(
        id: String,
        archive: FileHandle,
        destination: String,
        options: ContainerCopyTransferOptions,
    ) async throws {
        let tempDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let archiveFile = tempDirectory.appendingPathComponent("stdin.tar")
        try Self.copyStream(archive, to: archiveFile)
        try await copyArchiveFileIntoContainer(id: id, archive: archiveFile, destination: destination, options: options)
    }

    /// Extracts a tar archive file and copies each top-level member into `destination` inside container `id`.
    func copyArchiveFileIntoContainer(
        id: String,
        archive archiveFile: URL,
        destination: String,
        options: ContainerCopyTransferOptions,
    ) async throws {
        let tempDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let extractedRoot = tempDirectory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedRoot, withIntermediateDirectories: true)

        let reader = try ArchiveReader(file: archiveFile)
        let rejectedPaths = try reader.extractContents(to: extractedRoot)
        if !rejectedPaths.isEmpty {
            throw ComposeError.invalidProject("cp '-': archive contains unsafe paths: \(rejectedPaths.sorted().joined(separator: ", "))")
        }

        let members = try Self.topLevelArchiveMembers(in: extractedRoot)
        guard !members.isEmpty else {
            throw ComposeError.invalidProject("cp '-': archive contains no copyable entries")
        }

        for member in members {
            try await copyIntoContainer(id: id, source: member.path, destination: destination, options: options)
        }
    }

    /// Stages `source` from container `id` and writes it as a tar archive to the caller-provided output stream.
    func copyFromContainerAsArchive(
        id: String,
        source: String,
        archive: FileHandle,
        options: ContainerCopyTransferOptions,
    ) async throws {
        let tempDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let root = tempDirectory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await copyFromContainer(id: id, source: source, destination: root.path, options: options)

        let members = try Self.topLevelArchiveMembers(in: root)
        guard !members.isEmpty else {
            throw ComposeError.invalidProject("cp '-': source produced no copyable entries")
        }

        let output = tempDirectory.appendingPathComponent("stdout.tar")
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: output)
        try writer.archiveDirectory(root)
        try writer.finishEncoding()
        try Self.copyFile(output, to: archive)
    }

    private static func topLevelArchiveMembers(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func copyStream(_ input: FileHandle, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let bufferSize = 1024 * 1024
        while true {
            let chunk = input.readData(ofLength: bufferSize)
            if chunk.isEmpty {
                break
            }
            output.write(chunk)
        }
    }

    private static func copyFile(_ source: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let bufferSize = 1024 * 1024
        while true {
            let chunk = input.readData(ofLength: bufferSize)
            if chunk.isEmpty {
                break
            }
            output.write(chunk)
        }
    }
}
