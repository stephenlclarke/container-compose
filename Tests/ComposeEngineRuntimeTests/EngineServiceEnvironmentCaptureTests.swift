// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
@testable import ComposeEngineRuntime
import Darwin
import Foundation
import Testing

struct EngineServiceEnvironmentCaptureTests {
    @Test func capturesExactBytesAndOrderingUsingOwnedProcesses() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let first = fixture.root.appendingPathComponent("-first.env")
        let second = fixture.root.appendingPathComponent("second.env")
        let bytes = [Data("KEY=first\r\n".utf8), Data([0xff])]
        try bytes[0].write(to: first)
        try bytes[1].write(to: second)
        let result = try await EngineServiceEnvironment.capture(
            paths: [first.path, second.path], runner: ProcessRunner()
        )
        #expect(result == bytes)
    }

    @Test func missingAndOversizedFilesFailWithoutLeakingOutput() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("env")
        let secret = "TOKEN=private-value"
        try Data(secret.utf8).write(to: file)
        for paths in [[file.path, file.path], [fixture.root.appendingPathComponent("missing").path]] {
            do {
                _ = try await EngineServiceEnvironment.capture(
                    paths: paths, runner: ProcessRunner(), maximumBytes: secret.utf8.count
                )
                Issue.record("Capture should have failed")
            } catch {
                #expect(!String(describing: error).contains(secret))
            }
        }
    }

    @Test func unopenedFIFOIsCancelledAtDeadline() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let fifo = fixture.root.appendingPathComponent("waiting.env")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let start = ContinuousClock.now
        await #expect(throws: ComposeError.self) {
            try await EngineServiceEnvironment.capture(
                paths: [fifo.path], runner: ProcessRunner(), timeout: .milliseconds(100)
            )
        }
        #expect(start.duration(to: .now) < .seconds(10))
    }

    @Test func validatesBoundsAndEmptyPaths() async throws {
        #expect(try await EngineServiceEnvironment.capture(paths: [], runner: ProcessRunner()) == [])
        await #expect(throws: ComposeError.self) {
            try await EngineServiceEnvironment.capture(paths: [""], runner: ProcessRunner())
        }
        await #expect(throws: ComposeError.self) {
            try await EngineServiceEnvironment.capture(paths: ["unused"], runner: ProcessRunner(), maximumBytes: 0)
        }
    }
}
