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

import ComposeContainerRuntime
@testable import ComposeCore
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import Testing

extension ComposeOrchestratorTests {
    @Test("log manager normalizes unreadable driver errors for Compose")
    func logManagerNormalizesUnreadableDriverErrorsForCompose() async throws {
        let client = RecordingContainerLogAPIClient(
            error: ContainerizationError(
                .unsupported,
                message: "configured logging driver does not support reading"
            )
        )
        let manager = ContainerClientLogManager(client: client)

        do {
            try await manager.logs(id: "demo-api-1", tail: nil, follow: false) { (_: Data) in }
            Issue.record("Expected the unreadable-driver runtime error")
        } catch let error as ComposeRuntimeLogError {
            #expect(error == .readingUnsupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("log manager normalizes the public unreadable driver category")
    func logManagerNormalizesPublicUnreadableDriverCategory() async throws {
        let client = RecordingContainerLogAPIClient(
            error: ContainerLogReaderError.configuredDriverDoesNotSupportReading
        )
        let manager = ContainerClientLogManager(client: client)

        do {
            try await manager.logs(id: "demo-api-1", tail: nil, follow: false) { (_: Data) in }
            Issue.record("Expected the unreadable-driver runtime error")
        } catch let error as ComposeRuntimeLogError {
            #expect(error == .readingUnsupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("log manager passes tail to direct API for static logs")
    func logManagerPassesTailToDirectAPIForStaticLogs() async throws {
        let emitted = MessageRecorder()
        let client = try RecordingContainerLogAPIClient(fileHandles: [
            temporaryLogFileHandle(contents: "one\ntwo\nthree\n"),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(id: "demo-api-1", tail: 2, follow: false, emit: { emitted.append($0) })

        #expect(emitted.messages == ["one\ntwo\nthree"])
        #expect(await client.requests == ["demo-api-1"])
        #expect(await client.options == [
            ContainerLogOptions(tail: 2),
        ])
        #expect(await client.replayOptions == [
            ContainerLogReplayOptions(includeRotated: true),
        ])
    }

    @Test("log manager applies static time filters through structured records")
    func logManagerAppliesStaticTimeFiltersThroughStructuredRecords() async throws {
        let emitted = MessageRecorder()
        let since = Date(timeIntervalSince1970: 100)
        let until = Date(timeIntervalSince1970: 200)
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: since.addingTimeInterval(-1), stream: .stdout, data: Data("old\n".utf8)),
            ContainerLogRecord(timestamp: since, stream: .stdout, data: Data("inside".utf8)),
            ContainerLogRecord(timestamp: until, stream: .stdout, data: Data("-line\n".utf8)),
            ContainerLogRecord(timestamp: until.addingTimeInterval(1), stream: .stdout, data: Data("new\n".utf8)),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: 5,
            follow: false,
            since: since,
            until: until,
            timestamps: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == ["inside-line"])
        #expect(await client.recordRequests == ["demo-api-1"])
        #expect(await client.recordOptions == [
            ContainerLogOptions(tail: 5, since: since, until: until),
        ])
        #expect(await client.recordReplayOptions == [
            ContainerLogReplayOptions(includeRotated: true),
        ])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager reads all logs from direct API handles")
    func logManagerReadsAllLogsFromDirectAPIHandles() async throws {
        let emitted = MessageRecorder()
        let client = try RecordingContainerLogAPIClient(fileHandles: [
            temporaryLogFileHandle(contents: "one\ntwo\n"),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { emitted.append($0) })

        #expect(emitted.messages == ["one\ntwo"])
        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager preserves blank lines from direct API logs")
    func logManagerPreservesBlankLinesFromDirectAPILogs() async throws {
        let emitted = MessageRecorder()
        let client = try RecordingContainerLogAPIClient(fileHandles: [
            temporaryLogFileHandle(contents: "one\n\ntwo\n"),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { emitted.append($0) })

        #expect(emitted.messages == ["one\n\ntwo"])
        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager preserves Compose line boundary fixtures")
    func logManagerPreservesComposeLineBoundaryFixtures() async throws {
        struct Fixture {
            var name: String
            var input: Data
            var expectedMessages: [String]
        }

        let fixtures = [
            Fixture(name: "empty file emits nothing", input: Data(), expectedMessages: []),
            Fixture(name: "single blank line", input: Data("\n".utf8), expectedMessages: [""]),
            Fixture(name: "two blank lines", input: Data("\n\n".utf8), expectedMessages: ["\n"]),
            Fixture(name: "final newline is not an extra record", input: Data("one\n".utf8), expectedMessages: ["one"]),
            Fixture(name: "blank record before final newline", input: Data("one\n\n".utf8), expectedMessages: ["one\n"]),
            Fixture(name: "unterminated final record", input: Data("one\n\npartial".utf8), expectedMessages: ["one\n\npartial"]),
            Fixture(name: "CRLF and CR separators", input: Data("one\r\ntwo\rthree\n".utf8), expectedMessages: ["one\ntwo\nthree"]),
        ]

        for fixture in fixtures {
            let emitted = MessageRecorder()
            let client = try RecordingContainerLogAPIClient(fileHandles: [
                temporaryLogFileHandle(data: fixture.input),
            ])
            let manager = ContainerClientLogManager(client: client)

            try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { emitted.append($0) })

            #expect(emitted.messages == fixture.expectedMessages, "Fixture failed: \(fixture.name)")
            #expect(await client.requests == ["demo-api-1"], "Fixture did not request logs: \(fixture.name)")
        }
    }

    @Test("log manager renders timestamped records from direct API")
    func logManagerRendersTimestampedRecordsFromDirectAPI() async throws {
        let emitted = MessageRecorder()
        let firstTimestamp = date("2026-06-18T10:00:00.123Z")
        let secondTimestamp = date("2026-06-18T10:00:01.456Z")
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: firstTimestamp, stream: .stdout, data: Data("one\npa".utf8)),
            ContainerLogRecord(timestamp: secondTimestamp, stream: .stderr, data: Data("rt\n\n".utf8)),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: false,
            since: nil,
            until: nil,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            "2026-06-18T10:00:00.123Z one\n2026-06-18T10:00:00.123Z part\n2026-06-18T10:00:01.456Z ",
        ])
        #expect(await client.recordRequests == ["demo-api-1"])
        #expect(await client.recordOptions == [
            ContainerLogOptions(),
        ])
        #expect(await client.recordReplayOptions == [
            ContainerLogReplayOptions(includeRotated: true),
        ])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager applies static timestamped tail through direct API")
    func logManagerAppliesStaticTimestampedTailThroughDirectAPI() async throws {
        let emitted = MessageRecorder()
        let timestamp = date("2026-06-18T10:00:00Z")
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("one\n".utf8)),
            ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("two\n".utf8)),
            ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("three\n".utf8)),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: 2,
            follow: false,
            since: nil,
            until: nil,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            "2026-06-18T10:00:00.000Z two\n2026-06-18T10:00:00.000Z three",
        ])
        #expect(await client.recordOptions == [
            ContainerLogOptions(tail: 2),
        ])
        #expect(await client.recordReplayOptions == [
            ContainerLogReplayOptions(includeRotated: true),
        ])
    }

    @Test("log manager filters static timestamped records through direct API")
    func logManagerFiltersStaticTimestampedRecordsThroughDirectAPI() async throws {
        let emitted = MessageRecorder()
        let before = date("2026-06-18T10:00:00Z")
        let since = date("2026-06-18T10:00:01Z")
        let until = date("2026-06-18T10:00:02Z")
        let after = date("2026-06-18T10:00:03Z")
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: before, stream: .stdout, data: Data("old\n".utf8)),
            ContainerLogRecord(timestamp: since, stream: .stdout, data: Data("inside\n".utf8)),
            ContainerLogRecord(timestamp: until, stream: .stdout, data: Data("closing\n".utf8)),
            ContainerLogRecord(timestamp: after, stream: .stdout, data: Data("new\n".utf8)),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: false,
            since: since,
            until: until,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            "2026-06-18T10:00:01.000Z inside\n2026-06-18T10:00:02.000Z closing",
        ])
        #expect(await client.recordOptions == [
            ContainerLogOptions(since: since, until: until),
        ])
        #expect(await client.recordReplayOptions == [
            ContainerLogReplayOptions(includeRotated: true),
        ])
    }

    @Test("log manager preserves non-UTF-8 bytes from timestamped records")
    func logManagerPreservesNonUTF8BytesFromTimestampedRecords() async throws {
        let emitted = DataRecorder()
        let client = RecordingContainerLogAPIClient(records: [
            ContainerLogRecord(timestamp: date("2026-06-18T10:00:00Z"), stream: .stdout, data: Data([0xFF, 0xFE, 0x0A, 0x41])),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: false,
            since: nil,
            until: nil,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.data == [Data("2026-06-18T10:00:00.000Z ".utf8) + Data([0xFF, 0xFE, 0x0A]) + Data("2026-06-18T10:00:00.000Z A".utf8)])
        #expect(await client.recordRequests == ["demo-api-1"])
    }

    @Test("log manager rejects missing direct API log handles")
    func logManagerRejectsMissingDirectAPILogHandles() async throws {
        let client = RecordingContainerLogAPIClient()
        let manager = ContainerClientLogManager(client: client)

        do {
            try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { (_: Data) in })
            Issue.record("Expected missing log handle error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container logs returned no stdio handle for demo-api-1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager preserves non-UTF-8 bytes from direct API logs")
    func logManagerPreservesNonUTF8BytesFromDirectAPILogs() async throws {
        let emitted = DataRecorder()
        let client = try RecordingContainerLogAPIClient(fileHandles: [
            temporaryLogFileHandle(data: Data([0xFF, 0xFE, 0x0A, 0x41])),
        ])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(id: "demo-api-1", tail: nil, follow: false, emit: { emitted.append($0) })

        #expect(emitted.data == [Data([0xFF, 0xFE, 0x0A, 0x41])])
        #expect(await client.requests == ["demo-api-1"])
    }

    @Test("log manager follows appended direct API log stream")
    func logManagerFollowsAppendedDirectAPILogStream() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("live\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["live"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["live"])
        #expect(await client.followRequests == ["demo-api-1"])
        #expect(await client.followOptions == [ContainerLogOptions(tail: 0)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager follows blank and split direct API log stream")
    func logManagerFollowsBlankAndSplitDirectAPILogStream() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("one\n\npa".utf8),
            Data("rt\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["one", "", "part"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["one", "", "part"])
        #expect(await client.followRequests == ["demo-api-1"])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager completes initial followed direct API stream partial line")
    func logManagerCompletesInitialFollowedDirectAPIStreamPartialLine() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("pa".utf8),
            Data("rt\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: nil, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["part"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["part"])
        #expect(await client.followOptions == [ContainerLogOptions()])
    }

    @Test("log manager passes tail zero to followed direct API stream")
    func logManagerPassesTailZeroToFollowedDirectAPIStream() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("new\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["new"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["new"])
        #expect(await client.followOptions == [ContainerLogOptions(tail: 0)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager flushes initial followed direct API stream partial line after stop")
    func logManagerFlushesInitialFollowedDirectAPIStreamPartialLineAfterStop() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("partial".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider(responses: [true, false])
        )

        try await manager.logs(id: "demo-api-1", tail: nil, follow: true, emit: { emitted.append($0) })

        #expect(emitted.messages == ["partial"])
        #expect(await client.followRequests == ["demo-api-1"])
    }

    @Test("rotating log fixture tolerates a closed reader")
    func rotatingLogFixtureToleratesClosedReader() async throws {
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("delayed\n".utf8),
        ])
        let reader = try await client.followLogs(id: "demo-api-1", options: .default)

        try reader.close()
        try await Task.sleep(for: .milliseconds(100))

        #expect(await client.followRequests == ["demo-api-1"])
    }

    @Test("log manager emits runtime-followed rotated direct API stream")
    func logManagerEmitsRuntimeFollowedRotatedDirectAPIStream() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("new\n".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["new"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["new"])
        #expect(await client.followOptions == [ContainerLogOptions(tail: 0)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager keeps followed direct API stream partial line pending while live")
    func logManagerKeepsFollowedDirectAPIStreamPartialLinePendingWhileLive() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("partial".utf8),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await Task.sleep(for: .milliseconds(300))
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages.isEmpty)
        #expect(await client.followRequests == ["demo-api-1"])
    }

    @Test("log manager flushes followed direct API stream partial line after stop")
    func logManagerFlushesFollowedDirectAPIStreamPartialLineAfterStop() async throws {
        let emitted = MessageRecorder()
        let stateProvider = RecordingContainerLogFollowStateProvider(responses: [true, false])
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data("partial".utf8),
        ])
        let manager = ContainerClientLogManager(client: client, followStateProvider: stateProvider)

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForMessages(["partial"], in: emitted)
        try await followTask.value

        #expect(emitted.messages == ["partial"])
        #expect(await stateProvider.requests == ["demo-api-1", "demo-api-1"])
        #expect(await client.followRequests == ["demo-api-1"])
    }

    @Test("log manager preserves non-UTF-8 bytes while following direct API stream")
    func logManagerPreservesNonUTF8BytesWhileFollowingDirectAPIStream() async throws {
        let emitted = DataRecorder()
        let client = RotatingContainerLogAPIClient(followChunks: [
            Data([0xFF, 0xFE, 0x0A, 0x41, 0x0A]),
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(id: "demo-api-1", tail: 0, follow: true, emit: { emitted.append($0) })
        }
        try await waitForData([Data([0xFF, 0xFE]), Data([0x41])], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.data == [Data([0xFF, 0xFE]), Data([0x41])])
        #expect(await client.followRequests == ["demo-api-1"])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager follows timestamped structured record stream")
    func logManagerFollowsTimestampedStructuredRecordStream() async throws {
        let emitted = MessageRecorder()
        let firstTimestamp = date("2026-06-18T10:00:00.123Z")
        let secondTimestamp = date("2026-06-18T10:00:01.456Z")
        let client = RotatingContainerLogAPIClient(recordSnapshots: [
            [],
            [
                ContainerLogRecord(timestamp: firstTimestamp, stream: .stdout, data: Data("one\npa".utf8)),
                ContainerLogRecord(timestamp: secondTimestamp, stream: .stderr, data: Data("rt\n".utf8)),
            ],
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: nil,
                until: nil,
                timestamps: true,
                emit: { emitted.append($0) }
            )
        }
        try await waitForMessages([
            "2026-06-18T10:00:00.123Z one",
            "2026-06-18T10:00:00.123Z part",
        ], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == [
            "2026-06-18T10:00:00.123Z one",
            "2026-06-18T10:00:00.123Z part",
        ])
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.recordOptions.isEmpty)
        #expect(await client.recordReplayOptions.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager follows runtime structured record stream")
    func logManagerFollowsRuntimeStructuredRecordStream() async throws {
        let emitted = MessageRecorder()
        let first = ContainerLogRecord(timestamp: date("2026-06-18T10:00:00Z"), stream: .stdout, data: Data("one\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-06-18T10:00:01Z"), stream: .stdout, data: Data("two\n".utf8))
        let third = ContainerLogRecord(timestamp: date("2026-06-18T10:00:02Z"), stream: .stdout, data: Data("three\n".utf8))
        let client = RotatingContainerLogAPIClient(recordSnapshots: [
            [first, second],
            [second, third],
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: nil,
                until: nil,
                timestamps: true,
                emit: { emitted.append($0) }
            )
        }
        try await waitForMessages(["2026-06-18T10:00:02.000Z three"], in: emitted)
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages == ["2026-06-18T10:00:02.000Z three"])
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0)])
    }

    @Test("log manager filters followed structured records")
    func logManagerFiltersFollowedStructuredRecords() async throws {
        let emitted = MessageRecorder()
        let base = date("2100-01-01T00:00:00Z")
        let since = date("2100-01-01T00:00:01Z")
        let until = date("2100-01-01T00:00:02Z")
        let client = RotatingContainerLogAPIClient(recordSnapshots: [
            [],
            [
                ContainerLogRecord(timestamp: base, stream: .stdout, data: Data("old\n".utf8)),
                ContainerLogRecord(timestamp: since, stream: .stdout, data: Data("inside\n".utf8)),
                ContainerLogRecord(timestamp: until.addingTimeInterval(1), stream: .stdout, data: Data("new\n".utf8)),
            ],
        ])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: since,
                until: until,
                timestamps: false,
                emit: { emitted.append($0) }
            )
        }
        try await waitForMessages(["inside"], in: emitted)
        try await followTask.value

        #expect(emitted.messages == ["inside"])
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.recordOptions.isEmpty)
        #expect(await client.recordReplayOptions.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [
            ContainerLogOptions(tail: 0, since: since, until: until),
        ])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager skips structured follow when until already elapsed")
    func logManagerSkipsStructuredFollowWhenUntilAlreadyElapsed() async throws {
        let emitted = MessageRecorder()
        let until = Date().addingTimeInterval(-1)
        let records = [
            ContainerLogRecord(timestamp: until.addingTimeInterval(-1), stream: .stdout, data: Data("snapshot\n".utf8)),
        ]
        let client = RotatingContainerLogAPIClient(recordSnapshots: [records])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: true,
            since: nil,
            until: until,
            timestamps: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == ["snapshot"])
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.recordOptions.isEmpty)
        #expect(await client.recordReplayOptions.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(until: until)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager flushes structured partial line when until already elapsed")
    func logManagerFlushesStructuredPartialLineWhenUntilAlreadyElapsed() async throws {
        let emitted = MessageRecorder()
        let until = Date().addingTimeInterval(-1)
        let records = [
            ContainerLogRecord(timestamp: until.addingTimeInterval(-1), stream: .stdout, data: Data("snapshot".utf8)),
        ]
        let client = RotatingContainerLogAPIClient(recordSnapshots: [records])
        let manager = ContainerClientLogManager(client: client)

        try await manager.logs(
            id: "demo-api-1",
            tail: nil,
            follow: true,
            since: nil,
            until: until,
            timestamps: true,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages.count == 1)
        #expect(emitted.messages[0].hasSuffix(" snapshot"))
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.recordOptions.isEmpty)
        #expect(await client.recordReplayOptions.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(until: until)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log manager keeps followed structured partial line pending while live")
    func logManagerKeepsFollowedStructuredPartialLinePendingWhileLive() async throws {
        let emitted = MessageRecorder()
        let timestamp = date("2026-06-18T10:00:00.123Z")
        let client = RotatingContainerLogAPIClient(
            recordSnapshots: [
                [],
                [
                    ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("partial".utf8)),
                ],
            ],
            closeFollowRecordStream: false
        )
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: nil,
                until: nil,
                timestamps: true,
                emit: { emitted.append($0) }
            )
        }
        try await Task.sleep(for: .milliseconds(300))
        followTask.cancel()
        try await followTask.value

        #expect(emitted.messages.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0)])
    }

    @Test("log manager flushes followed structured partial line when runtime stream ends")
    func logManagerFlushesFollowedStructuredPartialLineWhenRuntimeStreamEnds() async throws {
        let emitted = MessageRecorder()
        let timestamp = date("2026-06-18T10:00:00.123Z")
        let client = RotatingContainerLogAPIClient(recordSnapshots: [
            [],
            [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("partial".utf8)),
            ],
        ])
        let manager = ContainerClientLogManager(client: client)

        let followTask = Task {
            try await manager.logs(
                id: "demo-api-1",
                tail: 0,
                follow: true,
                since: nil,
                until: nil,
                timestamps: true,
                emit: { emitted.append($0) }
            )
        }
        try await waitForMessages(["2026-06-18T10:00:00.123Z partial"], in: emitted)
        try await followTask.value

        #expect(emitted.messages == ["2026-06-18T10:00:00.123Z partial"])
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0)])
    }

    @Test("log manager delegates quiet structured follow deadline to runtime")
    func logManagerDelegatesQuietStructuredFollowDeadlineToRuntime() async throws {
        let emitted = MessageRecorder()
        let client = RotatingContainerLogAPIClient(recordSnapshots: [[]])
        let manager = ContainerClientLogManager(
            client: client,
            followStateProvider: RecordingContainerLogFollowStateProvider()
        )
        let until = Date().addingTimeInterval(1)

        try await manager.logs(
            id: "demo-api-1",
            tail: 0,
            follow: true,
            since: nil,
            until: until,
            timestamps: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages.isEmpty)
        #expect(await client.recordRequests.isEmpty)
        #expect(await client.followRecordRequests == ["demo-api-1"])
        #expect(await client.followRecordOptions == [ContainerLogOptions(tail: 0, until: until)])
        #expect(await client.requests.isEmpty)
    }

    @Test("log API client forwards configured operation")
    func logAPIClientForwardsConfiguredOperation() async throws {
        let fileHandle = try temporaryLogFileHandle(contents: "hello\n")
        let recorder = RecordingContainerLogAPIClient(fileHandles: [fileHandle])
        let options = ContainerLogOptions(tail: 1)
        let replay = ContainerLogReplayOptions(includeRotated: true)
        let client = ContainerLogAPIClient { id, options, replay in
            try await recorder.logFileHandles(id: id, options: options, replay: replay)
        }

        let handles = try await client.logFileHandles(id: "demo-api-1", options: options, replay: replay)

        #expect(handles.count == 1)
        #expect(await recorder.requests == ["demo-api-1"])
        #expect(await recorder.options == [options])
        #expect(await recorder.replayOptions == [replay])
    }

    @Test("log API client forwards configured record operation")
    func logAPIClientForwardsConfiguredRecordOperation() async throws {
        let records = [
            ContainerLogRecord(timestamp: date("2026-06-18T10:00:00Z"), stream: .stdout, data: Data("hello\n".utf8)),
        ]
        let recorder = RecordingContainerLogAPIClient(records: records)
        let options = ContainerLogOptions(tail: 1)
        let replay = ContainerLogReplayOptions(includeRotated: true)
        let client = ContainerLogAPIClient(
            logs: { id, options, replay in
                try await recorder.logFileHandles(id: id, options: options, replay: replay)
            },
            logRecords: { id, options, replay in
                try await recorder.logRecords(id: id, options: options, replay: replay)
            }
        )

        let response = try await client.logRecords(id: "demo-api-1", options: options, replay: replay)

        #expect(response == records)
        #expect(await recorder.recordRequests == ["demo-api-1"])
        #expect(await recorder.recordOptions == [options])
        #expect(await recorder.recordReplayOptions == [replay])
    }

    @Test("log API client forwards configured follow operation")
    func logAPIClientForwardsConfiguredFollowOperation() async throws {
        let fileHandle = try temporaryLogFileHandle(contents: "hello\n")
        let recorder = RecordingContainerLogAPIClient(fileHandles: [fileHandle])
        let options = ContainerLogOptions(tail: 1)
        let client = ContainerLogAPIClient(followLogs: { id, options in
            try await recorder.followLogs(id: id, options: options)
        })

        let handle = try await client.followLogs(id: "demo-api-1", options: options)
        defer {
            try? handle.close()
        }

        #expect(try handle.readToEnd() == Data("hello\n".utf8))
        #expect(await recorder.followRequests == ["demo-api-1"])
        #expect(await recorder.followOptions == [options])
    }

    @Test("log API client forwards configured structured follow operation")
    func logAPIClientForwardsConfiguredStructuredFollowOperation() async throws {
        let records = [
            ContainerLogRecord(timestamp: date("2026-06-18T10:00:00Z"), stream: .stdout, data: Data("hello\n".utf8)),
        ]
        let recorder = RecordingContainerLogAPIClient(records: records)
        let options = ContainerLogOptions(tail: 1)
        let client = ContainerLogAPIClient(followLogRecords: { id, options in
            try await recorder.followLogRecords(id: id, options: options)
        })

        let handle = try await client.followLogRecords(id: "demo-api-1", options: options)
        defer {
            try? handle.close()
        }

        let data = try #require(try handle.readToEnd())

        #expect(try logRecords(from: data) == records)
        #expect(await recorder.followRecordRequests == ["demo-api-1"])
        #expect(await recorder.followRecordOptions == [options])
    }

    @Test("stats manager renders static table from direct API stats")
    func statsManagerRendersStaticTableFromDirectAPIStats() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [
                ComposeStatsTarget(id: "demo-api-1", status: "running"),
                ComposeStatsTarget(id: "demo-db-1", status: "stopped"),
            ],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_250_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { _ in }
        )

        try await manager.stats(ids: ["demo-api-1", "demo-db-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { emitted.append($0) })

        #expect(emitted.messages.count == 1)
        #expect(emitted.messages[0].contains("CONTAINER ID"))
        #expect(emitted.messages[0].contains("MEM %"))
        #expect(emitted.messages[0].contains("demo-api-1"))
        #expect(emitted.messages[0].contains("25.00%"))
        #expect(emitted.messages[0].contains("1MiB / 2MiB"))
        #expect(emitted.messages[0].contains("50.00%"))
        #expect(emitted.messages[0].contains("1.024kB / 2.048kB"))
        #expect(emitted.messages[0].contains("4.096kB / 8.192kB"))
        #expect(!emitted.messages[0].contains("demo-db-1"))
        #expect(await client.listRequests == [["demo-api-1", "demo-db-1"]])
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats manager renders template output from direct API stats")
    func statsManagerRendersTemplateOutputFromDirectAPIStats() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_250_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { _ in }
        )

        try await manager.stats(
            ids: ["demo-api-1"],
            format: #"table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"#,
            noStream: true,
            noTrunc: false,
            includeStopped: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages.count == 1)
        #expect(emitted.messages[0].contains("CONTAINER ID"))
        #expect(emitted.messages[0].contains("CPU %"))
        #expect(emitted.messages[0].contains("MEM USAGE / LIMIT"))
        #expect(emitted.messages[0].contains("MEM %"))
        #expect(emitted.messages[0].contains("demo-api-1"))
        #expect(emitted.messages[0].contains("25.00%"))
        #expect(emitted.messages[0].contains("1MiB / 2MiB"))
        #expect(emitted.messages[0].contains("50.00%"))
    }

    @Test("stats template emits partial UTF-8 as exact bytes")
    func statsTemplateEmitsPartialUTF8AsExactBytes() async throws {
        let emittedText = MessageRecorder()
        let emittedData = DataRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_250_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { _ in }
        )

        try await manager.stats(
            ids: ["demo-api-1"],
            format: #"{{printf "%s" (truncate "é" 1)}}"#,
            noStream: true,
            noTrunc: false,
            includeStopped: false,
            emit: { emittedText.append($0) },
            emitData: { emittedData.append($0) }
        )

        #expect(emittedText.messages.isEmpty)
        #expect(emittedData.data == [Data([0xC3])])
    }

    @Test("stats template keeps display identifier aliases")
    func statsTemplateKeepsDisplayIdentifierAliases() async throws {
        let emitted = MessageRecorder()
        let identifier = "0123456789abcdef"
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: identifier, status: "running")],
            statsResponses: [
                identifier: [
                    containerStats(id: identifier, cpuUsageUsec: 1_000_000),
                    containerStats(id: identifier, cpuUsageUsec: 1_250_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { _ in }
        )

        try await manager.stats(
            ids: [identifier],
            format: #"{{.Container}}\t{{.ID}}\t{{.Name}}"#,
            noStream: true,
            noTrunc: false,
            includeStopped: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == ["0123456789ab\t0123456789ab\t0123456789ab"])
    }

    @Test("stats template renders control actions before emitting direct API rows")
    func statsTemplateRendersControlActionsBeforeEmittingDirectAPIRows() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_250_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { _ in }
        )

        try await manager.stats(
            ids: ["demo-api-1"],
            format: #"{{if .Container}}{{upper .Container}}={{.CPUPerc}}{{else}}missing{{end}}"#,
            noStream: true,
            noTrunc: false,
            includeStopped: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == ["DEMO-API-1=25.00%"])
    }

    @Test("stats manager honors no trunc table output")
    func statsManagerHonorsNoTruncTableOutput() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1-very-long-id", status: "running")],
            statsResponses: [
                "demo-api-1-very-long-id": [
                    containerStats(id: "demo-api-1-very-long-id", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1-very-long-id", cpuUsageUsec: 1_500_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(client: client, sampleInterval: .microseconds(1), sleep: { _ in })

        try await manager.stats(
            ids: ["demo-api-1-very-long-id"],
            format: "table",
            noStream: true,
            noTrunc: false,
            includeStopped: false,
            emit: { emitted.append($0) }
        )
        try await manager.stats(
            ids: ["demo-api-1-very-long-id"],
            format: "table",
            noStream: true,
            noTrunc: true,
            includeStopped: false,
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages.count == 2)
        #expect(emitted.messages[0].contains("demo-api-1-v"))
        #expect(!emitted.messages[0].contains("demo-api-1-very-long-id"))
        #expect(emitted.messages[1].contains("demo-api-1-very-long-id"))
    }

    @Test("stats manager includes stopped containers when all is requested")
    func statsManagerIncludesStoppedContainersWhenAllIsRequested() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [
                ComposeStatsTarget(id: "demo-api-1", status: "running"),
                ComposeStatsTarget(id: "demo-db-1", status: "stopped"),
            ],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_250_000),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { _ in }
        )

        try await manager.stats(ids: ["demo-api-1", "demo-db-1"], format: "table", noStream: true, noTrunc: false, includeStopped: true, emit: { emitted.append($0) })

        #expect(emitted.messages.count == 1)
        #expect(emitted.messages[0].contains("demo-api-1"))
        #expect(emitted.messages[0].contains("25.00%"))
        #expect(emitted.messages[0].contains("demo-db-1"))
        #expect(emitted.messages[0].contains("-- / --"))
        #expect(await client.listRequests == [["demo-api-1", "demo-db-1"]])
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats manager streams table output from direct API stats")
    func statsManagerStreamsTableOutputFromDirectAPIStats() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_500_000),
                ],
            ]
        )
        let sleeper = ThrowingSleeper(throwOnCall: 2)
        let manager = ContainerClientStatsManager(
            client: client,
            sampleInterval: .microseconds(1),
            sampleIntervalMicroseconds: 1_000_000,
            sleep: { try await sleeper.sleep($0) }
        )

        do {
            try await manager.stats(ids: ["demo-api-1"], format: " TABLE ", noStream: false, noTrunc: false, includeStopped: false, emit: { emitted.append($0) })
            Issue.record("Expected streaming stats cancellation")
        } catch is CancellationError {
            // Expected cancellation from the injected sleeper after one streamed frame.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let messages = emitted.messages
        #expect(messages.count == 4)
        if messages.count == 4 {
            #expect(messages[0] == "\u{001B}[?1049h\u{001B}[?25l")
            #expect(messages[1].contains("\u{001B}[H\u{001B}[JCONTAINER ID"))
            #expect(!messages[1].contains("demo-api-1"))
            #expect(messages[2].contains("\u{001B}[H\u{001B}[JCONTAINER ID"))
            #expect(messages[2].contains("demo-api-1"))
            #expect(messages[2].contains("50.00%"))
            #expect(messages[3] == "\u{001B}[?25h\u{001B}[?1049l")
        }
    }

    @Test("stats manager renders unavailable fields in direct API table output")
    func statsManagerRendersUnavailableFieldsInDirectAPITableOutput() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: nil),
                    containerStats(
                        id: "demo-api-1",
                        cpuUsageUsec: nil,
                        memoryUsageBytes: 1_073_741_824,
                        memoryLimitBytes: nil,
                        networkRxBytes: nil,
                        networkTxBytes: nil,
                        blockReadBytes: nil,
                        blockWriteBytes: nil,
                        numProcesses: nil
                    ),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(client: client, sampleInterval: .microseconds(1), sleep: { _ in })

        try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { emitted.append($0) })

        #expect(emitted.messages[0].contains("--"))
        #expect(emitted.messages[0].contains("1GiB / --"))
        #expect(emitted.messages[0].contains("-- / --"))
    }

    @Test("stats manager renders static JSON from direct API stats")
    func statsManagerRendersStaticJSONFromDirectAPIStats() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                    containerStats(
                        id: "demo-api-1",
                        cpuUsageUsec: 1_500_000,
                        memoryUsageBytes: 2_097_152,
                        networkRxBytes: 1100,
                        networkTxBytes: 126,
                        blockReadBytes: 0,
                        blockWriteBytes: 0
                    ),
                ],
            ]
        )
        let manager = ContainerClientStatsManager(client: client, sampleInterval: .microseconds(1), sleep: { _ in })

        try await manager.stats(ids: ["demo-api-1"], format: "json", noStream: false, noTrunc: false, includeStopped: false, emit: { emitted.append($0) })

        let decoded = try #require(JSONSerialization.jsonObject(with: Data(emitted.messages[0].utf8)) as? [String: String])
        #expect(decoded["Container"] == "demo-api-1")
        #expect(decoded["ID"] == "demo-api-1")
        #expect(decoded["Name"] == "demo-api-1")
        #expect(decoded["CPUPerc"] == "25.00%")
        #expect(decoded["MemUsage"] == "2MiB / 2MiB")
        #expect(decoded["MemPerc"] == "100.00%")
        #expect(decoded["NetIO"] == "1.1kB / 126B")
        #expect(decoded["BlockIO"] == "0B / 0B")
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats manager rejects missing direct API stat targets")
    func statsManagerRejectsMissingDirectAPIStatTargets() async throws {
        let client = RecordingContainerStatsAPIClient()
        let manager = ContainerClientStatsManager(client: client, sleep: { _ in })

        do {
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { _ in })
            Issue.record("Expected missing stats target error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("no such container: demo-api-1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.listRequests == [["demo-api-1"]])
        #expect(await client.statsRequests.isEmpty)
    }

    @Test("stats manager surfaces initial stats failures")
    func statsManagerSurfacesInitialStatsFailures() async throws {
        let expected = ComposeError.invalidProject("initial stats failed")
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsError: expected,
            statsErrorRequestIndex: 1
        )
        let manager = ContainerClientStatsManager(client: client, sleep: { _ in })

        do {
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { _ in })
            Issue.record("Expected initial stats failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.listRequests == [["demo-api-1"]])
        #expect(await client.statsRequests == ["demo-api-1"])
    }

    @Test("stats manager surfaces follow-up stats failures")
    func statsManagerSurfacesFollowUpStatsFailures() async throws {
        let expected = ComposeError.invalidProject("follow-up stats failed")
        let client = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: [
                "demo-api-1": [
                    containerStats(id: "demo-api-1", cpuUsageUsec: 1_000_000),
                ],
            ],
            statsError: expected,
            statsErrorRequestIndex: 2
        )
        let manager = ContainerClientStatsManager(client: client, sampleInterval: .microseconds(1), sleep: { _ in })

        do {
            try await manager.stats(ids: ["demo-api-1"], format: "table", noStream: true, noTrunc: false, includeStopped: false, emit: { _ in })
            Issue.record("Expected follow-up stats failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.listRequests == [["demo-api-1"]])
        #expect(await client.statsRequests == ["demo-api-1", "demo-api-1"])
    }

    @Test("stats API client forwards configured operations")
    func statsAPIClientForwardsConfiguredOperations() async throws {
        let recorder = RecordingContainerStatsAPIClient(
            targets: [ComposeStatsTarget(id: "demo-api-1", status: "running")],
            statsResponses: ["demo-api-1": [containerStats(id: "demo-api-1", cpuUsageUsec: 42)]]
        )
        let client = ContainerStatsAPIClient(
            list: { ids in try await recorder.listStatsTargets(ids: ids) },
            stats: { id in try await recorder.stats(id: id) }
        )

        let targets = try await client.listStatsTargets(ids: ["demo-api-1"])
        let stats = try await client.stats(id: "demo-api-1")

        #expect(targets == [ComposeStatsTarget(id: "demo-api-1", status: "running")])
        #expect(stats.id == "demo-api-1")
        #expect(stats.cpuUsageUsec == 42)
        #expect(await recorder.listRequests == [["demo-api-1"]])
        #expect(await recorder.statsRequests == ["demo-api-1"])
    }

    @Test("top manager renders process identifiers from direct API")
    func topManagerRendersProcessIdentifiersFromDirectAPI() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerTopAPIClient(responses: [
            "demo-api-1": ContainerProcesses(id: "demo-api-1", processIdentifiers: [42, 99]),
            "demo-db-1": ContainerProcesses(id: "demo-db-1", processIdentifiers: [7]),
        ])
        let manager = ContainerClientTopManager(client: client)

        try await manager.top(
            targets: [
                ComposeTopTarget(service: "api", containerID: "demo-api-1"),
                ComposeTopTarget(service: "db", containerID: "demo-db-1"),
            ],
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            "Service  Container ID  PID\napi      demo-api-1    42\napi      demo-api-1    99\ndb       demo-db-1     7",
        ])
        #expect(await client.requests == ["demo-api-1", "demo-db-1"])
    }

    @Test("top manager renders Docker process table from direct API")
    func topManagerRendersDockerProcessTableFromDirectAPI() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerTopAPIClient(responses: [
            "demo-api-1": ContainerProcesses(
                id: "demo-api-1",
                processIdentifiers: [42],
                processes: [
                    ContainerProcessInfo(
                        uid: "root",
                        pid: 42,
                        ppid: 7,
                        cpu: 0,
                        startTime: "15:33",
                        tty: "?",
                        time: "00:00:00",
                        command: "sleep 60"
                    ),
                ]
            ),
            "demo-db-1": ContainerProcesses(
                id: "demo-db-1",
                processIdentifiers: [7],
                processes: [
                    ContainerProcessInfo(
                        uid: "postgres",
                        pid: 7,
                        ppid: 1,
                        cpu: 1,
                        startTime: "15:34",
                        tty: "?",
                        time: "00:00:01",
                        command: "postgres"
                    ),
                ]
            ),
        ])
        let manager = ContainerClientTopManager(client: client)

        try await manager.top(
            targets: [
                ComposeTopTarget(service: "api", containerID: "demo-api-1"),
                ComposeTopTarget(service: "db", containerID: "demo-db-1"),
            ],
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            """
            demo-api-1
            UID   PID  PPID  C  STIME  TTY  TIME      CMD
            root  42   7     0  15:33  ?    00:00:00  sleep 60
            demo-db-1
            UID       PID  PPID  C  STIME  TTY  TIME      CMD
            postgres  7    1     1  15:34  ?    00:00:01  postgres
            """,
        ])
        #expect(await client.requests == ["demo-api-1", "demo-db-1"])
    }

    @Test("top manager falls back to PID table for mixed metadata responses")
    func topManagerFallsBackToPIDTableForMixedMetadataResponses() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerTopAPIClient(responses: [
            "demo-api-1": ContainerProcesses(
                id: "demo-api-1",
                processIdentifiers: [42],
                processes: [
                    ContainerProcessInfo(
                        uid: "root",
                        pid: 42,
                        ppid: 7,
                        cpu: 0,
                        startTime: "15:33",
                        tty: "?",
                        time: "00:00:00",
                        command: "sleep 60"
                    ),
                ]
            ),
            "demo-db-1": ContainerProcesses(id: "demo-db-1", processIdentifiers: [7]),
        ])
        let manager = ContainerClientTopManager(client: client)

        try await manager.top(
            targets: [
                ComposeTopTarget(service: "api", containerID: "demo-api-1"),
                ComposeTopTarget(service: "db", containerID: "demo-db-1"),
            ],
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == [
            "Service  Container ID  PID\napi      demo-api-1    42\ndb       demo-db-1     7",
        ])
        #expect(await client.requests == ["demo-api-1", "demo-db-1"])
    }

    @Test("top API client forwards configured operation")
    func topAPIClientForwardsConfiguredOperation() async throws {
        let recorder = RecordingContainerTopAPIClient(
            responses: ["demo-api-1": ContainerProcesses(id: "demo-api-1", processIdentifiers: [42])]
        )
        let client = ContainerTopAPIClient(processes: { id in try await recorder.processes(id: id) })

        let processes = try await client.processes(id: "demo-api-1")

        #expect(processes == ContainerProcesses(id: "demo-api-1", processIdentifiers: [42]))
        #expect(await recorder.requests == ["demo-api-1"])
    }

    @Test("detached exec manager maps request to direct process API")
    func detachedExecManagerMapsRequestToDirectProcessAPI() async throws {
        let emitted = MessageRecorder()
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .running,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        )
        let client = RecordingContainerExecAPIClient(snapshots: [snapshot])
        let manager = ContainerClientExecManager(client: client, processIdentifier: { "process-123" })

        try await manager.execDetached(
            request: ContainerDetachedExecRequest(
                id: "demo-api-1",
                command: ["env", "ARG"],
                environment: ["FOO=bar"],
                user: "1000:1000",
                workingDirectory: "/app",
                privileged: true
            ),
            emit: { emitted.append($0) }
        )

        #expect(emitted.messages == ["demo-api-1"])
        #expect(await client.getRequests == ["demo-api-1"])
        #expect(await client.processRequests == [
            ContainerExecProcessRequest(
                containerId: "demo-api-1",
                processId: "process-123",
                executable: "env",
                arguments: ["ARG"],
                environment: ["FOO=bar"],
                workingDirectory: "/app",
                terminal: false,
                user: "1000:1000",
                supplementalGroups: [],
                privileged: true,
                stdioCount: 0
            ),
        ])
    }

    @Test("detached exec manager rejects stopped containers")
    func detachedExecManagerRejectsStoppedContainers() async throws {
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .stopped,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        )
        let client = RecordingContainerExecAPIClient(snapshots: [snapshot])
        let manager = ContainerClientExecManager(client: client, processIdentifier: { "process-123" })

        do {
            try await manager.execDetached(
                request: ContainerDetachedExecRequest(id: "demo-api-1", command: ["true"]),
                emit: { _ in }
            )
            Issue.record("Expected stopped container error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("container 'demo-api-1' is not running"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.getRequests == ["demo-api-1"])
        #expect(await client.processRequests.isEmpty)
    }

    @Test("attached exec manager maps request to direct process API")
    func attachedExecManagerMapsRequestToDirectProcessAPI() async throws {
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .running,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        )
        let client = RecordingContainerExecAPIClient(snapshots: [snapshot], attachedStatus: 7)
        let manager = ContainerClientExecManager(client: client, processIdentifier: { "process-456" })

        let status = try await manager.execAttached(
            request: ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["echo", "ok"],
                environment: ["FOO=bar"],
                user: "1000:1000",
                workingDirectory: "/app",
                privileged: true,
                terminal: .init(interactive: true, tty: false)
            )
        )

        #expect(status == 7)
        #expect(await client.getRequests == ["demo-api-1"])
        #expect(await client.attachedProcessRequests == [
            ContainerAttachedExecProcessRequest(
                containerId: "demo-api-1",
                processId: "process-456",
                executable: "echo",
                arguments: ["ok"],
                environment: ["FOO=bar"],
                workingDirectory: "/app",
                terminal: false,
                user: "1000:1000",
                supplementalGroups: [],
                privileged: true,
                interactive: true,
                tty: false
            ),
        ])
    }

    @Test("exec API client forwards configured operations")
    func execAPIClientForwardsConfiguredOperations() async throws {
        let snapshot = try containerSnapshot(
            id: "demo-api-1",
            status: .running,
            imageReference: "example/api:latest",
            imageDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            platform: "linux/arm64"
        )
        let recorder = RecordingContainerExecAPIClient(snapshots: [snapshot])
        let client = ContainerExecAPIClient(
            get: { try await recorder.getContainer(id: $0) },
            createAndStart: { containerId, processId, configuration, stdio in
                try await recorder.createAndStartProcess(
                    containerId: containerId,
                    processId: processId,
                    configuration: configuration,
                    stdio: stdio
                )
            },
            runAttached: { containerId, processId, configuration, interactive, tty in
                try await recorder.runAttachedProcess(
                    containerId: containerId,
                    processId: processId,
                    configuration: configuration,
                    interactive: interactive,
                    tty: tty
                )
            }
        )
        let configuration = ProcessConfiguration(
            executable: "date",
            arguments: ["-u"],
            environment: ["TZ=UTC"],
            workingDirectory: "/"
        )

        let actualSnapshot = try await client.getContainer(id: "demo-api-1")
        try await client.createAndStartProcess(
            containerId: "demo-api-1",
            processId: "process-123",
            configuration: configuration,
            stdio: []
        )
        let status = try await client.runAttachedProcess(
            containerId: "demo-api-1",
            processId: "process-456",
            configuration: configuration,
            interactive: true,
            tty: false
        )

        #expect(actualSnapshot.id == "demo-api-1")
        #expect(status == 0)
        #expect(await recorder.getRequests == ["demo-api-1"])
        #expect(await recorder.processRequests == [
            ContainerExecProcessRequest(
                containerId: "demo-api-1",
                processId: "process-123",
                executable: "date",
                arguments: ["-u"],
                environment: ["TZ=UTC"],
                workingDirectory: "/",
                terminal: false,
                user: "0:0",
                supplementalGroups: [],
                stdioCount: 0
            ),
        ])
        #expect(await recorder.attachedProcessRequests == [
            ContainerAttachedExecProcessRequest(
                containerId: "demo-api-1",
                processId: "process-456",
                executable: "date",
                arguments: ["-u"],
                environment: ["TZ=UTC"],
                workingDirectory: "/",
                terminal: false,
                user: "0:0",
                supplementalGroups: [],
                interactive: true,
                tty: false
            ),
        ])
    }

    @Test("image manager pulls only missing images through direct API")
    func imageManagerPullsOnlyMissingImagesThroughDirectAPI() async throws {
        let client = RecordingContainerImageAPIClient(existingReferences: ["example/api"])
        let manager = ContainerClientImageManager(client: client)

        let exists = try await manager.imageExists("example/api")
        try await manager.pullMissingImage("example/api")
        try await manager.pullMissingImage("postgres")

        #expect(exists == true)
        #expect(await client.requests == [
            .exists("example/api"),
            .exists("example/api"),
            .exists("postgres"),
            .pull("postgres"),
        ])
    }

    @Test("image manager repeats an idempotent pull once after an XPC interruption")
    func imageManagerRecoversInterruptedPull() async throws {
        let interrupted = ContainerizationError(.interrupted, message: "XPC connection interrupted")
        let client = RecordingContainerImageAPIClient(pullErrors: [
            "example/api": [interrupted],
        ])
        let manager = ContainerClientImageManager(client: client)

        try await manager.pullImage("example/api")

        #expect(await client.requests == [
            .pull("example/api"),
            .pull("example/api"),
        ])
    }

    @Test("image manager returns image healthchecks through direct API")
    func imageManagerReturnsImageHealthchecksThroughDirectAPI() async throws {
        let healthCheck = ComposeImageHealthCheck(
            test: ["CMD-SHELL", "test -f /ready"],
            intervalInNanoseconds: 5_000_000_000,
            retries: 2
        )
        let client = RecordingContainerImageAPIClient(platformHealthChecks: [
            ImageHealthCheckRequestKey(reference: "example/api", platform: "linux/arm64"): healthCheck,
        ])
        let manager = ContainerClientImageManager(client: client)

        let resolved = try await manager.imageHealthCheck("example/api", platform: "linux/arm64")

        #expect(resolved == healthCheck)
        #expect(await client.requests == [
            .healthCheck(reference: "example/api", platform: "linux/arm64"),
        ])
    }

    @Test("image manager returns complete platform metadata through direct API")
    func imageManagerReturnsCompletePlatformMetadataThroughDirectAPI() async throws {
        let metadata = ComposeImageMetadata(reference: "example/api@sha256:platform") {
            $0.user = "service-user"
            $0.declaredVolumeTargets = ["/service-data"]
        }
        let client = RecordingContainerImageAPIClient(platformImageMetadata: [
            ImageMetadataRequestKey(reference: "example/api", platform: "linux/arm64"): metadata,
        ])
        let manager = ContainerClientImageManager(client: client)

        let resolved = try await manager.imageMetadataIfAvailable(
            "example/api",
            platform: "linux/arm64",
        )

        #expect(resolved == metadata)
        #expect(await client.requests == [
            .availableMetadata(reference: "example/api", platform: "linux/arm64"),
        ])
    }

    @Test("image manager returns platform image volume targets through direct API")
    func imageManagerReturnsPlatformImageVolumeTargetsThroughDirectAPI() async throws {
        let client = RecordingContainerImageAPIClient(platformImageVolumeTargets: [
            ImageVolumeTargetRequestKey(reference: "example/api", platform: "linux/arm64"): [
                "/image-data", "/cache",
            ],
        ])
        let manager = ContainerClientImageManager(client: client)

        let targets = try await manager.imageDeclaredVolumeTargets(
            "example/api", platform: "linux/arm64",
        )

        #expect(targets == ["/image-data", "/cache"])
        #expect(
            await client.requests == [
                .volumeTargets(reference: "example/api", platform: "linux/arm64"),
            ]
        )
    }

    @Test("image manager prepares missing image volume metadata through direct API")
    func imageManagerPreparesMissingImageVolumeMetadataThroughDirectAPI() async throws {
        let client = RecordingContainerImageAPIClient()
        let manager = ContainerClientImageManager(client: client)

        let prepared = try await manager.prepareImageVolumeMetadata("example/api", pullIfMissing: true)

        #expect(prepared)
        #expect(await client.requests == [
            .exists("example/api"),
            .pull("example/api"),
        ])

        let neverClient = RecordingContainerImageAPIClient()
        let neverManager = ContainerClientImageManager(client: neverClient)
        let unavailable = try await neverManager.prepareImageVolumeMetadata("example/api", pullIfMissing: false)

        #expect(!unavailable)
        #expect(await neverClient.requests == [
            .exists("example/api"),
        ])

        let availableClient = RecordingContainerImageAPIClient(existingReferences: ["example/api"])
        let availableManager = ContainerClientImageManager(client: availableClient)
        let available = try await availableManager.prepareImageVolumeMetadata("example/api", pullIfMissing: true)

        #expect(available)
        #expect(await availableClient.requests == [
            .exists("example/api"),
        ])
    }

    @Test("image manager resolves image digests through direct API")
    func imageManagerResolvesImageDigestsThroughDirectAPI() async throws {
        let client = RecordingContainerImageAPIClient(digests: [
            "example/api:latest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ])
        let manager = ContainerClientImageManager(client: client)

        let digest = try await manager.imageDigest("example/api:latest")

        #expect(digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(await client.requests == [.digest("example/api:latest")])
    }

    @Test("file pull metadata store persists pull dates")
    func filePullMetadataStorePersistsPullDates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("pull-metadata.json", isDirectory: false)
        let firstStore = FileComposePullMetadataStore(fileURL: fileURL)
        let recorded = Date(timeIntervalSince1970: 1_000_000)

        #expect(try await firstStore.lastPullDate(for: "example/api") == nil)
        try await firstStore.recordPullDate(recorded, for: "example/api")

        let secondStore = FileComposePullMetadataStore(fileURL: fileURL)
        #expect(try await secondStore.lastPullDate(for: "example/api") == recorded)
    }

    @Test("image manager emits pushed and deleted direct API references")
    func imageManagerEmitsPushedAndDeletedDirectAPIReferences() async throws {
        let emitted = MessageRecorder()
        let client = RecordingContainerImageAPIClient(
            existingReferences: ["example/api:latest"],
            pushOutputs: ["example/api:latest": "registry.example.com/example/api:latest"],
            deleteOutputs: ["example/api:latest": "example/api:latest", "missing:latest": nil]
        )
        let manager = ContainerClientImageManager(client: client)

        try await manager.pullImage("example/api:latest")
        try await manager.pushImage("example/api:latest", emit: { emitted.append($0) })
        try await manager.deleteImage("example/api:latest", force: true, emit: { emitted.append($0) })
        try await manager.deleteImage("missing:latest", force: true, emit: { emitted.append($0) })

        #expect(await client.requests == [
            .pull("example/api:latest"),
            .push("example/api:latest"),
            .delete(reference: "example/api:latest", force: true),
            .delete(reference: "missing:latest", force: true),
        ])
        #expect(emitted.messages == [
            "registry.example.com/example/api:latest",
            "example/api:latest",
        ])
    }

    @Test("image API client forwards configured operations")
    func imageAPIClientForwardsConfiguredOperations() async throws {
        let metadata = ComposeImageMetadata(reference: "example/api@sha256:platform") {
            $0.user = "service-user"
        }
        let recorder = RecordingContainerImageAPIClient(
            existingReferences: ["example/api:latest"],
            platformImageMetadata: [
                ImageMetadataRequestKey(
                    reference: "example/api:latest",
                    platform: "linux/arm64",
                ): metadata,
            ],
            pushOutputs: ["example/api:latest": "registry.example.com/example/api:latest"],
            deleteOutputs: ["example/api:latest": "example/api:latest"]
        )
        let client = ContainerImageAPIClient(
            queries: ContainerImageAPIClient.QueryOperations(
                exists: { try await recorder.imageExists(reference: $0) },
                healthCheck: { try await recorder.imageHealthCheck(reference: $0, platform: $1) },
                availableMetadata: {
                    try await recorder.imageMetadataIfAvailable(reference: $0, platform: $1)
                }
            ),
            mutations: ContainerImageAPIClient.MutationOperations(
                pull: { try await recorder.pullImage(reference: $0) },
                push: { try await recorder.pushImage(reference: $0) },
                delete: { try await recorder.deleteImage(reference: $0, force: $1) },
                load: { try await recorder.loadImageArchive(path: $0) }
            )
        )

        let exists = try await client.imageExists(reference: "example/api:latest")
        let healthCheck = try await client.imageHealthCheck(reference: "example/api:latest", platform: nil)
        let platformMetadata = try await client.imageMetadataIfAvailable(
            reference: "example/api:latest",
            platform: "linux/arm64",
        )
        try await client.pullImage(reference: "example/api:latest")
        let pushed = try await client.pushImage(reference: "example/api:latest")
        let deleted = try await client.deleteImage(reference: "example/api:latest", force: true)
        let loaded = try await client.loadImageArchive(path: "image.tar")

        #expect(exists == true)
        #expect(healthCheck == nil)
        #expect(platformMetadata == metadata)
        #expect(pushed == "registry.example.com/example/api:latest")
        #expect(deleted == "example/api:latest")
        #expect(loaded == ["loaded:latest"])
        #expect(await recorder.requests == [
            .exists("example/api:latest"),
            .healthCheck(reference: "example/api:latest", platform: nil),
            .availableMetadata(reference: "example/api:latest", platform: "linux/arm64"),
            .pull("example/api:latest"),
            .push("example/api:latest"),
            .delete(reference: "example/api:latest", force: true),
            .load("image.tar"),
        ])
    }

    @Test("image API client wraps an injected lower level client")
    func imageAPIClientWrapsInjectedLowerLevelClient() async throws {
        let metadata = ComposeImageMetadata(reference: "example/api@sha256:platform") {
            $0.user = "service-user"
        }
        let recorder = RecordingContainerImageAPIClient(
            existingReferences: ["example/api:latest"],
            platformImageMetadata: [
                ImageMetadataRequestKey(
                    reference: "example/api:latest",
                    platform: "linux/arm64",
                ): metadata,
            ],
            pushOutputs: ["example/api:latest": "registry.example.com/example/api:latest"],
            deleteOutputs: ["example/api:latest": "example/api:latest"]
        )
        let client = ContainerImageAPIClient(client: recorder)

        let exists = try await client.imageExists(reference: "example/api:latest")
        let healthCheck = try await client.imageHealthCheck(reference: "example/api:latest", platform: nil)
        let platformMetadata = try await client.imageMetadataIfAvailable(
            reference: "example/api:latest",
            platform: "linux/arm64",
        )
        try await client.pullImage(reference: "example/api:latest")
        let pushed = try await client.pushImage(reference: "example/api:latest")
        let deleted = try await client.deleteImage(reference: "example/api:latest", force: true)
        let loaded = try await client.loadImageArchive(path: "image.tar")

        #expect(exists == true)
        #expect(healthCheck == nil)
        #expect(platformMetadata == metadata)
        #expect(pushed == "registry.example.com/example/api:latest")
        #expect(deleted == "example/api:latest")
        #expect(loaded == ["loaded:latest"])
        #expect(await recorder.requests == [
            .exists("example/api:latest"),
            .healthCheck(reference: "example/api:latest", platform: nil),
            .availableMetadata(reference: "example/api:latest", platform: "linux/arm64"),
            .pull("example/api:latest"),
            .push("example/api:latest"),
            .delete(reference: "example/api:latest", force: true),
            .load("image.tar"),
        ])
    }

    @Test("resource manager maps compose resources to direct API client")
    func resourceManagerMapsComposeResourcesToDirectAPIClient() async throws {
        let client = RecordingContainerResourceAPIClient(volumes: [
            ComposeVolumeSummary(name: "demo_cache", labels: ["com.example.role": "cache"]),
        ])
        let manager = ContainerClientResourceManager(client: client)
        let labels = ["com.example.role": "cache"]

        try await manager.createNetwork(ComposeNetworkCreateRequest(
            name: "demo_default",
            isInternal: true,
            addressing: .init(
                ipv4Subnet: "10.10.0.0/24",
                ipv4Gateway: "10.10.0.254",
                ipv4AllocationRange: "10.10.0.128/25",
                ipv6Subnet: "fd00:10::/64",
                ipv6Gateway: "fd00:10::53"
            ),
            enableIPv6: true,
            driverOpts: ["variant": "vzNAT"],
            labels: labels
        ))
        try await manager.createVolume(ComposeVolumeCreateRequest(
            name: "demo_cache",
            driver: "local",
            driverOpts: ["size": "64m"],
            labels: labels
        ))
        let volumes = try await manager.listVolumes()
        try await manager.deleteNetwork(id: "demo_default")
        try await manager.deleteVolume(name: "demo_cache")

        #expect(volumes == [ComposeVolumeSummary(name: "demo_cache", labels: labels)])
        #expect(await client.requests == [
            .createNetwork(
                name: "demo_default",
                mode: .hostOnly,
                plugin: "container-network-vmnet",
                ipv4Subnet: "10.10.0.0/24",
                ipv4Gateway: "10.10.0.254",
                ipv4AllocationRange: "10.10.0.128/25",
                ipv6Subnet: "fd00:10::/64",
                ipv6Gateway: "fd00:10::53",
                enableIPv6: true,
                options: ["variant": "vzNAT"],
                labels: labels
            ),
            .createVolume(ComposeVolumeCreateRequest(
                name: "demo_cache",
                driver: "local",
                driverOpts: ["size": "64m"],
                labels: labels
            )),
            .listVolumes,
            .networkExists(id: "demo_default"),
            .deleteNetwork(id: "demo_default"),
            .listVolumes,
            .deleteVolume(name: "demo_cache"),
        ])
    }

    @Test("resource manager skips deleting missing networks")
    func resourceManagerSkipsDeletingMissingNetworks() async throws {
        let client = RecordingContainerResourceAPIClient(existingNetworks: [])
        let manager = ContainerClientResourceManager(client: client)

        try await manager.deleteNetwork(id: "demo_default")

        #expect(await client.requests == [
            .networkExists(id: "demo_default"),
        ])
    }

    @Test("resource manager ignores networks removed after preflight")
    func resourceManagerIgnoresNetworksRemovedAfterPreflight() async throws {
        let client = RecordingContainerResourceAPIClient(
            networkDeleteError: ContainerizationError(
                .notFound,
                message: "network demo_default not found"
            )
        )
        let manager = ContainerClientResourceManager(client: client)

        try await manager.deleteNetwork(id: "demo_default")

        #expect(await client.requests == [
            .networkExists(id: "demo_default"),
            .deleteNetwork(id: "demo_default"),
        ])
    }

    @Test("resource manager skips deleting missing volumes")
    func resourceManagerSkipsDeletingMissingVolumes() async throws {
        let client = RecordingContainerResourceAPIClient(volumes: [])
        let manager = ContainerClientResourceManager(client: client)

        try await manager.deleteVolume(name: "demo_cache")

        #expect(await client.requests == [
            .listVolumes,
        ])
    }

    @Test("resource manager ignores volumes removed after preflight")
    func resourceManagerIgnoresVolumesRemovedAfterPreflight() async throws {
        let client = RecordingContainerResourceAPIClient(
            volumes: [ComposeVolumeSummary(name: "demo_cache", labels: [:])],
            volumeDeleteError: VolumeError.volumeNotFound("demo_cache")
        )
        let manager = ContainerClientResourceManager(client: client)

        try await manager.deleteVolume(name: "demo_cache")

        #expect(await client.requests == [
            .listVolumes,
            .deleteVolume(name: "demo_cache"),
        ])
    }

    @Test("resource manager surfaces volume delete failures")
    func resourceManagerSurfacesVolumeDeleteFailures() async throws {
        let client = RecordingContainerResourceAPIClient(
            volumes: [ComposeVolumeSummary(name: "demo_cache", labels: [:])],
            volumeDeleteError: VolumeError.volumeInUse("demo_cache")
        )
        let manager = ContainerClientResourceManager(client: client)

        do {
            try await manager.deleteVolume(name: "demo_cache")
            Issue.record("Expected volume-in-use failure")
        } catch let VolumeError.volumeInUse(name) {
            #expect(name == "demo_cache")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests == [
            .listVolumes,
            .deleteVolume(name: "demo_cache"),
        ])
    }

    @Test("resource manager ignores existing network create errors")
    func resourceManagerIgnoresExistingNetworkCreateErrors() async throws {
        let client = RecordingContainerResourceAPIClient(networkCreateError: ContainerizationError(
            .exists,
            message: "network demo_default already exists"
        ))
        let manager = ContainerClientResourceManager(client: client)

        try await manager.createNetwork(ComposeNetworkCreateRequest(name: "demo_default"))

        #expect(await client.requests == [
            .createNetwork(
                name: "demo_default",
                mode: .nat,
                plugin: "container-network-vmnet",
                ipv4Subnet: nil,
                ipv4Gateway: nil,
                ipv4AllocationRange: nil,
                ipv6Subnet: nil,
                enableIPv6: true,
                options: [:],
                labels: [:]
            ),
        ])
    }

    @Test("resource manager ignores existing volume create errors")
    func resourceManagerIgnoresExistingVolumeCreateErrors() async throws {
        let client = RecordingContainerResourceAPIClient(
            volumeCreateError: VolumeError.volumeAlreadyExists("demo_cache")
        )
        let manager = ContainerClientResourceManager(client: client)

        try await manager.createVolume(ComposeVolumeCreateRequest(name: "demo_cache"))

        #expect(await client.requests == [
            .createVolume(ComposeVolumeCreateRequest(name: "demo_cache")),
        ])
    }

    @Test("resource manager disables IPv6 and suppresses an ignored IPv6 subnet")
    func resourceManagerDisablesIPv6AndSuppressesIgnoredSubnet() async throws {
        let client = RecordingContainerResourceAPIClient()
        let manager = ContainerClientResourceManager(client: client)

        try await manager.createNetwork(ComposeNetworkCreateRequest(
            name: "demo_no_ipv6",
            addressing: .init(ipv6Subnet: "fd00:10::/64", ipv6Gateway: "fd00:10::53"),
            enableIPv6: false
        ))

        #expect(await client.requests == [
            .createNetwork(
                name: "demo_no_ipv6",
                mode: .nat,
                plugin: "container-network-vmnet",
                ipv4Subnet: nil,
                ipv4Gateway: nil,
                ipv4AllocationRange: nil,
                ipv6Subnet: nil,
                ipv6Gateway: nil,
                enableIPv6: false,
                options: [:],
                labels: [:]
            ),
        ])
    }

    @Test("resource manager reuses volumes reported as existing by container")
    func resourceManagerReusesVolumesReportedAsExistingByContainer() async throws {
        let client = RecordingContainerResourceAPIClient(
            volumeCreateError: ContainerizationError(
                .exists,
                message: "volume 'demo_cache' already exists"
            )
        )
        let manager = ContainerClientResourceManager(client: client)

        try await manager.createVolume(ComposeVolumeCreateRequest(name: "demo_cache"))

        #expect(await client.requests == [
            .createVolume(ComposeVolumeCreateRequest(name: "demo_cache")),
        ])
    }

    @Test("resource manager reuses volumes reported as existing through XPC")
    func resourceManagerReusesVolumesReportedAsExistingThroughXPC() async throws {
        let client = RecordingContainerResourceAPIClient(
            volumeCreateError: ContainerizationError(
                .internalError,
                message: "volume 'demo_cache' already exists"
            )
        )
        let manager = ContainerClientResourceManager(client: client)

        try await manager.createVolume(ComposeVolumeCreateRequest(name: "demo_cache"))

        #expect(await client.requests == [
            .createVolume(ComposeVolumeCreateRequest(name: "demo_cache")),
        ])
    }

    @Test("resource manager rejects invalid network subnet before API create")
    func resourceManagerRejectsInvalidNetworkSubnetBeforeAPICreate() async throws {
        let client = RecordingContainerResourceAPIClient()
        let manager = ContainerClientResourceManager(client: client)

        do {
            try await manager.createNetwork(ComposeNetworkCreateRequest(
                name: "demo_default",
                addressing: .init(ipv4Subnet: "not-a-cidr")
            ))
            Issue.record("Expected invalid subnet error")
        } catch let CIDR.Error.invalidCIDR(cidr) {
            #expect(cidr == "not-a-cidr")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.requests.isEmpty)
    }

    @Test("resource API client forwards configured operations")
    func resourceAPIClientForwardsConfiguredOperations() async throws {
        let recorder = RecordingContainerResourceAPIClient()
        let client = ContainerResourceAPIClient(
            createNetwork: { configuration in
                try await recorder.createNetwork(configuration: configuration)
            },
            networkExists: { id in
                try await recorder.networkExists(id: id)
            },
            deleteNetwork: { id in
                try await recorder.deleteNetwork(id: id)
            },
            createVolume: { request in
                try await recorder.createVolume(request)
            },
            listVolumes: {
                try await recorder.listVolumes()
            },
            deleteVolume: { name in
                try await recorder.deleteVolume(name: name)
            }
        )
        let labels = ["com.example.role": "cache"]
        let configuration = try NetworkConfiguration(
            name: "demo_default",
            mode: .nat,
            labels: ResourceLabels(labels),
            plugin: "container-network-vmnet"
        )

        try await client.createNetwork(configuration: configuration)
        try await client.createVolume(ComposeVolumeCreateRequest(
            name: "demo_cache",
            driver: "local",
            driverOpts: ["size": "64m"],
            labels: labels
        ))
        _ = try await client.listVolumes()
        _ = try await client.networkExists(id: "demo_default")
        try await client.deleteNetwork(id: "demo_default")
        try await client.deleteVolume(name: "demo_cache")

        #expect(await recorder.requests == [
            .createNetwork(
                name: "demo_default",
                mode: .nat,
                plugin: "container-network-vmnet",
                ipv4Subnet: nil,
                ipv4Gateway: nil,
                ipv4AllocationRange: nil,
                ipv6Subnet: nil,
                enableIPv6: true,
                options: [:],
                labels: labels
            ),
            .createVolume(ComposeVolumeCreateRequest(
                name: "demo_cache",
                driver: "local",
                driverOpts: ["size": "64m"],
                labels: labels
            )),
            .listVolumes,
            .networkExists(id: "demo_default"),
            .deleteNetwork(id: "demo_default"),
            .deleteVolume(name: "demo_cache"),
        ])
    }

    @Test("rm supports force and anonymous volume removal")
    func rmSupportsForceAndAnonymousVolumeRemoval() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.volumes = [
                        ComposeMount(type: "volume", target: "/scratch"),
                        ComposeMount(type: "volume", source: "cache", target: "/cache"),
                        ComposeMount(type: "bind", source: "/host", target: "/host"),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: false, force: true, volumes: true)

        let commands = runner.commands.map(\.arguments)
        #expect(commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-api-1", force: true),
        ])
        let resources = await resourceManager.requests
        #expect(resources.count == 2)
        #expect(resources.first == .listVolumes)
        #expect(resources.last?.name.hasPrefix("demo_anon-") == true)
        #expect(!commands.contains { $0.contains("demo_cache") })
    }

    @Test("rm skips running containers unless stop is requested")
    func rmSkipsRunningContainersUnlessStopIsRequested() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: false, force: true)

        #expect(emitted.messages == ["No stopped containers"])
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("rm ignores containers that disappear during removal")
    func rmIgnoresContainersThatDisappearDuringRemoval() async throws {
        let missing = ContainerizationError(.notFound, message: "container not found")
        let deleteError = ContainerizationError(.internalError, message: "failed to delete container", cause: missing)
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(deleteErrorsByID: [
            "demo-api-1": deleteError,
        ])
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: false, force: true)

        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-api-1", force: true),
        ])
    }

    @Test("rm cancellation avoids stop and delete")
    func rmCancellationAvoidsStopAndDelete() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let prompts = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                runtimeHooks: .init(confirm: { prompt in
                    prompts.append(prompt)
                    return false
                })
            ),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true, force: false)

        #expect(prompts.messages == ["Going to remove demo-api-1\nAre you sure? [yN] "])
        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("rm confirms before stopping containers")
    func rmConfirmsBeforeStoppingContainers() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "running"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let prompts = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                runtimeHooks: .init(confirm: { prompt in
                    prompts.append(prompt)
                    return true
                })
            ),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true, force: false)

        #expect(prompts.messages == ["Going to remove demo-api-1\nAre you sure? [yN] "])
        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("rm stop skips stop for already stopped containers")
    func rmStopSkipsStopForAlreadyStoppedContainers() async throws {
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine"),
            ]
        )

        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true, force: true)

        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-api-1", force: true),
        ])
    }

    @Test("rm surfaces anonymous volume removal failures")
    func rmSurfacesAnonymousVolumeRemovalFailures() async throws {
        let runner = RecordingRunner()
        let expected = ComposeError.invalidProject("anonymous volume delete failed")
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            discoveredServiceContainer(id: "demo-api-1", serviceName: "api", status: "stopped"),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager(volumeDeleteError: expected)
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.volumes = [
                        ComposeMount(type: "volume", target: "/scratch"),
                    ]
                },
            ]
        )

        do {
            try await orchestrator.rm(project: project, services: ["api"], stopFirst: false, force: true, volumes: true)
            Issue.record("Expected anonymous volume delete failure")
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await lifecycleManager.requests == [
            .delete(id: "demo-api-1", force: true),
        ])
        let resources = await resourceManager.requests
        #expect(resources.count == 2)
        #expect(resources.first == .listVolumes)
        #expect(resources.last?.name.hasPrefix("demo_anon-") == true)
    }

    @Test("lifecycle timeout overrides service stop grace period")
    func lifecycleTimeoutOverridesServiceStopGracePeriod() async throws {
        let runner = RecordingRunner()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(runner: runner, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await orchestrator.stop(project: project, services: ["api"], timeout: 12)
        try await orchestrator.restart(project: project, services: ["api"], timeout: 13)
        try await orchestrator.down(project: project, options: ComposeDownOptions(timeout: 14))

        #expect(runner.commands.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 12),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 13),
            .start(id: "demo-api-1"),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 14),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("lifecycle rejects invalid timeout before runtime commands")
    func lifecycleRejectsInvalidTimeoutBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        do {
            try await orchestrator.stop(project: project, services: ["api"], timeout: -1)
            Issue.record("Expected invalid timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("stop --timeout must be between 0 and 2147483647 seconds"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await orchestrator.up(project: project, options: ComposeUpOptions {
                $0.timeout = -1
            })
            Issue.record("Expected invalid up timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("up --timeout must be between 0 and 2147483647 seconds"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await orchestrator.up(project: project, options: ComposeUpOptions {
                $0.waitTimeout = -1
            })
            Issue.record("Expected invalid up wait timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("up --wait-timeout must be between 0 and 2147483647 seconds"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await orchestrator.start(project: project, options: ComposeStartOptions {
                $0.waitTimeout = -1
            })
            Issue.record("Expected invalid start wait timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("start --wait-timeout must be between 0 and 2147483647 seconds"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("exec disables TTY while keeping stdin interactive")
    func execDisablesTTYWhileKeepingStdinInteractive() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let orchestrator = ComposeOrchestrator(runner: runner, execManager: execManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            command: ["echo", "ok"],
            interactive: true,
            tty: false
        )

        #expect(runner.commands.isEmpty)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["echo", "ok"],
                terminal: .init(interactive: true, tty: false)
            ),
        ])
    }

    @Test("attached exec emits progress before terminal handoff")
    func attachedExecEmitsProgressBeforeTerminalHandoff() async throws {
        let runner = RecordingRunner()
        let progress = LockedStringRecorder()
        let execManager = RecordingContainerExecManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            execManager: execManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            command: ["sh"],
            interactive: true,
            tty: true
        )

        #expect(progress.snapshot.joined() == "⠓ Executing api\n")
        #expect(runner.commands.isEmpty)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh"],
                terminal: .init(interactive: true, tty: true)
            ),
        ])
    }

    @Test("exec maps environment user workdir and detach options")
    func execMapsEnvironmentUserWorkdirAndDetachOptions() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let execManager = RecordingContainerExecManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            execManager: execManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            options: ComposeExecOptions {
                $0.command = ["env"]
                $0.detach = true
                $0.environment = ["FOO=bar", "DEBUG"]
                $0.user = "1000:1000"
                $0.workingDirectory = "/app"
                $0.privileged = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await execManager.requests == [
            ContainerDetachedExecRequest(
                id: "demo-api-1",
                command: ["env"],
                environment: ["FOO=bar", "DEBUG"],
                user: "1000:1000",
                workingDirectory: "/app",
                privileged: true
            ),
        ])
        #expect(emitted.messages == ["demo-api-1"])
    }

    @Test("exec dry run renders detached runtime command")
    func execDryRunRendersDetachedRuntimeCommand() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let execManager = RecordingContainerExecManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            execManager: execManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            options: ComposeExecOptions {
                $0.command = ["sleep", "60"]
                $0.detach = true
                $0.privileged = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(emitted.messages == ["+ container exec --detach --privileged demo-api-1 sleep 60"])
        #expect(await execManager.requests.isEmpty)
    }

    @Test("exec resolves selected service container indexes")
    func execResolvesSelectedServiceContainerIndexes() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeOneOffLabel: "false",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.execManager = execManager
        })
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            options: ComposeExecOptions {
                $0.command = ["true"]
                $0.index = 2
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-2",
                command: ["true"],
                terminal: .init(interactive: true, tty: true)
            ),
        ])
    }

    @Test("exec dry run renders selected service container indexes")
    func execDryRunRendersSelectedServiceContainerIndexes() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            discoveryManager: discoveryManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            options: ComposeExecOptions {
                $0.command = ["true"]
                $0.index = 2
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(emitted.messages == ["+ container exec --interactive --tty demo-api-2 true"])
        #expect(await discoveryManager.listRequests.isEmpty)
    }

    @Test("exec reports missing selected service container indexes")
    func execReportsMissingSelectedServiceContainerIndexes() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(runner: runner, dependencies: orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.execManager = execManager
        })
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await orchestrator.exec(
                project: project,
                serviceName: "api",
                options: ComposeExecOptions {
                    $0.command = ["true"]
                    $0.index = 2
                }
            )
            Issue.record("Expected missing indexed container error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' container 'demo-api-2' does not exist"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await execManager.attachedRequests.isEmpty)
    }

    @Test("exec maps privileged mode to runtime requests")
    func execMapsPrivilegedModeToRuntimeRequests() async throws {
        let runner = RecordingRunner()
        let execManager = RecordingContainerExecManager()
        let orchestrator = ComposeOrchestrator(runner: runner, execManager: execManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            options: ComposeExecOptions {
                $0.command = ["true"]
                $0.privileged = true
                $0.interactive = false
                $0.tty = false
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["true"],
                privileged: true,
                terminal: .init(interactive: false, tty: false)
            ),
        ])
    }

}
