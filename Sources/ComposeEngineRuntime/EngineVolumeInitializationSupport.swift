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
import Darwin
import Foundation

extension ComposeEngineRuntime {
    static func volumeInitializerPath(
        platform: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if let explicit = environment[volumeInitializerEnvironmentVariable], !explicit.isEmpty {
            return explicit
        }
        return try bundledVolumeInitializerPath(
            executable: URL(fileURLWithPath: CommandLine.arguments[0]),
            platform: platform
        )
    }

    static func bundledVolumeInitializerPath(
        executable: URL,
        platform: String?
    ) throws -> String {
        let executable = executable.resolvingSymlinksInPath().standardizedFileURL
        let architecture: String
        switch platform {
        case nil, "", "linux/arm64": architecture = "arm64"
        case "linux/amd64": architecture = "amd64"
        default:
            throw ComposeError.unsupported(
                "stock Apple image-volume copy-up does not support platform \(platform ?? "")"
            )
        }
        return executable.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("resources/volume-initializer")
            .appendingPathComponent("compose-volume-initializer-linux-\(architecture)")
            .path
    }
}

struct EngineVolumeInitializerImageBuild {
    let tag: String
    let platform: String?
    let helper: Data
    let helperName: String
    let helperPath: String

    static func make(
        sourceDigest: String,
        platform: String?,
        helper: Data,
        helperName: String,
        helperPath: String
    ) -> EngineVolumeInitializerImageBuild {
        EngineVolumeInitializerImageBuild(
            tag: EngineVolumeInitializerBuildContext.cacheTag(
                sourceDigest: sourceDigest,
                platform: platform,
                helper: helper,
                helperName: helperName,
                helperPath: helperPath
            ),
            platform: platform,
            helper: helper,
            helperName: helperName,
            helperPath: helperPath
        )
    }
}

enum EngineVolumeInitializerBuildContext {
    static let stagePrefix = ".compose-volume-init-stage-"

    private struct Entry {
        let name: String
        let mode: UInt64
        let contents: Data
    }

    static func make(
        sourceImage: String,
        helper: Data,
        helperName: String = "compose-volume-initializer-linux-arm64",
        helperPath: String
    ) async throws -> Data {
        let dockerfile = Data("""
        FROM \(sourceImage)
        COPY --chmod=0755 \(helperName) \(helperPath)
        USER 0:0
        ENTRYPOINT [\"\(helperPath)\"]
        """.utf8)
        return ustar([
            Entry(name: "Dockerfile", mode: 0o644, contents: dockerfile),
            Entry(name: helperName, mode: 0o755, contents: helper),
        ])
    }

    /// Apple's Engine build endpoint accepts a portable ustar context. Building
    /// the two-entry archive directly also avoids host PAX/xattr records and
    /// makes identical inputs byte-for-byte reproducible on every macOS host.
    private static func ustar(
        _ entries: [Entry]
    ) -> Data {
        var archive = Data()
        for entry in entries {
            var header = Data(repeating: 0, count: 512)
            write(entry.name, to: &header, offset: 0, length: 100)
            writeOctal(entry.mode, to: &header, offset: 100, length: 8)
            writeOctal(0, to: &header, offset: 108, length: 8)
            writeOctal(0, to: &header, offset: 116, length: 8)
            writeOctal(UInt64(entry.contents.count), to: &header, offset: 124, length: 12)
            writeOctal(0, to: &header, offset: 136, length: 12)
            header.replaceSubrange(148 ..< 156, with: repeatElement(UInt8(ascii: " "), count: 8))
            header[156] = UInt8(ascii: "0")
            write("ustar", to: &header, offset: 257, length: 6)
            write("00", to: &header, offset: 263, length: 2)
            write("root", to: &header, offset: 265, length: 32)
            write("root", to: &header, offset: 297, length: 32)
            let checksum = header.reduce(0) { $0 + UInt64($1) }
            let checksumText = String(format: "%06llo", checksum)
            write(checksumText, to: &header, offset: 148, length: 7)
            header[155] = UInt8(ascii: " ")

            archive.append(header)
            archive.append(entry.contents)
            let padding = (512 - (entry.contents.count % 512)) % 512
            archive.append(Data(repeating: 0, count: padding))
        }
        archive.append(Data(repeating: 0, count: 1024))
        return archive
    }

    private static func write(
        _ value: String,
        to data: inout Data,
        offset: Int,
        length: Int
    ) {
        let bytes = Array(value.utf8.prefix(length - 1))
        data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    }

    private static func writeOctal(
        _ value: UInt64,
        to data: inout Data,
        offset: Int,
        length: Int
    ) {
        let text = String(format: "%0*llo", length - 1, value)
        write(text, to: &data, offset: offset, length: length)
    }

    static func fnv1aHex(_ values: [Data]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for value in values {
            for byte in value {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return String(format: "%016llx", hash)
    }

    static func cacheTag(
        sourceDigest: String,
        platform: String?,
        helper: Data,
        helperName: String = "compose-volume-initializer-linux-arm64",
        helperPath: String
    ) -> String {
        let platformIdentity = platform ?? "<default>"
        let digest = fnv1aHex([
            Data(sourceDigest.utf8), Data([0]),
            Data(platformIdentity.utf8), Data([0]),
            Data(helperName.utf8), Data([0]),
            Data(helperPath.utf8), Data([0]),
            helper,
        ])
        return "devcontainer-volume-initializer:\(digest)"
    }
}

extension EngineRuntimeProvider {
    static func helperMountPath(imageSubpath: String) throws -> String {
        let source = URL(fileURLWithPath: imageSubpath).standardizedFileURL.path
        guard source != "/" else {
            throw ComposeError.unsupported(
                "stock Apple image-volume copy-up cannot safely use the image root as a volume target"
            )
        }
        let candidates = [
            "/.compose-image-volume-target",
            "/mnt/.compose-image-volume-target",
            "/var/tmp/.compose-image-volume-target",
        ]
        guard let candidate = candidates.first(where: { !pathsOverlap($0, source) }) else {
            throw ComposeError.unsupported(
                "stock Apple image-volume copy-up could not allocate an isolated helper mount path"
            )
        }
        return candidate
    }

    static func helperExecutablePath(imageSubpath: String) throws -> String {
        let source = URL(fileURLWithPath: imageSubpath).standardizedFileURL.path
        let candidates = [
            "/.compose-volume-initializer",
            "/usr/local/libexec/compose-volume-initializer",
            "/var/tmp/.compose-volume-initializer",
        ]
        guard let candidate = candidates.first(where: { !pathsOverlap($0, source) }) else {
            throw ComposeError.unsupported(
                "stock Apple image-volume copy-up could not allocate an isolated helper executable path"
            )
        }
        return candidate
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
}

struct EngineVolumeInitializationTransaction: Equatable {
    private static let fileName = ".compose-image-volume.transaction"

    let identifier: String
    let path: String

    static func load(volumeMountpoint: URL) throws -> EngineVolumeInitializationTransaction? {
        let path = transactionPath(volumeMountpoint: volumeMountpoint)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return try validated(path: path)
    }

    static func create(volumeMountpoint: URL) throws -> EngineVolumeInitializationTransaction {
        let path = transactionPath(volumeMountpoint: volumeMountpoint)
        let identifier = UUID().uuidString.lowercased()
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ComposeError.invalidProject(
                "cannot create image-volume transaction at \(path): \(String(cString: strerror(errno)))"
            )
        }
        do {
            try write(Data((identifier + "\n").utf8), descriptor: descriptor, path: path)
            guard Darwin.fsync(descriptor) == 0 else {
                throw ComposeError.invalidProject(
                    "cannot sync image-volume transaction at \(path): \(String(cString: strerror(errno)))"
                )
            }
        } catch {
            Darwin.close(descriptor)
            _ = Darwin.unlink(path)
            throw error
        }
        Darwin.close(descriptor)
        do {
            try syncParentDirectory(of: path)
        } catch {
            _ = Darwin.unlink(path)
            throw error
        }
        return EngineVolumeInitializationTransaction(identifier: identifier, path: path)
    }

    func complete() throws {
        let current = try Self.validated(path: path)
        guard current.identifier == identifier else {
            throw ComposeError.invalidProject(
                "image-volume transaction identity changed at \(path)"
            )
        }
        guard Darwin.unlink(path) == 0 else {
            throw ComposeError.invalidProject(
                "cannot remove image-volume transaction at \(path): \(String(cString: strerror(errno)))"
            )
        }
        try Self.syncParentDirectory(of: path)
    }

    private static func transactionPath(volumeMountpoint: URL) -> String {
        volumeMountpoint.deletingLastPathComponent()
            .appendingPathComponent(fileName)
            .path
    }

    private static func syncParentDirectory(of path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let descriptor = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ComposeError.invalidProject(
                "cannot open image-volume transaction directory at \(parent): \(String(cString: strerror(errno)))"
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ComposeError.invalidProject(
                "cannot sync image-volume transaction directory at \(parent): \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func validated(path: String) throws -> EngineVolumeInitializationTransaction {
        var status = stat()
        guard Darwin.lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & (S_IRWXG | S_IRWXO) == 0,
              status.st_size > 0,
              status.st_size <= 128
        else {
            throw ComposeError.invalidProject(
                "image-volume transaction is not a private current-user file at \(path)"
            )
        }
        let identifier = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: identifier) != nil,
              identifier == identifier.lowercased()
        else {
            throw ComposeError.invalidProject(
                "image-volume transaction has an invalid identity at \(path)"
            )
        }
        return EngineVolumeInitializationTransaction(identifier: identifier, path: path)
    }

    private static func write(_ data: Data, descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else {
                    throw ComposeError.invalidProject(
                        "cannot write image-volume transaction at \(path): \(String(cString: strerror(errno)))"
                    )
                }
                offset += count
            }
        }
    }
}

final class EngineVolumeInitializationFileLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(volumeMountpoint: URL) async throws -> EngineVolumeInitializationFileLock {
        let path = volumeMountpoint.deletingLastPathComponent()
            .appendingPathComponent(".compose-image-volume.lock")
            .path
        return try await acquire(path: path)
    }

    static func acquire(path: String) async throws -> EngineVolumeInitializationFileLock {
        try await Task.detached {
            let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw ComposeError.invalidProject(
                    "cannot open image-volume initialization lock at \(path): \(String(cString: strerror(errno)))"
                )
            }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_mode & (S_IRWXG | S_IRWXO) == 0
            else {
                Darwin.close(descriptor)
                throw ComposeError.invalidProject(
                    "image-volume initialization lock is not a private current-user file at \(path)"
                )
            }
            while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
                guard errno == EINTR else {
                    let message = String(cString: strerror(errno))
                    Darwin.close(descriptor)
                    throw ComposeError.invalidProject(
                        "cannot lock image-volume initialization at \(path): \(message)"
                    )
                }
            }
            return EngineVolumeInitializationFileLock(descriptor: descriptor)
        }.value
    }

    deinit {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
    }
}

actor EngineVolumeInitializationCoordinator {
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ volumeName: String) async {
        guard !held.insert(volumeName).inserted else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[volumeName, default: []].append(continuation)
        }
    }

    func release(_ volumeName: String) {
        guard var queued = waiters[volumeName], !queued.isEmpty else {
            held.remove(volumeName)
            return
        }
        let continuation = queued.removeFirst()
        waiters[volumeName] = queued.isEmpty ? nil : queued
        continuation.resume()
    }
}
