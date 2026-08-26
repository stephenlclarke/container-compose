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
///
/// The pinned Container client supplies both filesystem-path and native archive
/// copy calls. Native archive streaming is required for ownership preservation:
/// extracting an archive on macOS cannot retain arbitrary numeric Linux owners
/// before the staged files cross into the guest.
public struct ContainerClientCopier: ComposeRuntimeArchiveCopying {
    public typealias CopyInto = @Sendable (String, String, String, ContainerCopyTransferOptions) async throws -> Void
    public typealias CopyFrom = @Sendable (String, String, String, ContainerCopyTransferOptions) async throws -> Void
    public typealias CopyArchiveInto =
        @Sendable (String, FileHandle, String, ContainerCopyTransferOptions) async throws -> Void
    public typealias CopyArchiveFrom =
        @Sendable (String, String, FileHandle, Bool, ContainerCopyTransferOptions) async throws -> Void

    private let copyIntoOperation: CopyInto
    private let copyFromOperation: CopyFrom
    private let copyArchiveIntoOperation: CopyArchiveInto?
    private let copyArchiveFromOperation: CopyArchiveFrom?

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
        copyArchiveInto: CopyArchiveInto? = { id, archive, destination, options in
            try await ContainerClient().copyIn(
                id: id,
                archive: archive,
                destination: destination,
                createParents: true,
                preserveOwnership: options.preserveOwnership,
            )
        },
        copyArchiveFrom: CopyArchiveFrom? = { id, source, archive, copyContents, options in
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
        if let copyArchiveIntoOperation {
            try await copyArchiveIntoOperation(id, archive, destination, options)
            return
        }

        try await copyArchiveIntoContainer(
            id: id,
            archive: archive,
            destination: destination,
            options: options,
            temporaryDirectory: FileManager.default.temporaryDirectory,
        )
    }

    /// Streams a service container path as an archive through `ContainerClient`.
    public func copyFromContainerAsArchive(
        id: String,
        source: String,
        archive: FileHandle,
        copyContents: Bool = false,
        options: ContainerCopyTransferOptions = ContainerCopyTransferOptions(),
    ) async throws {
        if let copyArchiveFromOperation {
            try await copyArchiveFromOperation(id, source, archive, copyContents, options)
            return
        }

        try await copyFromContainerAsArchive(
            id: id,
            source: source,
            archive: archive,
            copyContents: copyContents,
            options: options,
            temporaryDirectory: FileManager.default.temporaryDirectory,
        )
    }

    /// Copies service container files through native archive APIs when supplied,
    /// otherwise through Compose's secure staged-archive fallback.
    public func copyBetweenContainers(sourceID: String, source: String, destinationID: String, destination: String, options: ContainerCopyTransferOptions = ContainerCopyTransferOptions()) async throws {
        guard copyArchiveIntoOperation != nil, copyArchiveFromOperation != nil else {
            try await copyBetweenContainersUsingStagedArchive(
                sourceID: sourceID,
                source: source,
                destinationID: destinationID,
                destination: destination,
                options: options,
            )
            return
        }

        let archiveSource = ComposeArchivePath.source(source)
        let (reader, writer) = try Self.archivePipe()
        let destinationOptions = ContainerCopyTransferOptions(preserveOwnership: options.preserveOwnership)

        try await Self.transferArchive(
            reader: reader,
            writer: writer,
            export: {
                try await copyFromContainerAsArchive(
                    id: sourceID,
                    source: archiveSource.path,
                    archive: writer,
                    copyContents: archiveSource.copyContents,
                    options: options,
                )
            },
            import: {
                try await copyArchiveIntoContainer(
                    id: destinationID,
                    archive: reader,
                    destination: destination,
                    options: destinationOptions,
                )
            },
        )
    }

    private func copyBetweenContainersUsingStagedArchive(
        sourceID: String,
        source: String,
        destinationID: String,
        destination: String,
        options: ContainerCopyTransferOptions,
    ) async throws {
        let temporaryDirectory = try ComposeTemporaryFiles.createDirectory(
            prefix: "container-compose-runtime-copy-",
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let archiveURL = temporaryDirectory.appendingPathComponent("transfer.tar")
        let archiveSource = ComposeArchivePath.source(source)
        let copier: any ComposeRuntimeCopying = self

        let writer = try ComposeTemporaryFiles.createFile(at: archiveURL)
        do {
            try await copier.copyFromContainerAsArchive(
                id: sourceID,
                source: archiveSource.path,
                archive: writer,
                copyContents: archiveSource.copyContents,
                options: options,
                temporaryDirectory: temporaryDirectory,
            )
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }

        let reader = try FileHandle(forReadingFrom: archiveURL)
        defer { try? reader.close() }
        try await copier.copyArchiveIntoContainer(
            id: destinationID,
            archive: reader,
            destination: destination,
            options: ContainerCopyTransferOptions(preserveOwnership: options.preserveOwnership),
            temporaryDirectory: temporaryDirectory,
        )
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

private extension ContainerClientCopier {
    static func transferArchive(
        reader: FileHandle,
        writer: FileHandle,
        export: @escaping @Sendable () async throws -> Void,
        import: @escaping @Sendable () async throws -> Void,
    ) async throws {
        let transferError = await withTaskGroup(of: Result<Void, any Error>.self) { group in
            group.addTask {
                defer { try? writer.close() }
                return await transferResult(export)
            }
            group.addTask {
                defer { try? reader.close() }
                return await transferResult(`import`)
            }

            var failures = [any Error]()
            while let result = await group.next() {
                if case let .failure(error) = result {
                    if failures.isEmpty {
                        // Closing both endpoints unblocks synchronous reads and writes.
                        try? writer.close()
                        try? reader.close()
                        group.cancelAll()
                    }
                    failures.append(error)
                }
            }

            // Pipe closure can surface before the operation that caused it.
            return failures.first(where: { !isBrokenPipe($0) }) ?? failures.first
        }

        if let transferError {
            try? writer.close()
            try? reader.close()
            throw transferError
        }
    }

    static func transferResult(
        _ operation: @escaping @Sendable () async throws -> Void,
    ) async -> Result<Void, any Error> {
        do {
            try await operation()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    static func isBrokenPipe(_ error: any Error) -> Bool {
        var candidate: NSError? = error as NSError
        while let current = candidate {
            if current.domain == NSPOSIXErrorDomain, current.code == Int(EPIPE) {
                return true
            }
            candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
            if candidate === current {
                break
            }
        }
        return false
    }
}

extension ContainerClientCopier {
    init(containerClient: @escaping ContainerClientProvider) {
        self.init(
            copyInto: { id, source, destination, options in
                try await containerClient().copyIn(
                    id: id,
                    source: source,
                    destination: destination,
                    createParents: true,
                    followSymlink: options.followSymlink,
                    preserveOwnership: options.preserveOwnership,
                )
            },
            copyFrom: { id, source, destination, options in
                try await containerClient().copyOut(
                    id: id,
                    source: source,
                    destination: destination,
                    followSymlink: options.followSymlink,
                    preserveOwnership: options.preserveOwnership,
                )
            },
            copyArchiveInto: { id, archive, destination, options in
                try await containerClient().copyIn(
                    id: id,
                    archive: archive,
                    destination: destination,
                    createParents: true,
                    preserveOwnership: options.preserveOwnership,
                )
            },
            copyArchiveFrom: { id, source, archive, copyContents, options in
                try await containerClient().copyOut(
                    id: id,
                    source: source,
                    archive: archive,
                    followSymlink: options.followSymlink,
                    copyContents: copyContents,
                )
            },
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

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        containerClient: @escaping ContainerClientProvider,
    ) {
        self.init(temporaryDirectory: temporaryDirectory) { id, archive, live, noFreeze in
            try await containerClient().export(
                id: id,
                archive: archive,
                live: live,
                noFreeze: noFreeze,
            )
        }
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
