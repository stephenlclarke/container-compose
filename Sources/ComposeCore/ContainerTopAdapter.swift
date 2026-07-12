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

/// One process identifier row for the fallback `compose top` table.
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

/// Process rows returned for one selected service container.
public struct ComposeTopContainerProcesses: Sendable, Equatable {
    public var service: String
    public var containerID: String
    public var processes: ContainerProcesses

    public init(service: String, containerID: String, processes: ContainerProcesses) {
        self.service = service
        self.containerID = containerID
        self.processes = processes
    }
}

/// Low-level apple/container process-listing call used by `ContainerClientTopManager`.
public protocol ContainerTopAPIClienting: Sendable {
    /// Returns process information currently associated with container `id`.
    func processes(id: String) async throws -> ContainerProcesses
}

/// Direct apple/container API used for service container process listing.
public protocol ContainerTopManaging: Sendable {
    /// Emits process information for the selected service containers.
    func top(targets: [ComposeTopTarget], emit: @escaping @Sendable (String) -> Void) async throws
}

/// Thin apple/container client wrapper around process-listing API calls.
public struct ContainerTopAPIClient: ContainerTopAPIClienting {
    public typealias Processes = @Sendable (String) async throws -> ContainerProcesses

    private let processesOperation: Processes

    public init(processes: @escaping Processes = { try await ContainerClient().processes(id: $0) }) {
        self.processesOperation = processes
    }

    /// Reads process information through `ContainerClient`.
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

    /// Emits Docker-shaped process tables for the selected service containers.
    public func top(targets: [ComposeTopTarget], emit: @escaping @Sendable (String) -> Void) async throws {
        let containers = try await collectContainers(targets: targets)
        emit(renderTopOutput(containers))
    }

    /// Collects process information while preserving Compose service/container order.
    private func collectContainers(targets: [ComposeTopTarget]) async throws -> [ComposeTopContainerProcesses] {
        var containers: [ComposeTopContainerProcesses] = []
        for target in targets {
            let processes = try await client.processes(id: target.containerID)
            containers.append(ComposeTopContainerProcesses(
                service: target.service,
                containerID: target.containerID,
                processes: processes
            ))
        }
        return containers
    }

    /// Renders Docker Compose-compatible process sections when metadata is available.
    private func renderTopOutput(_ containers: [ComposeTopContainerProcesses]) -> String {
        let hasProcessMetadata = containers.contains { !$0.processes.processes.isEmpty }
        let hasIdentifierOnlyContainer = containers.contains {
            $0.processes.processes.isEmpty && !$0.processes.processIdentifiers.isEmpty
        }
        if hasProcessMetadata && !hasIdentifierOnlyContainer {
            return renderProcessInfoSections(containers)
        }
        return renderIdentifierFallbackTable(containers)
    }

    /// Renders Docker Compose's per-container process-table layout.
    private func renderProcessInfoSections(_ containers: [ComposeTopContainerProcesses]) -> String {
        var sections: [String] = []
        for container in containers {
            sections.append(container.containerID)
            let rows = [["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"]] + container.processes.processes.map { process in
                [
                    process.uid,
                    String(process.pid),
                    String(process.ppid),
                    String(process.cpu),
                    process.startTime,
                    process.tty,
                    process.time,
                    process.command,
                ]
            }
            sections.append(renderTable(rows))
        }
        return sections.joined(separator: "\n")
    }

    /// Renders the identifier fallback used when process rows are unavailable.
    private func renderIdentifierFallbackTable(_ containers: [ComposeTopContainerProcesses]) -> String {
        var records: [ComposeTopRecord] = []
        for container in containers {
            let processes = container.processes
            for processIdentifier in processes.processIdentifiers {
                records.append(ComposeTopRecord(
                    service: container.service,
                    containerID: processes.id,
                    processIdentifier: processIdentifier
                ))
            }
        }

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
