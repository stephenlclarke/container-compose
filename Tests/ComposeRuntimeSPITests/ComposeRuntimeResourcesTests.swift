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

import ComposeRuntimeSPI
import Foundation
import Testing

struct ComposeRuntimeResourcesTests {
    @Test
    func `volume request uses local driver when unset or empty`() {
        #expect(ComposeVolumeCreateRequest(name: "cache").resolvedDriver == "local")
        #expect(ComposeVolumeCreateRequest(name: "cache", driver: "").resolvedDriver == "local")
        #expect(ComposeVolumeCreateRequest(name: "cache", driver: "nfs").resolvedDriver == "nfs")
    }

    @Test
    func `resource manager convenience creates default labeled volume`() async throws {
        let manager = RecordingResourceManager()
        let labels = ["com.example.role": "cache"]

        try await manager.createVolume(name: "cache", labels: labels)

        #expect(await manager.createdVolumes == [
            ComposeVolumeCreateRequest(name: "cache", labels: labels),
        ])
    }

    @Test
    func `network request retains resolved compose settings`() {
        let request = ComposeNetworkCreateRequest(
            name: "app_default",
            isInternal: true,
            addressing: .init(
                ipv4Subnet: "172.25.0.0/16",
                ipv4Gateway: "172.25.0.1",
                ipv4AllocationRange: "172.25.1.0/24",
                ipv4ReservedAddresses: ["172.25.0.2"],
                ipv6Subnet: "fd00::/64",
            ),
            driverOpts: ["dns": "enabled"],
            labels: ["com.docker.compose.project": "app"],
        )

        #expect(request.name == "app_default")
        #expect(request.isInternal)
        #expect(request.ipv4Subnet == "172.25.0.0/16")
        #expect(request.ipv4Gateway == "172.25.0.1")
        #expect(request.ipv4AllocationRange == "172.25.1.0/24")
        #expect(request.ipv4ReservedAddresses == ["172.25.0.2"])
        #expect(request.ipv6Subnet == "fd00::/64")
        #expect(request.driverOpts == ["dns": "enabled"])
        #expect(request.labels == ["com.docker.compose.project": "app"])
    }
}

struct ComposeRuntimeImagesTests {
    @Test
    func `image manager pulls only missing images`() async throws {
        let manager = RecordingImageManager(existingReferences: ["cached"])

        try await manager.pullMissingImage("cached")
        try await manager.pullMissingImage("missing")

        #expect(await manager.requests == [
            .exists("cached"),
            .exists("missing"),
            .pull("missing"),
        ])
    }
}

struct ComposeRuntimeCollaboratorsTests {
    @Test
    func `discovery summary retains normalized mount metadata`() {
        let mount = ComposeMount(
            type: "external-volume",
            source: "cache",
            target: "/var/lib/cache",
            options: .init(readOnly: true, volume: .init(subpath: "api")),
        )
        let summary = ComposeContainerSummary(
            id: "demo-api-1",
            status: "running",
            resources: .init(mounts: [mount]),
        )

        #expect(summary.mounts == [mount])
    }

    @Test
    func `exporter convenience preserves default snapshot policy`() async throws {
        let exporter = RecordingExporter()

        try await exporter.exportContainer(id: "demo-api-1", output: nil, live: true)

        #expect(await exporter.requests == [
            .init(id: "demo-api-1", output: nil, live: true, noFreeze: false),
        ])
    }

    @Test
    func `exec request retains terminal settings`() {
        let request = ContainerAttachedExecRequest(
            id: "demo-api-1",
            command: ["sh"],
            terminal: .init(interactive: false, tty: true),
        )

        #expect(request.terminal == .init(interactive: false, tty: true))
    }

    @Test
    func `event record round trips through codable`() throws {
        let record = ComposeEventRecord(
            time: Date(timeIntervalSince1970: 1000),
            type: "container",
            service: "api",
            id: "demo-api-1",
            action: "start",
            attributes: ["name": "demo-api-1"],
        )

        let decoded = try JSONDecoder().decode(
            ComposeEventRecord.self,
            from: JSONEncoder().encode(record),
        )

        #expect(decoded == record)
    }
}

private actor RecordingResourceManager: ComposeRuntimeResourceManaging {
    private var storage: [ComposeVolumeCreateRequest] = []

    var createdVolumes: [ComposeVolumeCreateRequest] {
        storage
    }

    func createNetwork(_: ComposeNetworkCreateRequest) async throws {}

    func deleteNetwork(id _: String) async throws {}

    func createVolume(_ request: ComposeVolumeCreateRequest) async throws {
        storage.append(request)
    }

    func listVolumes() async throws -> [ComposeVolumeSummary] {
        []
    }

    func deleteVolume(name _: String) async throws {}
}

private enum ImageRequest: Equatable {
    case exists(String)
    case pull(String)
}

private actor RecordingImageManager: ComposeRuntimeImageManaging {
    private let existingReferences: Set<String>
    private var storage: [ImageRequest] = []

    init(existingReferences: Set<String>) {
        self.existingReferences = existingReferences
    }

    var requests: [ImageRequest] {
        storage
    }

    func imageExists(_ reference: String) async throws -> Bool {
        storage.append(.exists(reference))
        return existingReferences.contains(reference)
    }

    func imageDigest(_: String) async throws -> String {
        ""
    }

    func imageHealthCheck(_: String, platform _: String?) async throws -> ComposeImageHealthCheck? {
        nil
    }

    func imageMetadata(_ reference: String) async throws -> ComposeImageMetadata {
        ComposeImageMetadata(reference: reference)
    }

    func bridgeTransformers() async throws -> [ComposeBridgeTransformer] {
        []
    }

    func pullImage(_ reference: String) async throws {
        storage.append(.pull(reference))
    }

    func pushImage(_: String, emit _: @escaping @Sendable (String) -> Void) async throws {}

    func deleteImage(_: String, force _: Bool, emit _: @escaping @Sendable (String) -> Void) async throws {}

    func loadImageArchive(_: String, emit _: @escaping @Sendable (String) -> Void) async throws {}
}

private struct ExportRequest: Equatable {
    var id: String
    var output: String?
    var live: Bool
    var noFreeze: Bool
}

private actor RecordingExporter: ComposeRuntimeExporting {
    private var storage: [ExportRequest] = []

    var requests: [ExportRequest] {
        storage
    }

    func exportContainer(id: String, output: String?, live: Bool, noFreeze: Bool) async throws {
        storage.append(.init(id: id, output: output, live: live, noFreeze: noFreeze))
    }
}
