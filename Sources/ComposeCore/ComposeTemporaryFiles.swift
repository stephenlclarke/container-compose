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
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Temporary storage shared by Compose and its runtime adapters.
public enum ComposeTemporaryFiles {
    /// Honor the caller's absolute TMPDIR, including external build storage.
    public static var defaultDirectory: URL {
        resolveDirectory(
            environment: ProcessInfo.processInfo.environment,
            fallback: FileManager.default.temporaryDirectory
        )
    }

    package static func resolveDirectory(environment: [String: String], fallback: URL) -> URL {
        guard let path = environment["TMPDIR"], path.hasPrefix("/") else { return fallback }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    package static let directoryPermissions = 0o700
    package static let filePermissions = 0o600

    package static func createDirectory(
        in parent: URL = ComposeTemporaryFiles.defaultDirectory,
        prefix: String = "container-compose-",
    ) throws -> URL {
        let directory = parent.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try createDirectory(at: directory)
        return directory
    }

    package static func createDirectory(at directory: URL) throws {
        let fileManager = FileManager.default
        var created = false
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: directoryPermissions],
            )
            created = true
            try setAndVerifyPermissions(directoryPermissions, type: .typeDirectory, at: directory)
        } catch {
            if created {
                try? fileManager.removeItem(at: directory)
            }
            throw error
        }
    }

    package static func createFile(at file: URL) throws -> FileHandle {
        let fileManager = FileManager.default
        // Create directly in the owned directory. Foundation createFile can
        // stage through a volume-level replacement area outside the sandbox.
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(filePermissions))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try setAndVerifyPermissions(filePermissions, type: .typeRegular, at: file)
            return handle
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: file)
            throw error
        }
    }

    package static func prepareFile(at file: URL) throws {
        let handle = try createFile(at: file)
        do {
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    package static func write(_ data: Data, to file: URL) throws {
        let handle = try createFile(at: file)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Publish bytes by a same-directory rename, with final permissions set
    /// before publication. No replacement directory on another path is used.
    package static func writeAtomically(_ data: Data, to destination: URL, permissions: Int = filePermissions) throws {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".container-compose-\(UUID().uuidString).tmp")
        let handle = try createFile(at: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try handle.write(contentsOf: data)
            guard fchmod(handle.fileDescriptor, mode_t(permissions)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    package static func secureFile(at file: URL) throws {
        try setAndVerifyPermissions(filePermissions, type: .typeRegular, at: file)
    }

    package static func secureDirectory(at directory: URL) throws {
        try setAndVerifyPermissions(directoryPermissions, type: .typeDirectory, at: directory)
    }

    private static func setAndVerifyPermissions(
        _ expected: Int,
        type expectedType: FileAttributeType,
        at url: URL,
    ) throws {
        let fileManager = FileManager.default
        let initialAttributes = try fileManager.attributesOfItem(atPath: url.path)
        guard initialAttributes[.type] as? FileAttributeType == expectedType else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try fileManager.setAttributes([.posixPermissions: expected], ofItemAtPath: url.path)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == expectedType,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == expected
        else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
