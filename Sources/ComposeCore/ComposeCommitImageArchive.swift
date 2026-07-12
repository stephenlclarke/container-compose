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

import ContainerizationArchive
import ContainerizationOCI
import Foundation

/// Builds a single-layer OCI image archive for `compose commit`.
package enum ComposeCommitImageArchive {
    /// Writes an OCI layout tar archive whose layer is the exported container root filesystem.
    package static func write(
        rootfsArchive: URL,
        output: URL,
        service: ComposeService,
        options: ComposeCommitOptions,
        baseImageMetadata: ComposeImageMetadata? = nil,
        createdAt: Date = Date()
    ) throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let layoutDirectory = tempDirectory.appendingPathComponent("layout", isDirectory: true)
        let blobsDirectory = layoutDirectory.appendingPathComponent("blobs/sha256", isDirectory: true)
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

        let writer = try ContentWriter(for: blobsDirectory)
        let layer = try writer.create(from: rootfsArchive)
        var config = try CommitImageConfig(baseImageMetadata: baseImageMetadata, service: service)
        try config.apply(changes: options.changes)

        let platform = try service.platform.map(ContainerizationOCI.Platform.init(from:)) ?? .current
        let image = CommitImage(
            created: iso8601String(createdAt),
            author: normalizedOptional(options.author),
            architecture: platform.architecture,
            os: platform.os,
            osVersion: platform.osVersion,
            osFeatures: platform.osFeatures,
            variant: platform.variant,
            config: config,
            rootfs: Rootfs(type: "layers", diffIDs: [layer.digest.digestString]),
            history: [
                History(
                    created: iso8601String(createdAt),
                    createdBy: "container compose commit \(service.name)",
                    author: normalizedOptional(options.author),
                    comment: normalizedOptional(options.message),
                    emptyLayer: false
                ),
            ]
        )
        let configResult = try writer.create(from: image)
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: configResult.digest.digestString,
                size: configResult.size
            ),
            layers: [
                Descriptor(
                    mediaType: MediaTypes.imageLayer,
                    digest: layer.digest.digestString,
                    size: layer.size
                ),
            ]
        )
        let manifestResult = try writer.create(from: manifest)
        var annotations: [String: String]?
        if let reference = normalizedOptional(options.reference) {
            annotations = [
                AnnotationKeys.containerizationImageName: reference,
                AnnotationKeys.containerdImageName: reference,
                AnnotationKeys.openContainersImageName: reference,
            ]
        }
        let index = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestResult.digest.digestString,
                    size: manifestResult.size,
                    annotations: annotations,
                    platform: platform
                ),
            ]
        )
        try writeJSON(["imageLayoutVersion": "1.0.0"], to: layoutDirectory.appendingPathComponent("oci-layout"))
        try writeJSON(index, to: layoutDirectory.appendingPathComponent("index.json"))

        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        let archive = try ArchiveWriter(format: .paxRestricted, filter: .none, file: output)
        try archive.archiveDirectory(layoutDirectory)
        try archive.finishEncoding()
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url)
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CommitImage: Encodable {
    var created: String
    var author: String?
    var architecture: String
    var os: String
    var osVersion: String?
    var osFeatures: [String]?
    var variant: String?
    var config: CommitImageConfig
    var rootfs: Rootfs
    var history: [History]

    enum CodingKeys: String, CodingKey {
        case created
        case author
        case architecture
        case os
        case osVersion
        case osFeatures
        case variant
        case config
        case rootfs
        case history
    }
}

private struct CommitImageConfig: Encodable {
    var user: String?
    var env: [String]?
    var entrypoint: [String]?
    var cmd: [String]?
    var workingDir: String?
    var labels: [String: String]?
    var exposedPorts: [String: [String: String]]?
    var stopSignal: String?
    var volumes: [String: [String: String]]?
    var onBuild: [String]?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case env = "Env"
        case entrypoint = "Entrypoint"
        case cmd = "Cmd"
        case workingDir = "WorkingDir"
        case labels = "Labels"
        case exposedPorts = "ExposedPorts"
        case stopSignal = "StopSignal"
        case volumes = "Volumes"
        case onBuild = "OnBuild"
    }

    init(baseImageMetadata base: ComposeImageMetadata?, service: ComposeService) throws {
        user = normalizedString(service.user) ?? normalizedString(base?.user)
        env = environmentEntries(base: base?.environment, service: service.environment)
        entrypoint = nonEmptyArray(service.entrypoint) ?? nonEmptyArray(base?.entrypoint)
        cmd = nonEmptyArray(service.command) ?? nonEmptyArray(base?.command)
        workingDir = normalizedString(service.workingDir) ?? normalizedString(base?.workingDir)
        labels = mergedLabels(base: base?.labels, service: service.labels)
        exposedPorts = try exposedPortMap(base: base?.exposedPorts, service: service)
        stopSignal = normalizedString(service.stopSignal) ?? normalizedString(base?.stopSignal)
        volumes = nil
        onBuild = nil
    }

    mutating func apply(changes: [String]) throws {
        for change in changes {
            try apply(change: change)
        }
    }

    private mutating func apply(change: String) throws {
        let trimmed = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ComposeError.invalidProject("commit --change cannot be empty")
        }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let instruction = parts[0].uppercased()
        let remainder = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch instruction {
        case "CMD":
            cmd = try shellOrExecForm(remainder, instruction: instruction)
        case "ENTRYPOINT":
            entrypoint = try shellOrExecForm(remainder, instruction: instruction)
        case "ENV":
            env = try mergeKeyValues(existing: env, remainder: remainder, instruction: instruction)
        case "EXPOSE":
            exposedPorts = try mergeExposedPorts(existing: exposedPorts, remainder: remainder)
        case "LABEL":
            labels = try mergeLabels(existing: labels, remainder: remainder)
        case "ONBUILD":
            guard !remainder.isEmpty else {
                throw ComposeError.invalidProject("commit --change ONBUILD requires an instruction")
            }
            onBuild = (onBuild ?? []) + [remainder]
        case "USER":
            user = try requiredRemainder(remainder, instruction: instruction)
        case "VOLUME":
            volumes = try mergeVolumes(existing: volumes, remainder: remainder)
        case "WORKDIR":
            workingDir = try requiredRemainder(remainder, instruction: instruction)
        default:
            throw ComposeError.unsupported("commit --change instruction '\(instruction)' is not supported")
        }
    }
}

private func nonEmptyArray(_ values: [String]?) -> [String]? {
    guard let values, !values.isEmpty else {
        return nil
    }
    return values
}

private func nonEmptyDictionary(_ values: [String: String]?) -> [String: String]? {
    guard let values, !values.isEmpty else {
        return nil
    }
    return values
}

private func normalizedString(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func environmentEntries(base: [String]?, service: [String: String?]?) -> [String]? {
    var values: [String: String?] = [:]
    for entry in base ?? [] {
        if let equals = entry.firstIndex(of: "=") {
            values[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        } else {
            values.updateValue(nil, forKey: entry)
        }
    }
    for (key, value) in service ?? [:] {
        values[key] = value
    }
    guard !values.isEmpty else {
        return nil
    }
    return values.keys.sorted().map { key in
        if let value = values[key] ?? nil {
            return "\(key)=\(value)"
        }
        return key
    }
}

private func mergedLabels(base: [String: String]?, service: [String: String]?) -> [String: String]? {
    var labels = base ?? [:]
    for (key, value) in service ?? [:] {
        labels[key] = value
    }
    return nonEmptyDictionary(labels)
}

private func exposedPortMap(base: [String]?, service: ComposeService) throws -> [String: [String: String]]? {
    var keys = Set<String>()
    for exposed in base ?? [] {
        keys.insert(try normalizedPort(exposed))
    }
    for exposed in service.expose ?? [] {
        keys.insert(try normalizedPort(exposed))
    }
    for port in service.ports ?? [] {
        guard let target = portTarget(port) else {
            continue
        }
        keys.insert(try normalizedPort(target))
    }
    guard !keys.isEmpty else {
        return nil
    }
    return Dictionary(uniqueKeysWithValues: keys.sorted().map { ($0, [:]) })
}

private func portTarget(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }
    guard let colon = trimmed.lastIndex(of: ":") else {
        return trimmed
    }
    let target = trimmed[trimmed.index(after: colon)...]
    return target.isEmpty ? nil : String(target)
}

private func normalizedPort(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ComposeError.invalidProject("commit EXPOSE value cannot be empty")
    }
    let split = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    let port = String(split[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !port.isEmpty else {
        throw ComposeError.invalidProject("commit EXPOSE value cannot be empty")
    }
    if split.count == 1 {
        return "\(port)/tcp"
    }
    let proto = String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !proto.isEmpty else {
        throw ComposeError.invalidProject("commit EXPOSE protocol cannot be empty")
    }
    return "\(port)/\(proto)"
}

private func shellOrExecForm(_ remainder: String, instruction: String) throws -> [String] {
    let value = try requiredRemainder(remainder, instruction: instruction)
    if value.hasPrefix("[") {
        let data = Data(value.utf8)
        return try JSONDecoder().decode([String].self, from: data)
    }
    return ["/bin/sh", "-c", value]
}

private func requiredRemainder(_ remainder: String, instruction: String) throws -> String {
    let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ComposeError.invalidProject("commit --change \(instruction) requires a value")
    }
    return trimmed
}

private func mergeLabels(existing: [String: String]?, remainder: String) throws -> [String: String] {
    var labels = existing ?? [:]
    for (key, value) in try keyValuePairs(remainder, instruction: "LABEL") {
        labels[key] = value
    }
    return labels.isEmpty ? [:] : labels
}

private func mergeKeyValues(existing: [String]?, remainder: String, instruction: String) throws -> [String] {
    var values: [String: String?] = [:]
    for entry in existing ?? [] {
        if let equals = entry.firstIndex(of: "=") {
            values[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        } else {
            values.updateValue(nil, forKey: entry)
        }
    }
    for (key, value) in try keyValuePairs(remainder, instruction: instruction) {
        values[key] = value
    }
    return values.keys.sorted().map { key in
        if let value = values[key] ?? nil {
            return "\(key)=\(value)"
        }
        return key
    }
}

private func mergeExposedPorts(existing: [String: [String: String]]?, remainder: String) throws -> [String: [String: String]] {
    var ports = existing ?? [:]
    let tokens = try shellTokens(requiredRemainder(remainder, instruction: "EXPOSE"))
    guard !tokens.isEmpty else {
        throw ComposeError.invalidProject("commit --change EXPOSE requires at least one port")
    }
    for token in tokens {
        ports[try normalizedPort(token)] = [:]
    }
    return ports
}

private func mergeVolumes(existing: [String: [String: String]]?, remainder: String) throws -> [String: [String: String]] {
    var volumes = existing ?? [:]
    let value = try requiredRemainder(remainder, instruction: "VOLUME")
    let paths: [String]
    if value.hasPrefix("[") {
        paths = try JSONDecoder().decode([String].self, from: Data(value.utf8))
    } else {
        paths = try shellTokens(value)
    }
    guard !paths.isEmpty else {
        throw ComposeError.invalidProject("commit --change VOLUME requires at least one path")
    }
    for path in paths {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ComposeError.invalidProject("commit --change VOLUME contains an empty path")
        }
        volumes[trimmed] = [:]
    }
    return volumes
}

private func keyValuePairs(_ remainder: String, instruction: String) throws -> [(String, String)] {
    let tokens = try shellTokens(requiredRemainder(remainder, instruction: instruction))
    guard !tokens.isEmpty else {
        throw ComposeError.invalidProject("commit --change \(instruction) requires at least one key/value pair")
    }
    if tokens.allSatisfy({ $0.contains("=") }) {
        return try tokens.map { token in
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard !key.isEmpty else {
                throw ComposeError.invalidProject("commit --change \(instruction) contains an empty key")
            }
            return (key, parts.count > 1 ? String(parts[1]) : "")
        }
    }
    guard tokens.count >= 2, !tokens[0].contains("=") else {
        throw ComposeError.unsupported("commit --change \(instruction) supports KEY=VALUE entries or one KEY VALUE pair")
    }
    return [(tokens[0], tokens.dropFirst().joined(separator: " "))]
}

private func shellTokens(_ value: String) throws -> [String] {
    var tokens: [String] = []
    var current = ""
    var quote: Character?
    var escaping = false
    for character in value {
        if escaping {
            current.append(character)
            escaping = false
            continue
        }
        if character == "\\" {
            escaping = true
            continue
        }
        if let activeQuote = quote {
            if character == activeQuote {
                quote = nil
            } else {
                current.append(character)
            }
            continue
        }
        if character == "\"" || character == "'" {
            quote = character
            continue
        }
        if character.isWhitespace {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            continue
        }
        current.append(character)
    }
    if escaping {
        current.append("\\")
    }
    if let quote {
        throw ComposeError.invalidProject("unterminated quote in commit --change value: \(quote)")
    }
    if !current.isEmpty {
        tokens.append(current)
    }
    return tokens
}
