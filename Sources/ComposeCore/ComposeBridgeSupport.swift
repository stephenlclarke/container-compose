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
import ContainerizationArchive
import Foundation

enum BridgeModelValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case binary(Data)
    case array([BridgeModelValue])
    case object([String: BridgeModelValue])

    init(_ value: ComposeValue) {
        switch value {
        case .null:
            self = .null
        case let .bool(value):
            self = .bool(value)
        case let .number(value):
            self = .number(value)
        case let .string(value):
            self = .string(value)
        case let .array(values):
            self = .array(values.map(BridgeModelValue.init))
        case let .object(values):
            self = .object(values.mapValues(BridgeModelValue.init))
        }
    }
}

func absoluteBridgePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let url = if expanded.hasPrefix("/") {
        URL(fileURLWithPath: expanded)
    } else {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(expanded)
    }
    return url.standardizedFileURL.path
}

func createBridgeInputDirectory(composeYAML: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("container-compose-bridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let composeFile = directory.appendingPathComponent("compose.yaml")
        try composeYAML.write(to: composeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: composeFile.path)
        return directory
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

func recreateBridgeOutputDirectory(_ output: String) throws {
    let url = URL(fileURLWithPath: output, isDirectory: true)
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
    let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
    guard candidate != "/", candidate != currentDirectory, !currentDirectory.hasPrefix(candidate + "/") else {
        throw ComposeError.invalidProject(
            "bridge output directory must not be the filesystem root, current directory, "
                + "or an ancestor of the current directory",
        )
    }
    if FileManager.default.fileExists(atPath: output) {
        try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o744], ofItemAtPath: output)
}

func ensureBridgeDestinationIsNew(_ destination: String) throws {
    if FileManager.default.fileExists(atPath: destination) {
        throw ComposeError.invalidProject("output folder \(destination) already exists")
    }
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: destination, isDirectory: true),
        withIntermediateDirectories: true,
    )
    do {
        try FileManager.default.setAttributes([.posixPermissions: 0o744], ofItemAtPath: destination)
    } catch {
        try? FileManager.default.removeItem(atPath: destination)
        throw error
    }
}

func createBridgeExportDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("container-compose-bridge-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

func extractBridgeTemplates(archive: URL, destination: String) throws {
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

private func bridgeArchiveMemberIsTemplate(_ path: String) -> Bool {
    var components = path.split(separator: "/", omittingEmptySubsequences: true)
    while components.first == "." {
        components.removeFirst()
    }
    return components.first == "templates"
}

func bridgeFileDefinitions(
    _ modelDefinitions: [String: BridgeModelValue]?,
    runtimeDefinitions: [String: ComposeValue]?,
    project: ComposeProject,
    kind: String,
) throws -> [String: BridgeModelValue]? {
    guard let runtimeDefinitions else {
        return modelDefinitions
    }
    var rendered = modelDefinitions ?? runtimeDefinitions.mapValues(BridgeModelValue.init)
    for name in runtimeDefinitions.keys.sorted() {
        guard case let .object(runtimeFields) = runtimeDefinitions[name] else {
            continue
        }
        guard case var .object(fields) = rendered[name] else {
            throw ComposeError.invalidProject("compose-go Bridge model is missing \(kind) '\(name)'")
        }
        if runtimeFields["external"]?.boolValue == true {
            continue
        }
        if let environment = runtimeFields["environment"]?.stringValue, !environment.isEmpty {
            fields["content"] = .string(hostEnvironmentValue(environment) ?? "")
        } else if let file = runtimeFields["file"]?.stringValue, !file.isEmpty {
            let path = resolvedProjectPath(file, project: project)
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw ComposeError.invalidProject(
                    "cannot load \(kind) '\(name)' from \(path): \(error.localizedDescription)",
                )
            }
            if let content = String(data: data, encoding: .utf8) {
                fields["content"] = .string(content)
            } else {
                fields["content"] = .binary(data)
            }
        }
        rendered[name] = .object(fields)
    }
    return rendered
}

func bridgeModelWithAdditionalResources(
    _ model: ComposeValue,
    project: ComposeProject,
) throws -> BridgeModelValue {
    let model = BridgeModelValue(model)
    guard case var .object(root) = model,
          case var .object(services) = root["services"]
    else {
        throw ComposeError.invalidProject("compose-go Bridge model is missing its services object")
    }

    for name in project.services.keys.sorted() {
        guard let service = project.services[name], case var .object(fields) = services[name] else {
            throw ComposeError.invalidProject("compose-go Bridge model is missing service '\(name)'")
        }
        if let image = service.image {
            fields["image"] = .string(image)
        }
        if let expose = service.expose, !expose.isEmpty {
            fields["expose"] = .array(expose.map(BridgeModelValue.string))
        }
        services[name] = .object(fields)
    }
    root["services"] = .object(services)
    let modelConfigs = try bridgeDefinitionObject(root["configs"], kind: "configs")
    if let configs = try bridgeFileDefinitions(
        modelConfigs,
        runtimeDefinitions: project.configs,
        project: project,
        kind: "config",
    ) {
        root["configs"] = .object(configs)
    }
    let modelSecrets = try bridgeDefinitionObject(root["secrets"], kind: "secrets")
    if let secrets = try bridgeFileDefinitions(
        modelSecrets,
        runtimeDefinitions: project.secrets,
        project: project,
        kind: "secret",
    ) {
        root["secrets"] = .object(secrets)
    }
    return .object(root)
}

private func bridgeDefinitionObject(
    _ value: BridgeModelValue?,
    kind: String,
) throws -> [String: BridgeModelValue]? {
    guard let value else {
        return nil
    }
    guard case let .object(definitions) = value else {
        throw ComposeError.invalidProject("compose-go Bridge model has a malformed \(kind) object")
    }
    return definitions
}

func bridgeModelYAML(_ model: BridgeModelValue) throws -> String {
    YAMLDocumentRenderer.render(model)
}

func coalescedBridgeTransformers(
    _ transformers: [ComposeBridgeTransformer],
) -> [ComposeBridgeTransformer] {
    let ordered = transformers.sorted {
        ($0.reference, $0.id) < ($1.reference, $1.id)
    }
    var byImage: [String: ComposeBridgeTransformer] = [:]
    for transformer in ordered {
        let key = transformer.id.isEmpty ? "reference:\(transformer.reference)" : "id:\(transformer.id)"
        guard var existing = byImage[key] else {
            byImage[key] = transformer
            continue
        }

        existing.createdAtUnix = max(existing.createdAtUnix, transformer.createdAtUnix)
        existing.containers = max(existing.containers, transformer.containers)
        existing.labels.merge(transformer.labels) { current, _ in current }
        if existing.parentID.isEmpty {
            existing.parentID = transformer.parentID
        }
        existing.repoDigests = Array(Set(existing.repoDigests + transformer.repoDigests)).sorted()
        existing.repoTags = Array(Set(existing.repoTags + transformer.repoTags)).sorted()
        existing.sharedSizeInBytes = max(existing.sharedSizeInBytes, transformer.sharedSizeInBytes)
        existing.sizeInBytes = max(existing.sizeInBytes, transformer.sizeInBytes)
        existing.reference = existing.repoTags.first
            ?? [existing.reference, transformer.reference].filter { !$0.isEmpty }.sorted().first
            ?? ""
        byImage[key] = existing
    }
    return byImage.values.sorted {
        ($0.repoTags.first ?? $0.reference, $0.id) < ($1.repoTags.first ?? $1.reference, $1.id)
    }
}

func writeBridgeTransformerDockerfile(destination: String) throws {
    let dockerfile = """
    FROM \(ComposeOrchestrator.bridgeTransformerBaseImage)
    LABEL \(ComposeOrchestrator.bridgeTransformerLabel)=transformation
    COPY templates /templates
    """ + "\n"
    let path = bridgeDockerfilePath(destination)
    try dockerfile.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
}

func bridgeDockerfilePath(_ destination: String) -> String {
    URL(fileURLWithPath: destination, isDirectory: true)
        .appendingPathComponent("Dockerfile")
        .path
}

func bridgeCurrentUID() -> String? {
    #if canImport(Darwin) || canImport(Glibc)
        String(getuid())
    #else
        nil
    #endif
}
