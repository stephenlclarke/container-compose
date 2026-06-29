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

let composePsTemplateFields: Set<String> = [
    "ExitCode",
    "Health",
    "ID",
    "Image",
    "Name",
    "Ports",
    "Project",
    "Publishers",
    "Service",
    "State",
    "Status",
]
let composeVolumesTemplateFields: Set<String> = [
    "Availability",
    "Driver",
    "Group",
    "Labels",
    "Links",
    "Mountpoint",
    "Name",
    "Scope",
    "Size",
    "Status",
]

/// Validates the `compose ps --format` value.
func composePsFormat(_ value: String) throws -> ComposePsFormat {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized.lowercased() {
    case "table":
        return .table
    case "json":
        return .json
    default:
        let tablePrefix = "table "
        if normalized.lowercased().hasPrefix(tablePrefix) {
            let template = String(normalized.dropFirst(tablePrefix.count))
            try validateDockerTemplateActions(in: template)
            try validateDockerTemplateFields(
                dockerTemplateFields(in: template),
                command: "ps",
                supported: composePsTemplateFields,
            )
            return .template(template, table: true)
        }
        try validateDockerTemplateActions(in: normalized)
        try validateDockerTemplateFields(
            dockerTemplateFields(in: normalized),
            command: "ps",
            supported: composePsTemplateFields,
        )
        return .template(normalized, table: false)
    }
}

/// Output modes supported by `compose ps`.
enum ComposePsFormat {
    case table
    case json
    case template(String, table: Bool)
}

/// Renders project container rows as a compact Docker Compose-style table.
func renderComposeContainerTable(
    _ containers: [ComposeContainerSummary],
    noTrunc _: Bool,
) -> String {
    let rows = [
        ["NAME", "IMAGE", "SERVICE", "STATUS", "PORTS"],
    ] + containers.map { container in
        [
            container.id,
            container.imageReference,
            container.serviceName ?? "",
            container.status,
            renderComposePublishedPorts(container.publishedPorts),
        ]
    }
    let widths = rows.reduce(Array(repeating: 0, count: rows[0].count)) { current, row in
        zip(current, row).map { max($0, $1.count) }
    }
    return rows.map { row in
        row.enumerated().map { index, value in
            index == row.count - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

/// Renders project containers through a Docker-style field template.
func renderComposeContainerTemplate(
    _ containers: [ComposeContainerSummary],
    template: String,
    table: Bool,
    noTrunc: Bool,
) throws -> String {
    let fields = dockerTemplateFields(in: template)
    try validateDockerTemplateActions(in: template)
    try validateDockerTemplateFields(
        fields,
        command: "ps",
        supported: composePsTemplateFields,
    )
    let rows = try containers.map { container in
        try renderDockerTemplate(template) { field in
            switch field {
            case "ID":
                noTrunc ? container.id : truncatedDockerIdentifier(container.id)
            case "Name":
                container.id
            case "Image":
                container.imageReference
            case "ExitCode":
                container.exitCode.map(String.init) ?? ""
            case "Health":
                container.health ?? ""
            case "Ports":
                renderComposePublishedPorts(container.publishedPorts)
            case "Publishers":
                renderComposePublishedPorts(container.publishedPorts)
            case "Service":
                container.serviceName ?? ""
            case "State", "Status":
                container.status
            case "Project":
                container.projectName ?? ""
            default:
                throw unsupportedDockerTemplateField(field, command: "ps", supported: composePsTemplateFields)
            }
        }
    }
    return table ? renderDockerTemplateTable(fields: fields, rows: rows) : rows.joined(separator: "\n")
}

/// Renders published ports the way Docker Compose shows them in `ps`.
func renderComposePublishedPorts(_ ports: [ComposeContainerPublishedPort]) -> String {
    ports.flatMap { port in
        (0 ..< Int(port.count)).map { offset in
            let hostPort = Int(port.hostPort) + offset
            let containerPort = Int(port.containerPort) + offset
            let hostAddress = dockerPortHostAddress(port.hostAddress)
            return "\(hostAddress):\(hostPort)->\(containerPort)/\(port.protocolName)"
        }
    }.joined(separator: ", ")
}

func dockerPortHostAddress(_ hostAddress: String) -> String {
    guard hostAddress.contains(":"), !hostAddress.hasPrefix("[") else {
        return hostAddress
    }
    return "[\(hostAddress)]"
}

/// Mirrors Docker-style default identifier truncation.
func truncatedDockerIdentifier(_ id: String) -> String {
    guard id.count > 12 else {
        return id
    }
    return String(id.prefix(12))
}

/// Returns container IDs from a filtered direct API list.
func containerIdentifiers(_ containers: [ComposeContainerSummary]) -> [String] {
    containers.map(\.id)
}

/// Applies `compose ps --orphans` using service labels from the normalized model.
func filterContainersByOrphanPolicy(
    _ containers: [ComposeContainerSummary],
    project: ComposeProject,
    includeOrphans: Bool,
) -> [ComposeContainerSummary] {
    guard !includeOrphans else {
        return containers
    }
    let serviceNames = Set(project.services.keys)
    return containers.filter { container in
        guard let serviceName = container.serviceName else {
            return false
        }
        return serviceNames.contains(serviceName)
    }
}

/// Returns unique service names from a filtered direct API list.
func containerServiceNames(_ containers: [ComposeContainerSummary]) -> [String] {
    let namesByContainer = containers.compactMap { container -> (identifier: String, service: String)? in
        guard let service = container.serviceName, !service.isEmpty else {
            return nil
        }
        return (container.id, service)
    }
    var seen: Set<String> = []
    var services: [String] = []
    for entry in namesByContainer.sorted(by: { $0.identifier < $1.identifier }) {
        if seen.insert(entry.service).inserted {
            services.append(entry.service)
        }
    }
    return services
}

/// Returns project rows from direct API containers, optionally filtered by project name.
func composeProjectRecords(containers: [ComposeContainerSummary], nameFilters: [String]) -> [ComposeProjectRecord] {
    let containers = composeLabeledContainers(containers)
    let grouped = Dictionary(grouping: containers) { $0.projectName ?? "" }
    return grouped.keys.sorted().compactMap { projectName in
        guard !projectName.isEmpty, lsProjectNameMatches(projectName, filters: nameFilters) else {
            return nil
        }
        let projectContainers = grouped[projectName] ?? []
        return ComposeProjectRecord(
            name: projectName,
            status: combinedProjectStatus(projectContainers),
            configFiles: combinedProjectConfigFiles(projectContainers),
        )
    }
}

/// Returns direct API containers carrying the labels needed to identify Compose projects.
func composeLabeledContainers(_ containers: [ComposeContainerSummary]) -> [ComposeContainerSummary] {
    containers.filter { $0.projectName != nil && $0.configHash != nil }
}

/// Combines direct API container states into Docker Compose's `state(count)` form.
func combinedProjectStatus(_ containers: [ComposeContainerSummary]) -> String {
    let statuses = containers.map { $0.status.lowercased() }
    let counts = Dictionary(grouping: statuses, by: { $0 }).mapValues(\.count)
    return counts.keys.sorted().map { "\($0)(\(counts[$0] ?? 0))" }.joined(separator: ", ")
}

/// Combines config-file labels across direct API containers while preserving first-seen order.
func combinedProjectConfigFiles(_ containers: [ComposeContainerSummary]) -> String {
    var seen: Set<String> = []
    var files: [String] = []
    for container in containers {
        let values = [
            container.labels[configFilesLabel],
            container.labels["com.apple.container.compose.project.config-file"],
        ].compactMap(\.self)
        for value in values {
            for file in value.split(separator: ",").map(String.init) where !file.isEmpty && seen.insert(file).inserted {
                files.append(file)
            }
        }
    }
    return files.isEmpty ? "N/A" : files.joined(separator: ",")
}

/// Returns image rows from direct API containers scoped by Compose labels.
func composeImageRecords(containers: [ComposeContainerSummary], selectedServices: Set<String>?) -> [ComposeImageRecord] {
    containers.compactMap { container in
        guard let service = container.serviceName, !service.isEmpty else {
            return nil
        }
        if let selectedServices, !selectedServices.contains(service) {
            return nil
        }
        guard !container.imageReference.isEmpty else {
            return nil
        }
        let reference = splitImageReference(container.imageReference)
        return ComposeImageRecord(
            container: container.id,
            service: service,
            repository: reference.repository,
            tag: reference.tag,
            platform: container.platform,
            imageID: shortImageID(container.imageDigest),
        )
    }
    .sorted { lhs, rhs in
        if lhs.container == rhs.container {
            return lhs.service < rhs.service
        }
        return lhs.container < rhs.container
    }
}

/// Applies status filtering after direct API project scoping.
func filterContainersByStatus(_ containers: [ComposeContainerSummary], statuses: Set<String>) -> [ComposeContainerSummary] {
    guard !statuses.isEmpty else {
        return containers
    }
    return containers.filter { statuses.contains($0.status.lowercased()) }
}

/// Filters direct API containers by Compose project label.
func filterProjectContainers(projectName: String, containers: [ComposeContainerSummary]) -> [ComposeContainerSummary] {
    containers.filter { $0.projectName == projectName }
}

/// Applies positional `compose ps SERVICE...` filtering after project scoping.
func filterContainersByService(_ containers: [ComposeContainerSummary], services: Set<String>?) -> [ComposeContainerSummary] {
    guard let services else {
        return containers
    }
    return containers.filter { container in
        guard let serviceName = container.serviceName else {
            return false
        }
        return services.contains(serviceName)
    }
}

/// Interprets direct runtime state for Compose wait-until-running operations.
func startWaitState(_ container: ComposeContainerSummary) -> ComposeStartWaitState {
    switch container.health?.lowercased() {
    case "healthy":
        return .ready
    case "starting":
        return .pending
    case "unhealthy":
        return .failed("is unhealthy")
    case .some("none"), nil:
        break
    case let health?:
        return .failed("has unsupported health status '\(health)'")
    }

    switch container.status.lowercased() {
    case "running":
        return .ready
    case "created", "creating", "starting", "stopping", "unknown":
        return .pending
    case "stopped":
        return .failed("is stopped")
    default:
        return .failed("is \(container.status)")
    }
}

enum ComposeStartWaitState {
    case ready
    case pending
    case failed(String)
}

/// Returns true when a discovered normal service container matches an ID.
func serviceContainerExists(_ containers: [ComposeContainerSummary], service: ComposeService, id: String) -> Bool {
    containers.contains { container in
        container.id == id && container.serviceName == service.name && !container.isOneOff
    }
}

/// Orders normal service containers before one-off `run` containers for `cp --all`.
func compareCopyTargetContainers(_ lhs: ComposeContainerSummary, _ rhs: ComposeContainerSummary) -> Bool {
    if lhs.isOneOff != rhs.isOneOff {
        return !lhs.isOneOff
    }
    return lhs.id < rhs.id
}

/// Validates the `compose ls --format` value.
func composeLsFormat(_ value: String) throws -> ComposeLsFormat {
    switch value.lowercased() {
    case "table":
        return .table
    case "json":
        return .json
    default:
        throw ComposeError.unsupported("ls --format '\(value)'; supported formats are table and json")
    }
}

/// Output modes supported by `compose ls`.
enum ComposeLsFormat {
    case table
    case json
}

/// One Docker Compose-style project row derived from labeled containers.
struct ComposeProjectRecord: Encodable, Equatable {
    let name: String
    let status: String
    let configFiles: String
}

/// Parses `compose ls --filter` values. Docker Compose currently accepts only `name`.
func lsNameFilters(_ filters: [String]) throws -> [String] {
    try filters.map { filter in
        let parts = filter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw ComposeError.invalidProject("ls --filter must be in KEY=VALUE form")
        }
        let key = String(parts[0])
        let value = String(parts[1])
        guard key == "name" else {
            throw ComposeError.unsupported("ls --filter \(key); supported filter is name")
        }
        guard !value.isEmpty else {
            throw ComposeError.invalidProject("ls --filter name requires a value")
        }
        return value
    }
}

/// Applies Docker Compose's exact-name or regular-expression project name matching.
func lsProjectNameMatches(_ name: String, filters: [String]) -> Bool {
    guard !filters.isEmpty else {
        return true
    }
    return filters.contains { filter in
        if name == filter {
            return true
        }
        return name.range(of: filter, options: .regularExpression) != nil
    }
}

/// Renders project rows as a compact table.
func renderComposeProjectTable(_ records: [ComposeProjectRecord]) -> String {
    guard !records.isEmpty else {
        return ""
    }
    let rows = [
        ["NAME", "STATUS", "CONFIG FILES"],
    ] + records.map { [$0.name, $0.status, $0.configFiles] }
    let widths = rows.reduce(Array(repeating: 0, count: rows[0].count)) { current, row in
        zip(current, row).map { max($0, $1.count) }
    }
    return rows.map { row in
        row.enumerated().map { index, value in
            index == row.count - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

/// Renders project rows as deterministic JSON.
func renderComposeProjectJSON(_ records: [ComposeProjectRecord]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(records)
    return String(decoding: data, as: UTF8.self)
}

/// Validates the `compose images --format` value.
func composeImagesFormat(_ value: String) throws -> ComposeImagesFormat {
    switch value.lowercased() {
    case "table":
        return .table
    case "json":
        return .json
    default:
        throw ComposeError.unsupported("images --format '\(value)'; supported formats are table and json")
    }
}

/// One Docker Compose-style image row derived from a created project container.
struct ComposeImageRecord: Encodable, Equatable {
    let container: String
    let service: String
    let repository: String
    let tag: String
    let platform: String
    let imageID: String
}

/// One Docker Compose-style volume row derived from apple/container volumes.
struct ComposeVolumeRecord: Encodable, Equatable {
    let availability: String
    let driver: String
    let group: String
    let labels: String
    let links: String
    let mountpoint: String
    let name: String
    let scope: String
    let size: String
    let status: String

    init(summary: ComposeVolumeSummary) {
        self.init(
            driver: summary.driver,
            labels: summary.labels,
            mountpoint: summary.source,
            name: summary.name,
            sizeInBytes: summary.sizeInBytes,
        )
    }

    init(
        driver: String,
        labels: [String: String] = [:],
        mountpoint: String = "",
        name: String,
        scope: String = "local",
        sizeInBytes: UInt64? = nil,
    ) {
        availability = "N/A"
        self.driver = driver
        group = "N/A"
        self.labels = labels
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        links = "N/A"
        self.mountpoint = mountpoint.isEmpty ? "N/A" : mountpoint
        self.name = name
        self.scope = scope
        size = sizeInBytes.map(String.init) ?? "N/A"
        status = "N/A"
    }

    enum CodingKeys: String, CodingKey {
        case availability = "Availability"
        case driver = "Driver"
        case group = "Group"
        case labels = "Labels"
        case links = "Links"
        case mountpoint = "Mountpoint"
        case name = "Name"
        case scope = "Scope"
        case size = "Size"
        case status = "Status"
    }
}

/// Renders image rows as a compact table.
func renderComposeImageTable(_ records: [ComposeImageRecord]) -> String {
    let rows = [
        ["CONTAINER", "REPOSITORY", "TAG", "IMAGE ID", "PLATFORM"],
    ] + records.map { record in
        [record.container, record.repository, record.tag, record.imageID.isEmpty ? "<none>" : record.imageID, record.platform]
    }
    let widths = rows.reduce(Array(repeating: 0, count: rows[0].count)) { current, row in
        zip(current, row).map { max($0, $1.count) }
    }
    return rows.map { row in
        row.enumerated().map { index, value in
            index == row.count - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

/// Renders image rows as deterministic JSON.
func renderComposeImageJSON(_ records: [ComposeImageRecord]) throws -> String {
    guard !records.isEmpty else {
        return "null"
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(records)
    return String(decoding: data, as: UTF8.self)
}

/// Validates the `compose volumes --format` value.
func composeVolumesFormat(_ value: String) throws -> ComposeVolumesFormat {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized.lowercased() {
    case "table":
        return .table
    case "json":
        return .json
    default:
        let tablePrefix = "table "
        if normalized.lowercased().hasPrefix(tablePrefix) {
            let template = String(normalized.dropFirst(tablePrefix.count))
            try validateDockerTemplateActions(in: template)
            try validateDockerTemplateFields(dockerTemplateFields(in: template), command: "volumes", supported: composeVolumesTemplateFields)
            return .template(template, table: true)
        }
        try validateDockerTemplateActions(in: normalized)
        try validateDockerTemplateFields(dockerTemplateFields(in: normalized), command: "volumes", supported: composeVolumesTemplateFields)
        return .template(normalized, table: false)
    }
}

/// Renders volume rows as a compact table.
func renderComposeVolumeTable(_ records: [ComposeVolumeRecord]) -> String {
    let rows = [
        ["DRIVER", "VOLUME NAME"],
    ] + records.map { [$0.driver, $0.name] }
    let widths = rows.reduce(Array(repeating: 0, count: rows[0].count)) { current, row in
        zip(current, row).map { max($0, $1.count) }
    }
    return rows.map { row in
        row.enumerated().map { index, value in
            index == row.count - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

/// Renders Compose volumes through a Docker-style field template.
func renderComposeVolumeTemplate(_ records: [ComposeVolumeRecord], template: String, table: Bool) throws -> String {
    let fields = dockerTemplateFields(in: template)
    try validateDockerTemplateActions(in: template)
    try validateDockerTemplateFields(fields, command: "volumes", supported: composeVolumesTemplateFields)
    let rows = try records.map { record in
        try renderDockerTemplate(template) { field in
            switch field {
            case "Availability":
                record.availability
            case "Driver":
                record.driver
            case "Group":
                record.group
            case "Labels":
                record.labels
            case "Links":
                record.links
            case "Mountpoint":
                record.mountpoint
            case "Name":
                record.name
            case "Scope":
                record.scope
            case "Size":
                record.size
            case "Status":
                record.status
            default:
                throw unsupportedDockerTemplateField(field, command: "volumes", supported: composeVolumesTemplateFields)
            }
        }
    }
    return table ? renderComposeVolumeTemplateTable(fields: fields, rows: rows) : rows.joined(separator: "\n")
}

/// Renders volume template table rows with Docker Compose's volume headers.
func renderComposeVolumeTemplateTable(fields: [String], rows: [String]) -> String {
    guard !rows.isEmpty else {
        return ""
    }
    guard !fields.isEmpty else {
        return rows.joined(separator: "\n")
    }
    let headers = fields.map { field in
        field == "Name" ? "VOLUME NAME" : field.uppercased()
    }
    let tableRows = [headers] + rows.map { row in
        let columns = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return columns.count == fields.count ? columns : [row]
    }
    return renderTable(tableRows)
}

/// Renders volume rows as deterministic newline-delimited Docker-style JSON.
func renderComposeVolumeJSON(_ records: [ComposeVolumeRecord]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try records.map { record in
        let data = try encoder.encode(record)
        return String(decoding: data, as: UTF8.self)
    }.joined(separator: "\n")
}

/// Splits a container image reference into repository and tag display fields.
func splitImageReference(_ reference: String) -> (repository: String, tag: String) {
    let withoutDigest = reference.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? reference
    guard let lastColon = withoutDigest.lastIndex(of: ":") else {
        return (withoutDigest, "<none>")
    }
    if let lastSlash = withoutDigest.lastIndex(of: "/"), lastColon < lastSlash {
        return (withoutDigest, "<none>")
    }
    return (String(withoutDigest[..<lastColon]), String(withoutDigest[withoutDigest.index(after: lastColon)...]))
}

/// Returns the short Docker-style image ID without an algorithm prefix.
func shortImageID(_ digest: String?) -> String {
    guard var digest, !digest.isEmpty else {
        return ""
    }
    if let colonIndex = digest.firstIndex(of: ":") {
        digest = String(digest[digest.index(after: colonIndex)...])
    }
    return String(digest.prefix(12))
}

/// Returns whether `compose rm` may remove a container without `--stop`.
func isRemovableStoppedContainerStatus(_ status: String) -> Bool {
    switch status.lowercased() {
    case "created", "dead", "exited", "stopped":
        true
    default:
        false
    }
}

/// Combines `ps --status` and `ps --filter status=...` into runtime state values.
func psStatusFilters(statuses: [String], filters: [String]) throws -> Set<String> {
    var requestedStatuses = statuses
    for filter in filters {
        let parts = filter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw ComposeError.invalidProject("ps --filter must be in KEY=VALUE form")
        }
        let key = String(parts[0])
        let value = String(parts[1])
        guard key == "status" else {
            throw ComposeError.unsupported("ps --filter \(key); supported filter is status")
        }
        guard !value.isEmpty else {
            throw ComposeError.invalidProject("ps --filter status requires a value")
        }
        requestedStatuses.append(value)
    }
    return try Set(requestedStatuses.map(normalizedRuntimeStatus))
}

/// Maps Compose status vocabulary onto states exposed by `apple/container`.
func normalizedRuntimeStatus(_ status: String) throws -> String {
    switch status.lowercased() {
    case "paused", "running", "stopped", "stopping", "unknown":
        return status.lowercased()
    case "exited":
        return "stopped"
    default:
        throw ComposeError.unsupported("ps status '\(status)'; apple/container exposes paused, running, stopped, stopping, and unknown")
    }
}
