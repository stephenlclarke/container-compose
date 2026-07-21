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

extension ComposeOrchestrator {
    /// Rejects image-declared volumes whose Docker copy-up behavior cannot be represented by apple/container.
    func validateRuntimeImageVolumes(
        project: ComposeProject,
        services: [ComposeService],
        externalVolumeMounts: ExternalVolumeMounts,
        pullPolicy: String?,
    ) async throws {
        guard !options.dryRun else {
            return
        }

        let cache = ComposeImageVolumeTargetsCache()
        for service in services {
            guard let image = serviceImage(project: project, service: service) else {
                continue
            }
            let targets = try await cache.targets(
                reference: image,
                platform: service.platform,
                pullIfMissing: imageVolumeMetadataMayPull(service: service, globalPullPolicy: pullPolicy),
                imageManager: imageManager,
            )
            guard !targets.isEmpty else {
                continue
            }
            let mounts = try effectiveServiceVolumes(
                project: project,
                service: service,
                externalVolumeMounts: externalVolumeMounts,
            )
            for target in targets where !imageVolumeTargetIsSafelyMasked(target, by: mounts) {
                throw unsupportedImageVolumeCopyUp(service: service, image: image, target: target)
            }
        }
    }

    /// Returns whether the effective Compose pull policy allows metadata inspection to prepare a missing image.
    private func imageVolumeMetadataMayPull(service: ComposeService, globalPullPolicy: String?) -> Bool {
        guard globalPullPolicy != "never", globalPullPolicy != "build" else {
            return false
        }
        return service.pullPolicy != "never" && service.pullPolicy != "build"
    }

    /// Returns whether a service mount masks an image `VOLUME` without needing Docker copy-up.
    private func imageVolumeTargetIsSafelyMasked(_ target: String, by mounts: [ComposeMount]) -> Bool {
        guard let mount = mounts.last(where: { imageVolumeTargetsMatch($0.target, target) }) else {
            return false
        }
        return switch mount.type {
        case "bind", "image", "tmpfs":
            true
        case "volume":
            (mount.unsupportedFields ?? []).contains("volume.nocopy")
        default:
            false
        }
    }

    /// Returns whether a mount destination covers an image volume target after lexical normalization.
    private func imageVolumeTargetsMatch(_ mountTarget: String?, _ imageTarget: String) -> Bool {
        guard let mountTarget else {
            return false
        }
        let mountPath = URL(fileURLWithPath: mountTarget).standardizedFileURL.path
        let imagePath = URL(fileURLWithPath: imageTarget).standardizedFileURL.path
        return mountPath == imagePath || mountPath == "/" || imagePath.hasPrefix(mountPath + "/")
    }

    /// Creates the explicit error used when a Docker image requires an unavailable copy-up primitive.
    private func unsupportedImageVolumeCopyUp(
        service: ComposeService,
        image: String,
        target: String,
    ) -> ComposeError {
        ComposeError.unsupported(
            "service '\(service.name)' image '\(image)' declares VOLUME '\(target)'; "
                + "Docker copy-up requires an apple/container image-to-volume initialization primitive. "
                + "Use a bind, tmpfs, or image mount to mask the target, "
                + "or set volume.nocopy: true to opt out of copy-up",
        )
    }
}

/// Caches platform-specific image volume metadata during one Compose lifecycle preflight.
private actor ComposeImageVolumeTargetsCache {
    private var storage: [String: [String]] = [:]

    /// Returns Docker image `VOLUME` targets for one image and selected platform.
    func targets(
        reference: String,
        platform: String?,
        pullIfMissing: Bool,
        imageManager: ContainerImageManaging,
    ) async throws -> [String] {
        let key = "\(reference)|\(platform ?? "")|\(pullIfMissing)"
        if let cached = storage[key] {
            return cached
        }
        guard try await imageManager.prepareImageVolumeMetadata(reference, pullIfMissing: pullIfMissing) else {
            storage[key] = []
            return []
        }
        let targets = try await imageManager.imageDeclaredVolumeTargets(reference, platform: platform)
            .sorted()
        storage[key] = targets
        return targets
    }
}
