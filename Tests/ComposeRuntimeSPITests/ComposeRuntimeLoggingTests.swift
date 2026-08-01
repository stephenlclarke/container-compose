//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

@testable import ComposeRuntimeSPI
import Foundation
import Testing

@Suite("Compose runtime logging contracts")
struct ComposeRuntimeLoggingTests {
    @Test
    func `read request defaults select both streams without follow`() {
        let request = ComposeLogReadRequest()

        #expect(request.stdout)
        #expect(request.stderr)
        #expect(!request.follow)
        #expect(request.tail == nil)
        #expect(request.since == nil)
        #expect(request.until == nil)
        #expect(!request.timestamps)
        #expect(!request.details)
    }

    @Test
    func `record round trip preserves binary payload stream and partial metadata`() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        let record = ComposeLogRecord(
            stream: .stderr,
            payload: Data([0x00, 0xFF, 0x0A]),
            timestamp: timestamp,
            attributes: ["container_name": "demo-api-1"],
            terminal: false,
            partial: ComposeLogPartialMetadata(id: "partial-1", ordinal: 2, last: true),
        )

        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ComposeLogRecord.self, from: encoded)

        #expect(decoded == record)
    }
}
