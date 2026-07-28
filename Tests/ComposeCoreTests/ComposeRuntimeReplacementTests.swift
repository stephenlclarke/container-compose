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
import Testing

@Suite("Runtime-neutral Apple helper replacements")
struct ComposeRuntimeReplacementTests {
    @Test
    func `byte sizes retain Apple parser whitespace behaviour`() throws {
        #expect(try ComposeByteSizeParser.bytes(" 2.5mb ") == 2_621_440)
        #expect(try ComposeByteSizeParser.bytes("2.5 mb") == 2_621_440)
        #expect(try ComposeByteSizeParser.bytes("1k") == 1024)
        #expect(try ComposeByteSizeParser.bytes("1kb") == 1024)
        #expect(try ComposeByteSizeParser.bytes("1kib") == 1024)
        #expect(throws: (any Error).self) {
            try ComposeByteSizeParser.bytes("2mb\n")
        }
    }

    @Test
    func `GPU CSV parsing rejects malformed quote placement`() {
        let quoted = try? ComposeRuntimeInputParser.gpuRequests(["\"device=0,1\""]).first
        #expect(quoted?.deviceIDs == ["0", "1"])
        #expect(quoted?.capabilities == ["gpu"])
        #expect(throws: (any Error).self) {
            try ComposeRuntimeInputParser.gpuRequests(["device=0\"1"])
        }
        #expect(throws: (any Error).self) {
            try ComposeRuntimeInputParser.gpuRequests(["\"device=0\"trailing"])
        }
        #expect(throws: (any Error).self) {
            try ComposeRuntimeInputParser.gpuRequests(["\"device=0"])
        }
    }

    @Test
    func `image reference parsing retains Apple domain and digest semantics`() throws {
        let repositoryPath = try ComposeImageReference.parse("example/app:tag")
        #expect(repositoryPath.domain == nil)
        #expect(repositoryPath.path == "example/app")

        let registry = try ComposeImageReference.parse("registry.example:5000/team/app:tag")
        #expect(registry.domain == "registry.example:5000")
        #expect(registry.path == "team/app")
        #expect(registry.tag == "tag")

        let ipv6Registry = try ComposeImageReference.parse("[abc12::4]:5683/swift")
        #expect(ipv6Registry.domain == "[abc12::4]:5683")
        #expect(ipv6Registry.path == "swift")

        #expect(throws: (any Error).self) {
            try ComposeImageReference.parse("localhost")
        }
        #expect(throws: (any Error).self) {
            try ComposeImageReference.parse("localhost:5000")
        }

        let digest = String(repeating: "a", count: 64)
        let digested = try ComposeImageReference.parse("example/app:ignored@sha256:\(digest)")
        #expect(digested.tag == nil)
        #expect(digested.digest == "sha256:\(digest)")
        #expect(throws: (any Error).self) {
            try ComposeImageReference.parse("https://registry.example/team/app")
        }
        #expect(throws: (any Error).self) {
            try ComposeImageReference.parse("mostly.valid/image/but/Caps")
        }
    }

    @Test
    func `IPv6 CIDRs retain valid zone identifiers`() throws {
        let subnet = try CIDRv6("fe80::1%en0/64")
        #expect(subnet.address.zone == "en0")
        #expect(subnet.description == "fe80::1%en0/64")
        #expect(try subnet.contains(IPv6Address("fe80::2%en0")))
        #expect(try !subnet.contains(IPv6Address("fe80::2%en1")))
        #expect(try CIDRv4("192.0.2.1//24").prefixLength == 24)
        #expect(try CIDRv6("2001:db8::1//64").prefixLength == 64)
        #expect(try IPv6Address("::ffff:192.0.2.1").description == "::ffff:c000:201")
        #expect(throws: (any Error).self) {
            try IPv4Address("192.168.001.1")
        }
        #expect(throws: (any Error).self) {
            try IPv6Address("::ffff:192.168.001.1")
        }
        #expect(throws: (any Error).self) {
            try IPv6Address("fe80::1%en0%unexpected")
        }
    }
}
