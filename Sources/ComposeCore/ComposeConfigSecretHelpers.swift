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

/// Reads the live host environment so tests and command invocations can
/// materialize Compose environment-backed configs and secrets deterministically.
func hostEnvironmentValue(_ name: String) -> String? {
    guard let value = getenv(name) else {
        return nil
    }
    return String(cString: value)
}

/// Returns the deterministic project directory used for materialized grants.
func materializedProjectDirectory(project: ComposeProject, root: URL) -> URL {
    let identity = [
        project.name,
        project.workingDirectory,
        project.composeFiles.sorted().joined(separator: "\n"),
    ].joined(separator: "\n")
    return root.appendingPathComponent(
        "\(slug(project.name))-\(stableHash(identity).prefix(12))",
        isDirectory: true,
    )
}

/// Removes local materialized config and secret files for a project.
func removeMaterializedConfigSecrets(project: ComposeProject, root: URL) throws {
    let directory = materializedProjectDirectory(project: project, root: root)
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return
    }
    try FileManager.default.removeItem(at: directory)
}

/// Resolves a project-relative file path the same way Compose paths are loaded.
func resolvedProjectPath(_ path: String, project: ComposeProject) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    return URL(
        fileURLWithPath: expanded,
        relativeTo: URL(fileURLWithPath: project.workingDirectory, isDirectory: true),
    ).standardizedFileURL.path
}

/// Resolves a normalized Compose network definition to its runtime name.
func networkRuntimeName(project: ComposeProject, composeName: String, network: ComposeNetwork) -> String {
    declaredResourceName(
        projectName: project.name,
        composeName: composeName,
        declaredName: network.name,
        external: network.external == true,
    )
}

/// Resolves a Compose volume reference to the name used by `container`.
func volumeRuntimeName(project: ComposeProject, composeName: String) -> String {
    guard let volume = project.volumes[composeName] else {
        return resourceName(project: project.name, name: composeName)
    }
    return volumeRuntimeName(project: project, composeName: composeName, volume: volume)
}

/// Resolves a normalized Compose volume definition to its runtime name.
func volumeRuntimeName(project: ComposeProject, composeName: String, volume: ComposeVolume) -> String {
    declaredResourceName(
        projectName: project.name,
        composeName: composeName,
        declaredName: volume.name,
        external: volume.external == true,
    )
}

/// Returns Compose service dependencies, including service-scoped
/// `volumes_from` references that Compose-go treats as implicit dependencies.
func serviceDependencies(
    _ service: ComposeService,
) -> [(key: String, value: ComposeDependency)] {
    var dependencies = service.dependsOn ?? [:]
    for name in serviceVolumesFromDependencyNames(service) where dependencies[name] == nil {
        dependencies[name] = ComposeDependency(condition: "service_started")
    }
    for name in serviceLinkDependencyNames(service) where dependencies[name] == nil {
        dependencies[name] = ComposeDependency(condition: "service_started")
    }
    return dependencies.sorted(by: { $0.key < $1.key })
}

/// Returns parsed legacy `links` references for validation and alias mapping.
func serviceLinkReferences(service: ComposeService, project: ComposeProject) throws -> [ComposeLinkReference] {
    try (service.links ?? []).map { rawValue in
        let reference = try serviceLinkReference(rawValue, service: service)
        guard project.services[reference.serviceName] != nil else {
            throw ComposeError.invalidProject("service '\(service.name)' links to unknown service '\(reference.serviceName)'")
        }
        return reference
    }
}

/// Parses one Compose `links` entry of the form `SERVICE` or `SERVICE:ALIAS`.
func serviceLinkReference(_ rawValue: String, service: ComposeService) throws -> ComposeLinkReference {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' contains an empty link")
    }

    let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let serviceName = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !serviceName.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' link '\(rawValue)' is missing a service name")
    }

    let rawAlias = parts.count == 2
        ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        : serviceName
    guard !rawAlias.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' link '\(rawValue)' is missing an alias")
    }
    guard let alias = canonicalRFC1123Hostname(rawAlias) else {
        throw ComposeError.invalidProject("service '\(service.name)' link alias '\(rawAlias)' is not a valid RFC1123 hostname")
    }
    return ComposeLinkReference(serviceName: serviceName, alias: alias)
}

/// Returns parsed legacy `external_links` references for validation and lookup.
func serviceExternalLinkReferences(service: ComposeService) throws -> [ComposeExternalLinkReference] {
    try (service.externalLinks ?? []).map { rawValue in
        try serviceExternalLinkReference(rawValue, service: service)
    }
}

/// Parses one Compose `external_links` entry of the form `CONTAINER` or `CONTAINER:ALIAS`.
func serviceExternalLinkReference(_ rawValue: String, service: ComposeService) throws -> ComposeExternalLinkReference {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' contains an empty external_links entry")
    }

    let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let containerName = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !containerName.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' external_links entry '\(rawValue)' is missing a container name")
    }

    let alias = parts.count == 2
        ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        : containerName
    guard !alias.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' external_links entry '\(rawValue)' is missing an alias")
    }
    return ComposeExternalLinkReference(containerName: containerName, alias: alias)
}

/// Returns service names referenced by legacy links for dependency ordering.
func serviceLinkDependencyNames(_ service: ComposeService) -> [String] {
    (service.links ?? []).compactMap { rawValue in
        let serviceName = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serviceName, !serviceName.isEmpty else {
            return nil
        }
        return serviceName
    }
}

/// Returns service names referenced by `volumes_from`, ignoring external
/// container references that should not affect project service ordering.
func serviceVolumesFromDependencyNames(_ service: ComposeService) -> [String] {
    (service.volumesFrom ?? []).compactMap { reference in
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("container:") else {
            return nil
        }
        return trimmed.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init)
    }
}

/// Returns external containers referenced through `volumes_from`.
func externalVolumesFromReferences(
    project: ComposeProject,
    services: [ComposeService],
) throws -> [ExternalVolumesFromReference] {
    try services.flatMap {
        try externalVolumesFromReferences(project: project, service: $0, stack: [])
    }
}

/// Recursively collects external inherited volume sources from a service and
/// any same-project services it inherits from.
func externalVolumesFromReferences(
    project: ComposeProject,
    service: ComposeService,
    stack: [String],
) throws -> [ExternalVolumesFromReference] {
    if stack.contains(service.name) {
        let cycle = (stack + [service.name]).joined(separator: " -> ")
        throw ComposeError.invalidProject("volume inheritance cycle involving \(cycle)")
    }

    var references: [ExternalVolumesFromReference] = []
    for reference in try volumesFromReferences(service: service, project: project) {
        switch reference.source {
        case let .service(serviceName):
            guard let sourceService = project.services[serviceName] else {
                throw ComposeError.invalidProject("service '\(service.name)' volumes_from references unknown service '\(serviceName)'")
            }
            try references.append(contentsOf: externalVolumesFromReferences(
                project: project,
                service: sourceService,
                stack: stack + [service.name],
            ))
        case let .externalContainer(containerName):
            references.append(ExternalVolumesFromReference(
                serviceName: service.name,
                rawValue: reference.rawValue,
                containerName: containerName,
            ))
        }
    }
    return references
}

/// Expands `volumes_from` references into concrete mounts.
func effectiveServiceVolumes(
    project: ComposeProject,
    service: ComposeService,
    externalVolumeMounts: ExternalVolumeMounts? = nil,
    materializedConfigSecretRoot: URL = ComposeExecutionOptions.defaultMaterializedConfigSecretDirectory(),
    materializeConfigSecrets: Bool = false,
) throws -> [ComposeMount] {
    try effectiveServiceVolumes(
        project: project,
        service: service,
        context: ServiceVolumeResolutionContext(
            externalVolumeMounts: externalVolumeMounts,
            materializedConfigSecretRoot: materializedConfigSecretRoot,
            materializeConfigSecrets: materializeConfigSecrets,
        ),
    )
}

private struct ServiceVolumeResolutionContext {
    let externalVolumeMounts: ExternalVolumeMounts?
    let materializedConfigSecretRoot: URL
    let materializeConfigSecrets: Bool
    let stack: [String]

    init(
        externalVolumeMounts: ExternalVolumeMounts?,
        materializedConfigSecretRoot: URL,
        materializeConfigSecrets: Bool,
        stack: [String] = [],
    ) {
        self.externalVolumeMounts = externalVolumeMounts
        self.materializedConfigSecretRoot = materializedConfigSecretRoot
        self.materializeConfigSecrets = materializeConfigSecrets
        self.stack = stack
    }

    func descending(from service: ComposeService) -> Self {
        Self(
            externalVolumeMounts: externalVolumeMounts,
            materializedConfigSecretRoot: materializedConfigSecretRoot,
            materializeConfigSecrets: materializeConfigSecrets,
            stack: stack + [service.name],
        )
    }
}

/// Recursively resolves inherited service mounts while detecting cycles in
/// hand-built test models that did not pass through Compose-go validation.
private func effectiveServiceVolumes(
    project: ComposeProject,
    service: ComposeService,
    context: ServiceVolumeResolutionContext,
) throws -> [ComposeMount] {
    if context.stack.contains(service.name) {
        let cycle = (context.stack + [service.name]).joined(separator: " -> ")
        throw ComposeError.invalidProject("volume inheritance cycle involving \(cycle)")
    }

    var volumes: [ComposeMount] = []
    for reference in try volumesFromReferences(service: service, project: project) {
        switch reference.source {
        case let .service(serviceName):
            guard let sourceService = project.services[serviceName] else {
                throw ComposeError.invalidProject("service '\(service.name)' volumes_from references unknown service '\(serviceName)'")
            }
            let inherited = try effectiveServiceVolumes(
                project: project,
                service: sourceService,
                context: context.descending(from: service),
            )
            volumes.append(contentsOf: inherited.map {
                mount($0, applyingVolumesFromReadOnly: reference.readOnly)
            })
        case let .externalContainer(containerName):
            guard let externalVolumeMounts = context.externalVolumeMounts else {
                continue
            }
            guard let inherited = externalVolumeMounts[containerName] else {
                throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(reference.rawValue)' references missing external container '\(containerName)'")
            }
            volumes.append(contentsOf: inherited.map {
                mount($0, applyingVolumesFromReadOnly: reference.readOnly)
            })
        }
    }
    volumes.append(contentsOf: service.volumes ?? [])
    try volumes.append(contentsOf: serviceConfigSecretMounts(
        project: project,
        service: service,
        materializedConfigSecretRoot: context.materializedConfigSecretRoot,
        materialize: context.materializeConfigSecrets,
    ))
    return volumes
}

/// Converts supported service configs and secrets into read-only bind mounts
/// accepted by apple/container `container --volume`.
func serviceConfigSecretMounts(
    project: ComposeProject,
    service: ComposeService,
    materializedConfigSecretRoot: URL = ComposeExecutionOptions.defaultMaterializedConfigSecretDirectory(),
    materialize: Bool = false,
) throws -> [ComposeMount] {
    try serviceConfigSecretMounts(context: ComposeFileMountResolutionContext(
        project: project,
        service: service,
        kind: .config,
        grants: service.configs ?? [],
        definitions: project.configs ?? [:],
        materializedConfigSecretRoot: materializedConfigSecretRoot,
        materialize: materialize,
    )) + serviceConfigSecretMounts(context: ComposeFileMountResolutionContext(
        project: project,
        service: service,
        kind: .secret,
        grants: service.secrets ?? [],
        definitions: project.secrets ?? [:],
        materializedConfigSecretRoot: materializedConfigSecretRoot,
        materialize: materialize,
    ))
}

private struct ComposeFileMountResolutionContext {
    let project: ComposeProject
    let service: ComposeService
    let kind: ComposeFileMountKind
    let grants: [ComposeValue]
    let definitions: [String: ComposeValue]
    let materializedConfigSecretRoot: URL
    let materialize: Bool

    var sourceContext: ComposeFileGrantSourceContext {
        ComposeFileGrantSourceContext(
            project: project,
            service: service,
            kind: kind,
            materializedConfigSecretRoot: materializedConfigSecretRoot,
            materialize: materialize,
        )
    }
}

/// Converts one config or secret grant list into bind mounts.
private func serviceConfigSecretMounts(
    context: ComposeFileMountResolutionContext,
) throws -> [ComposeMount] {
    try context.grants.map { value in
        let grant = try parseComposeFileGrant(value, kind: context.kind, service: context.service)
        let resolvedSource = try composeFileGrantSource(grant: grant, context: context)
        return ComposeMount(
            type: "bind",
            source: resolvedSource.path,
            target: context.kind.targetPath(source: grant.source, target: grant.target),
            options: .init(
                readOnly: true,
                volume: .init(fileOwnership: .init(
                    uid: resolvedSource.ownership?.uid,
                    gid: resolvedSource.ownership?.gid,
                )),
            ),
        )
    }
}

/// Parses one normalized service config or secret reference.
func parseComposeFileGrant(
    _ value: ComposeValue,
    kind: ComposeFileMountKind,
    service: ComposeService,
) throws -> ComposeFileGrant {
    switch value {
    case let .string(source):
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' \(kind.singularName) reference must not be empty")
        }
        return ComposeFileGrant(source: source)
    case let .object(fields):
        let source = fields["source"]?.stringValue?.trimmingCharacters(
            in: .whitespacesAndNewlines,
        )
        guard let source, !source.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' \(kind.singularName) reference is missing source")
        }
        return ComposeFileGrant(
            source: source,
            target: fields["target"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            uid: fields["uid"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            gid: fields["gid"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: fields["mode"],
        )
    default:
        throw ComposeError.invalidProject("service '\(service.name)' \(kind.singularName) reference must be a string or object")
    }
}

/// Resolves the top-level file source for one service config or secret grant.
private func composeFileGrantSource(
    grant: ComposeFileGrant,
    context: ComposeFileMountResolutionContext,
) throws -> ComposeFileGrantSource {
    guard let definition = context.definitions[grant.source] else {
        throw ComposeError.invalidProject(
            "service '\(context.service.name)' references undefined \(context.kind.singularName) '\(grant.source)'",
        )
    }
    guard case let .object(fields) = definition else {
        throw ComposeError.invalidProject(
            "\(context.kind.singularName.capitalized) '\(grant.source)' definition must be an object",
        )
    }
    return try resolvedComposeFileGrantSource(
        grant: grant,
        fields: fields,
        context: context.sourceContext,
    )
}

struct ComposeFileGrantSourceContext {
    let project: ComposeProject
    let service: ComposeService
    let kind: ComposeFileMountKind
    let materializedConfigSecretRoot: URL
    let materialize: Bool
}

private struct ComposeFileGrantSource {
    let path: String
    let ownership: ComposeFileGrantOwnership?
}

struct ComposeFileGrantOwnership {
    let uid: UInt32?
    let gid: UInt32?
}

private func resolvedComposeFileGrantSource(
    grant: ComposeFileGrant,
    fields: [String: ComposeValue],
    context: ComposeFileGrantSourceContext,
) throws -> ComposeFileGrantSource {
    if fields["external"]?.boolValue == true {
        return try externalComposeFileGrantSource(
            grant: grant,
            fields: fields,
            context: context,
        )
    }
    if let file = fields["file"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !file.isEmpty {
        return ComposeFileGrantSource(
            path: resolvedProjectPath(file, project: context.project),
            ownership: nil,
        )
    }
    if let environment = fields["environment"] {
        return try environmentComposeFileGrantSource(
            environment,
            grant: grant,
            context: context,
        )
    }
    if let content = fields["content"] {
        return try contentComposeFileGrantSource(
            content,
            grant: grant,
            context: context,
        )
    }
    throw ComposeError.invalidProject("\(context.kind.singularName.capitalized) '\(grant.source)' must define \(context.kind.supportedDefinitionFields) for runtime mounting")
}

private func environmentComposeFileGrantSource(
    _ environment: ComposeValue,
    grant: ComposeFileGrant,
    context: ComposeFileGrantSourceContext,
) throws -> ComposeFileGrantSource {
    let ownership = try composeFileGrantOwnership(grant: grant, service: context.service, kind: context.kind)
    let name = try composeFileGrantEnvironmentVariable(
        environment,
        grant: grant,
        service: context.service,
        kind: context.kind,
    )
    guard let contents = hostEnvironmentValue(name) else {
        throw ComposeError.invalidProject("service '\(context.service.name)' uses environment-backed \(context.kind.singularName) '\(grant.source)', but host environment variable '\(name)' is not set")
    }
    return try materializedComposeFileGrantSource(
        grant: grant,
        contents: contents,
        context: context,
        ownership: ownership,
    )
}

private func contentComposeFileGrantSource(
    _ content: ComposeValue,
    grant: ComposeFileGrant,
    context: ComposeFileGrantSourceContext,
) throws -> ComposeFileGrantSource {
    guard context.kind == .config else {
        throw ComposeError.unsupported("service '\(context.service.name)' uses content-backed secret '\(grant.source)'; Docker Compose secrets support file or environment sources")
    }
    let ownership = try composeFileGrantOwnership(grant: grant, service: context.service, kind: context.kind)
    guard let contents = content.stringValue else {
        throw ComposeError.invalidProject("config '\(grant.source)' content must be a string")
    }
    return try materializedComposeFileGrantSource(
        grant: grant,
        contents: contents,
        context: context,
        ownership: ownership,
    )
}

private func materializedComposeFileGrantSource(
    grant: ComposeFileGrant,
    contents: String,
    context: ComposeFileGrantSourceContext,
    ownership: ComposeFileGrantOwnership?,
) throws -> ComposeFileGrantSource {
    let materialized = try materializedComposeFile(
        contents: contents,
        permissions: composeFileGrantPermissions(grant: grant, kind: context.kind, service: context.service),
        grant: grant,
        context: context,
    )
    if context.materialize {
        try materialized.write()
    }
    return ComposeFileGrantSource(path: materialized.url.path, ownership: ownership)
}

private func externalComposeFileGrantSource(
    grant: ComposeFileGrant,
    fields: [String: ComposeValue],
    context: ComposeFileGrantSourceContext,
) throws -> ComposeFileGrantSource {
    let ownership = try composeFileGrantOwnership(grant: grant, service: context.service, kind: context.kind)
    let name = try externalComposeFileRuntimeName(
        project: context.project,
        composeName: grant.source,
        fields: fields,
        kind: context.kind,
    )
    let permissions = try composeFileGrantPermissions(grant: grant, kind: context.kind, service: context.service)
    return ComposeFileGrantSource(
        path: materializedExternalComposeFileURL(
            grant: grant,
            runtimeName: name,
            permissions: permissions,
            context: context,
        ).path,
        ownership: ownership,
    )
}

/// Validates generated grant ownership before it is sent to the runtime.
func composeFileGrantOwnership(
    grant: ComposeFileGrant,
    service: ComposeService,
    kind: ComposeFileMountKind,
) throws -> ComposeFileGrantOwnership? {
    let uid = try composeFileGrantOwnershipValue(
        grant.uid,
        field: "uid",
        grant: grant,
        service: service,
        kind: kind,
    )
    let gid = try composeFileGrantOwnershipValue(
        grant.gid,
        field: "gid",
        grant: grant,
        service: service,
        kind: kind,
    )
    guard uid != nil || gid != nil else {
        return nil
    }
    return ComposeFileGrantOwnership(uid: uid, gid: gid)
}

private func composeFileGrantOwnershipValue(
    _ rawValue: String?,
    field: String,
    grant: ComposeFileGrant,
    service: ComposeService,
    kind: ComposeFileMountKind,
) throws -> UInt32? {
    guard let rawValue = nonEmpty(rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    guard let value = UInt32(rawValue) else {
        throw ComposeError.invalidProject("service '\(service.name)' \(kind.singularName) '\(grant.source)' \(field) '\(rawValue)' must be an unsigned 32-bit integer")
    }
    return value
}

/// Returns the file permissions used for a generated config or secret grant.
func composeFileGrantPermissions(
    grant: ComposeFileGrant,
    kind: ComposeFileMountKind,
    service: ComposeService,
) throws -> Int {
    guard let mode = grant.mode else {
        return kind.defaultMaterializedPermissions
    }
    return try parseComposeFileGrantMode(mode, grant: grant, kind: kind, service: service) & ~0o222
}

/// Parses Compose's octal grant mode, leaving write bits to be ignored later.
func parseComposeFileGrantMode(
    _ value: ComposeValue,
    grant: ComposeFileGrant,
    kind: ComposeFileMountKind,
    service: ComposeService,
) throws -> Int {
    if let rawValue = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
        let normalized = rawValue.lowercased().hasPrefix("0o") ? String(rawValue.dropFirst(2)) : rawValue
        if !normalized.isEmpty,
           normalized.allSatisfy({ ("0" ... "7").contains($0) }),
           let parsed = Int(normalized, radix: 8),
           parsed <= 0o777
        {
            return parsed
        }
        throw ComposeError.invalidProject("service '\(service.name)' \(kind.singularName) '\(grant.source)' mode '\(rawValue)' must be an octal file mode between 0000 and 0777")
    }

    if let parsed = value.intValue, (0 ... 0o777).contains(parsed) {
        return parsed
    }

    throw ComposeError.invalidProject("service '\(service.name)' \(kind.singularName) '\(grant.source)' mode must be an octal file mode between 0000 and 0777")
}

/// Extracts the host environment variable name for an environment-backed grant.
func composeFileGrantEnvironmentVariable(
    _ value: ComposeValue,
    grant: ComposeFileGrant,
    service: ComposeService,
    kind: ComposeFileMountKind,
) throws -> String {
    guard let name = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' environment-backed \(kind.singularName) '\(grant.source)' must name a host environment variable")
    }
    return name
}

/// Builds a deterministic materialized file path for a config or secret value.
private func materializedComposeFile(
    contents: String,
    permissions: Int,
    grant: ComposeFileGrant,
    context: ComposeFileGrantSourceContext,
) -> ComposeMaterializedFile {
    let digest = stableHash("\(String(permissions, radix: 8))\n\(contents)")
    let directory = materializedProjectDirectory(
        project: context.project,
        root: context.materializedConfigSecretRoot,
    ).appendingPathComponent(context.kind.pluralName, isDirectory: true)
    let filename = "\(slug(grant.source))-\(digest.prefix(16))"
    return ComposeMaterializedFile(
        url: directory.appendingPathComponent(filename, isDirectory: false),
        contents: Data(contents.utf8),
        permissions: permissions,
    )
}

/// Resolves the configured runtime resource name for an external Compose file grant.
func externalComposeFileRuntimeName(
    project: ComposeProject,
    composeName: String,
    fields: [String: ComposeValue],
    kind: ComposeFileMountKind,
) throws -> String {
    guard fields["external"]?.boolValue == true else {
        throw ComposeError.invalidProject("\(kind.singularName) '\(composeName)' is not external")
    }
    let declaredName = fields["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    return declaredResourceName(
        projectName: project.name,
        composeName: composeName,
        declaredName: declaredName ?? "",
        external: true,
    )
}

/// Returns the stable project-private file location for an external config or secret.
func materializedExternalComposeFileURL(
    grant: ComposeFileGrant,
    runtimeName: String,
    permissions: Int,
    context: ComposeFileGrantSourceContext,
) -> URL {
    let digest = stableHash("\(String(permissions, radix: 8))\n\(runtimeName)")
    let directory = materializedProjectDirectory(
        project: context.project,
        root: context.materializedConfigSecretRoot,
    ).appendingPathComponent(context.kind.pluralName, isDirectory: true)
    let filename = "\(slug(grant.source))-external-\(digest.prefix(16))"
    return directory.appendingPathComponent(filename, isDirectory: false)
}

/// Parses and validates supported `volumes_from` references.
func volumesFromReferences(
    service: ComposeService,
    project: ComposeProject,
) throws -> [ParsedVolumesFromReference] {
    try (service.volumesFrom ?? []).map {
        try parseVolumesFromReference($0, service: service, project: project)
    }
}

/// Parses one `volumes_from` entry.
func parseVolumesFromReference(
    _ rawValue: String,
    service: ComposeService,
    project: ComposeProject,
) throws -> ParsedVolumesFromReference {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from contains an empty reference")
    }

    if trimmed.hasPrefix("container:") {
        let containerReference = String(trimmed.dropFirst("container:".count))
        let parts = containerReference.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let containerName = parts.first ?? ""
        guard parts.count <= 2 else {
            throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' must use SERVICE[:ro|rw] or container:NAME[:ro|rw]")
        }
        let mode = parts.count == 2 ? parts[1] : nil
        let readOnly = try volumesFromReadOnlyMode(
            mode,
            rawValue: rawValue,
            service: service,
        )
        guard !containerName.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' is missing an external container name")
        }
        return ParsedVolumesFromReference(
            source: .externalContainer(containerName),
            readOnly: readOnly,
            rawValue: rawValue,
        )
    }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard let sourceName = parts.first, !sourceName.isEmpty else {
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' is missing a source service")
    }
    guard parts.count <= 2 else {
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' must use SERVICE[:ro|rw] or container:NAME[:ro|rw]")
    }
    guard project.services[sourceName] != nil else {
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' references unknown service '\(sourceName)'")
    }
    let readOnly = try volumesFromReadOnlyMode(parts.count == 2 ? parts[1] : nil, rawValue: rawValue, service: service)
    return ParsedVolumesFromReference(source: .service(sourceName), readOnly: readOnly, rawValue: rawValue)
}

/// Converts `volumes_from` access mode into the inherited mount readonly flag.
func volumesFromReadOnlyMode(
    _ mode: String?,
    rawValue: String,
    service: ComposeService,
) throws -> Bool? {
    guard let mode, !mode.isEmpty else {
        return nil
    }
    switch mode {
    case "ro", "readonly":
        return true
    case "rw":
        return false
    default:
        throw ComposeError.invalidProject("service '\(service.name)' volumes_from '\(rawValue)' mode must be ro or rw")
    }
}

/// Applies a `volumes_from` readonly override to an inherited mount.
func mount(_ mount: ComposeMount, applyingVolumesFromReadOnly readOnly: Bool?) -> ComposeMount {
    guard let readOnly else {
        return mount
    }
    var inherited = mount
    inherited.readOnly = readOnly
    return inherited
}
