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
import ContainerAPIClient
import Darwin
import Foundation

/// `ContainerClient`-backed copier for real service container file copies.
public struct ContainerClientCopier: ComposeRuntimeArchiveCopying {
    public typealias CopyInto = @Sendable (String, String, String, ContainerCopyTransferOptions) async throws -> Void
    public typealias CopyFrom = @Sendable (String, String, String, ContainerCopyTransferOptions) async throws -> Void
    public typealias CopyArchiveInto = @Sendable (String, FileHandle, String, ContainerCopyTransferOptions) async throws -> Void
    public typealias CopyArchiveFrom = @Sendable (String, String, FileHandle, Bool, ContainerCopyTransferOptions) async throws -> Void

    private let copyIntoOperation: CopyInto
    private let copyFromOperation: CopyFrom
    private let copyArchiveIntoOperation: CopyArchiveInto
    private let copyArchiveFromOperation: CopyArchiveFrom

    public init(
        copyInto: @escaping CopyInto = { id, source, destination, options in
            try await ContainerClient().copyIn(
                id: id,
                source: source,
                destination: destination,
                createParents: true,
                followSymlink: options.followSymlink,
                preserveOwnership: options.preserveOwnership,
            )
        },
        copyFrom: @escaping CopyFrom = { id, source, destination, options in
            try await ContainerClient().copyOut(
                id: id,
                source: source,
                destination: destination,
                followSymlink: options.followSymlink,
                preserveOwnership: options.preserveOwnership,
            )
        },
        copyArchiveInto: @escaping CopyArchiveInto = { id, archive, destination, options in
            try await ContainerClient().copyIn(
                id: id,
                archive: archive,
                destination: destination,
                createParents: true,
                preserveOwnership: options.preserveOwnership,
            )
        },
        copyArchiveFrom: @escaping CopyArchiveFrom = { id, source, archive, copyContents, options in
            try await ContainerClient().copyOut(
                id: id,
                source: source,
                archive: archive,
                followSymlink: options.followSymlink,
                copyContents: copyContents,
            )
        },
    ) {
        copyIntoOperation = copyInto
        copyFromOperation = copyFrom
        copyArchiveIntoOperation = copyArchiveInto
        copyArchiveFromOperation = copyArchiveFrom
    }

    /// Copies host files into a service container through `ContainerClient`.
    public func copyIntoContainer(id: String, source: String, destination: String, options: ContainerCopyTransferOptions = ContainerCopyTransferOptions()) async throws {
        let sourcePath = (source as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory) else {
            throw ComposeError.invalidProject("source path does not exist: \(source)")
        }
        if source.hasSuffix("/"), !isDirectory.boolValue {
            throw ComposeError.invalidProject("source path is not a directory: \(source)")
        }

        try await copyIntoOperation(id, sourcePath, destination, options)
    }

    /// Copies service container files to the host through `ContainerClient`.
    public func copyFromContainer(id: String, source: String, destination: String, options: ContainerCopyTransferOptions = ContainerCopyTransferOptions()) async throws {
        let destinationPath = (destination as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destinationPath, isDirectory: &isDirectory)

        if exists, isDirectory.boolValue {
            let lastComponent = (source as NSString).lastPathComponent
            guard !lastComponent.isEmpty, lastComponent != "/" else {
                throw ComposeError.invalidProject("source path has no last component: \(source)")
            }
            let finalDestination = (destinationPath as NSString).appendingPathComponent(lastComponent)
            try await copyFromOperation(id, source, finalDestination, options)
        } else if destination.hasSuffix("/") {
            try await copyFromOperation(id, source, destinationPath, options)
            var resultIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: destinationPath, isDirectory: &resultIsDirectory),
               !resultIsDirectory.boolValue
            {
                try? FileManager.default.removeItem(atPath: destinationPath)
                throw ComposeError.invalidProject("destination is not a directory: \(destination)")
            }
        } else {
            try await copyFromOperation(id, source, destinationPath, options)
        }
    }

    /// Streams an archive into a service container through `ContainerClient`.
    public func copyArchiveIntoContainer(
        id: String,
        archive: FileHandle,
        destination: String,
        options: ContainerCopyTransferOptions = ContainerCopyTransferOptions(),
    ) async throws {
        try await copyArchiveIntoOperation(id, archive, destination, options)
    }

    /// Streams a service container path as an archive through `ContainerClient`.
    public func copyFromContainerAsArchive(
        id: String,
        source: String,
        archive: FileHandle,
        copyContents: Bool = false,
        options: ContainerCopyTransferOptions = ContainerCopyTransferOptions(),
    ) async throws {
        try await copyArchiveFromOperation(id, source, archive, copyContents, options)
    }

    /// Streams service container files directly between native copy APIs.
    public func copyBetweenContainers(sourceID: String, source: String, destinationID: String, destination: String, options: ContainerCopyTransferOptions = ContainerCopyTransferOptions()) async throws {
        let archiveSource = Self.archiveSource(source)
        let (reader, writer) = try Self.archivePipe()
        let destinationOptions = ContainerCopyTransferOptions(preserveOwnership: options.preserveOwnership)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    defer { try? writer.close() }
                    try await copyArchiveFromOperation(
                        sourceID,
                        archiveSource.path,
                        writer,
                        archiveSource.copyContents,
                        options,
                    )
                }
                group.addTask {
                    defer { try? reader.close() }
                    try await copyArchiveIntoOperation(
                        destinationID,
                        reader,
                        destination,
                        destinationOptions,
                    )
                }
                do {
                    while try await group.next() != nil {}
                } catch {
                    try? writer.close()
                    try? reader.close()
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            try? writer.close()
            try? reader.close()
            throw error
        }
    }

    private static func archiveSource(_ source: String) -> (path: String, copyContents: Bool) {
        if source == "/." {
            return ("/", true)
        }
        guard source.hasSuffix("/.") else {
            return (source, false)
        }
        let path = String(source.dropLast(2))
        return (path.isEmpty ? "/" : path, true)
    }

    private static func archivePipe() throws -> (reader: FileHandle, writer: FileHandle) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptors[1],
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal)),
        ) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptors[0])
            close(descriptors[1])
            throw error
        }

        return (
            FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
            FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true),
        )
    }
}

/// `ContainerClient`-backed exporter for real service container exports.
public struct ContainerClientExporter: ComposeRuntimeExporting {
    public typealias Export = @Sendable (String, URL, Bool, Bool) async throws -> Void

    private let temporaryDirectory: URL
    private let exportOperation: Export

    public init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        export: @escaping Export = { id, archive, live, noFreeze in
            try await ContainerClient().export(id: id, archive: archive, live: live, noFreeze: noFreeze)
        },
    ) {
        self.temporaryDirectory = temporaryDirectory
        exportOperation = export
    }

    /// Exports through `ContainerClient.export(id:archive:live:noFreeze:)`.
    public func exportContainer(id: String, output: String?, live: Bool, noFreeze: Bool) async throws {
        let tempDirectory = try ComposeTemporaryFiles.createDirectory(
            in: temporaryDirectory,
            prefix: "container-compose-export-",
        )
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let archive = tempDirectory.appendingPathComponent("archive.tar")
        try ComposeTemporaryFiles.prepareFile(at: archive)
        try await exportOperation(id, archive, live, noFreeze)
        try ComposeTemporaryFiles.secureFile(at: archive)

        if let output {
            try FileManager.default.moveItem(at: archive, to: Self.outputURL(output))
        } else {
            try streamArchiveToStandardOutput(archive)
        }
    }

    /// Resolves output paths the same way the apple/container CLI does.
    private static func outputURL(_ output: String) -> URL {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: output, relativeTo: currentDirectory).absoluteURL
    }

    /// Writes the tar archive without decoding binary data as text.
    private func streamArchiveToStandardOutput(_ archive: URL) throws {
        let fileHandle = try FileHandle(forReadingFrom: archive)
        defer {
            try? fileHandle.close()
        }

        let bufferSize = 4096
        while true {
            let chunk = fileHandle.readData(ofLength: bufferSize)
            if chunk.isEmpty {
                break
            }
            FileHandle.standardOutput.write(chunk)
        }
    }
}
