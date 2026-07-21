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

private struct RuntimeImageVolumeInitialization: Hashable {
    let imageSubpath: String
    let volumeName: String
}

private struct RuntimeImageVolumePlan {
    let implicitMounts: [ComposeMount]
    let anonymousVolumeNames: Set<String>
    let initializations: [RuntimeImageVolumeInitialization]
}

extension ComposeOrchestrator {
    /// Prepares image metadata before resources are created when the active
    /// pull policy permits it. Docker-specific mount and copy-up decisions are
    /// deferred until each concrete container target is rendered.
    func validateRuntimeImageVolumes(
        project: ComposeProject,
        services: [ComposeService],
        externalVolumeMounts _: ExternalVolumeMounts,
        pullPolicy: String?,
    ) async throws {
        guard !options.dryRun else {
            return
        }

        for service in services {
            guard let image = serviceImage(project: project, service: service) else {
                continue
            }
            _ = try await imageManager.prepareImageVolumeMetadata(
                image,
                pullIfMissing: imageVolumeMetadataMayPull(service: service, globalPullPolicy: pullPolicy),
            )
        }
    }

    /// Returns generated anonymous mounts and initializes every local volume
    /// that Docker would seed from the selected image on first use.
    func prepareRuntimeImageVolumes(
        project: ComposeProject,
        service: ComposeService,
        context: MountRenderContext,
        mounts: [ComposeMount],
    ) async throws -> [ComposeMount] {
        guard !options.dryRun,
              let image = serviceImage(project: project, service: service)
        else {
            return []
        }

        let targets = try await imageManager.imageDeclaredVolumeTargets(image, platform: service.platform).sorted()
        guard !targets.isEmpty else {
            return []
        }

        let plan = try imageVolumeInitializationPlan(targets: targets, mounts: mounts, context: context)
        for name in plan.anonymousVolumeNames.sorted() {
            try await resourceManager.createVolume(ComposeVolumeCreateRequest(
                name: name,
                labels: anonymousImageVolumeLabels(project: project, context: context),
            ))
        }
        for initialization in plan.initializations {
            try await imageVolumeInitializer.initializeImageVolume(ComposeImageVolumeInitializationRequest(
                image: image,
                platform: service.platform,
                imageSubpath: initialization.imageSubpath,
                volumeName: initialization.volumeName,
            ))
        }
        return plan.implicitMounts
    }

    /// Selects the anonymous mounts and copy-up operations required for image targets.
    private func imageVolumeInitializationPlan(
        targets: [String],
        mounts: [ComposeMount],
        context: MountRenderContext,
    ) throws -> RuntimeImageVolumePlan {
        var allMounts = mounts
        var implicitMounts: [ComposeMount] = []
        var initializationByVolume: [String: RuntimeImageVolumeInitialization] = [:]
        var anonymousVolumeNames = Set<String>()

        for target in targets {
            if let mount = allMounts.last(where: { imageVolumeTargetsMatch($0.target, target) }) {
                guard ["volume", "external-volume"].contains(mount.type), !mountDisablesImageVolumeCopyUp(mount) else {
                    continue
                }
                let volumeName = try imageVolumeRuntimeName(mount: mount, context: context)
                if mount.source?.isEmpty != false {
                    anonymousVolumeNames.insert(volumeName)
                }
                try recordImageVolumeInitialization(
                    imageSubpath: mount.target ?? target,
                    volumeName: volumeName,
                    mount: mount,
                    into: &initializationByVolume,
                )
                continue
            }

            let mount = ComposeMount(type: "volume", target: target)
            implicitMounts.append(mount)
            allMounts.append(mount)
            let volumeName = try imageVolumeRuntimeName(mount: mount, context: context)
            anonymousVolumeNames.insert(volumeName)
            try recordImageVolumeInitialization(
                imageSubpath: target,
                volumeName: volumeName,
                mount: mount,
                into: &initializationByVolume,
            )
        }
        return RuntimeImageVolumePlan(
            implicitMounts: implicitMounts,
            anonymousVolumeNames: anonymousVolumeNames,
            initializations: initializationByVolume.values.sorted { $0.volumeName < $1.volumeName },
        )
    }

    /// Returns whether the effective Compose pull policy allows metadata inspection to prepare a missing image.
    private func imageVolumeMetadataMayPull(service: ComposeService, globalPullPolicy: String?) -> Bool {
        guard globalPullPolicy != "never", globalPullPolicy != "build" else {
            return false
        }
        return service.pullPolicy != "never" && service.pullPolicy != "build"
    }

    /// Records one initialization per target volume. Docker's first mount wins
    /// when the same empty volume is attached at several destinations.
    private func recordImageVolumeInitialization(
        imageSubpath: String,
        volumeName: String,
        mount: ComposeMount,
        into storage: inout [String: RuntimeImageVolumeInitialization],
    ) throws {
        guard nonEmpty(mount.volumeSubpath) == nil else {
            throw ComposeError.unsupported(
                "volume subpath mount '\(mount.target ?? "")' requires image-to-volume subdirectory initialization",
            )
        }
        storage[volumeName] = storage[volumeName] ?? RuntimeImageVolumeInitialization(
            imageSubpath: imageSubpath,
            volumeName: volumeName,
        )
    }

    /// Returns the runtime volume name used by one explicit or generated mount.
    private func imageVolumeRuntimeName(
        mount: ComposeMount,
        context: MountRenderContext,
    ) throws -> String {
        guard let target = mount.target else {
            throw ComposeError.invalidProject("volume mount is missing target")
        }
        if mount.type == "external-volume" {
            guard let source = nonEmpty(mount.source) else {
                throw ComposeError.invalidProject("external volume mount is missing source")
            }
            return source
        }
        if let source = mount.source, !source.isEmpty {
            return volumeRuntimeName(project: context.project, composeName: source)
        }
        return anonymousVolumeRuntimeName(context: context, target: target)
    }

    /// Returns whether a volume mount has requested Docker's no-copy behavior.
    private func mountDisablesImageVolumeCopyUp(_ mount: ComposeMount) -> Bool {
        mount.volumeNoCopy == true || (mount.unsupportedFields ?? []).contains("volume.nocopy")
    }

    /// Labels generated image volumes so lifecycle cleanup never needs the
    /// source image to remain present after containers have stopped.
    private func anonymousImageVolumeLabels(
        project: ComposeProject,
        context: MountRenderContext,
    ) -> [String: String] {
        var labels = resourceLabels(project: project, labels: nil)
        labels[imageVolumeAnonymousLabel] = "true"
        labels[imageVolumeContainerLabel] = context.containerName
        labels[imageVolumeServiceLabel] = context.service.name
        return labels
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
}
