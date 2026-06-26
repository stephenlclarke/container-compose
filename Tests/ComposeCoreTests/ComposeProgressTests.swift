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
import Foundation
import Testing

@Suite("Compose progress reporter")
struct ComposeProgressTests {
    @Test
    func `plain progress emits pending and done rows`() async throws {
        let emitted = LockedDataRecorder()
        let reporter = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append($0) },
        )

        let value = try await reporter.activity("Loading Compose model") {
            "loaded"
        }

        #expect(value == "loaded")
        #expect(emitted.string == "⠋ Loading Compose model\n✔︎ Loading Compose model\n")
    }

    @Test
    func `plain progress emits failure row before rethrowing`() async throws {
        let emitted = LockedDataRecorder()
        let reporter = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append($0) },
        )

        do {
            _ = try await reporter.activity("Building api") {
                throw ComposeError.invalidProject("broken build")
            }
            Issue.record("Expected progress activity to rethrow")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("broken build"))
        }

        #expect(emitted.string == "⠋ Building api\n✘ Building api\n")
    }

    @Test
    func `quiet progress emits nothing`() async throws {
        let emitted = LockedDataRecorder()
        let reporter = ComposeProgressReporter(
            style: .quiet,
            emitData: { emitted.append($0) },
        )

        try await reporter.activity("Loading Compose model") {}

        #expect(emitted.string.isEmpty)
    }

    @Test
    func `colored plain progress wraps status marks`() async throws {
        let emitted = LockedDataRecorder()
        let reporter = ComposeProgressReporter(
            style: .plain,
            colorEnabled: true,
            emitData: { emitted.append($0) },
        )

        try await reporter.activity("Building api") {}

        #expect(emitted.string.contains("\u{001B}[38;5;63m⠋\u{001B}[0m Building api"))
        #expect(emitted.string.contains("\u{001B}[32m✔︎\u{001B}[0m Building api"))
    }

    @Test
    func `json progress emits structured running and done events`() async throws {
        let emitted = LockedDataRecorder()
        let reporter = ComposeProgressReporter(
            style: .json,
            emitData: { emitted.append($0) },
        )

        let value = try await reporter.activity("Loading Compose model") {
            "loaded"
        }

        #expect(value == "loaded")
        let events = try emitted.jsonLines()
        #expect(events == [
            ["id": "container-compose", "status": "running", "text": "Loading Compose model"],
            ["id": "container-compose", "status": "done", "text": "Loading Compose model"],
        ])
    }

    @Test
    func `json progress emits error event before rethrowing`() async throws {
        let emitted = LockedDataRecorder()
        let reporter = ComposeProgressReporter(
            style: .json,
            emitData: { emitted.append($0) },
        )

        do {
            _ = try await reporter.activity("Building api") {
                throw ComposeError.invalidProject("broken build")
            }
            Issue.record("Expected progress activity to rethrow")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("broken build"))
        }

        let events = try emitted.jsonLines()
        #expect(events == [
            ["id": "container-compose", "status": "running", "text": "Building api"],
            ["id": "container-compose", "status": "error", "text": "Building api"],
        ])
    }

    @Test
    func `tty progress emits first frame before operation starts`() async throws {
        let emitted = LockedDataRecorder()
        let reporter = ComposeProgressReporter(
            style: .tty,
            emitData: { emitted.append($0) },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
        )

        try await reporter.activity("Loading Compose model") {
            #expect(emitted.string == "\r⠋ Loading Compose model")
        }

        #expect(emitted.string == "\r⠋ Loading Compose model\r\u{001B}[K✔︎ Loading Compose model\n")
    }
}

private final class LockedDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer {
            lock.unlock()
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    func jsonLines() throws -> [[String: String]] {
        try string
            .split(separator: "\n")
            .map { line in
                let data = try #require(String(line).data(using: .utf8))
                return try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            }
    }
}
