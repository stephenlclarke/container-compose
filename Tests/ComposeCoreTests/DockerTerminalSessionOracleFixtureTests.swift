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

@Suite("Docker terminal-session oracle fixture")
struct DockerTerminalSessionOracleFixtureTests {
    @Test
    func `pins reference identity and raw TTY upgrade`() throws {
        let fixture = try Self.fixture()

        #expect(try integer(fixture, "schemaVersion") == 1)
        #expect(try string(fixture, "metadata", "engineVersion") == "29.2.1")
        #expect(try string(fixture, "metadata", "engineGitCommit") == "6bc6209")
        #expect(try string(fixture, "metadata", "apiVersion") == "1.53")
        #expect(try string(fixture, "metadata", "context") == "colima")
        #expect(try string(fixture, "metadata", "image") == "alpine:3.20")
        #expect(try number(fixture, "case", "durationSeconds") > 0)

        for session in ["firstAttach", "reattach"] {
            #expect(
                try integer(fixture, "case", session, "handshake", "httpStatus") == 101,
            )
            #expect(
                try string(fixture, "case", session, "handshake", "connection")
                    == "upgrade",
            )
            #expect(
                try string(fixture, "case", session, "handshake", "upgrade") == "tcp",
            )
            #expect(
                try string(fixture, "case", session, "handshake", "contentType")
                    == "application/vnd.docker.raw-stream",
            )
        }
    }

    @Test
    func `pins resize detach reattach exit and cleanup`() throws {
        let fixture = try Self.fixture()

        #expect(try integer(fixture, "case", "create", "httpStatus") == 201)
        #expect(try integer(fixture, "case", "start", "httpStatus") == 204)
        #expect(
            try strings(fixture, "case", "firstAttach", "initialLines") == ["READY"],
        )
        #expect(
            try integer(fixture, "case", "firstAttach", "resize", "httpStatus") == 200,
        )
        #expect(try integer(fixture, "case", "firstAttach", "resize", "height") == 48)
        #expect(try integer(fixture, "case", "firstAttach", "resize", "width") == 132)
        #expect(
            try strings(fixture, "case", "firstAttach", "resize", "observedLines")
                == ["size", "SIZE:48:132"],
        )
        #expect(
            try integers(fixture, "case", "firstAttach", "detach", "sequenceBytes")
                == [24],
        )
        #expect(try boolean(fixture, "case", "firstAttach", "detach", "eof"))
        #expect(
            try boolean(fixture, "case", "firstAttach", "detach", "workloadRunning"),
        )
        #expect(
            try strings(fixture, "case", "reattach", "observedLines")
                == ["after", "AFTER"],
        )
        #expect(
            try strings(fixture, "case", "reattach", "exitLines") == ["exit", "BYE"],
        )
        #expect(try boolean(fixture, "case", "reattach", "terminalEOF"))
        #expect(try integer(fixture, "case", "terminalState", "exitCode") == 0)
        #expect(try boolean(fixture, "case", "terminalState", "running") == false)
        #expect(try integer(fixture, "case", "cleanup", "deleteStatus") == 204)
        #expect(try boolean(fixture, "case", "cleanup", "absentAfterDelete"))
    }

    private static func fixture() throws -> [String: Any] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("logging")
            .appendingPathComponent("docker-engine-29.2.1-terminal-session.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
        guard let fixture = object as? [String: Any] else {
            throw FixtureError.invalid("top-level value is not an object")
        }
        return fixture
    }
}

private func value<T>(_ root: [String: Any], _ path: [String]) throws -> T {
    var current: Any = root
    for component in path {
        guard let object = current as? [String: Any], let next = object[component] else {
            throw FixtureError.invalid("missing \(path.joined(separator: "."))")
        }
        current = next
    }
    guard let typed = current as? T else {
        throw FixtureError.invalid("\(path.joined(separator: ".")) has an unexpected type")
    }
    return typed
}

private func string(_ root: [String: Any], _ path: String...) throws -> String {
    try value(root, path)
}

private func integer(_ root: [String: Any], _ path: String...) throws -> Int {
    let number: NSNumber = try value(root, path)
    return number.intValue
}

private func number(_ root: [String: Any], _ path: String...) throws -> Double {
    let number: NSNumber = try value(root, path)
    return number.doubleValue
}

private func integers(_ root: [String: Any], _ path: String...) throws -> [Int] {
    let numbers: [NSNumber] = try value(root, path)
    return numbers.map(\.intValue)
}

private func strings(_ root: [String: Any], _ path: String...) throws -> [String] {
    try value(root, path)
}

private func boolean(_ root: [String: Any], _ path: String...) throws -> Bool {
    let number: NSNumber = try value(root, path)
    return number.boolValue
}

private enum FixtureError: Error {
    case invalid(String)
}
