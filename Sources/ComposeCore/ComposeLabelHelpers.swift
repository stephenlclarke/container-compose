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

import ContainerResource
import CryptoKit
import Foundation

/// Uses normalized runtime resource names while falling back to generated
/// project-scoped names for hand-built test models.
func declaredResourceName(projectName: String, composeName: String, declaredName: String, external: Bool) -> String {
    let normalizedName = declaredName.isEmpty ? composeName : declaredName
    if external || normalizedName != composeName {
        return slug(normalizedName)
    }
    return resourceName(project: projectName, name: composeName)
}

/// Returns labels shared by all resources in a Compose project.
func resourceLabels(project: ComposeProject) -> [String] {
    [
        "\(projectLabel)=\(project.name)",
        "com.apple.container.compose.version=1",
        "\(workingDirectoryLabel)=\(project.workingDirectory)",
        "\(configFilesLabel)=\(project.composeFiles.joined(separator: ","))",
        "\(configFilesHashLabel)=\(composeFilesHash(project.composeFiles))",
    ]
}

/// Returns resource labels as a dictionary for direct API calls.
func resourceLabels(project: ComposeProject, labels: [String: String]?) -> [String: String] {
    var merged = [
        projectLabel: project.name,
        "com.apple.container.compose.version": "1",
        workingDirectoryLabel: project.workingDirectory,
        configFilesLabel: project.composeFiles.joined(separator: ","),
        configFilesHashLabel: composeFilesHash(project.composeFiles),
    ]
    for (key, value) in labels ?? [:] {
        merged[key] = value
    }
    return merged
}

/// Returns labels that identify a service container and its config hash.
func serviceLabels(
    project: ComposeProject,
    service: ComposeService,
    oneOff: Bool,
    externalVolumeMounts: ExternalVolumeMounts = [:],
    materializedConfigSecretRoot: URL = ComposeExecutionOptions.defaultMaterializedConfigSecretDirectory(),
) throws -> [String] {
    var labels = resourceLabels(project: project)
    labels.append("\(serviceLabel)=\(service.name)")
    labels.append("\(oneOffLabel)=\(oneOff)")
    let serviceConfigHash = try configHash(
        project: project,
        service: service,
        externalVolumeMounts: externalVolumeMounts,
        materializedConfigSecretRoot: materializedConfigSecretRoot,
    )
    labels.append("\(configHashLabel)=\(serviceConfigHash)")
    if let firstFile = project.composeFiles.first {
        labels.append("com.apple.container.compose.project.config-file=\(firstFile)")
    }
    return labels
}

/// Returns the typed metadata labels for direct service creation.
func serviceCreateLabels(
    project: ComposeProject,
    service: ComposeService,
    oneOff: Bool,
    externalVolumeMounts: ExternalVolumeMounts = [:],
    labelOverrides: [ComposeLabelOverride] = [],
    materializedConfigSecretRoot: URL = ComposeExecutionOptions.defaultMaterializedConfigSecretDirectory(),
) throws -> [String: String] {
    var labels = try serviceLabels(
        project: project,
        service: service,
        oneOff: oneOff,
        externalVolumeMounts: externalVolumeMounts,
        materializedConfigSecretRoot: materializedConfigSecretRoot,
    ).reduce(into: [String: String]()) { result, raw in
        let parsed = labelKeyValue(raw)
        result[parsed.key] = parsed.value
    }
    let effectiveLabels = try effectiveServiceLabels(project: project, service: service)
    let overriddenLabelKeys = Set(labelOverrides.map(\.key))
    for (key, value) in effectiveLabels where !overriddenLabelKeys.contains(key) {
        labels[key] = value
    }
    for (key, value) in try effectiveServiceAnnotations(
        service: service,
        conflictingLabelKeys: Set(effectiveLabels.keys),
        conflictingOverrideKeys: overriddenLabelKeys,
    ) {
        labels[key] = value
    }
    for override in labelOverrides {
        labels[override.key] = override.value ?? ""
    }
    return labels
}

/// Splits a runtime label assignment into key/value metadata.
func labelKeyValue(_ raw: String) -> (key: String, value: String) {
    guard let equals = raw.firstIndex(of: "=") else {
        return (raw, "")
    }
    return (String(raw[..<equals]), String(raw[raw.index(after: equals)...]))
}

/// Builds enough of the init process shape for typed create-time projections.
func serviceCreateBaseProcess(service: ComposeService) -> ProcessConfiguration {
    let executable: String
    let arguments: [String]
    if let entrypoint = service.entrypoint, !entrypoint.isEmpty {
        executable = entrypoint[0]
        arguments = Array(entrypoint.dropFirst()) + (service.command ?? [])
    } else if let command = service.command, !command.isEmpty {
        executable = command[0]
        arguments = Array(command.dropFirst())
    } else {
        executable = ComposeRuntimeDefaults.shellExecutable
        arguments = []
    }

    let environment = (service.environment ?? [:])
        .sorted(by: { $0.key < $1.key })
        .map { key, value in
            if let value {
                return "\(key)=\(value)"
            }
            return key
        }
    let workingDirectory = service.workingDir ?? "/"
    let user = service.user.map { ProcessConfiguration.User.raw(userString: $0) } ?? .id(uid: 0, gid: 0)
    return ProcessConfiguration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        terminal: service.tty == true,
        user: user,
        privileged: service.privileged == true,
    )
}

/// Hashes the compose file list in a stable order.
func composeFilesHash(_ composeFiles: [String]) -> String {
    stableHash(composeFiles.sorted().joined(separator: "\n"))
}

/// Hashes the effective service configuration for recreate decisions.
func configHash(
    project: ComposeProject,
    service: ComposeService,
    externalVolumeMounts: ExternalVolumeMounts = [:],
    materializedConfigSecretRoot: URL = ComposeExecutionOptions.defaultMaterializedConfigSecretDirectory(),
) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var effectiveService = service
    effectiveService.labels = try effectiveServiceLabels(project: project, service: service)
    effectiveService.labelFiles = nil
    effectiveService.deployLabels = nil
    effectiveService.volumes = try effectiveServiceVolumes(
        project: project,
        service: service,
        externalVolumeMounts: externalVolumeMounts,
        materializedConfigSecretRoot: materializedConfigSecretRoot,
    )
    let fingerprint = try ServiceConfigFingerprint(
        service: effectiveService,
        networks: serviceNetworkRuntimeNames(project: project, service: service),
        volumes: serviceVolumeRuntimeNames(
            project: project,
            service: service,
            externalVolumeMounts: externalVolumeMounts,
        ),
    )
    guard let data = try? encoder.encode(fingerprint) else {
        return stableHash(service.name)
    }
    return stableHash(String(decoding: data, as: UTF8.self))
}

/// Validates user-supplied service labels and label files before side effects.
func validateServiceLabels(project: ComposeProject, service: ComposeService) throws {
    let labels = try effectiveServiceLabels(project: project, service: service)
    _ = try effectiveServiceAnnotations(service: service, conflictingLabelKeys: Set(labels.keys))
}

/// Returns the user labels applied to a service after processing label files.
func effectiveServiceLabels(project: ComposeProject, service: ComposeService) throws -> [String: String] {
    var labels: [String: String] = [:]
    for file in service.labelFiles ?? [] {
        for (key, value) in try loadLabels(fromLabelFile: file, project: project, service: service) {
            labels[key] = value
        }
    }
    for (key, value) in service.labels ?? [:] {
        try validateUserLabelKey(key, source: "service '\(service.name)' label")
        labels[key] = value
    }
    return labels
}

/// Returns Compose service annotations mapped to apple/container runtime metadata labels.
func effectiveServiceAnnotations(
    service: ComposeService,
    conflictingLabelKeys: Set<String>,
    conflictingOverrideKeys: Set<String> = [],
) throws -> [String: String] {
    var annotations: [String: String] = [:]
    for (key, value) in service.annotations ?? [:] {
        try validateUserLabelKey(key, source: "service '\(service.name)' annotation")
        if conflictingLabelKeys.contains(key) {
            throw ComposeError.invalidProject("service '\(service.name)' annotation '\(key)' conflicts with a service label mapped to the same runtime metadata key")
        }
        if conflictingOverrideKeys.contains(key) {
            throw ComposeError.invalidProject("run --label cannot override service '\(service.name)' annotation '\(key)' because annotations map to runtime metadata labels")
        }
        annotations[key] = value
    }
    return annotations
}

/// Loads one Compose `label_file` using the env-file-like key-value syntax.
func loadLabels(fromLabelFile path: String, project: ComposeProject, service: ComposeService) throws -> [String: String] {
    let url = labelFileURL(path, project: project)
    let contents: String
    do {
        contents = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw ComposeError.invalidProject("service '\(service.name)' label_file '\(path)' could not be read")
    }

    var labels: [String: String] = [:]
    for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        guard let label = try parseLabelFileLine(String(line), path: path, lineNumber: offset + 1, service: service) else {
            continue
        }
        labels[label.key] = label.value
    }
    return labels
}

/// Resolves label files relative to the normalized project directory.
func labelFileURL(_ path: String, project: ComposeProject) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: project.workingDirectory, isDirectory: true)).absoluteURL
}

/// Parses one key-value line from a Compose label file.
func parseLabelFileLine(
    _ line: String,
    path: String,
    lineNumber: Int,
    service: ComposeService,
) throws -> (key: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
        return nil
    }

    let key: String
    let value: String
    if let equals = line.firstIndex(of: "=") {
        key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        key = trimmed
        value = ""
    }
    guard !key.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' label_file '\(path)' line \(lineNumber) has an empty label key")
    }
    try validateUserLabelKey(key, source: "service '\(service.name)' label_file '\(path)'")
    return (key, value)
}

/// Rejects labels that would conflict with Compose tracking metadata.
func validateUserLabelKey(_ key: String, source: String) throws {
    guard !reservedComposeLabelPrefixes.contains(where: { key.hasPrefix($0) }) else {
        throw ComposeError.invalidProject("\(source) cannot set reserved Compose tracking label '\(key)'")
    }
}

/// Returns runtime network names that affect a service's run arguments.
func serviceNetworkRuntimeNames(project: ComposeProject, service: ComposeService) -> [String: String] {
    var names: [String: String] = [:]
    for name in service.networks ?? [] {
        names[name] = networkRuntimeName(project: project, composeName: name)
    }
    return names
}

/// Returns runtime volume names that affect a service's run arguments.
func serviceVolumeRuntimeNames(
    project: ComposeProject,
    service: ComposeService,
    externalVolumeMounts: ExternalVolumeMounts = [:],
) throws -> [String: String] {
    var names: [String: String] = [:]
    for mount in try effectiveServiceVolumes(
        project: project,
        service: service,
        externalVolumeMounts: externalVolumeMounts,
    ) where mount.type == "volume" {
        guard let source = mount.source, !source.isEmpty else {
            continue
        }
        names[source] = volumeRuntimeName(project: project, composeName: source)
    }
    return names
}

/// Returns pretty JSON for a filtered direct API container list.
func containerListJSON(_ containers: [ComposeContainerSummary]) throws -> String {
    let scopedData = try JSONSerialization.data(withJSONObject: containers.map(containerListJSONObject), options: [.prettyPrinted, .sortedKeys])
    return String(decoding: scopedData, as: UTF8.self)
}

/// Builds the legacy `container list --format json` shape used by Compose projections.
func containerListJSONObject(_ container: ComposeContainerSummary) -> [String: Any] {
    [
        "id": container.id,
        "configuration": [
            "image": [
                "reference": container.imageReference,
                "descriptor": [
                    "digest": container.imageDigest ?? "",
                ],
            ],
            "labels": container.labels,
            "platform": platformJSONObject(container.platform),
        ],
        "status": [
            "state": container.status,
        ],
    ]
}

/// Converts a platform string into the JSON object emitted by `container list`.
func platformJSONObject(_ value: String) -> [String: String] {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else {
        return [:]
    }
    var object = [
        "os": parts[0],
        "architecture": parts[1],
    ]
    if parts.count >= 3, !parts[2].isEmpty {
        object["variant"] = parts[2]
    }
    return object
}
