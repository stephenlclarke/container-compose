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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import ContainerizationOCI
import Foundation

/// Options for `compose bridge convert`.
public struct ComposeBridgeConvertOptions: Sendable, Equatable {
    /// Directory where generated artifacts are written.
    public var output: String
    /// Optional template directory mounted into the transformer.
    public var templates: String?
    /// Transformer image references to apply.
    public var transformations: [String]

    public init(
        output: String = "out",
        templates: String? = nil,
        transformations: [String] = []
    ) {
        self.output = output
        self.templates = templates
        self.transformations = transformations
    }
}

/// Options for `compose bridge transformations list`.
public struct ComposeBridgeTransformationsListOptions: Sendable, Equatable {
    /// Output format, either `table` or `json`.
    public var format: String
    /// Whether to print only transformer image names.
    public var quiet: Bool

    public init(format: String = "table", quiet: Bool = false) {
        self.format = format
        self.quiet = quiet
    }
}

/// Options for `compose bridge transformations create`.
public struct ComposeBridgeTransformationsCreateOptions: Sendable, Equatable {
    /// Destination directory for the copied transformer templates.
    public var destination: String
    /// Source transformer image reference.
    public var from: String?

    public init(destination: String, from: String? = nil) {
        self.destination = destination
        self.from = from
    }
}

extension ComposeOrchestrator {
    static let defaultBridgeTransformerImage = "docker/compose-bridge-kubernetes"
    static let bridgeTransformerBaseImage = "docker/compose-bridge-transformer"
    static let bridgeTransformerLabel = "com.docker.compose.bridge"

    /// Converts the Compose model by running Compose Bridge transformer images.
    public func bridgeConvert(project: ComposeProject, options convert: ComposeBridgeConvertOptions) async throws {
        let transformations = convert.transformations.isEmpty
            ? [Self.defaultBridgeTransformerImage]
            : convert.transformations
        let output = absoluteBridgePath(convert.output)
        let templates = convert.templates.map(absoluteBridgePath)

        let renderedProject = options.dryRun
            ? project
            : try await projectWithBridgeAdditionalResources(project)
        let composeYAML = try configYAML(project: renderedProject)

        if options.dryRun {
            for transformation in transformations {
                try await runContainer(bridgeConvertRunArguments(
                    transformation: transformation,
                    input: "/tmp/container-compose-bridge-in",
                    output: output,
                    templates: templates
                ))
            }
            return
        }

        let input = try createBridgeInputDirectory(composeYAML: composeYAML)
        defer { try? FileManager.default.removeItem(at: input) }

        try recreateBridgeOutputDirectory(output)
        for transformation in transformations {
            try await pullMissingImage(transformation, quiet: true)
            try await runContainer(
                bridgeConvertRunArguments(
                    transformation: transformation,
                    input: input.path,
                    output: output,
                    templates: templates
                ),
                inheritedIO: true
            )
        }
    }

    /// Lists locally available Compose Bridge transformer images.
    public func bridgeTransformationsList(options list: ComposeBridgeTransformationsListOptions) async throws {
        let transformers = try await imageManager.bridgeTransformers()
        let output = try renderBridgeTransformers(transformers, options: list)
        guard !output.isEmpty else {
            return
        }
        self.options.emit(output)
    }

    /// Creates a local transformer source directory from an existing transformer image.
    public func bridgeTransformationsCreate(options create: ComposeBridgeTransformationsCreateOptions) async throws {
        let source = create.from?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? create.from!
            : Self.defaultBridgeTransformerImage
        let destination = absoluteBridgePath(create.destination)
        let containerID = "compose-bridge-\(self.options.oneOffIdentifier())"

        if options.dryRun {
            try await runContainer(["create", "--name", containerID, source])
            try await runContainer(["cp", "\(containerID):/templates", destination])
            try await runContainer(["rm", "--force", containerID])
            options.emit("+ write " + shellQuoted([bridgeDockerfilePath(destination)]))
            return
        }

        try ensureBridgeDestinationIsNew(destination)
        try await pullMissingImage(source, quiet: true)

        var createdID: String?
        func removeCreatedContainer() async {
            if let createdID, !createdID.isEmpty {
                _ = try? await runContainer(["rm", "--force", createdID], emitOutput: false)
            } else {
                _ = try? await runContainer(["rm", "--force", containerID], emitOutput: false)
            }
        }

        do {
            let result = try await runContainer(["create", "--name", containerID, source], emitOutput: false)
            createdID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            try await runContainer(["cp", "\(containerID):/templates", destination], emitOutput: false)
            try writeBridgeTransformerDockerfile(destination: destination)
        } catch {
            await removeCreatedContainer()
            throw error
        }
        await removeCreatedContainer()
        options.emit("Transformer created in \"\(destination)\"")
    }

    /// Adds image config metadata used by Docker Compose Bridge templates.
    func projectWithBridgeAdditionalResources(_ project: ComposeProject) async throws -> ComposeProject {
        var enriched = project
        for serviceName in project.services.keys.sorted() {
            guard var service = enriched.services[serviceName],
                  let image = serviceImage(project: project, service: service)
            else {
                continue
            }
            try await pullMissingImage(image, quiet: true)
            let metadata = try await imageManager.imageMetadata(image)
            service.image = metadata.reference
            let exposed = bridgeExposedPorts(metadata.exposedPorts)
            if !exposed.isEmpty {
                service.expose = Array(Set((service.expose ?? []) + exposed)).sorted()
            }
            enriched.services[serviceName] = service
        }
        return enriched
    }

    /// Builds the `container run` argument vector for one Bridge transformer.
    func bridgeConvertRunArguments(
        transformation: String,
        input: String,
        output: String,
        templates: String?
    ) -> [String] {
        var arguments = [
            "run",
            "--rm",
            "--env", "LICENSE_AGREEMENT=true",
            "--mount", "type=bind,src=\(input),dst=/in",
            "--mount", "type=bind,src=\(output),dst=/out",
        ]
        if let uid = bridgeCurrentUID() {
            arguments.append(contentsOf: ["--uid", uid])
        }
        if let templates {
            arguments.append(contentsOf: ["--mount", "type=bind,src=\(templates),dst=/templates"])
        }
        arguments.append(transformation)
        return arguments
    }
}

private struct BridgeTransformerRow: Encodable {
    var id: String
    var repository: String
    var tag: String
    var size: String
}

private func bridgeExposedPorts(_ ports: [String]) -> [String] {
    ports.compactMap { port in
        let fields = port.split(separator: "/", maxSplits: 1).map(String.init)
        guard let number = fields.first, Int(number) != nil else {
            return nil
        }
        return number
    }
}

private func renderBridgeTransformers(
    _ transformers: [ComposeBridgeTransformer],
    options: ComposeBridgeTransformationsListOptions
) throws -> String {
    if options.quiet {
        return transformers.map(\.reference).joined(separator: "\n")
    }

    let rows = transformers.map(bridgeTransformerRow)
    let normalized = options.format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "", "table":
        return renderTable([["IMAGE ID", "REPO", "TAG", "SIZE"]] + rows.map { [$0.id, $0.repository, $0.tag, $0.size] })
    case "json":
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(rows), as: UTF8.self)
    default:
        throw ComposeError.unsupported("bridge transformations list --format '\(options.format)'; supported values are table and json")
    }
}

private func bridgeTransformerRow(_ transformer: ComposeBridgeTransformer) -> BridgeTransformerRow {
    let parsed = try? Reference.parse(transformer.reference)
    let id = transformer.id.count > 12 ? String(transformer.id.prefix(12)) : transformer.id
    return BridgeTransformerRow(
        id: id,
        repository: parsed?.name ?? transformer.reference,
        tag: parsed?.tag ?? "<none>",
        size: humanBridgeSize(transformer.sizeInBytes)
    )
}

private func humanBridgeSize(_ size: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: size)
}

private func absoluteBridgePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let url: URL
    if expanded.hasPrefix("/") {
        url = URL(fileURLWithPath: expanded)
    } else {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(expanded)
    }
    return url.standardizedFileURL.path
}

private func createBridgeInputDirectory(composeYAML: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("container-compose-bridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try composeYAML.write(to: directory.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
    return directory
}

private func recreateBridgeOutputDirectory(_ output: String) throws {
    let url = URL(fileURLWithPath: output, isDirectory: true)
    if FileManager.default.fileExists(atPath: output) {
        try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func ensureBridgeDestinationIsNew(_ destination: String) throws {
    if FileManager.default.fileExists(atPath: destination) {
        throw ComposeError.invalidProject("output folder \(destination) already exists")
    }
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: destination, isDirectory: true),
        withIntermediateDirectories: true
    )
}

private func writeBridgeTransformerDockerfile(destination: String) throws {
    let dockerfile = """
    FROM \(ComposeOrchestrator.bridgeTransformerBaseImage)
    LABEL \(ComposeOrchestrator.bridgeTransformerLabel)=transformation
    COPY templates /templates
    """
    try dockerfile.write(toFile: bridgeDockerfilePath(destination), atomically: true, encoding: .utf8)
}

private func bridgeDockerfilePath(_ destination: String) -> String {
    URL(fileURLWithPath: destination, isDirectory: true)
        .appendingPathComponent("Dockerfile")
        .path
}

private func bridgeCurrentUID() -> String? {
#if canImport(Darwin) || canImport(Glibc)
    String(getuid())
#else
    nil
#endif
}
