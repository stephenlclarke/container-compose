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

/// Runtime-neutral inputs for building a `compose commit` OCI image archive.
public struct ComposeCommitImageArchiveRequest {
    public var rootfsArchive: URL
    public var output: URL
    public var service: ComposeService
    public var options: ComposeCommitOptions
    public var baseImage: ComposeImageMetadata?
    public var healthCheck: ComposeImageHealthCheck?
    public var createdAt: Date
    public var shellPath: String
    public var temporaryDirectory: URL

    public init(
        rootfsArchive: URL,
        output: URL,
        service: ComposeService,
        options: ComposeCommitOptions,
        baseImage: ComposeImageMetadata? = nil,
        healthCheck: ComposeImageHealthCheck? = nil,
        createdAt: Date = Date(),
        shellPath: String = "/bin/sh",
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    ) {
        self.rootfsArchive = rootfsArchive
        self.output = output
        self.service = service
        self.options = options
        self.baseImage = baseImage
        self.healthCheck = healthCheck
        self.createdAt = createdAt
        self.shellPath = shellPath
        self.temporaryDirectory = temporaryDirectory
    }
}

/// Archive operations supplied by a concrete Compose runtime package.
public protocol ComposeArchiveManaging: Sendable {
    /// Builds an OCI image archive for `compose commit`.
    func writeCommitImageArchive(_ request: ComposeCommitImageArchiveRequest) throws

    /// Extracts transformer templates from an exported container root filesystem.
    func extractBridgeTemplates(archive: URL, destination: String) throws

    /// Stages an archive stream through a runtime that only supports filesystem paths.
    func copyArchiveIntoContainer(
        using copier: any ComposeRuntimeCopying,
        id: String,
        archive: FileHandle,
        destination: String,
        options: ContainerCopyTransferOptions,
        temporaryDirectory: URL,
    ) async throws

    /// Stages a container path as an archive through a runtime that only supports filesystem paths.
    func copyFromContainerAsArchive(
        using copier: any ComposeRuntimeCopying,
        id: String,
        source: String,
        archive: FileHandle,
        copyContents: Bool,
        options: ContainerCopyTransferOptions,
        temporaryDirectory: URL,
    ) async throws
}
