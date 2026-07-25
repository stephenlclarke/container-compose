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

import ComposeCore
import ComposeRuntimeSPI
import ContainerAPIClient
import ContainerResource
import Foundation

private let composeStatsTemplateFields: Set<String> = [
    "BlockIO",
    "CPUPerc",
    "Container",
    "ID",
    "MemPerc",
    "MemUsage",
    "Name",
    "NetIO",
    "PIDs",
]

/// Low-level apple/container stats calls used by `ContainerClientStatsManager`.
public protocol ContainerStatsAPIClienting: Sendable {
    /// Lists the requested containers before stats collection.
    func listStatsTargets(ids: [String]) async throws -> [ComposeStatsTarget]

    /// Returns one statistics snapshot for container `id`.
    func stats(id: String) async throws -> ContainerStats
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
        stats: @escaping Stats = { try await ContainerClient().stats(id: $0) },
    ) {
        listOperation = list
        statsOperation = stats
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
public struct ContainerClientStatsManager: ComposeRuntimeStatsDataManaging {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let client: ContainerStatsAPIClienting
    private let sampleInterval: Duration
    private let sampleIntervalMicroseconds: UInt64
    private let sleep: Sleeper

    public init(
        client: ContainerStatsAPIClienting = ContainerStatsAPIClient(),
        sampleInterval: Duration = .seconds(2),
        sampleIntervalMicroseconds: UInt64 = 2_000_000,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
    ) {
        self.client = client
        self.sampleInterval = sampleInterval
        self.sampleIntervalMicroseconds = sampleIntervalMicroseconds
        self.sleep = sleep
    }

    // swiftlint:disable function_parameter_count
    /// Emits direct API stats, streaming table output unless static output is requested.
    public func stats(
        ids: [String],
        format: String,
        noStream: Bool,
        noTrunc: Bool,
        includeStopped: Bool,
        emit: @escaping @Sendable (String) -> Void,
    ) async throws {
        try await stats(
            ids: ids,
            format: format,
            noStream: noStream,
            noTrunc: noTrunc,
            includeStopped: includeStopped,
            emit: emit,
            emitData: { data in
                // Legacy String callback intentionally replaces partial UTF-8.
                // swiftlint:disable:next optional_data_string_conversion
                emit(String(decoding: Array(data), as: UTF8.self))
            },
        )
    }

    // swiftlint:enable function_parameter_count

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
            for index in snapshots.indices where snapshots[index].refresh {
                snapshots[index].second = try await client.stats(id: snapshots[index].second.id)
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
            numProcesses: nil,
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
    private func renderStatsData(
        _ records: [StatsSnapshot],
        format: ComposeStatsFormat,
        noTrunc: Bool,
    ) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let output = try records.map { snapshot in
                let data = try encoder.encode(statsJSONObject(snapshot, noTrunc: noTrunc))
                guard let output = String(data: data, encoding: .utf8) else {
                    throw ComposeError.invalidProject("failed to encode Compose stats JSON")
                }
                return output
            }.joined(separator: "\n")
            return Data(output.utf8)
        case .table:
            return Data(renderStatsTable(records, noTrunc: noTrunc).utf8)
        case let .template(template, table):
            return try renderStatsTemplateData(
                records,
                template: template,
                table: table,
                noTrunc: noTrunc,
            )
        }
    }

    /// Renders stats rows with Docker Compose-style columns.
    private func renderStatsTable(_ records: [StatsSnapshot], noTrunc: Bool) -> String {
        let headerRow = ["CONTAINER ID", "CPU %", "MEM USAGE / LIMIT", "MEM %", "NET I/O", "BLOCK I/O", "PIDS"]
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
            display.memoryPercent,
            "\(display.networkRx) / \(display.networkTx)",
            "\(display.blockRead) / \(display.blockWrite)",
            display.pids,
        ]
    }

    /// Renders stats rows through a Docker-style field template.
    private func renderStatsTemplateData(
        _ records: [StatsSnapshot],
        template: String,
        table: Bool,
        noTrunc: Bool,
    ) throws -> Data {
        let fields = dockerTemplateFields(in: template)
        try validateDockerTemplateActions(in: template)
        try validateDockerTemplateFields(fields, command: "stats", supported: composeStatsTemplateFields)
        let rows = try records.map { snapshot in
            try renderDockerTemplateData(
                template,
                values: statsTemplateValues(snapshot, noTrunc: noTrunc),
            )
        }
        let headers = [
            "BlockIO": "BLOCK I/O",
            "CPUPerc": "CPU %",
            "Container": "CONTAINER ID",
            "ID": "CONTAINER ID",
            "MemPerc": "MEM %",
            "MemUsage": "MEM USAGE / LIMIT",
            "Name": "NAME",
            "NetIO": "NET I/O",
            "PIDs": "PIDS",
        ]
        return try table
            ? renderDockerTemplateTableData(
                template: template,
                headers: headers,
                rows: rows,
            )
            : joinedDockerTemplateData(rows)
    }

    /// Projects one stats snapshot pair into display values.
    private func statsDisplayValues(_ snapshot: StatsSnapshot, noTrunc: Bool) -> StatsDisplayValues {
        let first = snapshot.first
        let second = snapshot.second
        let notAvailable = "--"
        let cpuPercent = cpuPercent(first: first.cpuUsageUsec, second: second.cpuUsageUsec)
            .map { String(format: "%.2f%%", $0) } ?? notAvailable
        let memoryUsage = second.memoryUsageBytes.map(formatDockerMemoryBytes) ?? notAvailable
        let memoryLimit = second.memoryLimitBytes.map(formatDockerMemoryBytes) ?? notAvailable
        let memoryPercent = memoryPercent(usage: second.memoryUsageBytes, limit: second.memoryLimitBytes)
            .map { String(format: "%.2f%%", $0) } ?? notAvailable
        let networkRx = second.networkRxBytes.map(formatDockerIOBytes) ?? notAvailable
        let networkTx = second.networkTxBytes.map(formatDockerIOBytes) ?? notAvailable
        let blockRead = second.blockReadBytes.map(formatDockerIOBytes) ?? notAvailable
        let blockWrite = second.blockWriteBytes.map(formatDockerIOBytes) ?? notAvailable
        let pids = second.numProcesses.map(String.init) ?? notAvailable

        return StatsDisplayValues(
            container: noTrunc ? second.id : truncatedContainerID(second.id),
            cpuPercent: cpuPercent,
            memoryUsage: memoryUsage,
            memoryLimit: memoryLimit,
            memoryPercent: memoryPercent,
            networkRx: networkRx,
            networkTx: networkTx,
            blockRead: blockRead,
            blockWrite: blockWrite,
            pids: pids,
        )
    }

    /// Mirrors Docker-style table truncation for container identifiers.
    private func truncatedContainerID(_ id: String) -> String {
        guard id.count > 12 else {
            return id
        }
        return String(id.prefix(12))
    }

    /// Renders one Docker Compose-style stats JSON object.
    private func statsJSONObject(_ snapshot: StatsSnapshot, noTrunc: Bool) -> [String: String] {
        let display = statsDisplayValues(snapshot, noTrunc: noTrunc)
        return [
            "BlockIO": "\(display.blockRead) / \(display.blockWrite)",
            "CPUPerc": display.cpuPercent,
            "Container": snapshot.second.id,
            "ID": display.container,
            "MemPerc": display.memoryPercent,
            "MemUsage": "\(display.memoryUsage) / \(display.memoryLimit)",
            "Name": snapshot.second.id,
            "NetIO": "\(display.networkRx) / \(display.networkTx)",
            "PIDs": display.pids,
        ]
    }

    /// Keeps custom templates aligned with the pre-existing table field values.
    ///
    /// JSON output intentionally retains the runtime identifier in `Container`
    /// and `Name`; a custom template historically rendered all three identifier
    /// aliases through the display/truncation policy.
    private func statsTemplateValues(_ snapshot: StatsSnapshot, noTrunc: Bool) -> [String: String] {
        var values = statsJSONObject(snapshot, noTrunc: noTrunc)
        let container = statsDisplayValues(snapshot, noTrunc: noTrunc).container
        values["Container"] = container
        values["ID"] = container
        values["Name"] = container
        return values
    }

    /// Computes CPU percentage from two microsecond counters.
    private func cpuPercent(first: UInt64?, second: UInt64?) -> Double? {
        guard let first, let second else {
            return nil
        }
        let delta = second > first ? second - first : 0
        return (Double(delta) / Double(sampleIntervalMicroseconds)) * 100.0
    }

    /// Computes Docker Compose-style memory usage percentage.
    private func memoryPercent(usage: UInt64?, limit: UInt64?) -> Double? {
        guard let usage, let limit, limit > 0 else {
            return nil
        }
        return (Double(usage) / Double(limit)) * 100.0
    }

    /// Formats memory like Docker's binary `go-units.BytesSize`.
    private func formatDockerMemoryBytes(_ bytes: UInt64) -> String {
        formatDockerBytes(bytes, base: 1024.0, units: ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB"])
    }

    /// Formats network and block I/O like Docker's decimal `go-units.HumanSize`.
    private func formatDockerIOBytes(_ bytes: UInt64) -> String {
        formatDockerBytes(bytes, base: 1000.0, units: ["B", "kB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"])
    }

    /// Applies Docker's four significant digit byte display rule.
    private func formatDockerBytes(_ bytes: UInt64, base: Double, units: [String]) -> String {
        var value = Double(bytes)
        var index = 0
        while value >= base, index < units.count - 1 {
            value /= base
            index += 1
        }
        return String(format: "%.4g%@", value, units[index])
    }
}

public extension ContainerClientStatsManager {
    // swiftlint:disable function_parameter_count
    /// Emits exact bytes for templates while preserving the text callback for ordinary output.
    func stats(
        ids: [String],
        format: String,
        noStream: Bool,
        noTrunc: Bool,
        includeStopped: Bool,
        emit: @escaping @Sendable (String) -> Void,
        emitData: @escaping @Sendable (Data) -> Void,
    ) async throws {
        let parsedFormat = try composeStatsFormat(format)
        if !parsedFormat.isStreamingTable || noStream {
            let records = try await collectStats(ids: ids, includeStopped: includeStopped)
            let output = try renderStatsData(
                records,
                format: parsedFormat,
                noTrunc: noTrunc,
            )
            if let text = String(data: output, encoding: .utf8) {
                emit(text)
            } else {
                emitData(output)
            }
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
    // swiftlint:enable function_parameter_count
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
    var memoryPercent: String
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
            try validateDockerTemplateFields(
                dockerTemplateFields(in: template),
                command: "stats",
                supported: composeStatsTemplateFields,
            )
            return .template(template, table: true)
        }
        try validateDockerTemplateActions(in: normalized)
        try validateDockerTemplateFields(
            dockerTemplateFields(in: normalized),
            command: "stats",
            supported: composeStatsTemplateFields,
        )
        return .template(normalized, table: false)
    }
}
