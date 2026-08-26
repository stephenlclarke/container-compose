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

    /// Returns atomically paired resource and lifecycle views.
    func listLifecycleViews(filters: ContainerListFilters) async throws -> [ContainerLifecycleViewV2]
}

public extension ContainerDiscoveryAPIClienting {
    func listLifecycleViews(filters _: ContainerListFilters) async throws -> [ContainerLifecycleViewV2] {
        throw ComposeError.unsupported(
            "the configured container discovery provider does not support atomic lifecycle views",
        )
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
    public typealias LifecycleViewList = @Sendable (ContainerListFilters) async throws -> [ContainerLifecycleViewV2]

    private let listOperation: List
    private let getOperation: Get
    private let lifecycleViewListOperation: LifecycleViewList

    public init(
        list: @escaping List = { try await ContainerClient().list(filters: $0) },
        get: @escaping Get = { try await ContainerClient().get(id: $0) },
        lifecycleViewList: @escaping LifecycleViewList = {
            try await ContainerClient().lifecycleViews(filters: $0)
        },
    ) {
        listOperation = list
        getOperation = get
        lifecycleViewListOperation = lifecycleViewList
    }

    init(containerClient: @escaping ContainerClientProvider) {
        self.init(
            list: { try await containerClient().list(filters: $0) },
            get: { try await containerClient().get(id: $0) },
            lifecycleViewList: { try await containerClient().lifecycleViews(filters: $0) },
        )
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

    public func listLifecycleViews(filters: ContainerListFilters) async throws -> [ContainerLifecycleViewV2] {
        try await lifecycleViewListOperation(filters)
    }
}

/// `ContainerClient`-backed discovery manager for Compose project metadata.
public struct ContainerClientDiscoveryManager: ContainerDiscoveryManaging {
    private let client: ContainerDiscoveryAPIClienting

    public init(client: ContainerDiscoveryAPIClienting = ContainerDiscoveryAPIClient()) {
        self.client = client
    }

    /// Lists non-machine containers through one atomic lifecycle-view read.
    public func listContainers(all: Bool) async throws -> [ComposeContainerSummary] {
        // Lifecycle-v2 transient states do not all have a corresponding legacy
        // RuntimeStatus. Fetch one coherent unfiltered view and apply the
        // Docker-visible active-state projection from its lifecycle authority.
        let filters = ContainerListFilters().withoutMachines()
        let views = try await client.listLifecycleViews(filters: filters)
        let summaries = views.map(ComposeContainerSummary.init(lifecycleView:))
        guard !all else {
            return summaries
        }
        return summaries.filter {
            $0.status == "running" || $0.status == "paused"
                || $0.status == "restarting"
        }
    }

    /// Fetches one container by immutable ID, canonical name, or bundle key.
    public func getContainer(id: String) async throws -> ComposeContainerSummary? {
        let views = try await client.listLifecycleViews(filters: .all)
        guard let view = views.first(where: {
            $0.lifecycle.containerID == id
                || $0.lifecycle.canonicalName == id
                || $0.lifecycle.immutableBundleKey == id
        }) else {
            return nil
        }
        return ComposeContainerSummary(lifecycleView: view)
    }
}

private extension ComposeContainerSummary {
    init(lifecycleView: ContainerLifecycleViewV2) {
        let snapshot = lifecycleView.container
        let lifecycle = lifecycleView.lifecycle
        self.init(
            id: lifecycle.containerID,
            name: lifecycle.canonicalName,
            bundleKey: lifecycle.immutableBundleKey,
            status: lifecycle.snapshot.state.rawValue,
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
            state: ComposeContainerSummary.State(
                exitCode: lifecycle.snapshot.exitCode,
                exitedDate: lifecycle.snapshot.finishedAt,
                health: lifecycle.snapshot.health,
            ),
        )
    }

    init(managedContainer: ManagedContainer) {
        self.init(
            id: managedContainer.id,
            name: managedContainer.configuration.dockerName,
            bundleKey: managedContainer.id,
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
