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

@testable import ComposeContainerRuntime
import ComposeRuntimeSPI
import ContainerizationEXT4
import ContainerResource
import Foundation
import SystemPackage
import Testing

struct ContainerImageVolumeInitializerTests {
    @Test
    func `volume summaries retain the runtime driver options`() {
        let summary = ContainerResourceAPIClient.composeVolumeSummary(from: VolumeConfiguration(
            name: "data",
            driver: "local",
            source: "/Volumes/data/volume.img",
            labels: ["com.example.role": "cache"],
            options: ["journal": "ordered:4m"],
            sizeInBytes: 8.mib(),
        ))

        #expect(summary == ComposeVolumeSummary(
            name: "data",
            driver: "local",
            source: "/Volumes/data/volume.img",
            labels: ["com.example.role": "cache"],
            options: ["journal": "ordered:4m"],
            sizeInBytes: 8.mib(),
        ))
    }

    @Test
    func `an empty volume uses its backing size and the default journal`() async throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imagePath = FilePath(directory.appendingPathComponent("image.ext4").path)
        let volumePath = FilePath(directory.appendingPathComponent("volume.img").path)
        let seed = Data("default-journal-seed\n".utf8)
        try formatImage(at: imagePath, contents: seed)
        try formatEmptyVolume(at: volumePath)

        let seeded = try await ContainerImageVolumeInitializer().initializeIfEmpty(
            imageFilesystem: imagePath.description,
            imageSubpath: "/var/lib/data",
            volume: ComposeVolumeSummary(name: "data", source: volumePath.description),
        )

        #expect(seeded)
        let reader = try EXT4.EXT4Reader(blockDevice: volumePath)
        #expect(try reader.readFile(at: FilePath("/payload.txt")) == seed)
    }

    @Test
    func `a volume without a backing path is rejected`() async {
        await #expect(throws: Error.self) {
            try await ContainerImageVolumeInitializer().initializeIfEmpty(
                imageFilesystem: "/missing",
                imageSubpath: "/data",
                volume: ComposeVolumeSummary(name: "data"),
            )
        }
    }

    @Test
    func `an empty volume is seeded from the selected image subtree and then reused`() async throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imagePath = FilePath(directory.appendingPathComponent("image.ext4").path)
        let volumePath = FilePath(directory.appendingPathComponent("volume.img").path)
        let seed = Data("seeded-image-data\n".utf8)
        try formatImage(at: imagePath, contents: seed)
        try formatEmptyVolume(
            at: volumePath,
            size: 8.mib(),
            journal: EXT4.JournalConfig(size: 4.mib(), defaultMode: .ordered),
        )

        let initializer = ContainerImageVolumeInitializer()
        let volume = ComposeVolumeSummary(
            name: "data",
            source: volumePath.description,
            options: ["journal": "ordered:4m"],
            sizeInBytes: 8.mib(),
        )
        #expect(try await initializer.initializeIfEmpty(
            imageFilesystem: imagePath.description,
            imageSubpath: "/var/lib/data",
            volume: volume,
        ))

        let seededReader = try EXT4.EXT4Reader(blockDevice: volumePath)
        #expect(try seededReader.readFile(at: FilePath("/payload.txt")) == seed)
        #expect(try seededReader.stat(FilePath("/payload.txt")).inode.mode & 0o777 == 0o640)
        #expect(try seededReader.stat(FilePath("/payload.txt")).inode.uid == 1000)
        #expect(try seededReader.stat(FilePath("/payload.txt")).inode.gid == 1001)

        #expect(try await !(initializer.initializeIfEmpty(
            imageFilesystem: imagePath.description,
            imageSubpath: "/var/lib/data",
            volume: volume,
        )))
        let reusedReader = try EXT4.EXT4Reader(blockDevice: volumePath)
        #expect(try reusedReader.readFile(at: FilePath("/payload.txt")) == seed)
    }

    @Test
    func `an empty volume preserves its selected image directory metadata`() async throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imagePath = FilePath(directory.appendingPathComponent("image.ext4").path)
        let volumePath = FilePath(directory.appendingPathComponent("volume.img").path)
        let imageVolumeOwner: UInt32 = 65534
        let imageVolumeGroup: UInt32 = 65534
        try formatImage(
            at: imagePath,
            contents: Data("writable-by-image-user\n".utf8),
            directoryMode: 0o755,
            directoryUID: imageVolumeOwner,
            directoryGID: imageVolumeGroup,
        )
        try formatEmptyVolume(at: volumePath)

        #expect(try await ContainerImageVolumeInitializer().initializeIfEmpty(
            imageFilesystem: imagePath.description,
            imageSubpath: "/var/lib/data",
            volume: ComposeVolumeSummary(name: "data", source: volumePath.description),
        ))

        let reader = try EXT4.EXT4Reader(blockDevice: volumePath)
        let root = try reader.stat(FilePath("/")).inode
        #expect(root.mode & 0o777 == 0o755)
        #expect(root.uid == UInt16(imageVolumeOwner))
        #expect(root.uidHigh == 0)
        #expect(root.gid == UInt16(imageVolumeGroup))
        #expect(root.gidHigh == 0)
    }

    @Test
    func `runtime image volume initializer resolves then reuses an existing volume`() async throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imagePath = FilePath(directory.appendingPathComponent("image.ext4").path)
        let volumePath = FilePath(directory.appendingPathComponent("volume.img").path)
        let seed = Data("resolved-image-seed\n".utf8)
        try formatImage(at: imagePath, contents: seed)
        try formatEmptyVolume(at: volumePath)

        let recorder = ImageVolumeResolutionRecorder()
        let initializer = ContainerClientImageVolumeInitializer(
            resolveImageFilesystem: { image, platform in
                await recorder.recordImage(image: image, platform: platform)
                return imagePath.description
            },
            resolveVolume: { name in
                await recorder.recordVolume(name)
                return ComposeVolumeSummary(name: name, source: volumePath.description)
            },
        )
        let request = ComposeImageVolumeInitializationRequest(
            image: "example/api:latest",
            platform: "linux/arm64",
            imageSubpath: "/var/lib/data",
            volumeName: "demo_data",
        )

        try await initializer.initializeImageVolume(request)
        try await initializer.initializeImageVolume(request)

        #expect(await recorder.imageRequests == [
            ImageVolumeImageRequest(image: "example/api:latest", platform: "linux/arm64"),
            ImageVolumeImageRequest(image: "example/api:latest", platform: "linux/arm64"),
        ])
        #expect(await recorder.volumeRequests == ["demo_data", "demo_data"])
        let reader = try EXT4.EXT4Reader(blockDevice: volumePath)
        #expect(try reader.readFile(at: FilePath("/payload.txt")) == seed)
    }

    @Test
    func `a missing image path leaves an empty target volume unchanged`() async throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imagePath = FilePath(directory.appendingPathComponent("image.ext4").path)
        let volumePath = FilePath(directory.appendingPathComponent("volume.img").path)
        try formatImage(at: imagePath, contents: Data("seed\n".utf8))
        try formatEmptyVolume(at: volumePath)

        let initializer = ContainerImageVolumeInitializer()
        let volume = ComposeVolumeSummary(
            name: "data",
            source: volumePath.description,
            sizeInBytes: 4.mib(),
        )
        let seeded = try await initializer.initializeIfEmpty(
            imageFilesystem: imagePath.description,
            imageSubpath: "/missing",
            volume: volume,
        )

        #expect(!seeded)
        let reader = try EXT4.EXT4Reader(blockDevice: volumePath)
        #expect(try reader.listDirectory(FilePath("/")) == ["lost+found"])
    }

    @Test
    func `an invalid journal setting leaves an empty target volume unchanged`() async throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imagePath = FilePath(directory.appendingPathComponent("image.ext4").path)
        let volumePath = FilePath(directory.appendingPathComponent("volume.img").path)
        try formatImage(at: imagePath, contents: Data("seed\n".utf8))
        try formatEmptyVolume(at: volumePath)

        let initializer = ContainerImageVolumeInitializer()
        let volume = ComposeVolumeSummary(
            name: "data",
            source: volumePath.description,
            options: ["journal": "invalid"],
            sizeInBytes: 4.mib(),
        )
        await #expect(throws: Error.self) {
            try await initializer.initializeIfEmpty(
                imageFilesystem: imagePath.description,
                imageSubpath: "/var/lib/data",
                volume: volume,
            )
        }

        let reader = try EXT4.EXT4Reader(blockDevice: volumePath)
        #expect(try reader.listDirectory(FilePath("/")) == ["lost+found"])
    }

    private func formatImage(
        at path: FilePath,
        contents: Data,
        directoryMode: UInt16 = 0o750,
        directoryUID: UInt32 = 1000,
        directoryGID: UInt32 = 1001,
    ) throws {
        let formatter = try EXT4.Formatter(path, minDiskSize: 4.mib())
        try formatter.create(
            path: FilePath("/var/lib/data"),
            mode: EXT4.Inode.Mode(.S_IFDIR, directoryMode),
            uid: directoryUID,
            gid: directoryGID,
        )
        let stream = InputStream(data: contents)
        stream.open()
        defer { stream.close() }
        try formatter.create(
            path: FilePath("/var/lib/data/payload.txt"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o640),
            buf: stream,
            uid: directoryUID,
            gid: directoryGID,
        )
        try formatter.close()
    }

    private func formatEmptyVolume(
        at path: FilePath,
        size: UInt64 = 4.mib(),
        journal: EXT4.JournalConfig? = nil,
    ) throws {
        let formatter = try EXT4.Formatter(path, minDiskSize: size, journal: journal)
        try formatter.close()
    }
}

private actor ImageVolumeResolutionRecorder {
    private var imageStorage: [ImageVolumeImageRequest] = []
    private var volumeStorage: [String] = []

    var imageRequests: [ImageVolumeImageRequest] {
        imageStorage
    }

    var volumeRequests: [String] {
        volumeStorage
    }

    func recordImage(image: String, platform: String?) {
        imageStorage.append(ImageVolumeImageRequest(image: image, platform: platform))
    }

    func recordVolume(_ name: String) {
        volumeStorage.append(name)
    }
}

private struct ImageVolumeImageRequest: Equatable {
    let image: String
    let platform: String?
}
