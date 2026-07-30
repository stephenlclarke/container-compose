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

/// Apple containerization-backed archive operations used by Compose.
public struct ContainerArchiveManager: ComposeArchiveManaging {
    public init() {
        // This adapter is stateless; the explicit initializer supports provider injection.
    }

    public func writeCommitImageArchive(_ request: ComposeCommitImageArchiveRequest) throws {
        try ComposeCommitImageArchive.write(
            rootfsArchive: request.rootfsArchive,
            output: request.output,
            service: request.service,
            options: request.options,
            metadata: .init(
                baseImage: request.image.baseImage,
                healthCheck: request.image.healthCheck,
                createdAt: request.image.createdAt,
                shellPath: request.image.shellPath,
            ),
            temporaryDirectory: request.temporaryDirectory,
        )
    }

    public func extractBridgeTemplates(archive: URL, destination: String) throws {
        let reader = try ArchiveReader(file: archive)
        let rejected = try reader.extractContents(
            to: URL(fileURLWithPath: destination, isDirectory: true),
            including: bridgeArchiveMemberIsTemplate,
        )
        guard rejected.isEmpty else {
            let paths = rejected.sorted().joined(separator: ", ")
            throw ComposeError.invalidProject("transformer archive contains unsafe template paths: \(paths)")
        }
    }

    // The runtime copier protocol keeps transfer inputs explicit at this boundary.
    // swiftlint:disable:next function_parameter_count
    public func copyArchiveIntoContainer(
        using copier: any ComposeRuntimeCopying,
        id: String,
        archive: FileHandle,
        destination: String,
        options: ContainerCopyTransferOptions,
        temporaryDirectory: URL,
    ) async throws {
        try await copier.copyArchiveIntoContainer(
            id: id,
            archive: archive,
            destination: destination,
            options: options,
            temporaryDirectory: temporaryDirectory,
        )
    }

    // The runtime copier protocol keeps transfer inputs explicit at this boundary.
    // swiftlint:disable:next function_parameter_count
    public func copyFromContainerAsArchive(
        using copier: any ComposeRuntimeCopying,
        id: String,
        source: String,
        archive: FileHandle,
        copyContents: Bool,
        options: ContainerCopyTransferOptions,
        temporaryDirectory: URL,
    ) async throws {
        try await copier.copyFromContainerAsArchive(
            id: id,
            source: source,
            archive: archive,
            copyContents: copyContents,
            options: options,
            temporaryDirectory: temporaryDirectory,
        )
    }
}

private func bridgeArchiveMemberIsTemplate(_ path: String) -> Bool {
    var components = path.split(separator: "/", omittingEmptySubsequences: true)
    while components.first == "." {
        components.removeFirst()
    }
    return components.first == "templates"
}
