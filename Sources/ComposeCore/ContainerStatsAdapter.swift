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

import ContainerAPIClient
import ContainerResource
import Foundation

private let composeStatsTemplateFields: Set<String> = [
    "BlockIO",
    "CPUPerc",
    "Container",
    "ID",
    "MemUsage",
    "Name",
    "NetIO",
    "PIDs",
]

/// Validates the `compose stats --format` value.
func validateComposeStatsFormat(_ value: String) throws {
    _ = try composeStatsFormat(value)
}

/// Container identity and status needed before collecting direct API stats.
public struct ComposeStatsTarget: Sendable, Equatable {
    public var id: String
    public var status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

/// Low-level apple/container stats calls used by `ContainerClientStatsManager`.
public protocol ContainerStatsAPIClienting: Sendable {
    /// Lists the requested containers before stats collection.
    func listStatsTargets(ids: [String]) async throws -> [ComposeStatsTarget]

    /// Returns one statistics snapshot for container `id`.
    func stats(id: String) async throws -> ContainerStats
}

/// Direct apple/container API used for service container stats.
public protocol ContainerStatsManaging: Sendable {
    /// Emits stats for the requested service container ids.
    func stats(
        ids: [String],
        format: String,
        noStream: Bool,
        noTrunc: Bool,
        includeStopped: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws
}

/// Thin apple/container client wrapper around stats API calls.
public struct ContainerStatsAPIClient: ContainerStatsAPIClienting {
    public typealias List = @Sendable ([String]) async throws -> [ComposeStatsTarget]
    public typealias Stats = @Sendable (String) async throws -> ContainerStats

    private let listOperation: List
    private let statsOperation: Stats

    public init(
        list: @escaping List = {
            try await ContainerClient().list(filters: ContainerListFilters(ids: $0).withoutMachines())
                .map { ComposeStatsTarget(id: $0.id, status: $0.status.rawValue) }
        },
        stats: @escaping Stats = { try await ContainerClient().stats(id: $0) }
    ) {
        self.listOperation = list
        self.statsOperation = stats
    }

    /// Lists stat targets through `ContainerClient`.
    public func listStatsTargets(ids: [String]) async throws -> [ComposeStatsTarget] {
        try await listOperation(ids)
    }

    /// Reads one stats snapshot through `ContainerClient`.
    public func stats(id: String) async throws -> ContainerStats {
        try await statsOperation(id)
    }
}

/// `ContainerClient`-backed stats manager for service containers.
public struct ContainerClientStatsManager: ContainerStatsManaging {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let client: ContainerStatsAPIClienting
    private let sampleInterval: Duration
    private let sampleIntervalMicroseconds: UInt64
    private let sleep: Sleeper

    public init(
        client: ContainerStatsAPIClienting = ContainerStatsAPIClient(),
        sampleInterval: Duration = .seconds(2),
        sampleIntervalMicroseconds: UInt64 = 2_000_000,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.sampleInterval = sampleInterval
        self.sampleIntervalMicroseconds = sampleIntervalMicroseconds
        self.sleep = sleep
    }

    /// Emits direct API stats, streaming table output unless static output is requested.
    public func stats(
        ids: [String],
        format: String,
        noStream: Bool,
        noTrunc: Bool,
        includeStopped: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        let parsedFormat = try composeStatsFormat(format)
        if !parsedFormat.isStreamingTable || noStream {
            let records = try await collectStats(ids: ids, includeStopped: includeStopped)
            emit(try renderStats(records, format: parsedFormat, noTrunc: noTrunc))
            return
        }

        emit("\u{001B}[?1049h\u{001B}[?25l")
        defer {
            emit("\u{001B}[?25h\u{001B}[?1049l")
        }

        emit("\u{001B}[H\u{001B}[J" + renderStatsTable([], noTrunc: noTrunc))
        while !Task.isCancelled {
            let records = try await collectStats(ids: ids, includeStopped: includeStopped)
            emit("\u{001B}[H\u{001B}[J" + renderStatsTable(records, noTrunc: noTrunc))
            try await sleep(sampleInterval)
        }
    }

    /// Collects two samples for running containers so CPU percentages are meaningful.
    private func collectStats(ids: [String], includeStopped: Bool) async throws -> [StatsSnapshot] {
        let targets = try await validatedTargets(ids: ids)
        var snapshots: [StatsSnapshot] = []

        for target in targets {
            guard target.status == "running" else {
                if includeStopped {
                    let stats = unavailableStats(id: target.id)
                    snapshots.append(StatsSnapshot(first: stats, second: stats, refresh: false))
                }
                continue
            }
            let stats = try await client.stats(id: target.id)
            snapshots.append(StatsSnapshot(first: stats, second: stats, refresh: true))
        }

        if snapshots.contains(where: \.refresh) {
            try await sleep(sampleInterval)
            for index in snapshots.indices {
                if snapshots[index].refresh {
                    snapshots[index].second = try await client.stats(id: snapshots[index].second.id)
                }
            }
        }

        return snapshots
    }

    /// Builds an empty stat record for stopped containers included by `--all`.
    private func unavailableStats(id: String) -> ContainerStats {
        ContainerStats(
            id: id,
            memoryUsageBytes: nil,
            memoryLimitBytes: nil,
            cpuUsageUsec: nil,
            networkRxBytes: nil,
            networkTxBytes: nil,
            blockReadBytes: nil,
            blockWriteBytes: nil,
            numProcesses: nil
        )
    }

    /// Mirrors the apple/container CLI check that every named container exists.
    private func validatedTargets(ids: [String]) async throws -> [ComposeStatsTarget] {
        let targets = try await client.listStatsTargets(ids: ids)
        let foundIDs = Set(targets.map(\.id))
        for id in ids where !foundIDs.contains(id) {
            throw ComposeError.invalidProject("no such container: \(id)")
        }
        return targets
    }

    /// Renders the direct stats payload in a supported format.
    private func renderStats(_ records: [StatsSnapshot], format: ComposeStatsFormat, noTrunc: Bool) throws -> String {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records.map(\.second))
            return String(decoding: data, as: UTF8.self)
        case .table:
            return renderStatsTable(records, noTrunc: noTrunc)
        case .template(let template, let table):
            return try renderStatsTemplate(records, template: template, table: table, noTrunc: noTrunc)
        }
    }

    /// Renders stats rows with the same columns as `container stats`.
    private func renderStatsTable(_ records: [StatsSnapshot], noTrunc: Bool) -> String {
        let headerRow = ["Container ID", "Cpu %", "Memory Usage", "Net Rx/Tx", "Block I/O", "Pids"]
        let rows = [headerRow] + records.map { statsTableRow($0, noTrunc: noTrunc) }
        return renderTable(rows)
    }

    /// Projects one stats snapshot pair into display columns.
    private func statsTableRow(_ snapshot: StatsSnapshot, noTrunc: Bool) -> [String] {
        let display = statsDisplayValues(snapshot, noTrunc: noTrunc)
        return [
            display.container,
            display.cpuPercent,
            "\(display.memoryUsage) / \(display.memoryLimit)",
            "\(display.networkRx) / \(display.networkTx)",
            "\(display.blockRead) / \(display.blockWrite)",
            display.pids,
        ]
    }

    /// Projects one stats snapshot pair into template fields.
    private func statsTemplateValue(_ field: String, snapshot: StatsSnapshot, noTrunc: Bool) throws -> String {
        let display = statsDisplayValues(snapshot, noTrunc: noTrunc)
        switch field {
        case "Container", "ID", "Name":
            return display.container
        case "CPUPerc":
            return display.cpuPercent
        case "MemUsage":
            return "\(display.memoryUsage) / \(display.memoryLimit)"
        case "NetIO":
            return "\(display.networkRx) / \(display.networkTx)"
        case "BlockIO":
            return "\(display.blockRead) / \(display.blockWrite)"
        case "PIDs":
            return display.pids
        default:
            throw unsupportedDockerTemplateField(field, command: "stats", supported: composeStatsTemplateFields)
        }
    }

    /// Renders stats rows through a Docker-style field template.
    private func renderStatsTemplate(_ records: [StatsSnapshot], template: String, table: Bool, noTrunc: Bool) throws -> String {
        let fields = dockerTemplateFields(in: template)
        try validateDockerTemplateActions(in: template)
        try validateDockerTemplateFields(fields, command: "stats", supported: composeStatsTemplateFields)
        let rows = try records.map { snapshot in
            try renderDockerTemplate(template) { field in
                try statsTemplateValue(field, snapshot: snapshot, noTrunc: noTrunc)
            }
        }
        return table ? renderDockerTemplateTable(fields: fields, rows: rows) : rows.joined(separator: "\n")
    }

    /// Projects one stats snapshot pair into display values.
    private func statsDisplayValues(_ snapshot: StatsSnapshot, noTrunc: Bool) -> StatsDisplayValues {
        let first = snapshot.first
        let second = snapshot.second
        let notAvailable = "--"
        let cpuPercent = cpuPercent(first: first.cpuUsageUsec, second: second.cpuUsageUsec)
            .map { String(format: "%.2f%%", $0) } ?? notAvailable
        let memoryUsage = second.memoryUsageBytes.map(formatBytes) ?? notAvailable
        let memoryLimit = second.memoryLimitBytes.map(formatBytes) ?? notAvailable
        let networkRx = second.networkRxBytes.map(formatBytes) ?? notAvailable
        let networkTx = second.networkTxBytes.map(formatBytes) ?? notAvailable
        let blockRead = second.blockReadBytes.map(formatBytes) ?? notAvailable
        let blockWrite = second.blockWriteBytes.map(formatBytes) ?? notAvailable
        let pids = second.numProcesses.map(String.init) ?? notAvailable

        return StatsDisplayValues(
            container: noTrunc ? second.id : truncatedContainerID(second.id),
            cpuPercent: cpuPercent,
            memoryUsage: memoryUsage,
            memoryLimit: memoryLimit,
            networkRx: networkRx,
            networkTx: networkTx,
            blockRead: blockRead,
            blockWrite: blockWrite,
            pids: pids
        )
    }

    /// Mirrors Docker-style table truncation for container identifiers.
    private func truncatedContainerID(_ id: String) -> String {
        guard id.count > 12 else {
            return id
        }
        return String(id.prefix(12))
    }

    /// Computes CPU percentage from two microsecond counters.
    private func cpuPercent(first: UInt64?, second: UInt64?) -> Double? {
        guard let first, let second else {
            return nil
        }
        let delta = second > first ? second - first : 0
        return (Double(delta) / Double(sampleIntervalMicroseconds)) * 100.0
    }

    /// Formats bytes like the apple/container `container stats` command.
    private func formatBytes(_ bytes: UInt64) -> String {
        let kib = 1024.0
        let mib = kib * 1024.0
        let gib = mib * 1024.0
        let value = Double(bytes)

        if value >= gib {
            return String(format: "%.2f GiB", value / gib)
        }
        if value >= mib {
            return String(format: "%.2f MiB", value / mib)
        }
        return String(format: "%.2f KiB", value / kib)
    }
}

private enum ComposeStatsFormat {
    case table
    case json
    case template(String, table: Bool)

    var isStreamingTable: Bool {
        if case .table = self {
            return true
        }
        return false
    }
}

private struct StatsDisplayValues {
    var container: String
    var cpuPercent: String
    var memoryUsage: String
    var memoryLimit: String
    var networkRx: String
    var networkTx: String
    var blockRead: String
    var blockWrite: String
    var pids: String
}

/// Two samples for one container, used to calculate rate-based fields.
private struct StatsSnapshot {
    var first: ContainerStats
    var second: ContainerStats
    var refresh: Bool
}

private func composeStatsFormat(_ value: String) throws -> ComposeStatsFormat {
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
            try validateDockerTemplateFields(dockerTemplateFields(in: template), command: "stats", supported: composeStatsTemplateFields)
            return .template(template, table: true)
        }
        try validateDockerTemplateActions(in: normalized)
        try validateDockerTemplateFields(dockerTemplateFields(in: normalized), command: "stats", supported: composeStatsTemplateFields)
        return .template(normalized, table: false)
    }
}
