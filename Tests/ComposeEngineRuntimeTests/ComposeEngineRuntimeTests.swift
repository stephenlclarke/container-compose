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
// swiftlint:disable:next type_body_length
struct ComposeEngineRuntimeTests {
    @Test
    func `bundled volume initializer resolves Homebrew links and platform`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-engine-homebrew-\(UUID().uuidString)")
        let executable = root.appendingPathComponent(
            "Cellar/container-compose/current/libexec/container-plugins/compose/bin/compose"
        )
        let link = root.appendingPathComponent("bin/container-compose")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        defer { try? FileManager.default.removeItem(at: root) }

        let resources = executable.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("resources/volume-initializer")
        #expect(
            try ComposeEngineRuntime.bundledVolumeInitializerPath(
                executable: link,
                platform: "linux/arm64/v8"
            ) == resources.appendingPathComponent(
                "compose-volume-initializer-linux-arm64"
            ).path
        )
        #expect(
            try ComposeEngineRuntime.bundledVolumeInitializerPath(
                executable: link,
                platform: "linux/amd64/v3"
            ) == resources.appendingPathComponent(
                "compose-volume-initializer-linux-amd64"
            ).path
        )
        #expect(throws: ComposeError.self) {
            _ = try ComposeEngineRuntime.bundledVolumeInitializerPath(
                executable: link,
                platform: "linux/riscv64"
            )
        }
    }

    @Test
    func `volume initializer build context is deterministic portable ustar`() async throws {
        let helper = Data([0, 1, 127, 128, 255])
        let first = try await EngineVolumeInitializerBuildContext.make(
            sourceImage: "example/image:latest",
            helper: helper,
            helperPath: "/.compose-volume-initializer"
        )
        let second = try await EngineVolumeInitializerBuildContext.make(
            sourceImage: "example/image:latest",
            helper: helper,
            helperPath: "/.compose-volume-initializer"
        )
        let isolated = try await EngineVolumeInitializerBuildContext.make(
            sourceImage: "example/image:latest",
            helper: helper,
            helperPath: "/usr/local/libexec/compose-volume-initializer"
        )
        let amd = try await EngineVolumeInitializerBuildContext.make(
            sourceImage: "example/image:latest",
            helper: helper,
            helperName: "compose-volume-initializer-linux-amd64",
            helperPath: "/.compose-volume-initializer"
        )

        #expect(first == second)
        #expect(first.count.isMultiple(of: 512))
        #expect(first.tarEntryName(at: 0) == "Dockerfile")
        #expect(first.tarMagic(at: 0) == "ustar")
        let helperOffset = try #require(first.nextTarEntryOffset(after: 0))
        #expect(first.tarEntryName(at: helperOffset) == "compose-volume-initializer-linux-arm64")
        #expect(first.tarMagic(at: helperOffset) == "ustar")
        #expect(first.tarContents(at: helperOffset) == helper)
        #expect(first.suffix(1024).allSatisfy { $0 == 0 })
        #expect(first.containsText("FROM example/image:latest"))
        let amdHelperOffset = try #require(amd.nextTarEntryOffset(after: 0))
        #expect(amd.tarEntryName(at: amdHelperOffset) == "compose-volume-initializer-linux-amd64")
        #expect(isolated.containsText("ENTRYPOINT [\"/usr/local/libexec/compose-volume-initializer\"]"))
        #expect(first != isolated)
    }

    @Test
    func `volume initializer cache separates platforms and helper bytes`() {
        let helper = Data([0, 1, 2])
        let arm = EngineVolumeInitializerBuildContext.cacheTag(
            sourceDigest: "example/image@sha256:digest",
            platform: "linux/arm64",
            helper: helper,
            helperPath: "/.compose-volume-initializer"
        )
        let amd = EngineVolumeInitializerBuildContext.cacheTag(
            sourceDigest: "example/image@sha256:digest",
            platform: "linux/amd64",
            helper: helper,
            helperPath: "/.compose-volume-initializer"
        )
        let selectedDefault = EngineVolumeInitializerBuildContext.cacheTag(
            sourceDigest: "example/image@sha256:digest",
            platform: nil,
            helper: helper,
            helperPath: "/.compose-volume-initializer"
        )
        let changedHelper = EngineVolumeInitializerBuildContext.cacheTag(
            sourceDigest: "example/image@sha256:digest",
            platform: "linux/arm64",
            helper: Data([0, 1, 3]),
            helperPath: "/.compose-volume-initializer"
        )
        let changedPath = EngineVolumeInitializerBuildContext.cacheTag(
            sourceDigest: "example/image@sha256:digest",
            platform: "linux/arm64",
            helper: helper,
            helperPath: "/usr/local/libexec/compose-volume-initializer"
        )
        let changedName = EngineVolumeInitializerBuildContext.cacheTag(
            sourceDigest: "example/image@sha256:digest",
            platform: "linux/arm64",
            helper: helper,
            helperName: "compose-volume-initializer-linux-amd64",
            helperPath: "/.compose-volume-initializer"
        )

        #expect(arm != amd)
        #expect(arm != selectedDefault)
        #expect(arm != changedHelper)
        #expect(arm != changedPath)
        #expect(arm != changedName)
    }

    @Test
    func `volume initializer lock rejects links and non-private files`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("target.lock")
        try Data().write(to: target)
        let link = fixture.root.appendingPathComponent("linked.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        await #expect(throws: ComposeError.self) {
            _ = try await EngineVolumeInitializationFileLock.acquire(path: link.path)
        }

        let exposed = fixture.root.appendingPathComponent("exposed.lock")
        try Data().write(to: exposed)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: exposed.path
        )
        await #expect(throws: ComposeError.self) {
            _ = try await EngineVolumeInitializationFileLock.acquire(path: exposed.path)
        }
    }

    @Test
    func `volume initializer mount never obscures the selected image directory`() throws {
        #expect(
            try EngineRuntimeProvider.helperMountPath(imageSubpath: "/workspace")
                == "/.compose-image-volume-target"
        )
        #expect(
            try EngineRuntimeProvider.helperMountPath(
                imageSubpath: "/.compose-image-volume-target/data"
            ) == "/mnt/.compose-image-volume-target"
        )
        #expect(throws: ComposeError.self) {
            _ = try EngineRuntimeProvider.helperMountPath(imageSubpath: "/")
        }
        let first = try EngineRuntimeProvider.helperExecutablePath(
            sourceDigest: "sha256:first",
            platform: "linux/arm64/v8",
            helperName: "compose-volume-initializer-linux-arm64",
            helper: Data([1, 2, 3]),
            imageSubpath: "/workspace"
        )
        let repeated = try EngineRuntimeProvider.helperExecutablePath(
            sourceDigest: "sha256:first",
            platform: "linux/arm64/v8",
            helperName: "compose-volume-initializer-linux-arm64",
            helper: Data([1, 2, 3]),
            imageSubpath: "/workspace"
        )
        let changed = try EngineRuntimeProvider.helperExecutablePath(
            sourceDigest: "sha256:second",
            platform: "linux/arm64/v8",
            helperName: "compose-volume-initializer-linux-arm64",
            helper: Data([1, 2, 3]),
            imageSubpath: "/workspace"
        )
        #expect(first == repeated)
        #expect(first != changed)
        #expect(first.hasPrefix("/.compose-volume-initializer-"))
        #expect(first.hasSuffix("/bin/compose-volume-initializer"))
    }

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
                    source: "/volumes/project_data/_data",
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
    func `exec resolves Engine identity and invokes only the Apple container CLI`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let runner = RecordingRunner(responses: [
            .init(status: 23, stdout: "", stderr: ""),
            .init(status: 0, stdout: "", stderr: ""),
        ])
        let server = fixture.server(EngineFixtureResponder())
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(
                socketPath: fixture.socketPath,
                runner: runner,
                containerBinary: "/usr/local/bin/container"
            )
            let status = try await provider.execAttached(request: .init(
                id: "abc",
                command: ["sh", "-c", "printf ok"],
                environment: ["A=B"],
                user: "1000:1000",
                workingDirectory: "/workspace",
                terminal: .init(interactive: true, tty: true)
            ))
            #expect(status == 23)

            let emitted = LockedStrings()
            try await provider.execDetached(
                request: .init(id: "abc", command: ["sleep", "1"]),
                emit: { emitted.append($0) }
            )
            #expect(emitted.values == ["abc"])
            let commands = runner.commands
            #expect(commands.count == 2)
            #expect(commands[0].executable == "/usr/local/bin/container")
            #expect(commands[0].arguments == [
                "exec", "--env", "A=B", "--user", "1000:1000",
                "--workdir", "/workspace", "--interactive", "--tty",
                "demo", "sh", "-c", "printf ok",
            ])
            #expect(commands[0].io == .inherited)
            #expect(commands[1].executable == "/usr/local/bin/container")
            #expect(commands[1].arguments == ["exec", "--detach", "demo", "sleep", "1"])
            #expect(commands[1].io == .captured(input: nil))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `stock launch binds the Engine managed volume data directory`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let runner = RecordingRunner()
        let server = fixture.server(EngineFixtureResponder())
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(
                socketPath: fixture.socketPath,
                runner: runner,
                containerBinary: "/usr/local/bin/container",
                environmentLauncher: "/usr/bin/env"
            )
            let launchStatus = try await provider.launchContainer(.init(
                command: .create,
                arguments: [
                    "--name", "demo", "--volume", "project_data:/data:ro",
                    "docker.io/library/alpine:3.20",
                ],
                logging: .init(driver: nil, options: [:])
            ))
            let bindStatus = try await provider.launchContainer(.init(
                command: .create,
                arguments: ["--volume", "/tmp/source:/workspace", "alpine"],
                logging: .init(driver: nil, options: [:])
            ))
            let foregroundStatus = try await provider.launchContainer(.init(
                command: .run,
                arguments: ["--volume", "project_data:/data", "alpine", "true"],
                logging: .init(driver: nil, options: [:])
            ))

            #expect(launchStatus == 0)
            #expect(bindStatus == 0)
            #expect(foregroundStatus == 0)
            let commands = runner.commands
            let command = try #require(commands.first)
            #expect(command.executable == "/usr/bin/env")
            #expect(command.arguments == [
                "/usr/local/bin/container", "create", "--name", "demo", "--volume",
                "/volumes/project_data/_data:/data:ro",
                "docker.io/library/alpine:3.20",
            ])
            #expect(commands[1].arguments == [
                "/usr/local/bin/container", "create", "--volume",
                "/tmp/source:/workspace", "alpine",
            ])
            #expect(commands[1].io == .captured(input: nil))
            #expect(commands[2].arguments == [
                "/usr/local/bin/container", "run", "--volume",
                "/volumes/project_data/_data:/data", "alpine", "true",
            ])
            #expect(commands[2].io == .inherited)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `stock launch preserves a managed volume subpath`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let runner = RecordingRunner()
        let server = fixture.server(EngineFixtureResponder())
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(
                socketPath: fixture.socketPath,
                runner: runner,
                containerBinary: "/usr/local/bin/container",
                environmentLauncher: "/usr/bin/env"
            )
            let status = try await provider.launchContainer(.init(
                command: .create,
                arguments: [
                    "--mount",
                    "type=volume,source=project_data,destination=/data,volume-subpath=logs/app,readonly",
                    "alpine",
                ],
                logging: .init(driver: nil, options: [:])
            ))

            #expect(status == 0)
            #expect(runner.commands.first?.arguments == [
                "/usr/local/bin/container", "create", "--mount",
                "type=bind,source=/volumes/project_data/_data/logs/app,destination=/data,readonly",
                "alpine",
            ])
            await #expect(throws: ComposeError.self) {
                _ = try await provider.launchContainer(.init(
                    command: .create,
                    arguments: [
                        "--mount",
                        "type=volume,source=project_data,destination=/data,volume-subpath=../outside",
                        "alpine",
                    ],
                    logging: .init(driver: nil, options: [:])
                ))
            }
            #expect(runner.commands.count == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `stock exec rejects unsupported privileged mode before process launch`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let runner = RecordingRunner()
        let provider = EngineRuntimeProvider(
            socketPath: fixture.socketPath,
            runner: runner,
            containerBinary: "/usr/local/bin/container"
        )

        await #expect(throws: ComposeError.self) {
            _ = try await provider.execAttached(request: .init(
                id: "abc",
                command: ["true"],
                privileged: true
            ))
        }
        #expect(runner.commands.isEmpty)
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
    // swiftlint:disable:next function_body_length
    func `image volume initialization seeds only an empty Engine volume`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: volume.appendingPathComponent("lost+found", isDirectory: true),
            withIntermediateDirectories: false
        )
        let pending = try EngineVolumeInitializationTransaction.create(
            volumeMountpoint: volume
        )
        let staleStage = volume.appendingPathComponent(
            EngineVolumeInitializerBuildContext.stagePrefix + pending.identifier,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staleStage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("partial\n".utf8).write(
            to: staleStage.appendingPathComponent("partial.txt")
        )

        let recorder = RequestRecorder()
        let server = fixture.server(ImageVolumeResponder(
            recorder: recorder,
            mountpoint: volume.path,
        ))
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(
                socketPath: fixture.socketPath,
                volumeInitializerPath: fixture.volumeInitializerPath,
            )
            let request = ComposeImageVolumeInitializationRequest(
                image: "example/image:latest",
                platform: "linux/arm64",
                imageSubpath: "/state",
                volumeName: "project_state",
            )
            let helperPath = try EngineRuntimeProvider.helperExecutablePath(
                sourceDigest: "example/image@sha256:digest",
                platform: request.platform,
                helperName: URL(fileURLWithPath: fixture.volumeInitializerPath).lastPathComponent,
                helper: Data(),
                imageSubpath: request.imageSubpath
            )
            try await provider.initializeImageVolume(request)
            let message = volume.appendingPathComponent("message.txt")
            #expect(try String(contentsOf: message, encoding: .utf8) == "from-image\n")

            try Data("preserved\n".utf8).write(to: message)
            try await provider.initializeImageVolume(request)
            #expect(try String(contentsOf: message, encoding: .utf8) == "preserved\n")

            let requests = await recorder.requests
            #expect(requests.filter { $0.target.contains("/containers/create?") }.count == 1)
            #expect(requests.filter { $0.target.contains("/build?") }.count == 1)
            #expect(requests.filter { $0.target.contains("/start") }.count == 1)
            #expect(requests.filter { $0.target.contains("/wait?") }.count == 1)
            #expect(requests.filter { $0.method == .delete }.count == 1)
            #expect(requests.contains { $0.target.contains("platform=linux/arm64") })
            let create = try #require(requests.first { $0.target.contains("/containers/create?") })
            #expect(create.body.containsText(#""Source":"project_state""#))
            #expect(create.body.containsText(#""Target":"/.compose-image-volume-target""#))
            #expect(create.body.containsText(#""User":"0""#))
            #expect(
                create.body.containsText(
                    #""Entrypoint":["\#(helperPath)"]"#
                )
            )
            #expect(create.body.containsText(#""Image":"devcontainer-volume-initializer:"#))
            #expect(create.body.containsText(#""Cmd":["/state","/.compose-image-volume-target",""#))
            #expect(create.body.containsText(pending.identifier))
            #expect(!create.body.containsText("/bin/sh"))
            let build = try #require(requests.first { $0.target.contains("/build?") })
            #expect(build.target.contains("dockerfile=Dockerfile"))
            #expect(build.target.contains("platform=linux/arm64"))
            #expect(build.body.containsText("FROM example/image@sha256:digest"))
            #expect(!build.body.containsText("FROM example/image:latest"))
            #expect(
                build.body.containsText(
                    #"ENTRYPOINT ["\#(helperPath)"]"#
                )
            )
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
            let firstProvider = EngineRuntimeProvider(
                socketPath: fixture.socketPath,
                volumeInitializerPath: fixture.volumeInitializerPath,
            )
            let secondProvider = EngineRuntimeProvider(
                socketPath: fixture.socketPath,
                volumeInitializerPath: fixture.volumeInitializerPath,
            )
            let request = ComposeImageVolumeInitializationRequest(
                image: "example/image:latest",
                platform: nil,
                imageSubpath: "/state",
                volumeName: "project_state",
            )
            async let first: Void = firstProvider.initializeImageVolume(request)
            async let second: Void = secondProvider.initializeImageVolume(request)
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

    @Test
    func `image volume initialization preserves stage-like user data`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let userData = volume.appendingPathComponent(
            EngineVolumeInitializerBuildContext.stagePrefix
                + "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: userData,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("keep\n".utf8).write(to: userData.appendingPathComponent("value"))

        let recorder = RequestRecorder()
        let server = fixture.server(ImageVolumeResponder(
            recorder: recorder,
            mountpoint: volume.path,
        ))
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(
                socketPath: fixture.socketPath,
                volumeInitializerPath: fixture.volumeInitializerPath,
            )
            try await provider.initializeImageVolume(.init(
                image: "example/image:latest",
                platform: nil,
                imageSubpath: "/state",
                volumeName: "project_state",
            ))

            #expect(
                try String(
                    contentsOf: userData.appendingPathComponent("value"),
                    encoding: .utf8
                ) == "keep\n"
            )
            let requests = await recorder.requests
            #expect(requests.filter { $0.target.contains("/containers/create?") }.isEmpty)
            #expect(requests.filter { $0.target.contains("/build?") }.isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `locally built image uses a verified temporary build alias`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let recorder = RequestRecorder()
        let server = fixture.server(ImageVolumeResponder(
            recorder: recorder,
            mountpoint: volume.path,
            hasRepositoryDigest: false
        ))
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(
                socketPath: fixture.socketPath,
                volumeInitializerPath: fixture.volumeInitializerPath
            )
            try await provider.initializeImageVolume(.init(
                image: "local/devcontainer:latest",
                platform: "linux/arm64",
                imageSubpath: "/workspace",
                volumeName: "project_state"
            ))

            let requests = await recorder.requests
            let tag = try #require(requests.first {
                $0.method == .post && $0.target.contains("/tag?repo=devcontainer-volume-source")
            })
            #expect(tag.target.contains("/images/local%2Fdevcontainer:latest/tag?"))
            let build = try #require(requests.first { $0.target.contains("/build?") })
            #expect(build.body.containsText("FROM devcontainer-volume-source:"))
            #expect(!build.body.containsText("FROM sha256:source-image"))
            #expect(requests.contains {
                $0.method == .delete
                    && $0.target.contains("/images/devcontainer-volume-source:")
            })
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `image volume transaction is private durable and removable`() throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)

        let transaction = try EngineVolumeInitializationTransaction.create(
            volumeMountpoint: volume
        )
        #expect(
            try EngineVolumeInitializationTransaction.load(volumeMountpoint: volume)
                == transaction
        )
        var status = stat()
        #expect(Darwin.lstat(transaction.path, &status) == 0)
        #expect(status.st_mode & (S_IRWXG | S_IRWXO) == 0)

        try transaction.complete()
        #expect(
            try EngineVolumeInitializationTransaction.load(volumeMountpoint: volume) == nil
        )
    }
}

private struct EngineFixture {
    let root: URL
    let socketPath: String
    let volumeInitializerPath: String

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("ccer-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700],
        )
        socketPath = root.appendingPathComponent("engine.sock").path
        let initializerDirectory = root.appendingPathComponent("volume-initializer")
        try FileManager.default.createDirectory(
            at: initializerDirectory,
            withIntermediateDirectories: false,
        )
        let initializer = initializerDirectory
            .appendingPathComponent("compose-volume-initializer-linux-arm64")
        try Data().write(to: initializer)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: initializer.path,
        )
        volumeInitializerPath = initializer.path
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

    // swiftlint:disable:next cyclomatic_complexity
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
        case let (.get, target) where target.hasPrefix("/v1.53/volumes/"):
            return .fixture(Self.volume)
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
    private static let volume = #"{"CreatedAt":"2026-09-10T00:00:00Z","Driver":"local","Labels":{"project":"demo"},"Mountpoint":"/volumes/project_data/_data","Name":"project_data","Options":{},"Scope":"local"}"#
    private static let imageInspect = #"{"Id":"sha256:img","RepoTags":["alpine:3.22"],"RepoDigests":["alpine@sha256:digest"],"Created":"2026-09-10T00:00:00Z","Size":42,"VirtualSize":42,"Architecture":"arm64","Variant":"v8","Os":"linux","Config":{"User":"1000:1000","Env":["A=B"],"Entrypoint":["/bin/sh"],"Cmd":["sleep","1"],"Labels":{"purpose":"test"},"WorkingDir":"/workspace","ExposedPorts":{"8080/tcp":{}},"Volumes":{"/data":{}},"StopSignal":"SIGTERM","Healthcheck":{"Test":["CMD","true"],"Interval":1000,"Timeout":500,"StartPeriod":0,"Retries":3}}}"#
    private static let imageList = #"[{"Containers":-1,"Created":1,"Id":"sha256:img","Labels":{"purpose":"test"},"ParentId":"","RepoDigests":["alpine@sha256:digest"],"RepoTags":["alpine:3.22"],"SharedSize":-1,"Size":42,"VirtualSize":42}]"#
    // swiftlint:enable line_length
}

private struct ImageVolumeResponder: DockerHTTPResponder {
    let recorder: RequestRecorder
    let mountpoint: String
    var hasRepositoryDigest = true

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
        case let (.get, target) where target.contains("devcontainer-volume-initializer"):
            return .fixture(#"{"message":"not found"}"#, status: 404)
        case let (.get, target) where target.contains("/images/"):
            let digests = hasRepositoryDigest
                ? #"["example/image@sha256:digest"]"#
                : "[]"
            return .fixture(
                #"{"Id":"sha256:source-image","RepoTags":["example/image:latest"],"RepoDigests":\#(digests),"Created":"2026-09-11T00:00:00Z","Size":42,"VirtualSize":42,"Architecture":"arm64","Os":"linux","Config":{}}"#
            )
        case let (.post, target) where target.contains("/build?"):
            return .empty(status: 200)
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
        range(of: Data(value.utf8)) != nil
    }

    func tarEntryName(at offset: Int) -> String? {
        tarString(offset: offset, length: 100)
    }

    func tarMagic(at offset: Int) -> String? {
        tarString(offset: offset + 257, length: 6)
    }

    func tarContents(at offset: Int) -> Data? {
        guard let size = tarSize(at: offset) else {
            return nil
        }
        let start = offset + 512
        guard start + size <= count else {
            return nil
        }
        return self[start ..< start + size]
    }

    func nextTarEntryOffset(after offset: Int) -> Int? {
        guard let size = tarSize(at: offset) else {
            return nil
        }
        return offset + 512 + ((size + 511) / 512 * 512)
    }

    private func tarSize(at offset: Int) -> Int? {
        guard let value = tarString(offset: offset + 124, length: 12) else {
            return nil
        }
        return Int(value, radix: 8)
    }

    private func tarString(offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= count else {
            return nil
        }
        let field = self[offset ..< offset + length].prefix { $0 != 0 }
        return String(bytes: field, encoding: .utf8)
    }
}
