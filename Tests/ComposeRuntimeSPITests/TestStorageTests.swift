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

import ComposeTestStorage
import Foundation
import Testing

struct TestStorageTests {
    @Test
    func `fixture publication replaces atomically and cleans failed staging`() throws {
        let directory = TestStorage.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("value")
        try "one".writeFixture(to: file, encoding: .utf8)
        try "two".writeFixture(to: file, encoding: .utf8)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        #expect(throws: Error.self) { try "\u{20ac}".writeFixture(to: file, encoding: .ascii) }
        #expect(throws: Error.self) { try TestStorage.writeFixture(Data(), to: directory) }
        #expect(throws: Error.self) { try TestStorage.writeFixture(Data(), to: directory.appendingPathComponent("missing/file")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["value"])
    }

    @Test
    func `scratch precedence honors the runner before process and platform defaults`() {
        #expect(TestStorage.resolve(environment: ["TEST_TMPDIR": "/test-scratch", "TMPDIR": "/process-scratch"], fallback: "/fallback")?.path == "/test-scratch")
        #expect(TestStorage.resolve(environment: ["TMPDIR": "/process-scratch"], fallback: "/fallback")?.path == "/process-scratch")
        #expect(TestStorage.resolve(environment: [:], fallback: "/fallback")?.path == "/fallback")
    }

    @Test
    func `relative and unbound Bazel storage is rejected`() {
        #expect(TestStorage.resolve(environment: ["TMPDIR": "relative"], fallback: "/fallback") == nil)
        #expect(TestStorage.resolve(environment: ["BAZEL_TEST": "1", "TMPDIR": "/scratch"], fallback: "/fallback") == nil)
        #expect(TestStorage.resolve(environment: ["BAZEL_TEST": "1", "TMPDIR": "/scratch", "DEVCONTAINER_TEST_SCRATCH_ROOT": "/"], fallback: "/fallback") == nil)
    }

    @Test
    func `Bazel scratch must be a strict child of the enrolled root`() {
        var environment = ["BAZEL_TEST": "1", "DEVCONTAINER_TEST_SCRATCH_ROOT": "/scratch", "TEST_TMPDIR": "/scratch/case"]
        #expect(TestStorage.resolve(environment: environment, fallback: "/fallback")?.path == "/scratch/case")
        for invalid in ["/scratch", "/scratch-other/case", "/scratch/../outside"] {
            environment["TEST_TMPDIR"] = invalid
            #expect(TestStorage.resolve(environment: environment, fallback: "/fallback") == nil)
        }
    }

    @Test
    func `real runner storage remains on its declared volume`() throws {
        let directory = TestStorage.temporaryDirectory
        #expect(directory.path.hasPrefix("/"))
        if ProcessInfo.processInfo.environment["BAZEL_TEST"] == "1" {
            let root = try #require(ProcessInfo.processInfo.environment["DEVCONTAINER_TEST_SCRATCH_ROOT"])
            #expect(directory.path.hasPrefix(URL(fileURLWithPath: root).path + "/"))
        }
    }
}
