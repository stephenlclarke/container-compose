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

import ContainerizationOCI
import Foundation

/// Compose runtime projection paired with compose-go's public Bridge model.
public struct ComposeBridgeProject: Codable, Equatable {
    public var project: ComposeProject
    public var model: ComposeValue

    public init(project: ComposeProject, model: ComposeValue) {
        self.project = project
        self.model = model
    }
}

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

// swiftlint:disable type_name
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

// swiftlint:enable type_name

extension ComposeOrchestrator {
    static let defaultBridgeTransformerImage = "docker/compose-bridge-kubernetes"
    static let bridgeTransformerBaseImage = "docker/compose-bridge-transformer"
    static let bridgeTransformerLabel = "com.docker.compose.bridge"
    static var dryRunBridgeInputPath: String {
        FileManager.default.temporaryDirectory.appendingPathComponent("container-compose-bridge-in").path
    }

    /// Converts the Compose model by running Compose Bridge transformer images.
    public func bridgeConvert(
        project: ComposeProject,
        model: ComposeValue? = nil,
        options convert: ComposeBridgeConvertOptions
    ) async throws {
        let transformations = convert.transformations.isEmpty
            ? [Self.defaultBridgeTransformerImage]
            : convert.transformations
        let output = absoluteBridgePath(convert.output)
        let templates = convert.templates.flatMap { $0.isEmpty ? nil : absoluteBridgePath($0) }

        let renderedProject = options.dryRun
            ? project
            : try await projectWithBridgeAdditionalResources(project)
        let composeYAML = if let model {
            try bridgeModelYAML(
                options.dryRun
                    ? BridgeModelValue(model)
                    : bridgeModelWithAdditionalResources(model, project: renderedProject)
            )
        } else {
            try configYAML(project: renderedProject)
        }

        if options.dryRun {
            for transformation in transformations {
                try await runContainer(bridgeConvertRunArguments(
                    transformation: transformation,
                    input: Self.dryRunBridgeInputPath,
                    output: output,
                    templates: templates
                ))
            }
            return
        }

        let input = try createBridgeInputDirectory(composeYAML: composeYAML)
        defer { try? FileManager.default.removeItem(at: input) }

        if !convert.output.isEmpty {
            try recreateBridgeOutputDirectory(output)
        }
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
        options.emit(output)
    }

    /// Creates a local transformer source directory from an existing transformer image.
    public func bridgeTransformationsCreate(options create: ComposeBridgeTransformationsCreateOptions) async throws {
        let source = create.from?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? create.from!
            : Self.defaultBridgeTransformerImage
        let destination = absoluteBridgePath(create.destination)
        let containerID = "compose-bridge-\(options.oneOffIdentifier())"

        if options.dryRun {
            try await runContainer(["create", "--name", containerID, source])
            let archive = "/tmp/\(containerID).tar"
            emitComposeRuntimeOperation(["export-rootfs", containerID, archive])
            emitComposeRuntimeOperation(["extract-archive", "--include", "templates", archive, destination])
            try await runContainer(["rm", "--force", containerID])
            options.emit("+ write " + shellQuoted([bridgeDockerfilePath(destination)]))
            return
        }

        try ensureBridgeDestinationIsNew(destination)
        try await pullMissingImage(source, quiet: true)

        var createdContainer = false
        var createdID: String?
        func removeCreatedContainer() async {
            guard createdContainer else {
                return
            }
            if let createdID, !createdID.isEmpty {
                _ = try? await runContainer(["rm", "--force", createdID], emitOutput: false)
            } else {
                _ = try? await runContainer(["rm", "--force", containerID], emitOutput: false)
            }
        }

        do {
            let result = try await runContainer(["create", "--name", containerID, source], emitOutput: false)
            createdContainer = true
            createdID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let exportDirectory = try createBridgeExportDirectory()
            defer { try? FileManager.default.removeItem(at: exportDirectory) }
            let archive = exportDirectory.appendingPathComponent("rootfs.tar")
            let exportID = createdID.flatMap { $0.isEmpty ? nil : $0 } ?? containerID
            try await exporter.exportContainer(
                id: exportID,
                output: archive.path
            )
            try extractBridgeTemplates(archive: archive, destination: destination)
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
                  let runtimeImage = serviceImage(project: project, service: service)
            else {
                continue
            }
            try await pullMissingImage(runtimeImage, quiet: true)
            let metadata = try await imageManager.imageMetadata(runtimeImage)
            service.image = service.image ?? "\(project.name)-\(service.name)"
            var exposed = try bridgeExposedPorts(metadata.exposedPorts, image: runtimeImage)
            for port in service.ports ?? [] {
                let mapping = try parsePublishedPortMapping(port, serviceName: service.name)
                exposed.append(contentsOf: (0 ..< mapping.targetRange.count).map {
                    String(mapping.targetRange.start + $0)
                })
            }
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
            "--volume", "\(input):/in",
            "--volume", "\(output):/out",
        ]
        if bridgeOfficialTransformerNeedsAMD64(transformation) {
            arguments.append(contentsOf: ["--arch", "amd64"])
        }
        if let uid = bridgeCurrentUID() {
            arguments.append(contentsOf: ["--uid", uid])
        }
        if let templates {
            arguments.append(contentsOf: ["--volume", "\(templates):/templates"])
        }
        arguments.append(transformation)
        return arguments
    }
}

private struct BridgeTransformerRow {
    var id: String
    var repository: String
    var tag: String
    var size: String
}

private struct BridgeTransformerSummary: Encodable {
    var containers: Int64
    var created: Int64
    var id: String
    var labels: [String: String]
    var parentID: String
    var repoDigests: [String]
    var repoTags: [String]
    var sharedSize: Int64
    var size: Int64

    enum CodingKeys: String, CodingKey {
        case containers = "Containers"
        case created = "Created"
        case id = "Id"
        case labels = "Labels"
        case parentID = "ParentId"
        case repoDigests = "RepoDigests"
        case repoTags = "RepoTags"
        case sharedSize = "SharedSize"
        case size = "Size"
    }
}

private func bridgeExposedPorts(_ ports: [String], image: String) throws -> [String] {
    try ports.map { port in
        let fields = port.split(separator: "/", maxSplits: 1).map(String.init)
        guard let number = fields.first, let parsed = UInt16(number) else {
            throw ComposeError.invalidProject("image '\(image)' exposes invalid port '\(port)'")
        }
        return String(parsed)
    }
}

private func renderBridgeTransformers(
    _ transformers: [ComposeBridgeTransformer],
    options: ComposeBridgeTransformationsListOptions
) throws -> String {
    let transformers = coalescedBridgeTransformers(transformers)
    if options.quiet {
        return transformers.map {
            bridgeTransformerDisplayReferences($0).first ?? $0.id
        }.joined(separator: "\n")
    }

    let rows = transformers.map(bridgeTransformerRow)
    let normalized = options.format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "", "pretty", "table":
        return renderTable(
            [["IMAGE ID", "REPO", "TAGS", "SIZE"]]
                + rows.map { [$0.id, $0.repository, $0.tag, $0.size] }
        )
    case "json":
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let summaries = transformers.map(bridgeTransformerSummary)
        let data = try encoder.encode(summaries)
        guard let output = String(data: data, encoding: .utf8) else {
            throw ComposeError.invalidProject("failed to encode Bridge transformer summaries as UTF-8")
        }
        return output
    default:
        throw ComposeError.unsupported(
            "bridge transformations list --format '\(options.format)'; "
                + "supported values are table and json"
        )
    }
}

private func bridgeTransformerRow(_ transformer: ComposeBridgeTransformer) -> BridgeTransformerRow {
    let reference = bridgeTransformerDisplayReferences(transformer).first ?? transformer.reference
    let parsed = try? Reference.parse(reference)
    let digest = transformer.id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? transformer.id
    let id = digest.count > 12 ? String(digest.prefix(12)) : digest
    return BridgeTransformerRow(
        id: id,
        repository: parsed?.name ?? reference,
        tag: parsed?.tag ?? "<none>",
        size: humanBridgeSize(transformer.sizeInBytes)
    )
}

private func bridgeTransformerSummary(_ transformer: ComposeBridgeTransformer) -> BridgeTransformerSummary {
    BridgeTransformerSummary(
        containers: transformer.containers,
        created: transformer.createdAtUnix,
        id: transformer.id,
        labels: transformer.labels,
        parentID: transformer.parentID,
        repoDigests: transformer.repoDigests,
        repoTags: bridgeTransformerDisplayReferences(transformer),
        sharedSize: transformer.sharedSizeInBytes,
        size: transformer.sizeInBytes
    )
}

private func humanBridgeSize(_ size: Int64) -> String {
    guard size >= 1000 else {
        return "\(size)B"
    }
    let units = ["kB", "MB", "GB", "TB", "PB"]
    var value = Double(size)
    var unit = 0
    repeat {
        value /= 1000
        unit += 1
    } while value >= 1000 && unit < units.count
    return String(format: "%.3g%@", locale: Locale(identifier: "en_US_POSIX"), value, units[unit - 1])
}
