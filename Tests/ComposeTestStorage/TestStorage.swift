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

// Derived from devcontainer TestStorage; Copyright 2026 devcontainer project authors.

import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Explicit scratch selection for test fixtures on both SwiftPM and Bazel.
public enum TestStorage {
    /// Atomic fixture publication without Foundation's volume-level staging.
    public static func writeFixture(_ data: Data, to destination: URL) throws {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".fixture-\(UUID().uuidString)")
        try data.write(to: staged, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: staged) }
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static var temporaryDirectory: URL {
        guard let directory = resolve(
            environment: ProcessInfo.processInfo.environment,
            fallback: FileManager.default.temporaryDirectory.path
        ) else {
            preconditionFailure("Test runner must declare valid absolute scratch on its enrolled storage")
        }
        return directory
    }

    /// Explicit inputs let both build systems check canonical scratch roots
    /// without mutating process-wide environment during parallel tests.
    public static func resolve(environment: [String: String], fallback: String) -> URL? {
        let path = environment["TEST_TMPDIR"] ?? environment["TMPDIR"]
            ?? fallback
        guard path.hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        if environment["BAZEL_TEST"] == "1" {
            guard let root = environment["DEVCONTAINER_TEST_SCRATCH_ROOT"], root.hasPrefix("/"), root != "/"
            else { return nil }
            let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
            let rootPath = rootURL.resolvingSymlinksInPath().path
            guard rootPath == rootURL.path, rootPath != "/",
                  directory.path.hasPrefix(rootPath + "/") else { return nil }
        }
        return directory
    }
}

public extension String {
    /// Keep watcher tests' atomic replacement semantics inside their own root.
    func writeFixture(to destination: URL, encoding: String.Encoding) throws {
        guard let data = data(using: encoding) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try TestStorage.writeFixture(data, to: destination)
    }
}
