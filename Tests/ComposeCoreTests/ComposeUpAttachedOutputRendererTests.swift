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
import ComposeRuntimeSPI
import Foundation
import Testing

@Suite("Compose up attached output renderer")
struct ComposeUpAttachedOutputRendererTests {
    @Test("frames an unevenly chunked line larger than one mebibyte")
    func framesLargeUnevenlyChunkedLine() {
        let emitted = OutputDataRecorder()
        let renderer = makeRenderer { emitted.append($0) }
        let payload = Data(repeating: 0x61, count: 1_100_003)
        let chunkSizes = [257, 8_191, 33, 16_384, 1_003]
        var offset = 0
        var chunkIndex = 0

        while offset < payload.count {
            let end = min(offset + chunkSizes[chunkIndex % chunkSizes.count], payload.count)
            var chunk = Data(payload[offset..<end])
            if end == payload.count {
                chunk.append(UInt8(ascii: "\n"))
            }
            renderer.append(ComposeLogRecord(stream: .stdout, payload: chunk))
            offset = end
            chunkIndex += 1
        }

        var expected = Data("api-1 | ".utf8)
        expected.append(payload)
        expected.append(UInt8(ascii: "\n"))
        #expect(emitted.batches == [expected])
    }

    @Test("batches many completed lines from one append")
    func batchesManyLinesFromOneAppend() {
        let emitted = OutputDataRecorder()
        let renderer = makeRenderer { emitted.append($0) }
        var payload = Data()
        var expected = Data()
        for _ in 0..<2_000 {
            payload.append(contentsOf: "row\n".utf8)
            expected.append(contentsOf: "api-1 | row\n".utf8)
        }

        renderer.append(ComposeLogRecord(stream: .stdout, payload: payload))

        #expect(emitted.batches == [expected])
    }

    @Test("preserves split LF and CRLF framing, binary bytes, timestamps, and stream flush order")
    func preservesFramingBytesTimestampsAndFlushOrder() {
        let currentDate = DateSequence([Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 101)])
        let emitted = OutputDataRecorder()
        let renderer = makeRenderer(timestamps: true, currentDate: { currentDate.next() }) {
            emitted.append($0)
        }
        let firstDate = Date(timeIntervalSince1970: 10)
        let completingDate = Date(timeIntervalSince1970: 20)

        renderer.append(ComposeLogRecord(
            stream: .stdout,
            payload: Data("first\r".utf8),
            timestamp: firstDate,
        ))
        renderer.append(ComposeLogRecord(
            stream: .stderr,
            payload: Data([0xFF, 0x0A]),
            timestamp: firstDate,
        ))
        renderer.append(ComposeLogRecord(
            stream: .stdout,
            payload: Data("\n\nsecond\r\nthird\rX\nTAIL".utf8),
            timestamp: completingDate,
        ))
        renderer.append(ComposeLogRecord(stream: .stderr, payload: Data([0x80])))
        renderer.flush()

        var expected = Data()
        expected.append(contentsOf: "api-1 | 1970-01-01T00:00:10.000Z ".utf8)
        expected.append(0xFF)
        expected.append(UInt8(ascii: "\n"))
        for line in ["first", "", "second", "third\rX"] {
            expected.append(contentsOf: "api-1 | 1970-01-01T00:00:20.000Z \(line)\n".utf8)
        }
        expected.append(contentsOf: "api-1 | 1970-01-01T00:01:40.000Z TAIL".utf8)
        expected.append(contentsOf: "api-1 | 1970-01-01T00:01:41.000Z ".utf8)
        expected.append(0x80)

        #expect(Data(emitted.batches.flatMap { Array($0) }) == expected)
        #expect(emitted.batches.count == 3)
        #expect(currentDate.calls == 2)
    }

    @Test("uses current date separately for each completed line without a record timestamp")
    func usesCurrentDateForEachCompletedLineWithoutRecordTimestamp() {
        let currentDate = DateSequence([Date(timeIntervalSince1970: 30), Date(timeIntervalSince1970: 31)])
        let emitted = OutputDataRecorder()
        let renderer = makeRenderer(timestamps: true, currentDate: { currentDate.next() }) {
            emitted.append($0)
        }

        renderer.append(ComposeLogRecord(stream: .stdout, payload: Data("one\ntwo\n".utf8)))

        #expect(emitted.batches == [Data(
            "api-1 | 1970-01-01T00:00:30.000Z one\napi-1 | 1970-01-01T00:00:31.000Z two\n".utf8
        )])
        #expect(currentDate.calls == 2)
    }

    @Test("supports callback reentrancy without recursion or deadlock")
    func supportsCallbackReentrancy() {
        let recorder = ReentrantAppendRecorder()
        let renderer = makeRenderer { recorder.emit($0) }
        recorder.renderer = renderer

        renderer.append(ComposeLogRecord(stream: .stdout, payload: Data("first\n".utf8)))

        recorder.renderer = nil
        #expect(recorder.output.batches == [
            Data("api-1 | first\n".utf8),
            Data("api-1 | second\n".utf8),
        ])
    }

    @Test("serializes concurrent batches in append order")
    func serializesConcurrentBatchesInAppendOrder() {
        let firstBatchEntered = DispatchSemaphore(value: 0)
        let releaseFirstBatch = DispatchSemaphore(value: 0)
        let secondAppendStarted = DispatchSemaphore(value: 0)
        let secondAppendReturned = DispatchSemaphore(value: 0)
        let firstAppendReturned = DispatchSemaphore(value: 0)
        let emitted = OutputDataRecorder()
        let firstBatch = Data("api-1 | first\n".utf8)
        let renderer = makeRenderer { data in
            if data == firstBatch {
                firstBatchEntered.signal()
                _ = releaseFirstBatch.wait(timeout: .now() + 5)
            }
            emitted.append(data)
        }

        DispatchQueue.global().async {
            renderer.append(ComposeLogRecord(stream: .stdout, payload: Data("first\n".utf8)))
            firstAppendReturned.signal()
        }
        #expect(firstBatchEntered.wait(timeout: .now() + 5) == .success)

        DispatchQueue.global().async {
            secondAppendStarted.signal()
            renderer.append(ComposeLogRecord(stream: .stderr, payload: Data("second\n".utf8)))
            secondAppendReturned.signal()
        }
        #expect(secondAppendStarted.wait(timeout: .now() + 5) == .success)
        #expect(secondAppendReturned.wait(timeout: .now() + 5) == .success)
        releaseFirstBatch.signal()
        #expect(firstAppendReturned.wait(timeout: .now() + 5) == .success)

        #expect(emitted.batches == [
            Data("api-1 | first\n".utf8),
            Data("api-1 | second\n".utf8),
        ])
    }

    @Test("allows a callback to synchronously delegate an append to another thread")
    func supportsCrossThreadCallbackReentrancy() {
        let output = OutputDataRecorder()
        let recorder = ReentrantAppendRecorder()
        let first = Data("api-1 | first\n".utf8)
        let renderer = makeRenderer { data in
            output.append(data)
            if data == first {
                let returned = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    recorder.renderer?.append(ComposeLogRecord(stream: .stderr, payload: Data("second\n".utf8)))
                    returned.signal()
                }
                #expect(returned.wait(timeout: .now() + 5) == .success)
            }
        }
        recorder.renderer = renderer
        renderer.append(ComposeLogRecord(stream: .stdout, payload: Data("first\n".utf8)))
        recorder.renderer = nil
        #expect(output.batches == [first, Data("api-1 | second\n".utf8)])
    }

    @Test("preserves prefix and color options", arguments: [false, true], [false, true])
    func preservesPrefixOptions(noLogPrefix: Bool, colorPrefixes: Bool) {
        let emitted = OutputDataRecorder()
        let renderer = makeRenderer(noLogPrefix: noLogPrefix, colorPrefixes: colorPrefixes) { emitted.append($0) }
        renderer.append(ComposeLogRecord(stream: .stdout, payload: Data("row\n".utf8)))
        let name = colorPrefixes ? "\u{001B}[35mapi-1\u{001B}[0m" : "api-1"
        let prefix = noLogPrefix ? "" : "\(name) | "
        #expect(emitted.batches == [Data("\(prefix)row\n".utf8)])
        renderer.flush()
        renderer.flush()
        #expect(emitted.batches.count == 1)
    }

    @Test("preserves empty chunks, split carriage returns, and successive buffered tails")
    func preservesSuccessiveBufferedTails() {
        let emitted = OutputDataRecorder()
        let renderer = makeRenderer { emitted.append($0) }
        for chunk in [Data(), Data("one\nT".utf8), Data("wo\r".utf8), Data("\nThree\nF".utf8), Data("our".utf8)] {
            renderer.append(ComposeLogRecord(stream: .stdout, payload: chunk))
        }
        renderer.flush()
        renderer.flush()
        #expect(emitted.batches.reduce(into: Data()) { $0.append($1) } == Data("api-1 | one\napi-1 | Two\napi-1 | Three\napi-1 | Four".utf8))
    }

    @Test("accepts sliced Data whose indices do not start at zero")
    func acceptsSlicedData() {
        let emitted = OutputDataRecorder()
        let renderer = makeRenderer { emitted.append($0) }
        let source = Data("ignoredsliced\n".utf8)
        let payload = source.dropFirst(7)
        #expect(payload.startIndex == 7)
        renderer.append(ComposeLogRecord(stream: .stdout, payload: payload))
        #expect(emitted.batches == [Data("api-1 | sliced\n".utf8)])
    }

    private func makeRenderer(
        timestamps: Bool = false,
        noLogPrefix: Bool = false,
        colorPrefixes: Bool = false,
        currentDate: @escaping @Sendable () -> Date = Date.init,
        emit: @escaping @Sendable (Data) -> Void,
    ) -> ComposeUpAttachedOutputRenderer {
        ComposeUpAttachedOutputRenderer(
            target: ServiceContainerTarget(
                service: ComposeService(name: "api", image: "example/api"),
                index: 1,
                name: "demo-api-1",
            ),
            timestamps: timestamps,
            noLogPrefix: noLogPrefix,
            colorPrefixes: colorPrefixes,
            currentDate: currentDate,
            emit: emit,
        )
    }
}

private final class OutputDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var batches: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

private final class DateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let dates: [Date]
    private var index = 0

    init(_ dates: [Date]) {
        self.dates = dates
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let date = dates[index]
        index += 1
        return date
    }
}

private final class ReentrantAppendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var didReenter = false
    private var storedRenderer: ComposeUpAttachedOutputRenderer?
    let output = OutputDataRecorder()

    var renderer: ComposeUpAttachedOutputRenderer? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedRenderer
        }
        set {
            lock.lock()
            storedRenderer = newValue
            lock.unlock()
        }
    }

    func emit(_ data: Data) {
        output.append(data)
        lock.lock()
        let shouldReenter = !didReenter
        didReenter = true
        let renderer = storedRenderer
        lock.unlock()
        if shouldReenter {
            renderer?.append(ComposeLogRecord(stream: .stdout, payload: Data("second\n".utf8)))
        }
    }
}
