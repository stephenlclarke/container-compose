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

@testable import ComposeCore
import Foundation
import Testing

/// A synchronous archive-boundary probe, not an OCI archive implementation.
private struct CommitArchiveProbe: ComposeArchiveManaging {
    let write: @Sendable (ComposeCommitImageArchiveRequest) throws -> Void

    func writeCommitImageArchive(_ request: ComposeCommitImageArchiveRequest) throws {
        try write(request)
    }

    func extractBridgeTemplates(archive _: URL, destination _: String) throws {
        throw ComposeError.invalidProject("unexpected bridge archive operation")
    }

    // swiftlint:disable function_parameter_count
    func copyArchiveIntoContainer(
        using _: any ComposeRuntimeCopying,
        id _: String,
        archive _: FileHandle,
        destination _: String,
        options _: ContainerCopyTransferOptions,
        temporaryDirectory _: URL
    ) async throws {
        throw ComposeError.invalidProject("unexpected archive copy operation")
    }

    func copyFromContainerAsArchive(
        using _: any ComposeRuntimeCopying,
        id _: String,
        source _: String,
        archive _: FileHandle,
        copyContents _: Bool,
        options _: ContainerCopyTransferOptions,
        temporaryDirectory _: URL
    ) async throws {
        throw ComposeError.invalidProject("unexpected archive copy operation")
    }
    // swiftlint:enable function_parameter_count
}

@Suite("Provider-neutral commit transaction")
struct ComposeOrchestratorCommitBoundaryTests {
    @Test("commit routes snapshots and removes private staging after load", arguments: [
        ("created", true, false), ("dead", false, false), ("exited", true, false),
        ("stopped", false, false), ("running", true, true), ("RUNNING", false, true),
    ])
    func commitTransaction(status: String, pause: Bool, live: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootfs = Data("rootfs boundary fixture".utf8)
        let archive = Data("image boundary fixture".utf8)
        let exporter = RecordingContainerExporter(archiveData: rootfs)
        let images = RecordingContainerImageManager()
        let discovery = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: status),
            discoveredServiceContainer(id: "demo-api-2", serviceName: "api", status: status),
        ])
        let service = ComposeService(name: "api", image: "example/api")
        var execution = ComposeExecutionOptions()
        execution.temporaryDirectory = root
        let orchestrator = ComposeOrchestrator(options: execution, dependencies: orchestratorDependencies {
            $0.discoveryManager = discovery
            $0.exporter = exporter
            $0.imageManager = images
            $0.archiveManager = CommitArchiveProbe { request in
                #expect(request.temporaryDirectory == root)
                #expect(request.service.name == "api")
                #expect(request.options.reference == "example/api:snapshot")
                #expect(request.options.pause == pause)
                #expect(try Data(contentsOf: request.rootfsArchive) == rootfs)
                let parent = request.output.deletingLastPathComponent()
                #expect(parent.deletingLastPathComponent() == root)
                #expect(request.rootfsArchive.deletingLastPathComponent() == parent)
                let parentAttributes = try FileManager.default.attributesOfItem(atPath: parent.path)
                let rootfsAttributes = try FileManager.default.attributesOfItem(atPath: request.rootfsArchive.path)
                #expect(parentAttributes[.posixPermissions] as? Int == 0o700)
                #expect(rootfsAttributes[.posixPermissions] as? Int == 0o600)
                // The test checks orchestration bytes, not OCI archive conformance.
                try archive.write(to: request.output)
            }
        })

        try await orchestrator.commit(
            project: ComposeProject(name: "demo", services: ["api": service]), serviceName: "api",
            options: ComposeCommitOptions {
                $0.index = 2
                $0.pause = pause
                $0.reference = "example/api:snapshot"
            }
        )

        let exported = try #require(await exporter.requests.first)
        #expect(exported.id == "demo-api-2")
        #expect(exported.live == live)
        #expect(exported.noFreeze == (live && !pause))
        #expect(await discovery.getRequests == ["demo-api-2"])
        #expect(await images.loadedArchiveData == [archive])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("commit cleans staging and preserves the failing phase", arguments: ["export", "archive", "load"])
    func commitFailureCleanup(phase: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = ComposeError.invalidProject("injected \(phase) failure")
        let exporter = RecordingContainerExporter(
            archiveData: Data("rootfs".utf8), failure: phase == "export" ? failure : nil
        )
        let images = RecordingContainerImageManager(failure: phase == "load" ? failure : nil)
        let service = ComposeService(name: "api", image: "example/api")
        var execution = ComposeExecutionOptions()
        execution.temporaryDirectory = root
        let orchestrator = ComposeOrchestrator(options: execution, dependencies: orchestratorDependencies {
            $0.exporter = exporter
            $0.imageManager = images
            $0.archiveManager = CommitArchiveProbe { request in
                try Data("partial or complete image".utf8).write(to: request.output)
                if phase == "archive" {
                    throw failure
                }
            }
        })

        await #expect(throws: failure) {
            try await orchestrator.writeCommitImage(
                project: ComposeProject(name: "demo", services: ["api": service]),
                service: service, options: ComposeCommitOptions(),
                container: ComposeContainerSummary(id: "demo-api-1", status: "stopped")
            )
        }
        #expect(await exporter.requests.count == 1)
        let requests = await images.requests
        let loads = requests.filter {
            if case .load = $0 {
                return true
            }; return false
        }
        // This recorder stores successful loads only; the exact injected error
        // above proves that a load-phase failure was reached, not swallowed.
        #expect(loads.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("commit rejects transient states before metadata or export", arguments: ["paused", "starting", "stopping", "unknown"])
    func rejectTransientState(status: String) async throws {
        let exporter = RecordingContainerExporter()
        let images = RecordingContainerImageManager()
        let service = ComposeService(name: "api", image: "example/api")
        let orchestrator = ComposeOrchestrator(dependencies: orchestratorDependencies {
            $0.exporter = exporter
            $0.imageManager = images
        })
        await #expect(throws: ComposeError.self) {
            try await orchestrator.writeCommitImage(
                project: ComposeProject(name: "demo", services: ["api": service]),
                service: service, options: ComposeCommitOptions(),
                container: ComposeContainerSummary(id: "demo-api-1", status: status)
            )
        }
        #expect(await exporter.requests.isEmpty)
        #expect(await images.requests.isEmpty)
    }
}
