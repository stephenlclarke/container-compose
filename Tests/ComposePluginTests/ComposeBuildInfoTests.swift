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

@testable import ComposePlugin
import Foundation
import Testing

@Suite("Compose build information")
struct ComposeBuildInfoTests {
    @Test
    // swiftlint:disable:next identifier_name
    func `Local dependency paths override stale lockfile metadata`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "compose-build-info-\(UUID().uuidString)",
            isDirectory: true,
        )
        defer { try? fileManager.removeItem(at: root) }

        let composeRoot = root.appendingPathComponent(
            "container-compose",
            isDirectory: true,
        )
        let containerRoot = root.appendingPathComponent(
            "container",
            isDirectory: true,
        )
        let containerizationRoot = root.appendingPathComponent(
            "containerization",
            isDirectory: true,
        )
        try fileManager.createDirectory(
            at: composeRoot,
            withIntermediateDirectories: true,
        )
        let containerRef = try makeGitRepository(
            at: containerRoot,
            remote: "https://github.com/example/container.git",
        )
        let containerizationRef = try makeGitRepository(
            at: containerizationRoot,
            remote: "git@github.com:example/containerization.git",
        )
        try staleResolvedFile.write(
            to: composeRoot.appendingPathComponent("Package.resolved"),
            atomically: true,
            encoding: .utf8,
        )

        let info = ComposeBuildInfo.localBuildInfo(
            root: composeRoot.path,
            environment: [
                "CONTAINER_PACKAGE_PATH": containerRoot.path,
                "CONTAINER_SOURCE": "example/fork-container",
                "CONTAINERIZATION_PACKAGE_PATH": containerizationRoot.path,
                "CONTAINERIZATION_SOURCE": "example/fork-containerization",
            ],
        )

        #expect(info.containerSource == "example/fork-container")
        #expect(info.containerRef == containerRef)
        #expect(info.containerizationSource == "example/fork-containerization")
        #expect(info.containerizationRef == containerizationRef)
    }

    private func makeGitRepository(
        at root: URL,
        remote: String,
    ) throws -> String {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
        )
        try Data("fixture\n".utf8).write(
            to: root.appendingPathComponent("fixture.txt"),
        )
        try runGit(["init", "--quiet"], root: root)
        try runGit(["add", "fixture.txt"], root: root)
        try runGit(
            [
                "-c", "user.name=Compose Tests",
                "-c", "user.email=compose-tests@example.invalid",
                "commit", "--quiet", "-m", "test fixture",
            ],
            root: root,
        )
        try runGit(["remote", "add", "origin", remote], root: root)
        return try runGit(["rev-parse", "HEAD"], root: root)
    }

    @discardableResult
    private func runGit(
        _ arguments: [String],
        root: URL,
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw GitFixtureError.failed("git returned non-UTF-8 output")
        }
        let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw GitFixtureError.failed(text)
        }
        return text
    }

    private var staleResolvedFile: String {
        """
        {
          "originHash" : "fixture",
          "pins" : [
            {
              "identity" : "container",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/stale/container.git",
              "state" : { "revision" : "stale-container-ref" }
            },
            {
              "identity" : "containerization",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/stale/containerization.git",
              "state" : { "revision" : "stale-containerization-ref" }
            }
          ],
          "version" : 3
        }
        """
    }
}

private enum GitFixtureError: Error {
    case failed(String)
}
