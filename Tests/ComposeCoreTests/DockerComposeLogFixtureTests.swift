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

import Foundation
import Testing

@Suite("Docker Compose log fixtures")
struct DockerComposeLogFixtureTests {
    @Test
    func `rotated tail fixture records Docker Compose line semantics`() throws {
        let fixture = try String(contentsOf: Self.rotatedTailFixtureURL(), encoding: .utf8)

        assertFixture(fixture, contains: "## rotating-json --tail 5")
        assertFixture(fixture, contains: "## rotating-json --tail 0\nline-count: 0")
        assertFixture(fixture, contains: "## rotating-json --tail -1\nline-count: 40")
        assertFixture(fixture, contains: "## rotating-json --tail all\nline-count: 40")
        assertFixture(fixture, contains: "rotate-json-246 abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz")
        assertFixture(fixture, contains: "rotate-json-250 abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz")

        assertFixture(fixture, contains: "## rotating-local --tail 5")
        assertFixture(fixture, contains: "## rotating-local --tail 0\nline-count: 0")
        assertFixture(fixture, contains: "## rotating-local --tail -1\nline-count: 61")
        assertFixture(fixture, contains: "## rotating-local --tail all\nline-count: 61")
        assertFixture(fixture, contains: "rotate-local-246 abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz")
        assertFixture(fixture, contains: "rotate-local-250 abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz")
    }

    private static func rotatedTailFixtureURL() throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "docker-compose-rotated-tail",
            withExtension: "expected",
        ) else {
            throw FixtureError.missing("Fixtures/logging/docker-compose-rotated-tail.expected")
        }
        return url
    }

    private func assertFixture(_ fixture: String, contains expected: String) {
        #expect(fixture.contains(expected), "Fixture is missing expected content: \(expected)")
    }
}

private enum FixtureError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case let .missing(path):
            "Missing test fixture: \(path)"
        }
    }
}
