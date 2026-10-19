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

// Original work Copyright 2026 devcontainer project authors. Apache-2.0.

@testable import ComposeEngineRuntime
import ContainerEngineWire
import Foundation
import Testing

struct EngineStreamDecoderTests {
    @Test
    func `multiplex headers and binary payload survive every split`() throws {
        let first = Data([0, 255, 42, 10])
        let second = Data("error".utf8)
        let bytes = try DockerStreamFraming.encode(.init(channel: .standardOutput, data: first), terminal: false)
            + DockerStreamFraming.encode(.init(channel: .standardError, data: second), terminal: false)
        for split in 0 ... bytes.count {
            var decoder = EngineStreamDecoder()
            let frames = try decoder.consume(bytes.prefix(split)) + decoder.consume(bytes.dropFirst(split))
            try decoder.finish()
            #expect(frames.filter { $0.channel == .standardOutput }.reduce(Data()) { $0 + $1.data } == first)
            #expect(frames.filter { $0.channel == .standardError }.reduce(Data()) { $0 + $1.data } == second)
        }
        var decoder = EngineStreamDecoder()
        #expect(try decoder.consume(Data([1, 0, 0, 0, 0, 0, 0, 0])).isEmpty)
        try decoder.finish()
    }

    @Test(arguments: [Data([4, 0, 0, 0, 0, 0, 0, 0]), Data([1, 2, 0, 0, 0, 0, 0, 0])])
    func `invalid channel or reserved bits are not output`(bytes: Data) {
        var decoder = EngineStreamDecoder()
        #expect(throws: (any Error).self) { try decoder.consume(bytes) }
    }

    @Test(arguments: [Data([1]), Data([1, 0, 0, 0, 0, 0, 0, 2, 65])])
    func `truncated header or payload is not clean EOF`(bytes: Data) throws {
        var decoder = EngineStreamDecoder()
        _ = try decoder.consume(bytes)
        #expect(throws: (any Error).self) { try decoder.finish() }
    }
}
