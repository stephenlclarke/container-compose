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
@testable import ComposeEngineRuntime
import ComposeRuntimeSPI
import ContainerEngineWire
import ContainerUnixHTTPServer
import Foundation
import Logging
import Testing

@Suite(.serialized)
struct ComposeEngineRuntimeTests {
    @Test
    func `discovery maps Engine list and inspect responses`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let server = fixture.server(EngineFixtureResponder())
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
            let containers = try await provider.listContainers(all: true)
            #expect(containers.count == 1)
            #expect(containers[0].id == "abc")
            #expect(containers[0].displayName == "demo")
            #expect(containers[0].imageReference == "alpine:3.22")
            #expect(containers[0].publishedPorts.first?.hostPort == 8080)
            #expect(containers[0].mounts.first?.target == "/workspace")

            let inspected = try #require(try await provider.getContainer(id: "abc"))
            #expect(inspected.health == "healthy")
            #expect(inspected.exitCode == 0)
            #expect(inspected.networks == [.init(network: "project_default", ipv4Address: "192.168.1.2")])
            #expect(try await provider.getContainer(id: "missing") == nil)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `lifecycle and resources use bounded native Engine requests`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(EngineFixtureResponder(recorder: recorder))
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
            try await provider.startContainer(id: "demo/id")
            try await provider.stopContainer(id: "demo/id", signal: "SIG TERM", timeoutInSeconds: 7)
            try await provider.restartContainer(id: "demo/id", signal: nil, timeoutInSeconds: nil)
            try await provider.killContainer(id: "demo/id", signal: "SIGKILL")
            try await provider.pauseContainer(id: "demo/id")
            try await provider.unpauseContainer(id: "demo/id")
            #expect(try await provider.waitContainer(id: "demo/id") == 17)
            try await provider.deleteContainer(id: "demo/id", force: true)
            try await provider.createNetwork(.init(name: "project_default", labels: ["project": "demo"]))
            try await provider.createVolume(.init(name: "project_data", labels: ["project": "demo"]))
            let volumes = try await provider.listVolumes()
            #expect(volumes == [
                .init(
                    name: "project_data",
                    source: "/volumes/project_data",
                    labels: ["project": "demo"],
                ),
            ])
            try await provider.deleteNetwork(id: "project_default")
            try await provider.deleteVolume(name: "project_data")

            let requests = await recorder.requests
            #expect(requests.contains { $0.target == "/v1.53/containers/demo%2Fid/start" })
            #expect(requests.contains { $0.target.contains("/stop?") && $0.target.contains("signal=SIG%20TERM") })
            #expect(requests.contains {
                $0.target == "/v1.53/networks/create"
                    && $0.body.containsText("project_default")
            })
            #expect(requests.contains {
                $0.target == "/v1.53/volumes/create"
                    && $0.body.containsText("project_data")
            })
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `image operations map metadata and missing images`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(EngineFixtureResponder(recorder: recorder))
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
            #expect(try await provider.imageExists("alpine:3.22"))
            #expect(try await !provider.imageExists("missing"))
            #expect(try await provider.imageDigest("alpine:3.22") == "alpine@sha256:digest")
            let metadata = try await provider.imageMetadata("alpine:3.22")
            #expect(metadata.user == "1000:1000")
            #expect(metadata.environment == ["A=B"])
            #expect(metadata.exposedPorts == ["8080/tcp"])
            #expect(metadata.declaredVolumeTargets == ["/data"])
            #expect(metadata.healthCheck?.test == ["CMD", "true"])
            #expect(try await provider.imageMetadataIfAvailable("missing", platform: nil) == nil)
            #expect(try await provider.bridgeTransformers().first?.reference == "alpine:3.22")

            try await provider.pullImage("alpine:3.22")
            let emitted = LockedStrings()
            try await provider.deleteImage("alpine:3.22", force: true) { emitted.append($0) }
            #expect(emitted.values == ["alpine:3.22"])
            let requests = await recorder.requests
            #expect(requests.contains { $0.target.contains("fromImage=alpine:3.22") })
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `image volume initialization seeds only an empty Engine volume`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)

        let recorder = RequestRecorder()
        let server = fixture.server(ImageVolumeResponder(
            recorder: recorder,
            mountpoint: volume.path,
        ))
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
            let request = ComposeImageVolumeInitializationRequest(
                image: "example/image:latest",
                platform: "linux/arm64",
                imageSubpath: "/state",
                volumeName: "project_state",
            )
            try await provider.initializeImageVolume(request)
            let message = volume.appendingPathComponent("message.txt")
            #expect(try String(contentsOf: message, encoding: .utf8) == "from-image\n")

            try Data("preserved\n".utf8).write(to: message)
            try await provider.initializeImageVolume(request)
            #expect(try String(contentsOf: message, encoding: .utf8) == "preserved\n")

            let requests = await recorder.requests
            #expect(requests.filter { $0.target.contains("/containers/create?") }.count == 1)
            #expect(requests.filter { $0.target.contains("/start") }.count == 1)
            #expect(requests.filter { $0.target.contains("/wait?") }.count == 1)
            #expect(requests.filter { $0.method == .delete }.count == 1)
            #expect(requests.contains { $0.target.contains("platform=linux/arm64") })
            let create = try #require(requests.first { $0.target.contains("/containers/create?") })
            #expect(create.body.containsText(#""Source":"project_state""#))
            #expect(create.body.containsText(#""Target":"/.compose-image-volume""#))
            #expect(create.body.containsText("chown"))
            #expect(create.body.containsText("chmod"))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `image volume initialization serializes concurrent users of one volume`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let recorder = RequestRecorder()
        let server = fixture.server(ImageVolumeResponder(
            recorder: recorder,
            mountpoint: volume.path,
        ))
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
            let request = ComposeImageVolumeInitializationRequest(
                image: "example/image:latest",
                platform: nil,
                imageSubpath: "/state",
                volumeName: "project_state",
            )
            async let first: Void = provider.initializeImageVolume(request)
            async let second: Void = provider.initializeImageVolume(request)
            _ = try await (first, second)

            let requests = await recorder.requests
            #expect(requests.filter { $0.target.contains("/containers/create?") }.count == 1)
            #expect(requests.filter { $0.target.contains("/wait?") }.count == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }
}

private struct EngineFixture {
    let root: URL
    let socketPath: String

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("ccer-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700],
        )
        socketPath = root.appendingPathComponent("engine.sock").path
    }

    func server(_ responder: some DockerHTTPResponder) -> ContainerUnixHTTPServer {
        ContainerUnixHTTPServer(
            responder: responder,
            socketPath: socketPath,
            logger: Logger(label: "ComposeEngineRuntimeTests"),
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RequestRecorder {
    private(set) var requests: [DockerHTTPRequest] = []
    func append(_ request: DockerHTTPRequest) {
        requests.append(request)
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }

    var values: [String] {
        lock.withLock { storage }
    }
}

private struct EngineFixtureResponder: DockerHTTPResponder {
    let recorder: RequestRecorder?

    init(recorder: RequestRecorder? = nil) {
        self.recorder = recorder
    }

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        await recorder?.append(request)
        if request.target.contains("missing") {
            return .fixture(#"{"message":"not found"}"#, status: 404)
        }
        switch (request.method, request.target) {
        case let (.get, target) where target.hasPrefix("/v1.53/containers/json"):
            return .fixture(Self.containerList)
        case let (.get, target) where target.hasSuffix("/json") && target.contains("/containers/"):
            return .fixture(Self.containerInspect)
        case let (.post, target) where target.contains("/wait"):
            return .fixture(#"{"StatusCode":17}"#)
        case (.post, "/v1.53/networks/create"):
            return .fixture(#"{"Id":"network-id","Warning":""}"#, status: 201)
        case (.post, "/v1.53/volumes/create"):
            return .fixture(Self.volume, status: 201)
        case (.get, "/v1.53/volumes"):
            return .fixture(#"{"Volumes":["# + Self.volume + #"],"Warnings":[]}"#)
        case (.get, "/v1.53/images/json"):
            return .fixture(Self.imageList)
        case let (.get, target) where target.hasSuffix("/json") && target.contains("/images/"):
            return .fixture(Self.imageInspect)
        default:
            return .empty(status: 204)
        }
    }

    // Test data mirrors the compact Engine wire representation.
    // swiftlint:disable line_length
    private static let containerList = #"[{"Id":"abc","Names":["/demo"],"Image":"alpine:3.22","ImageID":"sha256:img","Command":"sleep","Created":1,"State":"running","Status":"Up","Ports":[{"IP":"127.0.0.1","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],"Labels":{"project":"demo"},"Mounts":[{"Type":"bind","Name":"","Source":"/tmp/workspace","Destination":"/workspace","Driver":"","Mode":"","RW":true,"Propagation":""}]}]"#
    private static let containerInspect = #"{"Id":"abc","Created":"2026-09-10T00:00:00.000Z","Path":"/bin/sh","Args":[],"Name":"/demo","State":{"Status":"running","Running":true,"Paused":false,"Restarting":false,"OOMKilled":false,"Dead":false,"Pid":1,"ExitCode":0,"Error":"","StartedAt":"2026-09-10T00:00:00.000Z","FinishedAt":"2026-09-10T00:00:00.000Z","Health":{"Status":"healthy","FailingStreak":0,"Log":[]}},"Image":"sha256:img","Config":{"Hostname":"demo","User":"","AttachStdin":false,"AttachStdout":false,"AttachStderr":false,"Tty":false,"OpenStdin":false,"Env":[],"Cmd":[],"Image":"alpine:3.22","ExposedPorts":{},"Volumes":{},"WorkingDir":"","Entrypoint":[],"Labels":{"project":"demo"}},"HostConfig":{"Binds":[],"NetworkMode":"default"},"Mounts":[],"NetworkSettings":{"Ports":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]},"Networks":{"project_default":{"IPAddress":"192.168.1.2"}}}}"#
    private static let volume = #"{"CreatedAt":"2026-09-10T00:00:00Z","Driver":"local","Labels":{"project":"demo"},"Mountpoint":"/volumes/project_data","Name":"project_data","Options":{},"Scope":"local"}"#
    private static let imageInspect = #"{"Id":"sha256:img","RepoTags":["alpine:3.22"],"RepoDigests":["alpine@sha256:digest"],"Created":"2026-09-10T00:00:00Z","Size":42,"VirtualSize":42,"Architecture":"arm64","Variant":"v8","Os":"linux","Config":{"User":"1000:1000","Env":["A=B"],"Entrypoint":["/bin/sh"],"Cmd":["sleep","1"],"Labels":{"purpose":"test"},"WorkingDir":"/workspace","ExposedPorts":{"8080/tcp":{}},"Volumes":{"/data":{}},"StopSignal":"SIGTERM","Healthcheck":{"Test":["CMD","true"],"Interval":1000,"Timeout":500,"StartPeriod":0,"Retries":3}}}"#
    private static let imageList = #"[{"Containers":-1,"Created":1,"Id":"sha256:img","Labels":{"purpose":"test"},"ParentId":"","RepoDigests":["alpine@sha256:digest"],"RepoTags":["alpine:3.22"],"SharedSize":-1,"Size":42,"VirtualSize":42}]"#
    // swiftlint:enable line_length
}

private struct ImageVolumeResponder: DockerHTTPResponder {
    let recorder: RequestRecorder
    let mountpoint: String

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        await recorder.append(request)
        switch (request.method, request.target) {
        case let (.get, target) where target.contains("/volumes/project_state"):
            let body = try? JSONSerialization.data(withJSONObject: [
                "CreatedAt": "2026-09-11T00:00:00Z",
                "Driver": "local",
                "Labels": [:],
                "Mountpoint": mountpoint,
                "Name": "project_state",
                "Options": [:],
                "Scope": "local",
            ], options: [.sortedKeys])
            return DockerHTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: .bytes(body ?? Data()),
            )
        case let (.post, target) where target.contains("/containers/create?"):
            return .fixture(#"{"Id":"helper-id","Warnings":[]}"#, status: 201)
        case let (.post, target) where target.contains("/wait?"):
            try? Data("from-image\n".utf8).write(
                to: URL(fileURLWithPath: mountpoint).appendingPathComponent("message.txt")
            )
            return .fixture(#"{"StatusCode":0}"#)
        default:
            return .empty(status: 204)
        }
    }
}

private extension DockerHTTPResponse {
    static func fixture(_ json: String, status: Int = 200) -> DockerHTTPResponse {
        DockerHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: .bytes(Data(json.utf8)),
        )
    }
}

private extension Data {
    func containsText(_ value: String) -> Bool {
        String(data: self, encoding: .utf8)?.contains(value) == true
    }
}
