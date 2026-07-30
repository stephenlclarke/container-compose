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

/// Canonical archive-source path handling shared by Compose and runtime adapters.
public enum ComposeArchivePath {
    public static let root = ComposeRuntimeDefaults.workingDirectory
    public static let rootContents = "\(root)."

    public static func source(_ source: String) -> (path: String, copyContents: Bool) {
        if source == rootContents {
            return (root, true)
        }
        guard source.hasSuffix(rootContents) else {
            return (source, false)
        }
        let path = String(source.dropLast(rootContents.count))
        return (path.isEmpty ? root : path, true)
    }

    public static func contentsSource(_ source: String) -> String {
        if source == root {
            return rootContents
        }
        return source.hasSuffix(root) ? "\(source)." : "\(source)\(rootContents)"
    }
}

/// Runtime-neutral inputs for building a `compose commit` OCI image archive.
public struct ComposeCommitImageArchiveRequest {
    public struct ImageConfiguration {
        public var baseImage: ComposeImageMetadata?
        public var healthCheck: ComposeImageHealthCheck?
        public var createdAt: Date
        public var shellPath: String

        public init(
            baseImage: ComposeImageMetadata? = nil,
            healthCheck: ComposeImageHealthCheck? = nil,
            createdAt: Date = Date(),
            shellPath: String = ComposeRuntimeDefaults.shellExecutable,
        ) {
            self.baseImage = baseImage
            self.healthCheck = healthCheck
            self.createdAt = createdAt
            self.shellPath = shellPath
        }
    }

    public var rootfsArchive: URL
    public var output: URL
    public var service: ComposeService
    public var options: ComposeCommitOptions
    public var image: ImageConfiguration
    public var temporaryDirectory: URL

    @available(*, deprecated, message: "Use image.baseImage")
    public var baseImage: ComposeImageMetadata? {
        get { image.baseImage }
        set { image.baseImage = newValue }
    }

    @available(*, deprecated, message: "Use image.healthCheck")
    public var healthCheck: ComposeImageHealthCheck? {
        get { image.healthCheck }
        set { image.healthCheck = newValue }
    }

    @available(*, deprecated, message: "Use image.createdAt")
    public var createdAt: Date {
        get { image.createdAt }
        set { image.createdAt = newValue }
    }

    @available(*, deprecated, message: "Use image.shellPath")
    public var shellPath: String {
        get { image.shellPath }
        set { image.shellPath = newValue }
    }

    public init(
        rootfsArchive: URL,
        output: URL,
        service: ComposeService,
        options: ComposeCommitOptions,
        image: ImageConfiguration = ImageConfiguration(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    ) {
        self.rootfsArchive = rootfsArchive
        self.output = output
        self.service = service
        self.options = options
        self.image = image
        self.temporaryDirectory = temporaryDirectory
    }

    @available(*, deprecated, message: "Use init(rootfsArchive:output:service:options:image:temporaryDirectory:)")
    public init(
        rootfsArchive: URL,
        output: URL,
        service: ComposeService,
        options: ComposeCommitOptions,
        baseImage: ComposeImageMetadata? = nil,
        healthCheck: ComposeImageHealthCheck? = nil,
        createdAt: Date = Date(),
        shellPath: String = ComposeRuntimeDefaults.shellExecutable,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    ) {
        self.init(
            rootfsArchive: rootfsArchive,
            output: output,
            service: service,
            options: options,
            image: ImageConfiguration(
                baseImage: baseImage,
                healthCheck: healthCheck,
                createdAt: createdAt,
                shellPath: shellPath,
            ),
            temporaryDirectory: temporaryDirectory,
        )
    }
}

/// Archive operations supplied by a concrete Compose runtime package.
public protocol ComposeArchiveManaging: Sendable {
    /// Builds an OCI image archive for `compose commit`.
    func writeCommitImageArchive(_ request: ComposeCommitImageArchiveRequest) throws

    /// Extracts transformer templates from an exported container root filesystem.
    func extractBridgeTemplates(archive: URL, destination: String) throws

    // The archive boundary keeps transfer inputs explicit for runtime adapters.
    // swiftlint:disable function_parameter_count
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
    // swiftlint:enable function_parameter_count
}
