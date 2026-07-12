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

public extension ComposeOrchestrator {
    /// Copies files between a Compose service container and the local host.
    func copy(project: ComposeProject, arguments: [String]) async throws {
        try await copy(
            project: project,
            options: ComposeCopyOptions {
                $0.arguments = arguments
            },
        )
    }

    /// Copies files between a Compose service container and the local host with Compose options.
    func copy(project: ComposeProject, options copy: ComposeCopyOptions) async throws {
        let (source, destination) = try await copyEndpoints(project: project, copy: copy)
        let transferOptions = ContainerCopyTransferOptions(
            followSymlink: copy.followLink,
            preserveOwnership: copy.archive,
        )

        switch (source, destination) {
        case let (.local("-"), .containers(destinations)):
            try await copyArchiveIntoContainers(
                destinations: destinations,
                copy: copy,
                transferOptions: transferOptions,
            )
        case let (.containers(sources), .local(localPath)):
            try await copyFromContainerTargets(
                sources: sources,
                localPath: localPath,
                copy: copy,
                transferOptions: transferOptions,
            )
        case let (.local(localPath), .containers(destinations)):
            try await copyLocalPathIntoContainers(
                localPath: localPath,
                destinations: destinations,
                copy: copy,
                transferOptions: transferOptions,
            )
        case let (.containers(sources), .containers(destinations)):
            try await copyBetweenContainerTargets(
                sources: sources,
                destinations: destinations,
                allDestinations: copy.all,
                copy: copy,
                transferOptions: transferOptions,
            )
        case (.local, .local):
            throw ComposeError.invalidProject("unknown copy direction")
        }
    }

    private func copyEndpoints(
        project: ComposeProject,
        copy: ComposeCopyOptions,
    ) async throws -> (ComposeCopyEndpoint, ComposeCopyEndpoint) {
        guard copy.arguments.count == 2 else {
            throw ComposeError.invalidProject("cp requires exactly source and destination")
        }
        let sourceIsArchiveStream = copy.arguments[0] == "-"
        let destinationIsArchiveStream = copy.arguments[1] == "-"
        if sourceIsArchiveStream, destinationIsArchiveStream {
            throw ComposeError.invalidProject("cp cannot use '-' for both source and destination")
        }

        let source = try await copyEndpoint(
            copy.arguments[0],
            project: project,
            index: copy.index,
            includeOneOff: copy.all && !options.dryRun,
        )
        let destination = try await copyEndpoint(
            copy.arguments[1],
            project: project,
            index: copy.index,
            includeOneOff: copy.all && !options.dryRun,
        )
        return (source, destination)
    }

    private func copyArchiveIntoContainers(
        destinations: [ComposeCopyContainerTarget],
        copy: ComposeCopyOptions,
        transferOptions: ContainerCopyTransferOptions,
    ) async throws {
        if options.dryRun {
            for destination in destinations {
                emitComposeRuntimeOperation(
                    copyCommandArguments(source: "-", destination: destination.runtimeArgument, options: copy),
                )
            }
            return
        }

        let archiveFile = try stagedCopyInputArchive(options.copyInputArchive())
        defer {
            try? FileManager.default.removeItem(at: archiveFile.deletingLastPathComponent())
        }
        for destination in destinations {
            try await copier.copyArchiveFileIntoContainer(
                id: destination.id,
                archive: archiveFile,
                destination: destination.path,
                options: transferOptions,
            )
        }
    }

    private func copyFromContainerTargets(
        sources: [ComposeCopyContainerTarget],
        localPath: String,
        copy: ComposeCopyOptions,
        transferOptions: ContainerCopyTransferOptions,
    ) async throws {
        guard let source = sources.first else {
            throw ComposeError.invalidProject("no source container found for cp")
        }
        if options.dryRun {
            emitComposeRuntimeOperation(
                copyCommandArguments(source: source.runtimeArgument, destination: localPath, options: copy),
            )
            return
        }
        if localPath == "-" {
            try await copier.copyFromContainerAsArchive(
                id: source.id,
                source: source.path,
                archive: options.copyOutputArchive(),
                options: transferOptions,
            )
            return
        }
        try await copier.copyFromContainer(
            id: source.id,
            source: source.path,
            destination: localPath,
            options: transferOptions,
        )
    }

    private func copyLocalPathIntoContainers(
        localPath: String,
        destinations: [ComposeCopyContainerTarget],
        copy: ComposeCopyOptions,
        transferOptions: ContainerCopyTransferOptions,
    ) async throws {
        if options.dryRun {
            for destination in destinations {
                emitComposeRuntimeOperation(
                    copyCommandArguments(source: localPath, destination: destination.runtimeArgument, options: copy),
                )
            }
            return
        }

        for destination in destinations {
            try await copier.copyIntoContainer(
                id: destination.id,
                source: localPath,
                destination: destination.path,
                options: transferOptions,
            )
        }
    }

    private func stagedCopyInputArchive(_ input: FileHandle) throws -> URL {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true,
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let archive = tempDirectory.appendingPathComponent("stdin.tar")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let output = try FileHandle(forWritingTo: archive)
        defer {
            try? output.close()
        }
        let bufferSize = 1024 * 1024
        while true {
            let chunk = input.readData(ofLength: bufferSize)
            if chunk.isEmpty {
                break
            }
            output.write(chunk)
        }
        return archive
    }

    /// Stages copies from one source service container into selected destination containers.
    internal func copyBetweenContainerTargets(
        sources: [ComposeCopyContainerTarget],
        destinations: [ComposeCopyContainerTarget],
        allDestinations: Bool,
        copy: ComposeCopyOptions,
        transferOptions: ContainerCopyTransferOptions,
    ) async throws {
        guard let source = sources.first else {
            throw ComposeError.invalidProject("no source or destination container found for cp")
        }
        let selectedDestinations = allDestinations ? destinations : Array(destinations.prefix(1))
        guard !selectedDestinations.isEmpty else {
            throw ComposeError.invalidProject("no source or destination container found for cp")
        }

        if options.dryRun {
            for destination in selectedDestinations {
                emitComposeRuntimeOperation(
                    copyCommandArguments(
                        source: source.runtimeArgument,
                        destination: destination.runtimeArgument,
                        options: copy,
                    ),
                )
            }
            return
        }

        for destination in selectedDestinations {
            try await copier.copyBetweenContainers(
                sourceID: source.id,
                source: source.path,
                destinationID: destination.id,
                destination: destination.path,
                options: transferOptions,
            )
        }
    }

    internal func copyCommandArguments(
        source: String,
        destination: String,
        options: ComposeCopyOptions,
    ) -> [String] {
        var arguments = ["cp"]
        if options.archive {
            arguments.append("--archive")
        }
        if options.followLink {
            arguments.append("--follow-link")
        }
        arguments.append(contentsOf: [source, destination])
        return arguments
    }
}
