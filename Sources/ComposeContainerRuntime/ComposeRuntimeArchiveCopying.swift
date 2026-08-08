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

import ComposeCore
import ComposeRuntimeSPI
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
        try await copyArchiveIntoContainer(
            id: id,
            archive: archive,
            destination: destination,
            options: options,
            temporaryDirectory: FileManager.default.temporaryDirectory,
        )
    }

    package func copyArchiveIntoContainer(
        id: String,
        archive: FileHandle,
        destination: String,
        options: ContainerCopyTransferOptions,
        temporaryDirectory: URL,
    ) async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(in: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let archiveFile = tempDirectory.appendingPathComponent("stdin.tar")
        try Self.copyStream(archive, to: archiveFile)
        try await copyArchiveFileIntoContainer(
            id: id,
            archive: archiveFile,
            destination: destination,
            options: options,
            temporaryDirectory: temporaryDirectory,
        )
    }

    /// Extracts a tar archive file and copies each top-level member into `destination` inside container `id`.
    func copyArchiveFileIntoContainer(
        id: String,
        archive archiveFile: URL,
        destination: String,
        options: ContainerCopyTransferOptions,
    ) async throws {
        try await copyArchiveFileIntoContainer(
            id: id,
            archive: archiveFile,
            destination: destination,
            options: options,
            temporaryDirectory: FileManager.default.temporaryDirectory,
        )
    }

    package func copyArchiveFileIntoContainer(
        id: String,
        archive archiveFile: URL,
        destination: String,
        options: ContainerCopyTransferOptions,
        temporaryDirectory: URL,
    ) async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(in: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let extractedRoot = tempDirectory.appendingPathComponent("root", isDirectory: true)
        try ComposeTemporaryFiles.createDirectory(at: extractedRoot)

        let reader = try ArchiveReader(file: archiveFile)
        let rejectedPaths = try reader.extractContents(to: extractedRoot)
        try ComposeTemporaryFiles.secureDirectory(at: extractedRoot)
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
        copyContents: Bool = false,
        options: ContainerCopyTransferOptions,
    ) async throws {
        try await copyFromContainerAsArchive(
            id: id,
            source: source,
            archive: archive,
            copyContents: copyContents,
            options: options,
            temporaryDirectory: FileManager.default.temporaryDirectory,
        )
    }

    package func copyFromContainerAsArchive(
        id: String,
        source: String,
        archive: FileHandle,
        copyContents: Bool = false,
        options: ContainerCopyTransferOptions,
        temporaryDirectory: URL,
    ) async throws {
        let tempDirectory = try Self.makeTemporaryDirectory(in: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let root = tempDirectory.appendingPathComponent("root", isDirectory: true)
        try ComposeTemporaryFiles.createDirectory(at: root)
        let stagedSource = copyContents ? ComposeArchivePath.contentsSource(source) : source
        try await copyFromContainer(id: id, source: stagedSource, destination: root.path, options: options)
        try ComposeTemporaryFiles.secureDirectory(at: root)

        let members = try Self.topLevelArchiveMembers(in: root)
        guard !members.isEmpty else {
            throw ComposeError.invalidProject("cp '-': source produced no copyable entries")
        }

        let output = tempDirectory.appendingPathComponent("stdout.tar")
        try ComposeTemporaryFiles.prepareFile(at: output)
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: output)
        try writer.archiveDirectory(root)
        try writer.finishEncoding()
        try ComposeTemporaryFiles.secureFile(at: output)
        try Self.copyFile(output, to: archive)
    }

    private static func topLevelArchiveMembers(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func makeTemporaryDirectory(in parent: URL) throws -> URL {
        try ComposeTemporaryFiles.createDirectory(in: parent, prefix: "container-compose-archive-copy-")
    }

    private static func copyStream(_ input: FileHandle, to destination: URL) throws {
        let output = try ComposeTemporaryFiles.createFile(at: destination)
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
