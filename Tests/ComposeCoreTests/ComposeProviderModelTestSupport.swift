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

import ComposeContainerRuntime
@testable import ComposeCore
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import ComposeTestStorage
import Foundation
import Testing

// Concrete provider API fixtures are deliberately enhanced-only.

struct CommitArchiveIndex: Decodable {
    var manifests: [Descriptor]
}

struct CommitArchiveManifest: Decodable {
    var config: Descriptor
}

struct CommitArchiveImageConfig: Decodable {
    var author: String?
    var config: CommitArchiveRuntimeConfig
}

struct CommitArchiveRuntimeConfig: Decodable {
    var user: String?
    var env: [String]?
    var entrypoint: [String]?
    var cmd: [String]?
    var workingDir: String?
    var labels: [String: String]?
    var exposedPorts: [String: [String: String]]?
    var stopSignal: String?
    var healthCheck: CommitArchiveHealthCheck?
    var volumes: [String: [String: String]]?
    var onBuild: [String]?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case env = "Env"
        case entrypoint = "Entrypoint"
        case cmd = "Cmd"
        case workingDir = "WorkingDir"
        case labels = "Labels"
        case exposedPorts = "ExposedPorts"
        case stopSignal = "StopSignal"
        case healthCheck = "Healthcheck"
        case volumes = "Volumes"
        case onBuild = "OnBuild"
    }
}

struct CommitArchiveHealthCheck: Decodable, Equatable {
    var test: [String]?
    var intervalInNanoseconds: Int64?
    var timeoutInNanoseconds: Int64?
    var startPeriodInNanoseconds: Int64?
    var startIntervalInNanoseconds: Int64?
    var retries: Int?

    enum CodingKeys: String, CodingKey {
        case test = "Test"
        case intervalInNanoseconds = "Interval"
        case timeoutInNanoseconds = "Timeout"
        case startPeriodInNanoseconds = "StartPeriod"
        case startIntervalInNanoseconds = "StartInterval"
        case retries = "Retries"
    }
}

func commitArchiveConfig(from archive: URL) throws -> CommitArchiveImageConfig {
    let indexData = try ArchiveReader(file: archive).extractFile(path: "index.json").1
    let index = try JSONDecoder().decode(CommitArchiveIndex.self, from: indexData)
    let manifestDigest = try #require(index.manifests.first?.digest)
    let manifestData = try ArchiveReader(file: archive).extractFile(path: blobPath(for: manifestDigest)).1
    let manifest = try JSONDecoder().decode(CommitArchiveManifest.self, from: manifestData)
    let configData = try ArchiveReader(file: archive).extractFile(path: blobPath(for: manifest.config.digest)).1
    return try JSONDecoder().decode(CommitArchiveImageConfig.self, from: configData)
}

func blobPath(for digest: String) throws -> String {
    guard digest.hasPrefix("sha256:") else {
        throw ComposeError.invalidProject("unexpected digest \(digest)")
    }
    return "blobs/sha256/\(digest.dropFirst("sha256:".count))"
}

func containerSnapshot(
    id: String,
    status: RuntimeStatus,
    labels: [String: String] = [:],
    imageReference: String,
    imageDigest: String,
    platform: String,
    publishedPorts: [PublishPort] = [],
    mounts: [Filesystem] = [],
    networks: [ContainerResource.Attachment] = [],
    startedDate: Date? = nil,
    exitCode: Int32? = nil,
    exitedDate: Date? = nil,
    health: HealthStatus? = nil
) throws -> ContainerSnapshot {
    var configuration = ContainerConfiguration(
        id: id,
        image: ImageDescription(
            reference: imageReference,
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: imageDigest,
                size: 0
            )
        ),
        process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
    )
    configuration.labels = labels
    configuration.platform = try ociPlatform(platform)
    configuration.publishedPorts = publishedPorts
    configuration.mounts = mounts
    return ContainerSnapshot(
        configuration: configuration,
        status: status,
        networks: networks,
        startedDate: startedDate,
        exitCode: exitCode,
        exitedDate: exitedDate,
        health: health
    )
}

func managedContainerJSON(_ snapshots: [ContainerSnapshot]) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshots.map(ManagedContainer.init))
    return try #require(String(bytes: data, encoding: .utf8))
}

func ociPlatform(_ value: String) throws -> Platform {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else {
        throw ComposeError.invalidProject("invalid platform fixture '\(value)'")
    }
    let variant = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
    return Platform(arch: parts[1], os: parts[0], variant: variant)
}

func containerStats(
    id: String,
    cpuUsageUsec: UInt64?,
    memoryUsageBytes: UInt64? = 1_048_576,
    memoryLimitBytes: UInt64? = 2_097_152,
    networkRxBytes: UInt64? = 1024,
    networkTxBytes: UInt64? = 2048,
    blockReadBytes: UInt64? = 4096,
    blockWriteBytes: UInt64? = 8192,
    numProcesses: UInt64? = 3
) -> ContainerStats {
    ContainerStats(
        id: id,
        memoryUsageBytes: memoryUsageBytes,
        memoryLimitBytes: memoryLimitBytes,
        cpuUsageUsec: cpuUsageUsec,
        networkRxBytes: networkRxBytes,
        networkTxBytes: networkTxBytes,
        blockReadBytes: blockReadBytes,
        blockWriteBytes: blockWriteBytes,
        numProcesses: numProcesses
    )
}
