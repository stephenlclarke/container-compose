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
import ComposeTestStorage
import Foundation
import Testing

@Suite("Secure temporary paths")
struct ComposeTemporaryFilesTests {
    @Test
    func `atomic publication preserves contents permissions and cleanup`() throws {
        let directory = try ComposeTemporaryFiles.createDirectory(prefix: "compose-atomic-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload")
        try ComposeTemporaryFiles.writeAtomically(Data("first".utf8), to: file)
        #expect(try permissions(at: file) == 0o600)
        try ComposeTemporaryFiles.writeAtomically(Data("second".utf8), to: file, permissions: 0o444)
        #expect(try Data(contentsOf: file) == Data("second".utf8))
        #expect(try permissions(at: file) == 0o444)
        #expect(throws: Error.self) {
            try ComposeTemporaryFiles.writeAtomically(Data(), to: directory)
        }
        #expect(throws: Error.self) {
            try ComposeTemporaryFiles.writeAtomically(Data(), to: directory.appendingPathComponent("missing/child"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["payload"])
    }

    @Test
    func `atomic publication replaces a symlink without modifying its target`() throws {
        let directory = try ComposeTemporaryFiles.createDirectory(prefix: "compose-atomic-link-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("target")
        try Data("preserve".utf8).write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        try ComposeTemporaryFiles.writeAtomically(Data("published".utf8), to: link)
        #expect(try Data(contentsOf: file) == Data("preserve".utf8))
        #expect(try Data(contentsOf: link) == Data("published".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType == .typeRegular)
    }

    @Test
    func `absolute caller scratch overrides the Foundation default`() {
        let fallback = URL(fileURLWithPath: "/fallback")
        #expect(ComposeTemporaryFiles.resolveDirectory(environment: ["TMPDIR": "/scratch/child/../test"], fallback: fallback).path == "/scratch/test")
        for environment in [[:], ["TMPDIR": ""], ["TMPDIR": "relative"]] {
            #expect(ComposeTemporaryFiles.resolveDirectory(environment: environment, fallback: fallback) == fallback)
        }
        if ProcessInfo.processInfo.environment["BAZEL_TEST"] == "1" {
            #expect(ComposeTemporaryFiles.defaultDirectory.resolvingSymlinksInPath() == TestStorage.temporaryDirectory)
        }
    }

    @Test
    func `creating private files refuses existing files and symlinks`() throws {
        let directory = try ComposeTemporaryFiles.createDirectory(prefix: "compose-exclusive-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("preserve".utf8).write(to: target)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        for existing in [target, link, directory, directory.appendingPathComponent("missing/child")] {
            #expect(throws: Error.self) { _ = try ComposeTemporaryFiles.createFile(at: existing) }
        }
        #expect(try Data(contentsOf: target) == Data("preserve".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test
    func `standard temporary root creates private directories and files`() throws {
        let directory = try ComposeTemporaryFiles.createDirectory(prefix: "compose-permissions-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload")

        try ComposeTemporaryFiles.write(Data("sensitive\n".utf8), to: file)

        #expect(try permissions(at: directory) == 0o700)
        #expect(try permissions(at: file) == 0o600)
        #expect(try Data(contentsOf: file) == Data("sensitive\n".utf8))
    }

    @Test
    func `shared temporary root retains private child permissions`() throws {
        let sharedRoot = TestStorage.temporaryDirectory
            .appendingPathComponent("compose-shared-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sharedRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o777],
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: sharedRoot.path)
        defer { try? FileManager.default.removeItem(at: sharedRoot) }

        let directory = try ComposeTemporaryFiles.createDirectory(in: sharedRoot)
        let file = directory.appendingPathComponent("payload")
        try ComposeTemporaryFiles.prepareFile(at: file)

        #expect(try permissions(at: sharedRoot) == 0o777)
        #expect(try permissions(at: directory) == 0o700)
        #expect(try permissions(at: file) == 0o600)
    }

    @Test
    func `failed directory creation preserves an existing path`() throws {
        let parent = try ComposeTemporaryFiles.createDirectory(prefix: "compose-existing-path-")
        defer { try? FileManager.default.removeItem(at: parent) }
        let existing = parent.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("sentinel")
        try Data("preserve\n".utf8).write(to: sentinel)

        #expect(throws: Error.self) {
            try ComposeTemporaryFiles.createDirectory(at: existing)
        }

        #expect(try Data(contentsOf: sentinel) == Data("preserve\n".utf8))
    }

    @Test
    func `file permission verification rejects symlink replacement`() throws {
        let directory = try ComposeTemporaryFiles.createDirectory(prefix: "compose-symlink-check-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("target\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let link = directory.appendingPathComponent("archive.tar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: Error.self) {
            try ComposeTemporaryFiles.secureFile(at: link)
        }

        #expect(try permissions(at: target) == 0o644)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}
