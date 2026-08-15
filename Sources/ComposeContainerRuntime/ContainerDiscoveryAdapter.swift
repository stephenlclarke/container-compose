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
import ContainerizationError
import ContainerResource
import Foundation

/// Low-level apple/container discovery calls used by
/// `ContainerClientDiscoveryManager`.
public protocol ContainerDiscoveryAPIClienting: Sendable {
    /// Lists containers with fully resolved apple/container filters.
    func listContainers(filters: ContainerListFilters) async throws -> [ContainerSnapshot]

    /// Returns a container snapshot when `id` exists.
    func getContainer(id: String) async throws -> ContainerSnapshot?

    /// Returns one coherent lifecycle-v2 snapshot for all containers.
    func listLifecycleRecords() async throws -> [ContainerLifecycleRecordV2]
}

public extension ContainerDiscoveryAPIClienting {
    func listLifecycleRecords() async throws -> [ContainerLifecycleRecordV2] {
        []
    }
}

/// Live Compose discovery through the stable container CLI JSON boundary.
public struct ContainerLiveDiscoveryManager: ContainerDiscoveryManaging {
    private let listManager: ContainerDiscoveryManaging
    private let detailManager: ContainerDiscoveryManaging

    public init(
        runner: CommandRunning = ProcessRunner(),
        environmentLauncher: String = ComposeExecutionOptions.defaultEnvironmentLauncher,
        containerBinary: String = ComposeExecutionOptions.defaultContainerBinary(),
        detailManager: ContainerDiscoveryManaging? = nil,
    ) {
        let cliManager = ContainerCLIJSONDiscoveryManager(
            runner: runner,
            environmentLauncher: environmentLauncher,
            containerBinary: containerBinary,
        )
        listManager = cliManager
        self.detailManager = detailManager ?? cliManager
    }

    /// Lists project candidates through the stable CLI JSON boundary.
    public func listContainers(all: Bool) async throws -> [ComposeContainerSummary] {
        try await listManager.listContainers(all: all)
    }

    /// Fetches one container through the same stable JSON boundary.
    public func getContainer(id: String) async throws -> ComposeContainerSummary? {
        try await detailManager.getContainer(id: id)
    }
}

/// `container list --format json` backed discovery manager for live Compose
/// project metadata.
public struct ContainerCLIJSONDiscoveryManager: ContainerDiscoveryManaging {
    private let runner: CommandRunning
    private let environmentLauncher: String
    private let containerBinary: String

    public init(
        runner: CommandRunning = ProcessRunner(),
        environmentLauncher: String = ComposeExecutionOptions.defaultEnvironmentLauncher,
        containerBinary: String = ComposeExecutionOptions.defaultContainerBinary(),
    ) {
        self.runner = runner
        self.environmentLauncher = environmentLauncher
        self.containerBinary = containerBinary
    }

    /// Lists non-machine containers through the stable container CLI JSON shape.
    public func listContainers(all: Bool) async throws -> [ComposeContainerSummary] {
        try await listManagedContainers(all: all).map(ComposeContainerSummary.init(managedContainer:))
    }

    /// Fetches one container summary by filtering the complete CLI JSON list.
    public func getContainer(id: String) async throws -> ComposeContainerSummary? {
        try await listManagedContainers(all: true)
            .first { $0.id == id }
            .map(ComposeContainerSummary.init(managedContainer:))
    }

    private func listManagedContainers(all: Bool) async throws -> [ManagedContainer] {
        var arguments = ["list", "--format", "json"]
        if all {
            arguments.append("--all")
        }
        let result = try await runner.run(
            environmentLauncher,
            [containerBinary] + arguments,
            workingDirectory: nil,
            environment: nil,
        )
        guard result.succeeded else {
            throw ComposeError.commandFailed(
                command: shellQuotedDiscoveryCommand([containerBinary] + arguments),
                status: result.status,
                stderr: result.stderr,
            )
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return []
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ManagedContainer].self, from: Data(result.stdout.utf8))
        } catch {
            throw ComposeError.invalidProject("failed to decode container list JSON: \(error)")
        }
    }
}

/// Thin apple/container client wrapper around discovery API calls.
public struct ContainerDiscoveryAPIClient: ContainerDiscoveryAPIClienting {
    public typealias List = @Sendable (ContainerListFilters) async throws -> [ContainerSnapshot]
    public typealias Get = @Sendable (String) async throws -> ContainerSnapshot
    public typealias LifecycleList = @Sendable () async throws -> [ContainerLifecycleRecordV2]

    private let listOperation: List
    private let getOperation: Get
    private let lifecycleListOperation: LifecycleList

    public init(
        list: @escaping List = { try await ContainerClient().list(filters: $0) },
        get: @escaping Get = { try await ContainerClient().get(id: $0) },
        lifecycleList: @escaping LifecycleList = {
            try await ContainerClient().lifecycleRecords()
        },
    ) {
        listOperation = list
        getOperation = get
        lifecycleListOperation = lifecycleList
    }

    /// Lists containers through `ContainerClient`.
    public func listContainers(filters: ContainerListFilters) async throws -> [ContainerSnapshot] {
        try await listOperation(filters)
    }

    /// Fetches one container through `ContainerClient`.
    public func getContainer(id: String) async throws -> ContainerSnapshot? {
        do {
            return try await getOperation(id)
        } catch let error as ContainerizationError where error.code == .notFound {
            return nil
        }
    }

    public func listLifecycleRecords() async throws -> [ContainerLifecycleRecordV2] {
        try await lifecycleListOperation()
    }
}

/// `ContainerClient`-backed discovery manager for Compose project metadata.
public struct ContainerClientDiscoveryManager: ContainerDiscoveryManaging {
    private let client: ContainerDiscoveryAPIClienting

    public init(client: ContainerDiscoveryAPIClienting = ContainerDiscoveryAPIClient()) {
        self.client = client
    }

    /// Lists non-machine containers through `ContainerClient.list(filters:)`.
    public func listContainers(all: Bool) async throws -> [ComposeContainerSummary] {
        // Lifecycle-v2 transient states do not all have a corresponding legacy
        // RuntimeStatus. Fetch one coherent unfiltered snapshot and apply the
        // Docker-visible active-state projection after joining lifecycle data.
        let filters = ContainerListFilters().withoutMachines()
        async let snapshots = client.listContainers(filters: filters)
        async let lifecycleRecords = client.listLifecycleRecords()
        let records = try await lifecycleRecords
        let recordsByBundleKey = Dictionary(
            uniqueKeysWithValues: records.map { ($0.immutableBundleKey, $0) },
        )
        let summaries = try await snapshots.map {
            ComposeContainerSummary(
                snapshot: $0,
                lifecycle: recordsByBundleKey[$0.id],
            )
        }
        guard !all else {
            return summaries
        }
        return summaries.filter {
            $0.status == "running" || $0.status == "paused"
                || $0.status == "restarting"
        }
    }

    /// Fetches one container through `ContainerClient.get(id:)`.
    public func getContainer(id: String) async throws -> ComposeContainerSummary? {
        async let snapshotResult = client.getContainer(id: id)
        async let lifecycleRecords = client.listLifecycleRecords()
        guard let snapshot = try await snapshotResult else {
            return nil
        }
        let lifecycle = try await lifecycleRecords.first {
            $0.immutableBundleKey == snapshot.id
                || $0.containerID == id
                || $0.canonicalName == id
        }
        return ComposeContainerSummary(snapshot: snapshot, lifecycle: lifecycle)
    }
}

private extension ComposeContainerSummary {
    init(
        snapshot: ContainerSnapshot,
        lifecycle: ContainerLifecycleRecordV2? = nil,
    ) {
        self.init(
            id: snapshot.id,
            status: lifecycle?.snapshot.state.rawValue
                ?? Self.composeStatus(
                    runtimeStatus: snapshot.status,
                    startedDate: snapshot.startedDate,
                ),
            labels: snapshot.configuration.labels,
            image: ComposeContainerSummary.Image(
                reference: snapshot.configuration.image.reference,
                digest: snapshot.configuration.image.digest,
                platform: snapshot.platform.description,
            ),
            resources: ComposeContainerSummary.Resources(
                publishedPorts: snapshot.configuration.publishedPorts.map(Self.publishedPort(from:)),
                mounts: snapshot.configuration.mounts.map(Self.mount(from:)),
                networks: snapshot.networks.map(Self.network(from:)),
            ),
            state: lifecycle.map {
                ComposeContainerSummary.State(
                    exitCode: $0.snapshot.exitCode,
                    exitedDate: $0.snapshot.finishedAt,
                    health: $0.snapshot.health,
                )
            } ?? ComposeContainerSummary.State(
                exitCode: snapshot.exitCode,
                exitedDate: snapshot.exitedDate,
                health: snapshot.health?.rawValue,
            ),
        )
    }

    init(managedContainer: ManagedContainer) {
        self.init(
            id: managedContainer.id,
            status: Self.composeStatus(
                runtimeStatus: managedContainer.status.state,
                startedDate: managedContainer.status.startedDate,
            ),
            labels: managedContainer.configuration.labels,
            image: ComposeContainerSummary.Image(
                reference: managedContainer.configuration.image.reference,
                digest: managedContainer.configuration.image.digest,
                platform: managedContainer.platform.description,
            ),
            resources: ComposeContainerSummary.Resources(
                publishedPorts: managedContainer.configuration.publishedPorts.map(Self.publishedPort(from:)),
                mounts: managedContainer.configuration.mounts.map(Self.mount(from:)),
                networks: managedContainer.status.networks.map(Self.network(from:)),
            ),
            state: ComposeContainerSummary.State(
                exitCode: managedContainer.exitCode,
                exitedDate: managedContainer.exitedDate,
                health: managedContainer.health?.rawValue,
            ),
        )
    }

    /// Projects the runtime's stopped state into Docker's lifecycle vocabulary.
    /// A container that has never started is `created`; a later stopped
    /// container is `exited`. All active runtime states retain their native
    /// spelling.
    static func composeStatus(runtimeStatus: RuntimeStatus, startedDate: Date?) -> String {
        guard runtimeStatus == .stopped else {
            return runtimeStatus.rawValue
        }
        return startedDate == nil ? "created" : "exited"
    }

    static func publishedPort(from port: PublishPort) -> ComposeContainerPublishedPort {
        ComposeContainerPublishedPort(
            hostAddress: String(describing: port.hostAddress),
            hostPort: port.hostPort,
            containerPort: port.containerPort,
            protocolName: port.proto.rawValue,
            count: port.count,
        )
    }

    static func network(from attachment: Attachment) -> ComposeContainerNetworkAttachment {
        ComposeContainerNetworkAttachment(
            network: attachment.network,
            ipv4Address: attachment.ipv4Address.map { String(describing: $0.address) },
        )
    }

    /// Projects an apple/container filesystem mount into a runtime-ready Compose mount.
    static func mount(from filesystem: Filesystem) -> ComposeMount {
        let readOnly = filesystem.options.readonly ? true : nil
        let fileOwnerUID = filesystem.fileOwnership?.uid
        let fileOwnerGID = filesystem.fileOwnership?.gid
        switch filesystem.type {
        case let .volume(name, _, _, _):
            return ComposeMount(
                type: "external-volume",
                source: name,
                target: filesystem.destination,
                options: .init(
                    readOnly: readOnly,
                    volume: .init(subpath: filesystem.sourceSubpath),
                ),
            )
        case .virtiofs:
            return ComposeMount(
                type: "bind",
                source: filesystem.source,
                target: filesystem.destination,
                options: .init(
                    readOnly: readOnly,
                    volume: .init(fileOwnership: .init(uid: fileOwnerUID, gid: fileOwnerGID)),
                ),
            )
        case .tmpfs:
            return ComposeMount(type: "tmpfs", target: filesystem.destination, readOnly: readOnly)
        case .block:
            return ComposeMount(
                type: "block",
                source: filesystem.source,
                target: filesystem.destination,
                options: ComposeMount.MountOptions(readOnly: readOnly),
                unsupportedFields: ["apple.container.block"],
            )
        }
    }
}

private func shellQuotedDiscoveryCommand(_ parts: [String]) -> String {
    parts.map { part in
        if part.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=,".contains($0) }) {
            return part
        }
        return "'" + part.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}
