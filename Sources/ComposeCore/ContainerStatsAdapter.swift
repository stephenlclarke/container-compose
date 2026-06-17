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

/// Container identity and status needed before collecting direct API stats.
public struct ComposeStatsTarget: Sendable, Equatable {
    public var id: String
    public var status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

/// Low-level Apple container stats calls used by `ContainerClientStatsManager`.
public protocol ContainerStatsAPIClienting: Sendable {
    /// Lists the requested containers before stats collection.
    func listStatsTargets(ids: [String]) async throws -> [ComposeStatsTarget]

    /// Returns one statistics snapshot for container `id`.
    func stats(id: String) async throws -> ContainerStats
}

/// Direct Apple container API used for service container stats.
public protocol ContainerStatsManaging: Sendable {
    /// Emits stats for the requested service container ids.
    func stats(
        ids: [String],
        format: String,
        noStream: Bool,
        emit: @escaping @Sendable (String) -> Void
    ) async throws
}

/// Thin Apple `container` client wrapper around stats API calls.
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
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        if format == "json" || noStream {
            let records = try await collectStats(ids: ids)
            emit(try renderStats(records, format: format))
            return
        }

        emit("\u{001B}[?1049h\u{001B}[?25l")
        defer {
            emit("\u{001B}[?25h\u{001B}[?1049l")
        }

        emit("\u{001B}[H\u{001B}[J" + renderStatsTable([]))
        while !Task.isCancelled {
            let records = try await collectStats(ids: ids)
            emit("\u{001B}[H\u{001B}[J" + renderStatsTable(records))
            try await sleep(sampleInterval)
        }
    }

    /// Collects two samples for running containers so CPU percentages are meaningful.
    private func collectStats(ids: [String]) async throws -> [StatsSnapshot] {
        let targets = try await validatedTargets(ids: ids)
        var snapshots: [StatsSnapshot] = []

        for target in targets where target.status == "running" {
            do {
                let stats = try await client.stats(id: target.id)
                snapshots.append(StatsSnapshot(first: stats, second: stats))
            } catch {
                continue
            }
        }

        if !snapshots.isEmpty {
            try await sleep(sampleInterval)
            for index in snapshots.indices {
                do {
                    snapshots[index].second = try await client.stats(id: snapshots[index].second.id)
                } catch {
                    continue
                }
            }
        }

        return snapshots
    }

    /// Mirrors the Apple CLI check that every named container exists.
    private func validatedTargets(ids: [String]) async throws -> [ComposeStatsTarget] {
        let targets = try await client.listStatsTargets(ids: ids)
        let foundIDs = Set(targets.map(\.id))
        for id in ids where !foundIDs.contains(id) {
            throw ComposeError.invalidProject("no such container: \(id)")
        }
        return targets
    }

    /// Renders the direct stats payload in a supported format.
    private func renderStats(_ records: [StatsSnapshot], format: String) throws -> String {
        switch format {
        case "json":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records.map(\.second))
            return String(decoding: data, as: UTF8.self)
        case "table":
            return renderStatsTable(records)
        default:
            throw ComposeError.unsupported("stats --format '\(format)': apple/container stats supports table and json output")
        }
    }

    /// Renders stats rows with the same columns as `container stats`.
    private func renderStatsTable(_ records: [StatsSnapshot]) -> String {
        let headerRow = ["Container ID", "Cpu %", "Memory Usage", "Net Rx/Tx", "Block I/O", "Pids"]
        let rows = [headerRow] + records.map(statsTableRow)
        return renderTable(rows)
    }

    /// Projects one stats snapshot pair into display columns.
    private func statsTableRow(_ snapshot: StatsSnapshot) -> [String] {
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

        return [
            second.id,
            cpuPercent,
            "\(memoryUsage) / \(memoryLimit)",
            "\(networkRx) / \(networkTx)",
            "\(blockRead) / \(blockWrite)",
            pids,
        ]
    }

    /// Computes CPU percentage from two microsecond counters.
    private func cpuPercent(first: UInt64?, second: UInt64?) -> Double? {
        guard let first, let second else {
            return nil
        }
        let delta = second > first ? second - first : 0
        return (Double(delta) / Double(sampleIntervalMicroseconds)) * 100.0
    }

    /// Formats bytes like the Apple `container stats` command.
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

/// Two samples for one container, used to calculate rate-based fields.
private struct StatsSnapshot {
    var first: ContainerStats
    var second: ContainerStats
}

/// Renders rows as a padded table.
private func renderTable(_ rows: [[String]]) -> String {
    guard let firstRow = rows.first else {
        return ""
    }
    let widths = rows.reduce(Array(repeating: 0, count: firstRow.count)) { current, row in
        zip(current, row).map { max($0, $1.count) }
    }
    return rows.map { row in
        row.enumerated().map { index, value in
            index == row.count - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}
