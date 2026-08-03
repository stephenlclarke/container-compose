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

@Suite("Compose execution options")
struct ComposeExecutionOptionsTests {
    @Test
    func `options builder preserves configured runtime hooks`() {
        let expectedDate = Date(timeIntervalSince1970: 1234.0)
        let options = ComposeExecutionOptions {
            $0.dryRun = true
            $0.currentDate = { expectedDate }
        }

        #expect(options.dryRun)
        #expect(options.currentDate() == expectedDate)
    }

    @Test
    func `parallelism defaults to unlimited when no control is configured`() throws {
        #expect(try ComposeExecutionOptions.effectiveParallelism(explicit: nil, environment: [:]) == -1)
    }

    @Test
    func `explicit parallelism overrides the environment`() throws {
        #expect(try ComposeExecutionOptions.effectiveParallelism(
            explicit: 2,
            environment: ["COMPOSE_PARALLEL_LIMIT": "4"],
        ) == 2)
    }

    @Test
    func `parallelism uses the environment when the option is absent`() throws {
        #expect(try ComposeExecutionOptions.effectiveParallelism(
            explicit: nil,
            environment: ["COMPOSE_PARALLEL_LIMIT": "3"],
        ) == 3)
    }

    @Test
    func `parallelism rejects an invalid environment value`() {
        do {
            _ = try ComposeExecutionOptions.effectiveParallelism(
                explicit: nil,
                environment: ["COMPOSE_PARALLEL_LIMIT": "0"],
            )
            Issue.record("Expected invalid COMPOSE_PARALLEL_LIMIT failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("COMPOSE_PARALLEL_LIMIT must be -1 or a positive integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `dynamic host port allocation supports wildcard UDP and bracketed IPv6`() throws {
        let wildcardUDPPort = try ComposeExecutionOptions.defaultHostPortAllocator(
            hostAddress: nil,
            protocolName: "udp",
        )
        let ipv6TCPPort = try ComposeExecutionOptions.defaultHostPortAllocator(
            hostAddress: "[::1]",
            protocolName: "tcp",
        )

        #expect(wildcardUDPPort > 0)
        #expect(ipv6TCPPort > 0)
    }

    @Test
    func `dynamic host port allocation rejects malformed IP literals`() {
        assertInvalidHostAddress("not-an-ip")
        assertInvalidHostAddress("invalid::address")
    }

    private func assertInvalidHostAddress(_ hostAddress: String) {
        do {
            _ = try ComposeExecutionOptions.defaultHostPortAllocator(
                hostAddress: hostAddress,
                protocolName: "tcp",
            )
            Issue.record("Expected malformed host address failure for \(hostAddress)")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "dynamic host-port allocation requires an IPv4 or IPv6 literal host address, got '\(hostAddress)'",
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
