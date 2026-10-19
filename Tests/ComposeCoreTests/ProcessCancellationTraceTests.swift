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

struct ProcessCancellationTraceTests {
    @Test
    func `process diagnostics report normal completion without cancellation`() async throws {
        let trace = ProcessCancellationTrace()
        let result = try await ProcessRunner(observe: trace.record).run("/bin/sh", ["-c", "printf out; printf err >&2"])
        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
        #expect(trace.phases == Set([
            .waitStarted, .processReaped, .stdoutDrainStarted, .stderrDrainStarted,
            .stdoutDrained, .stderrDrained, .completionResumed,
        ]))
        #expect(trace.count == trace.phases.count)
    }
}

/// Keeps payload-free monotonic observations outside production state locks.
final class ProcessCancellationTrace: @unchecked Sendable {
    private struct Entry: Encodable {
        let phase: String
        let offsetNS: Int64
    }

    private let lock = NSLock()
    private var observations: [(ProcessRunPhase, ContinuousClock.Instant)] = []

    func record(_ phase: ProcessRunPhase) {
        let instant = ContinuousClock.now
        lock.lock()
        observations.append((phase, instant))
        lock.unlock()
    }

    var phases: Set<ProcessRunPhase> {
        lock.lock()
        defer { lock.unlock() }
        return Set(observations.map(\.0))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observations.count
    }

    func expectCancellation(since start: ContinuousClock.Instant, elapsed: Duration, io: CommandIO) throws {
        let phaseReport = try report(since: start, elapsed: elapsed)
        print("Process cancellation phases [\(io)]: \(phaseReport)")
        #expect(elapsed < .seconds(2), "Cancellation phase offsets: \(phaseReport)")
        #expect(phases.isSuperset(of: [
            .waitStarted, .processReaped, .cancellationRequested, .termSent,
            .escalationStarted, .terminationWaitFinished, .completionResumed,
        ]))
        #expect(count == phases.count)
    }

    private func report(since start: ContinuousClock.Instant, elapsed: Duration) throws -> String {
        lock.lock()
        let snapshot = observations
        lock.unlock()
        var entries = snapshot.sorted { $0.1 < $1.1 }.map { phase, instant in
            Entry(phase: phase.rawValue, offsetNS: nanoseconds(instant - start))
        }
        entries.append(Entry(phase: "awaitReturned", offsetNS: nanoseconds(elapsed)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try #require(String(data: encoder.encode(entries), encoding: .utf8))
    }

    private func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }
}
