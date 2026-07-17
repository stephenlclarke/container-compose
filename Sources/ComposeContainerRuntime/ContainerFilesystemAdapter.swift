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
import Foundation

/// `ContainerClient`-backed copier for real service container file copies.
public struct ContainerClientCopier: ComposeRuntimeCopying {
    public typealias CopyInto = @Sendable (String, String, String, ContainerCopyTransferOptions) async throws -> Void
    public typealias CopyFrom = @Sendable (String, String, String, ContainerCopyTransferOptions) async throws -> Void

    private let copyIntoOperation: CopyInto
    private let copyFromOperation: CopyFrom

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
    ) {
        copyIntoOperation = copyInto
        copyFromOperation = copyFrom
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

    /// Copies service container files through a temporary host path using
    /// `ContainerClient.copyOut` followed by `ContainerClient.copyIn`.
    public func copyBetweenContainers(sourceID: String, source: String, destinationID: String, destination: String, options: ContainerCopyTransferOptions = ContainerCopyTransferOptions()) async throws {
        let lastComponent = (source as NSString).lastPathComponent
        guard !lastComponent.isEmpty, lastComponent != "/" else {
            throw ComposeError.invalidProject("source path has no last component: \(source)")
        }

        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true,
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let stagedSource = tempDirectory.appendingPathComponent(lastComponent).path
        try await copyFromContainer(id: sourceID, source: source, destination: stagedSource, options: options)
        let destinationOptions = ContainerCopyTransferOptions(preserveOwnership: options.preserveOwnership)
        try await copyIntoContainer(
            id: destinationID,
            source: stagedSource,
            destination: destination,
            options: destinationOptions,
        )
    }
}

/// `ContainerClient`-backed exporter for real service container exports.
public struct ContainerClientExporter: ComposeRuntimeExporting {
    private static let isStateless = true

    public init() {
        _ = Self.isStateless
    }

    /// Exports through `ContainerClient.export(id:archive:live:noFreeze:)`.
    public func exportContainer(id: String, output: String?, live: Bool, noFreeze: Bool) async throws {
        let client = ContainerClient()
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let archive = tempDirectory.appendingPathComponent("archive.tar")
        try await client.export(id: id, archive: archive, live: live, noFreeze: noFreeze)

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
