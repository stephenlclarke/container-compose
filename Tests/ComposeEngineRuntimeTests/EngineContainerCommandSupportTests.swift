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
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct EngineContainerCommandSupportTests {
    @Test
    func `volume initializer allocates an isolated recovery mount`() throws {
        #expect(
            try EngineRuntimeProvider.helperRecoveryMountPath(
                imageSubpath: "/workspace",
                volumeMountPath: "/.compose-image-volume-target"
            ) == "/.compose-image-volume-recovery"
        )
        #expect(
            try EngineRuntimeProvider.helperRecoveryMountPath(
                imageSubpath: "/.compose-image-volume-recovery/data",
                volumeMountPath: "/.compose-image-volume-target"
            ) == "/mnt/.compose-image-volume-recovery"
        )
    }

    @Test
    func `volume transaction owns a private persistent recovery directory`() throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let transaction = try EngineVolumeInitializationTransaction.create(
            volumeMountpoint: volume
        )
        var status = stat()

        #expect(
            try EngineVolumeInitializationTransaction.load(volumeMountpoint: volume)
                == transaction
        )
        #expect(Darwin.lstat(transaction.path, &status) == 0)
        #expect(status.st_mode & (S_IRWXG | S_IRWXO) == 0)
        #expect(Darwin.lstat(transaction.recoveryPath, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFDIR)
        #expect(status.st_mode & (S_IRWXG | S_IRWXO) == 0)
        let pending = URL(fileURLWithPath: transaction.recoveryPath)
            .appendingPathComponent("journal")
        try Data("pending".utf8).write(to: pending)
        #expect(throws: ComposeError.self) {
            try transaction.complete()
        }
        try FileManager.default.removeItem(at: pending)
        try transaction.complete()
        #expect(
            try EngineVolumeInitializationTransaction.load(volumeMountpoint: volume) == nil
        )
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: transaction.recoveryPath).isEmpty
        )
    }

    @Test
    func `stock launch parses generated option arities through managed volumes`() async throws {
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
                    "--engine-api-socket", "--health-cmd", "true", "--restart", "on-failure",
                    "--log-opt", "max-size=10m", "--volume", "project_data:/data",
                    "alpine", "--volume", "container-command:/unchanged",
                ],
                logging: .init(driver: nil, options: [:])
            ))

            #expect(status == 0)
            #expect(runner.commands.first?.arguments == [
                "/usr/local/bin/container", "create", "--engine-api-socket",
                "--health-cmd", "true", "--restart", "on-failure", "--log-opt",
                "max-size=10m", "--volume", "/volumes/project_data/_data:/data",
                "alpine", "--volume", "container-command:/unchanged",
            ])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }
}
