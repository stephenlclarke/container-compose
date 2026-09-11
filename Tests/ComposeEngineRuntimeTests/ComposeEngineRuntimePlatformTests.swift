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
        #expect(requests.contains { $0.target.contains("platform=linux/amd64/v3") })
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
        #expect(requests.contains { $0.target.contains("platform=linux/arm64/v7") })
        #expect(!requests.contains { $0.target.contains("/build?") })
        #expect(!requests.contains { $0.target.contains("/containers/create?") })
        try await server.shutdown()
    }
}
