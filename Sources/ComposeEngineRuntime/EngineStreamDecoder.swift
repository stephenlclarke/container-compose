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
// Adapted from devcontainer 263ec4e; retained here to keep Compose independent.

import ContainerEngineWire
import ContainerUnixHTTPClient
import Foundation

/// Incrementally decodes Docker's eight-byte non-TTY frame headers without
/// buffering a frame payload. Memory stays proportional to the input chunk.
struct EngineStreamDecoder {
    private var header = Data()
    private var remaining: UInt32 = 0
    private var channel = DockerStreamChannel.standardOutput

    init() {}

    mutating func consume(_ bytes: Data) throws -> [DockerStreamFrame] {
        var offset = bytes.startIndex
        var output: [DockerStreamFrame] = []
        while offset < bytes.endIndex {
            if remaining == 0 {
                let size = min(8 - header.count, bytes.distance(from: offset, to: bytes.endIndex))
                let end = bytes.index(offset, offsetBy: size)
                header.append(bytes[offset ..< end])
                offset = end
                guard header.count == 8 else { break }
                guard let channel = DockerStreamChannel(rawValue: header[0]),
                      channel == .standardOutput || channel == .standardError,
                      header[1 ..< 4].allSatisfy({ $0 == 0 })
                else {
                    throw ContainerUnixHTTPClientError.invalidResponse("invalid Docker output frame")
                }
                self.channel = channel
                remaining = header[4 ..< 8].reduce(0) { ($0 << 8) | UInt32($1) }
                header.removeAll(keepingCapacity: true)
            }
            let size = min(Int(remaining), bytes.distance(from: offset, to: bytes.endIndex))
            if size > 0 {
                let end = bytes.index(offset, offsetBy: size)
                output.append(.init(channel: channel, data: Data(bytes[offset ..< end])))
                remaining -= UInt32(size)
                offset = end
            }
        }
        return output
    }

    func finish() throws {
        guard header.isEmpty, remaining == 0 else {
            throw ContainerUnixHTTPClientError.invalidResponse("truncated Docker output frame")
        }
    }
}
