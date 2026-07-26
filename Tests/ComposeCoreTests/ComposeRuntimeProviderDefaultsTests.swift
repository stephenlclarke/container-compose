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

@Suite("Compose runtime provider defaults")
struct ComposeRuntimeProviderDefaultsTests {
    private func expectUnavailable(
        _ operation: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        body: () async throws -> Void,
    ) async {
        do {
            try await body()
            Issue.record(
                "Expected unconfigured runtime failure for \(operation)",
                sourceLocation: sourceLocation,
            )
        } catch let error as ComposeError {
            #expect(
                error == .unsupported("\(operation) requires an installed Compose runtime provider"),
                sourceLocation: sourceLocation,
            )
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test
    func `copying defaults fail every operation`() async {
        let copying = ComposeRuntimeProviderDefaults.copying()
        let options = ContainerCopyTransferOptions()

        await expectUnavailable("copy into container") {
            try await copying.copyIntoContainer(
                id: "app", source: "/tmp/source", destination: "/data", options: options,
            )
        }
        await expectUnavailable("copy from container") {
            try await copying.copyFromContainer(
                id: "app", source: "/data", destination: "/tmp/output", options: options,
            )
        }
        await expectUnavailable("copy between containers") {
            try await copying.copyBetweenContainers(
                sourceID: "source",
                source: "/data",
                destinationID: "destination",
                destination: "/data",
                options: options,
            )
        }
    }

    @Test
    func `export and exec defaults fail every operation`() async {
        await expectUnavailable("container export") {
            try await ComposeRuntimeProviderDefaults.exporting().exportContainer(
                id: "app",
                output: nil,
                live: false,
                noFreeze: false,
            )
        }

        let executing = ComposeRuntimeProviderDefaults.executing()
        await expectUnavailable("container exec") {
            _ = try await executing.execAttached(request: ContainerAttachedExecRequest(id: "app", command: ["true"]))
        }
        await expectUnavailable("container exec") {
            try await executing.execDetached(
                request: ContainerDetachedExecRequest(id: "app", command: ["true"]),
                emit: { _ in },
            )
        }
    }

    @Test
    func `event and lifecycle defaults fail every operation`() async {
        await expectUnavailable("container events") {
            try await ComposeRuntimeProviderDefaults.events().events(
                projectName: "example",
                services: ["app"],
                format: .json,
                since: nil,
                until: nil,
                emit: { _ in },
            )
        }

        let lifecycle = ComposeRuntimeProviderDefaults.lifecycle()
        await expectUnavailable("container start") {
            try await lifecycle.startContainer(id: "app")
        }
        await expectUnavailable("container kill") {
            try await lifecycle.killContainer(id: "app", signal: "SIGTERM")
        }
        await expectUnavailable("container stop") {
            try await lifecycle.stopContainer(id: "app", signal: nil, timeoutInSeconds: nil)
        }
        await expectUnavailable("container pause") {
            try await lifecycle.pauseContainer(id: "app")
        }
        await expectUnavailable("container unpause") {
            try await lifecycle.unpauseContainer(id: "app")
        }
        await expectUnavailable("container wait") {
            _ = try await lifecycle.waitContainer(id: "app")
        }
        await expectUnavailable("container remove") {
            try await lifecycle.deleteContainer(id: "app", force: false)
        }
    }

    @Test
    func `inspection and content defaults fail every operation`() async {
        await expectUnavailable("container stats") {
            try await ComposeRuntimeProviderDefaults.stats().stats(
                ids: ["app"],
                format: "table",
                noStream: true,
                noTrunc: false,
                includeStopped: false,
                emit: { _ in },
            )
        }
        await expectUnavailable("container top") {
            try await ComposeRuntimeProviderDefaults.top().top(
                targets: [ComposeTopTarget(service: "app", containerID: "app")],
                emit: { _ in },
            )
        }
        await expectUnavailable("container logs") {
            try await ComposeRuntimeProviderDefaults.logs().logs(
                id: "app",
                tail: nil,
                follow: false,
                since: nil,
                until: nil,
                timestamps: false,
                emit: { (_: Data) in },
            )
        }
        await expectUnavailable("external config read") {
            _ = try await ComposeRuntimeProviderDefaults.configReader().readConfig(name: "config")
        }
        await expectUnavailable("external secret read") {
            _ = try await ComposeRuntimeProviderDefaults.secretReader().readSecret(name: "secret")
        }

        let discovery = ComposeRuntimeProviderDefaults.discovery()
        await expectUnavailable("container discovery") {
            _ = try await discovery.listContainers(all: true)
        }
        await expectUnavailable("container discovery") {
            _ = try await discovery.getContainer(id: "app")
        }
    }

    @Test
    func `image defaults fail every operation`() async {
        let images = ComposeRuntimeProviderDefaults.images()

        await expectUnavailable("image lookup") {
            _ = try await images.imageExists("example/declared-volume:latest")
        }
        await expectUnavailable("image digest lookup") {
            _ = try await images.imageDigest("example/declared-volume:latest")
        }
        await expectUnavailable("image healthcheck lookup") {
            _ = try await images.imageHealthCheck("example/declared-volume:latest", platform: "linux/arm64")
        }
        await expectUnavailable("image metadata lookup") {
            _ = try await images.imageMetadata("example/declared-volume:latest")
        }
        await expectUnavailable("image metadata lookup") {
            _ = try await images.prepareImageVolumeMetadata(
                "example/declared-volume:latest",
                pullIfMissing: false,
            )
        }
        await expectUnavailable("image metadata lookup") {
            _ = try await images.imageDeclaredVolumeTargets(
                "example/declared-volume:latest",
                platform: "linux/arm64",
            )
        }
        await expectUnavailable("bridge transformer lookup") {
            _ = try await images.bridgeTransformers()
        }
        await expectUnavailable("image pull") {
            try await images.pullImage("example/declared-volume:latest")
        }
        await expectUnavailable("image pull") {
            try await images.pullMissingImage("example/declared-volume:latest")
        }
        await expectUnavailable("image push") {
            try await images.pushImage("example/declared-volume:latest", emit: { _ in })
        }
        await expectUnavailable("image remove") {
            try await images.deleteImage("example/declared-volume:latest", force: false, emit: { _ in })
        }
        await expectUnavailable("image load") {
            try await images.loadImageArchive("/tmp/image.tar", emit: { _ in })
        }
    }

    @Test
    func `image-volume planning fails before resource creation without a provider`() async {
        let service = ComposeService(name: "app", image: "example/declared-volume:latest")
        let project = ComposeProject(name: "example", services: [service.name: service])

        await expectUnavailable("image metadata lookup") {
            _ = try await ComposeOrchestrator().prepareRuntimeImageVolumes(
                project: project,
                service: service,
                context: MountRenderContext(
                    project: project,
                    service: service,
                    containerName: "example-app-1",
                    oneOff: false,
                    containerIndex: 1,
                ),
                mounts: [],
            )
        }
    }

    @Test
    func `image-volume initialization and resource defaults fail every operation`() async {
        await expectUnavailable("image volume initialization") {
            try await ComposeRuntimeProviderDefaults.imageVolumeInitializer().initializeImageVolume(
                ComposeImageVolumeInitializationRequest(
                    image: "example/declared-volume:latest",
                    imageSubpath: "/data",
                    volumeName: "example-data",
                ),
            )
        }

        let resources = ComposeRuntimeProviderDefaults.resources()
        await expectUnavailable("network create") {
            try await resources.createNetwork(ComposeNetworkCreateRequest(name: "example"))
        }
        await expectUnavailable("network remove") {
            try await resources.deleteNetwork(id: "example")
        }
        await expectUnavailable("volume create") {
            try await resources.createVolume(ComposeVolumeCreateRequest(name: "example-data"))
        }
        await expectUnavailable("volume list") {
            _ = try await resources.listVolumes()
        }
        await expectUnavailable("volume remove") {
            try await resources.deleteVolume(name: "example-data")
        }
    }
}
