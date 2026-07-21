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
import ComposeRuntimeSPI
import ContainerizationEXT4
import ContainerizationExtras
import Foundation
import SystemPackage

/// Seeds an empty local ext4 volume from an unpacked image filesystem subtree.
///
/// This adapter deliberately contains no Compose lifecycle policy. Its caller
/// chooses whether a Docker image `VOLUME` declaration requires initialization,
/// then supplies the resolved image snapshot, source path, and target volume.
public struct ContainerImageVolumeInitializer: Sendable {
    private static let minimumVolumeSize: UInt64 = 1 * 1024 * 1024

    public init() {}

    /// Copies `imageSubpath` into `volume` only when the volume contains no
    /// entries other than ext4's required `lost+found` directory.
    ///
    /// - Returns: `true` when the volume was seeded; `false` when its existing
    ///   contents were preserved or the requested image path is absent.
    @discardableResult
    public func initializeIfEmpty(
        imageFilesystem: String,
        imageSubpath: String,
        volume: ComposeVolumeSummary,
    ) async throws -> Bool {
        guard !volume.source.isEmpty else {
            throw ComposeError.invalidProject("runtime volume '\(volume.name)' does not expose an ext4 backing path")
        }

        let volumePath = FilePath(volume.source)
        let volumeReader = try EXT4.EXT4Reader(blockDevice: volumePath)
        guard try volumeReader.listDirectory(FilePath("/")) == ["lost+found"] else {
            return false
        }

        let fileManager = FileManager.default
        let volumeURL = URL(fileURLWithPath: volume.source)
        let stagingDirectory = volumeURL.deletingLastPathComponent()
            .appendingPathComponent(".compose-image-volume-init-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let archivePath = FilePath(stagingDirectory.appendingPathComponent("contents.tar").path)
        let stagedVolumeURL = stagingDirectory.appendingPathComponent("volume.img")
        let stagedVolumePath = FilePath(stagedVolumeURL.path)
        let imageReader = try EXT4.EXT4Reader(blockDevice: FilePath(imageFilesystem))
        let imageVolumeRoot: EXT4.Inode
        do {
            let sourcePath = FilePath(imageSubpath)
            imageVolumeRoot = try imageReader.stat(sourcePath, followSymlinks: false).inode
            try imageReader.export(archive: archivePath, subtree: sourcePath)
        } catch let error as EXT4.PathIOError {
            guard case .notFound = error else {
                throw error
            }
            // Docker leaves a fresh volume empty when it is mounted at an
            // image path that does not exist. Do not create that path or
            // replace the target volume merely to model this no-copy case.
            return false
        }

        let formatter = try EXT4.Formatter(
            stagedVolumePath,
            minDiskSize: volumeSize(volume: volume, at: volumeURL),
            journal: journalConfig(volume.options["journal"]),
        )
        do {
            try await formatter.unpack(source: archivePath.url, compression: .none)
            // `export(subtree:)` deliberately writes the selected directory's
            // children at the archive root. Restore the selected directory's
            // ownership and mode on that root so a non-root image user can
            // write to its Docker image `VOLUME` after the first copy-up.
            try formatter.create(
                path: FilePath("/"),
                mode: imageVolumeRoot.mode,
                uid: Self.id(low: imageVolumeRoot.uid, high: imageVolumeRoot.uidHigh),
                gid: Self.id(low: imageVolumeRoot.gid, high: imageVolumeRoot.gidHigh),
            )
            try formatter.close()
        } catch {
            try? formatter.close()
            throw error
        }

        _ = try fileManager.replaceItemAt(volumeURL, withItemAt: stagedVolumeURL)
        return true
    }

    private func volumeSize(volume: ComposeVolumeSummary, at path: URL) throws -> UInt64 {
        if let size = volume.sizeInBytes, size >= Self.minimumVolumeSize {
            return size
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value, size >= Self.minimumVolumeSize else {
            throw ComposeError.invalidProject("runtime volume '\(volume.name)' has an invalid backing size")
        }
        return size
    }

    private static func id(low: UInt16, high: UInt16) -> UInt32 {
        UInt32(high) << 16 | UInt32(low)
    }

    private func journalConfig(_ value: String?) throws -> EXT4.JournalConfig? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let modeValue = parts.first else {
            throw ComposeError.invalidProject("runtime volume journal must use mode or mode:size")
        }
        let mode: EXT4.JournalConfig.JournalMode
        switch modeValue {
        case "writeback": mode = .writeback
        case "ordered": mode = .ordered
        case "journal": mode = .journal
        default:
            throw ComposeError.invalidProject("runtime volume journal mode '\(modeValue)' is invalid")
        }
        let size: UInt64? = try parts.count > 1
            ? UInt64(Measurement.parse(parsing: String(parts[1])).converted(to: .bytes).value)
            : nil
        return EXT4.JournalConfig(size: size, defaultMode: mode)
    }
}
