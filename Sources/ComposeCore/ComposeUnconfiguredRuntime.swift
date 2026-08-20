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

// swiftlint:disable function_parameter_count
/// Fails clearly when library consumers have not supplied a runtime provider.
///
/// The executable installs concrete providers from `ComposeContainerRuntime`.
/// Keeping this fallback in ComposeCore prevents policy code from importing a
/// particular runtime implementation merely to construct default dependencies.
struct ComposeUnconfiguredRuntime: ComposeRuntimeCopying, ComposeRuntimeExporting, ComposeRuntimeExecManaging,
    ComposeRuntimeEventsManaging, ComposeRuntimeLifecycleManaging, ComposeRuntimeStatsManaging,
    ComposeRuntimeTopManaging, ComposeRuntimeLogManaging, ComposeRuntimeAttachManaging, ComposeRuntimeConfigReading,
    ComposeRuntimeSecretReading, ComposeRuntimeDiscoveryManaging, ComposeRuntimeImageManaging,
    ComposeRuntimeImageVolumeInitializing, ComposeArchiveManaging,
    ComposeRuntimeResourceManaging, ComposeRuntimeContainerLaunching
{
    private func unavailable(_ operation: String) -> ComposeError {
        .unsupported("\(operation) requires an installed Compose runtime provider")
    }

    func copyIntoContainer(id _: String, source _: String, destination _: String, options _: ContainerCopyTransferOptions) async throws {
        throw unavailable("copy into container")
    }

    func copyFromContainer(id _: String, source _: String, destination _: String, options _: ContainerCopyTransferOptions) async throws {
        throw unavailable("copy from container")
    }

    func copyBetweenContainers(
        sourceID _: String,
        source _: String,
        destinationID _: String,
        destination _: String,
        options _: ContainerCopyTransferOptions,
    ) async throws {
        throw unavailable("copy between containers")
    }

    func writeCommitImageArchive(_: ComposeCommitImageArchiveRequest) throws {
        throw unavailable("commit image archive")
    }

    func extractBridgeTemplates(archive _: URL, destination _: String) throws {
        throw unavailable("bridge template extraction")
    }

    func copyArchiveIntoContainer(
        using _: any ComposeRuntimeCopying,
        id _: String,
        archive _: FileHandle,
        destination _: String,
        options _: ContainerCopyTransferOptions,
        temporaryDirectory _: URL,
    ) async throws {
        throw unavailable("archive copy into container")
    }

    func copyFromContainerAsArchive(
        using _: any ComposeRuntimeCopying,
        id _: String,
        source _: String,
        archive _: FileHandle,
        copyContents _: Bool,
        options _: ContainerCopyTransferOptions,
        temporaryDirectory _: URL,
    ) async throws {
        throw unavailable("archive copy from container")
    }

    func exportContainer(id _: String, output _: String?, live _: Bool, noFreeze _: Bool) async throws {
        throw unavailable("container export")
    }

    func execAttached(request _: ContainerAttachedExecRequest) async throws -> Int32 {
        throw unavailable("container exec")
    }

    func execDetached(request _: ContainerDetachedExecRequest, emit _: @escaping @Sendable (String) -> Void) async throws {
        throw unavailable("container exec")
    }

    func events(
        projectName _: String,
        services _: [String],
        format _: ComposeEventsOutputFormat,
        since _: Date?,
        until _: Date?,
        emit _: @escaping @Sendable (String) -> Void,
    ) async throws {
        throw unavailable("container events")
    }

    func startContainer(id _: String) async throws {
        throw unavailable("container start")
    }

    func killContainer(id _: String, signal _: String) async throws {
        throw unavailable("container kill")
    }

    func stopContainer(id _: String, signal _: String?, timeoutInSeconds _: Int?) async throws {
        throw unavailable("container stop")
    }

    func restartContainer(id _: String, signal _: String?, timeoutInSeconds _: Int?) async throws {
        throw unavailable("container restart")
    }

    func pauseContainer(id _: String) async throws {
        throw unavailable("container pause")
    }

    func unpauseContainer(id _: String) async throws {
        throw unavailable("container unpause")
    }

    func waitContainer(id _: String) async throws -> Int32 {
        throw unavailable("container wait")
    }

    func deleteContainer(id _: String, force _: Bool) async throws {
        throw unavailable("container remove")
    }

    func launchContainer(_: ComposeRuntimeContainerLaunchRequest) async throws -> Int32 {
        throw unavailable("container create")
    }

    func stats(
        ids _: [String],
        format _: String,
        noStream _: Bool,
        noTrunc _: Bool,
        includeStopped _: Bool,
        emit _: @escaping @Sendable (String) -> Void,
    ) async throws {
        throw unavailable("container stats")
    }

    func top(targets _: [ComposeTopTarget], emit _: @escaping @Sendable (String) -> Void) async throws {
        throw unavailable("container top")
    }

    func logs(
        id _: String,
        tail _: Int?,
        follow _: Bool,
        since _: Date?,
        until _: Date?,
        timestamps _: Bool,
        emit _: @escaping @Sendable (Data) -> Void,
    ) async throws {
        throw unavailable("container logs")
    }

    func attachOutput(
        id _: String,
        stdout _: Bool,
        stderr _: Bool,
        mode _: ComposeOutputAttachmentMode,
        onReady _: @escaping @Sendable () -> Void,
        onStarted _: @escaping @Sendable () -> Void,
        emit _: @escaping @Sendable (ComposeLogRecord) -> Void,
    ) async throws {
        throw unavailable("container attach")
    }

    func readConfig(name _: String) async throws -> Data {
        throw unavailable("external config read")
    }

    func readSecret(name _: String) async throws -> Data {
        throw unavailable("external secret read")
    }

    func listContainers(all _: Bool) async throws -> [ComposeContainerSummary] {
        throw unavailable("container discovery")
    }

    func getContainer(id _: String) async throws -> ComposeContainerSummary? {
        throw unavailable("container discovery")
    }

    func imageExists(_: String) async throws -> Bool {
        throw unavailable("image lookup")
    }

    func imageDigest(_: String) async throws -> String {
        throw unavailable("image digest lookup")
    }

    func imageHealthCheck(_: String, platform _: String?) async throws -> ComposeImageHealthCheck? {
        throw unavailable("image healthcheck lookup")
    }

    func imageMetadata(_: String) async throws -> ComposeImageMetadata {
        throw unavailable("image metadata lookup")
    }

    func prepareImageVolumeMetadata(_: String, pullIfMissing _: Bool) async throws -> Bool {
        throw unavailable("image metadata lookup")
    }

    func imageDeclaredVolumeTargets(_: String, platform _: String?) async throws -> [String] {
        throw unavailable("image metadata lookup")
    }

    func initializeImageVolume(_: ComposeImageVolumeInitializationRequest) async throws {
        throw unavailable("image volume initialization")
    }

    func bridgeTransformers() async throws -> [ComposeBridgeTransformer] {
        throw unavailable("bridge transformer lookup")
    }

    func pullImage(_: String) async throws {
        throw unavailable("image pull")
    }

    func pullMissingImage(_: String) async throws {
        throw unavailable("image pull")
    }

    func pushImage(_: String, emit _: @escaping @Sendable (String) -> Void) async throws {
        throw unavailable("image push")
    }

    func deleteImage(_: String, force _: Bool, emit _: @escaping @Sendable (String) -> Void) async throws {
        throw unavailable("image remove")
    }

    func loadImageArchive(_: String, emit _: @escaping @Sendable (String) -> Void) async throws {
        throw unavailable("image load")
    }

    func createNetwork(_: ComposeNetworkCreateRequest) async throws {
        throw unavailable("network create")
    }

    func deleteNetwork(id _: String) async throws {
        throw unavailable("network remove")
    }

    func createVolume(_: ComposeVolumeCreateRequest) async throws {
        throw unavailable("volume create")
    }

    func listVolumes() async throws -> [ComposeVolumeSummary] {
        throw unavailable("volume list")
    }

    func deleteVolume(name _: String) async throws {
        throw unavailable("volume remove")
    }
}

// swiftlint:enable function_parameter_count

/// Default runtime collaborators for library-only ComposeCore use.
///
/// Each collaborator reports an explicit unsupported-runtime error when used.
/// Executables should supply real providers from a runtime composition package.
public enum ComposeRuntimeProviderDefaults {
    public static func archives() -> any ComposeArchiveManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func copying() -> any ComposeRuntimeCopying {
        ComposeUnconfiguredRuntime()
    }

    public static func exporting() -> any ComposeRuntimeExporting {
        ComposeUnconfiguredRuntime()
    }

    public static func executing() -> any ComposeRuntimeExecManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func launching() -> any ComposeRuntimeContainerLaunching {
        ComposeUnconfiguredRuntime()
    }

    public static func events() -> any ComposeRuntimeEventsManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func lifecycle() -> any ComposeRuntimeLifecycleManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func stats() -> any ComposeRuntimeStatsManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func top() -> any ComposeRuntimeTopManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func logs() -> any ComposeRuntimeLogManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func attach() -> any ComposeRuntimeAttachManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func configReader() -> any ComposeRuntimeConfigReading {
        ComposeUnconfiguredRuntime()
    }

    public static func secretReader() -> any ComposeRuntimeSecretReading {
        ComposeUnconfiguredRuntime()
    }

    public static func discovery() -> any ComposeRuntimeDiscoveryManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func images() -> any ComposeRuntimeImageManaging {
        ComposeUnconfiguredRuntime()
    }

    public static func imageVolumeInitializer() -> any ComposeRuntimeImageVolumeInitializing {
        ComposeUnconfiguredRuntime()
    }

    public static func resources() -> any ComposeRuntimeResourceManaging {
        ComposeUnconfiguredRuntime()
    }
}
