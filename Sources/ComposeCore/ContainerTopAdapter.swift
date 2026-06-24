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

/// Service container selected for Compose process listing.
public struct ComposeTopTarget: Sendable, Equatable {
    public var service: String
    public var containerID: String

    public init(service: String, containerID: String) {
        self.service = service
        self.containerID = containerID
    }
}

/// One process identifier row for `compose top`.
public struct ComposeTopRecord: Sendable, Equatable, Codable {
    public var service: String
    public var containerID: String
    public var processIdentifier: Int32

    public init(service: String, containerID: String, processIdentifier: Int32) {
        self.service = service
        self.containerID = containerID
        self.processIdentifier = processIdentifier
    }
}

/// Low-level apple/container process-listing call used by `ContainerClientTopManager`.
public protocol ContainerTopAPIClienting: Sendable {
    /// Returns process identifiers currently associated with container `id`.
    func processes(id: String) async throws -> ContainerProcesses
}

/// Direct apple/container API used for service container process listing.
public protocol ContainerTopManaging: Sendable {
    /// Emits process identifiers for the selected service containers.
    func top(targets: [ComposeTopTarget], emit: @escaping @Sendable (String) -> Void) async throws
}

/// Thin apple/container client wrapper around process-listing API calls.
public struct ContainerTopAPIClient: ContainerTopAPIClienting {
    public typealias Processes = @Sendable (String) async throws -> ContainerProcesses

    private let processesOperation: Processes

    public init(processes: @escaping Processes = { try await ContainerClient().processes(id: $0) }) {
        self.processesOperation = processes
    }

    /// Reads process identifiers through `ContainerClient`.
    public func processes(id: String) async throws -> ContainerProcesses {
        try await processesOperation(id)
    }
}

/// `ContainerClient`-backed process-listing manager for service containers.
public struct ContainerClientTopManager: ContainerTopManaging {
    private let client: ContainerTopAPIClienting

    public init(client: ContainerTopAPIClienting = ContainerTopAPIClient()) {
        self.client = client
    }

    /// Emits a PID-only process table for the selected service containers.
    public func top(targets: [ComposeTopTarget], emit: @escaping @Sendable (String) -> Void) async throws {
        let records = try await collectRecords(targets: targets)
        emit(renderTopTable(records))
    }

    /// Collects process identifiers while preserving Compose service/container order.
    private func collectRecords(targets: [ComposeTopTarget]) async throws -> [ComposeTopRecord] {
        var records: [ComposeTopRecord] = []
        for target in targets {
            let processes = try await client.processes(id: target.containerID)
            for processIdentifier in processes.processIdentifiers {
                records.append(ComposeTopRecord(
                    service: target.service,
                    containerID: processes.id,
                    processIdentifier: processIdentifier
                ))
            }
        }
        return records
    }

    /// Renders the PID-only subset currently exposed by apple/container.
    private func renderTopTable(_ records: [ComposeTopRecord]) -> String {
        let headerRow = ["Service", "Container ID", "PID"]
        let rows = [headerRow] + records.map { record in
            [
                record.service,
                record.containerID,
                String(record.processIdentifier),
            ]
        }
        return renderTable(rows)
    }
}
