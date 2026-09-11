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
import Foundation
import Testing

struct ComposeEngineRuntimePlatformTests {
    @Test
    func `image volume initialization derives an omitted platform from the image`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let recorder = RequestRecorder()
        let server = fixture.server(ImageVolumeResponder(
            recorder: recorder,
            mountpoint: volume.path,
            architecture: "amd64"
        ))
        try await server.start()
        let provider = EngineRuntimeProvider(
            socketPath: fixture.socketPath,
            volumeInitializerPath: fixture.volumeInitializerPath
        )

        try await provider.initializeImageVolume(.init(
            image: "example/image:latest",
            platform: nil,
            imageSubpath: "/state",
            volumeName: "project_state"
        ))

        let requests = await recorder.requests
        #expect(requests.contains {
            $0.target.contains("/build?") && $0.target.contains("platform=linux/amd64")
        })
        #expect(requests.contains {
            $0.target.contains("/containers/create?")
                && $0.target.contains("platform=linux/amd64")
        })
        try await server.shutdown()
    }

    @Test
    func `platform aware image metadata uses the selected variant`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let recorder = RequestRecorder()
        let server = fixture.server(ImageVolumeResponder(
            recorder: recorder,
            mountpoint: volume.path
        ))
        try await server.start()
        let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)

        let healthCheck = try await provider.imageHealthCheck(
            "example/image:latest",
            platform: "linux/arm64"
        )
        let volumeTargets = try await provider.imageDeclaredVolumeTargets(
            "example/image:latest",
            platform: "linux/arm64"
        )
        let metadata = try await provider.imageMetadataIfAvailable(
            "example/image:latest",
            platform: "linux/arm64"
        )

        #expect(healthCheck?.test == ["CMD", "true"])
        #expect(volumeTargets == ["/state"])
        #expect(metadata?.environment == ["PLATFORM=arm64"])
        let requests = await recorder.requests
        #expect(requests.filter {
            Self.requestsPlatform(
                $0.target,
                operatingSystem: "linux",
                architecture: "arm64",
                variant: nil
            )
        }.count == 3)
        try await server.shutdown()
    }

    @Test
    func `image volume initialization rejects a mismatched local platform`() async throws {
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
        let provider = EngineRuntimeProvider(
            socketPath: fixture.socketPath,
            volumeInitializerPath: fixture.volumeInitializerPath
        )

        await #expect(throws: ComposeError.self) {
            try await provider.initializeImageVolume(
                ComposeImageVolumeInitializationRequest(
                    image: "example/image:latest",
                    platform: "linux/amd64/v3",
                    imageSubpath: "/state",
                    volumeName: "project_state"
                )
            )
        }

        let requests = await recorder.requests
        #expect(requests.contains {
            Self.requestsPlatform(
                $0.target,
                operatingSystem: "linux",
                architecture: "amd64",
                variant: "v3"
            )
        })
        #expect(!requests.contains { $0.target.contains("/build?") })
        #expect(!requests.contains { $0.target.contains("/containers/create?") })
        try await server.shutdown()
    }

    @Test
    func `image volume initialization rejects a mismatched platform variant`() async throws {
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
        let provider = EngineRuntimeProvider(
            socketPath: fixture.socketPath,
            volumeInitializerPath: fixture.volumeInitializerPath
        )

        await #expect(throws: ComposeError.self) {
            try await provider.initializeImageVolume(
                ComposeImageVolumeInitializationRequest(
                    image: "example/image:latest",
                    platform: "linux/arm64/v7",
                    imageSubpath: "/state",
                    volumeName: "project_state"
                )
            )
        }

        let requests = await recorder.requests
        #expect(requests.contains {
            Self.requestsPlatform(
                $0.target,
                operatingSystem: "linux",
                architecture: "arm64",
                variant: "v7"
            )
        })
        #expect(!requests.contains { $0.target.contains("/build?") })
        #expect(!requests.contains { $0.target.contains("/containers/create?") })
        try await server.shutdown()
    }

    private static func requestsPlatform(
        _ target: String,
        operatingSystem: String,
        architecture: String,
        variant: String?
    ) -> Bool {
        guard let decoded = target.removingPercentEncoding else {
            return false
        }
        return decoded.contains("platform={")
            && decoded.contains(#""os":"\#(operatingSystem)""#)
            && decoded.contains(#""architecture":"\#(architecture)""#)
            && variant.map { decoded.contains(#""variant":"\#($0)""#) } ?? true
    }
}

extension ComposeEngineRuntimeTests {
    @Test
    func `stock launch never rewrites process mount arguments`() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let runner = RecordingRunner()
        let server = fixture.server(EngineFixtureResponder())
        try await server.start()
        let provider = EngineRuntimeProvider(
            socketPath: fixture.socketPath,
            runner: runner,
            containerBinary: "/usr/local/bin/container",
            environmentLauncher: "/usr/bin/env"
        )

        let status = try await provider.launchContainer(.init(
            command: .run,
            arguments: [
                "--name", "command-arguments", "alpine", "tool", "--volume",
                "project_data:/application-data",
            ],
            logging: .init(driver: nil, options: [:])
        ))

        #expect(status == 0)
        #expect(runner.commands.first?.arguments == [
            "/usr/local/bin/container", "run", "--name", "command-arguments",
            "alpine", "tool", "--volume", "project_data:/application-data",
        ])
        try await server.shutdown()
    }
}
