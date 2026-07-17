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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
import Foundation

extension ComposeOrchestrator {
    /// Appends a Compose mount in the form accepted by `container run`.
    func appendMount(_ mount: ComposeMount, context: MountRenderContext, args: inout [String]) throws {
        if mount.type == "tmpfs" {
            guard let target = mount.target else {
                throw ComposeError.invalidProject("tmpfs mount is missing target")
            }
            if mountRequiresTypedTmpfsArgument(mount) {
                args.append(contentsOf: ["--mount", typedTmpfsMountArgument(mount, target: target)])
            } else {
                args.append(contentsOf: ["--tmpfs", target])
            }
            return
        }
        guard let target = mount.target else {
            throw ComposeError.invalidProject("volume mount is missing target")
        }
        let source = mount.source ?? ""
        let mappedSource: String = if mount.type == "volume", !source.isEmpty {
            volumeRuntimeName(project: context.project, composeName: source)
        } else if source.isEmpty {
            anonymousVolumeRuntimeName(context: context, target: target)
        } else {
            source
        }

        if mount.fileOwnerUID != nil || mount.fileOwnerGID != nil {
            guard mount.type == "bind" else {
                throw ComposeError.invalidProject("file ownership is only supported for bind mounts")
            }
            guard nonEmpty(mount.bindPropagation) == nil else {
                throw ComposeError.invalidProject("file ownership cannot be combined with bind propagation")
            }
            var fields = [
                "type=bind",
                "source=\(mappedSource)",
                "destination=\(target)",
            ]
            if mount.readOnly == true {
                fields.append("readonly")
            }
            if let uid = mount.fileOwnerUID {
                fields.append("uid=\(uid)")
            }
            if let gid = mount.fileOwnerGID {
                fields.append("gid=\(gid)")
            }
            args.append(contentsOf: ["--mount", fields.joined(separator: ",")])
            return
        }

        if let subpath = nonEmpty(mount.volumeSubpath) {
            guard mount.type == "volume" || mount.type == "external-volume" else {
                throw ComposeError.invalidProject("volume subpath is only supported for volume mounts")
            }
            var fields = [
                "type=volume",
                "source=\(mappedSource)",
                "destination=\(target)",
                "volume-subpath=\(subpath)",
            ]
            if mount.readOnly == true {
                fields.append("readonly")
            }
            args.append(contentsOf: ["--mount", fields.joined(separator: ",")])
            return
        }

        var value = "\(mappedSource):\(target)"
        let options = try volumeMountOptions(mount)
        if !options.isEmpty {
            value += ":\(options.joined(separator: ","))"
        }
        args.append(contentsOf: ["--volume", value])
    }

    /// Returns the apple/container short volume options for a Compose mount.
    func volumeMountOptions(_ mount: ComposeMount) throws -> [String] {
        var options: [String] = []
        if mount.readOnly == true {
            options.append("ro")
        }
        if let propagation = nonEmpty(mount.bindPropagation) {
            guard mount.type == "bind" else {
                throw ComposeError.invalidProject("bind propagation is only supported on bind mounts")
            }
            options.append(try supportedBindPropagationOption(propagation))
        }
        return options
    }

    /// Validates a Compose bind propagation value before runtime handoff.
    func supportedBindPropagationOption(_ propagation: String) throws -> String {
        switch propagation {
        case "private", "rprivate", "shared", "rshared", "slave", "rslave":
            return propagation
        default:
            throw ComposeError.invalidProject("bind propagation '\(propagation)' is not supported; use private, rprivate, shared, rshared, slave, or rslave")
        }
    }

    /// Rejects missing bind sources when Compose explicitly opted out of
    /// Docker-compatible host path creation.
    func validateBindMountSourcePolicy(project: ComposeProject, service: ComposeService) throws {
        let mounts = try effectiveServiceVolumes(project: project, service: service)
        for mount in mounts where mount.type == "bind" && mount.bindCreateHostPath == false {
            guard let source = nonEmpty(mount.source) else {
                continue
            }
            let sourceURL = bindMountSourceURL(project: project, source: source)
            if !FileManager.default.fileExists(atPath: sourceURL.path) {
                throw ComposeError.invalidProject("service '\(service.name)' bind mount source '\(sourceURL.path)' does not exist and bind.create_host_path is false")
            }
        }
    }

    /// Creates missing bind source directories for Compose bind mounts that use
    /// the Docker-compatible default `create_host_path: true` behavior.
    func prepareBindMountSources(project: ComposeProject, service: ComposeService, mounts: [ComposeMount]) throws {
        guard !options.dryRun else {
            return
        }
        for mount in mounts where mount.type == "bind" && mount.bindCreateHostPath == true {
            guard let source = nonEmpty(mount.source) else {
                continue
            }
            let sourceURL = bindMountSourceURL(project: project, source: source)
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                continue
            }
            do {
                try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            } catch {
                throw ComposeError.invalidProject("service '\(service.name)' bind mount source '\(sourceURL.path)' could not be created: \(error.localizedDescription)")
            }
        }
    }

    /// Creates deterministic anonymous volumes when Compose attached labels to
    /// the long-form anonymous mount. Named service volume labels are config
    /// metadata in Docker Compose and do not affect the named volume resource.
    func ensureLabeledAnonymousVolumes(
        project: ComposeProject,
        service: ComposeService,
        context: MountRenderContext,
        externalVolumeMounts: ExternalVolumeMounts = [:]
    ) async throws {
        let requests = try labeledAnonymousVolumeCreateRequests(
            project: project,
            service: service,
            context: context,
            externalVolumeMounts: externalVolumeMounts
        )
        for request in requests {
            if options.dryRun {
                var args = ["volume", "create"]
                for label in request.labels.sorted(by: { $0.key < $1.key }) {
                    args.append(contentsOf: ["--label", "\(label.key)=\(label.value)"])
                }
                args.append(request.name)
                try await runContainer(args, check: false)
            } else {
                try await resourceManager.createVolume(request)
            }
        }
    }

    /// Returns create requests for anonymous volumes that carry long-form
    /// service volume labels.
    func labeledAnonymousVolumeCreateRequests(
        project: ComposeProject,
        service: ComposeService,
        context: MountRenderContext,
        externalVolumeMounts: ExternalVolumeMounts = [:]
    ) throws -> [ComposeVolumeCreateRequest] {
        let mounts = try effectiveServiceVolumes(
            project: project,
            service: service,
            externalVolumeMounts: externalVolumeMounts,
            materializedConfigSecretRoot: options.materializedConfigSecretDirectory,
            materializeConfigSecrets: false,
        )
        var requestsByName: [String: ComposeVolumeCreateRequest] = [:]
        for mount in mounts where mount.type == "volume" {
            guard mount.source?.isEmpty != false,
                  let target = mount.target,
                  let labels = mount.volumeLabels,
                  !labels.isEmpty
            else {
                continue
            }
            let name = anonymousVolumeRuntimeName(context: context, target: target)
            requestsByName[name] = ComposeVolumeCreateRequest(
                name: name,
                labels: resourceLabels(project: project, labels: labels)
            )
        }
        return requestsByName.values.sorted { $0.name < $1.name }
    }

    /// Resolves a normalized bind source path. compose-go normally emits
    /// absolute sources, while hand-built tests can still use relative paths.
    func bindMountSourceURL(project: ComposeProject, source: String) -> URL {
        let expanded = (source as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(
            fileURLWithPath: expanded,
            relativeTo: URL(fileURLWithPath: project.workingDirectory, isDirectory: true),
        ).standardizedFileURL
    }

    /// Returns whether a tmpfs mount needs the typed `--mount` form.
    func mountRequiresTypedTmpfsArgument(_ mount: ComposeMount) -> Bool {
        mount.readOnly == true || nonEmpty(mount.tmpfsSize) != nil || nonEmpty(mount.tmpfsMode) != nil
    }

    /// Builds a typed apple/container `container --mount` value for long-form tmpfs options.
    func typedTmpfsMountArgument(_ mount: ComposeMount, target: String) -> String {
        var fields = [
            "type=tmpfs",
            "destination=\(target)",
        ]
        if mount.readOnly == true {
            fields.append("readonly")
        }
        if let size = nonEmpty(mount.tmpfsSize) {
            fields.append("size=\(size)")
        }
        if let mode = nonEmpty(mount.tmpfsMode) {
            fields.append("mode=\(mode)")
        }
        return fields.joined(separator: ",")
    }

    /// Returns stable runtime names for anonymous volumes attached to service
    /// container targets.
    func anonymousVolumeRuntimeNames(project: ComposeProject, targets: [ServiceContainerTarget]) throws -> [String] {
        let targetCounts = Dictionary(grouping: targets, by: { $0.service.name }).mapValues(\.count)
        let names = try targets.flatMap { serviceTarget in
            try effectiveServiceVolumes(project: project, service: serviceTarget.service).compactMap { mount -> String? in
                guard mount.type == "volume", mount.source?.isEmpty != false, let mountTarget = mount.target else {
                    return nil
                }
                let replicaCount = targetCounts[serviceTarget.service.name] ?? 1
                return anonymousVolumeRuntimeName(
                    project: project,
                    service: serviceTarget.service,
                    target: mountTarget,
                    containerIndex: serviceTarget.index,
                    replicaCount: replicaCount,
                )
            }
        }
        return Array(Set(names)).sorted()
    }

    /// Removes existing anonymous volume names for one service container target.
    func removeExistingAnonymousVolumes(project: ComposeProject, target: ServiceContainerTarget) async throws {
        let names = try anonymousVolumeRuntimeNames(project: project, targets: [target])
        guard !names.isEmpty else {
            return
        }
        if options.dryRun {
            for name in names {
                try await runContainer(["volume", "delete", name], check: false)
            }
            return
        }
        let existingVolumes = try await resourceManager.listVolumes()
        let existingNames = Set(existingVolumes.map(\.name))
        for name in names where existingNames.contains(name) {
            try await resourceManager.deleteVolume(name: name)
        }
    }

    /// Returns the project-scoped name used for an anonymous Compose service
    /// volume.
    func anonymousVolumeRuntimeName(context: MountRenderContext, target: String) -> String {
        anonymousVolumeRuntimeName(
            project: context.project,
            service: context.service,
            target: target,
            containerIndex: context.containerIndex,
            replicaCount: context.replicaCount,
        )
    }

    /// Returns the project-scoped name used for an anonymous Compose service
    /// volume.
    func anonymousVolumeRuntimeName(
        project: ComposeProject,
        service: ComposeService,
        target: String,
        containerIndex: Int?,
        replicaCount: Int?,
    ) -> String {
        guard let containerIndex, containerIndex >= 1, (replicaCount ?? 1) > 1 else {
            return anonymousVolumeRuntimeName(project: project, target: target)
        }
        return resourceName(project: project.name, name: "anon-\(slug(service.name))-\(containerIndex)-\(stableHash(target).prefix(12))")
    }

    /// Returns the project-scoped name used for an anonymous Compose volume.
    func anonymousVolumeRuntimeName(project: ComposeProject, target: String) -> String {
        resourceName(project: project.name, name: "anon-\(stableHash(target).prefix(12))")
    }

    /// Starts a service container and runs `post_start` hooks while preserving
    /// dry-run command rendering.
    func startContainer(service: ComposeService, containerName: String) async throws {
        try validateLifecycleHookSupport(service: service)
        let args = ["start", containerName]
        if options.dryRun {
            try await runContainer(args)
        } else {
            try await progressActivity("Starting \(service.name)", quiet: false) {
                try await lifecycleManager.startContainer(id: containerName)
            }
        }
        try await runPostStartHooks(service: service, containerID: containerName)
    }

    /// Stops a service container through the direct API while preserving
    /// dry-run command rendering.
    func stopContainer(service: ComposeService, containerName: String, timeout: Int? = nil) async throws {
        try validateLifecycleHookSupport(service: service)
        try await runPreStopHooks(service: service, containerID: containerName)
        let args = stopArguments(service: service, containerName: containerName, timeout: timeout)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await lifecycleManager.stopContainer(
                id: containerName,
                signal: service.stopSignal,
                timeoutInSeconds: timeout ?? service.stopGracePeriodSeconds,
            )
        }
    }

    /// Restarts a service container through the direct API.
    func restartContainer(service: ComposeService, containerName: String, timeout: Int? = nil) async throws {
        try await stopContainer(service: service, containerName: containerName, timeout: timeout)
        try await startContainer(service: service, containerName: containerName)
    }

    /// Stops a container that may not map to a declared service, such as an
    /// orphan container discovered from project labels.
    func stopContainer(id: String, timeout: Int? = nil) async throws {
        var args = ["stop"]
        if let timeout {
            args.append(contentsOf: ["--time", "\(timeout)"])
        }
        args.append(id)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await lifecycleManager.stopContainer(id: id, signal: nil, timeoutInSeconds: timeout)
        }
    }

    /// Deletes a container through the direct API while preserving dry-run
    /// command rendering.
    func deleteContainer(_ id: String, force: Bool = false) async throws {
        var args = ["delete"]
        if force {
            args.append("--force")
        }
        args.append(id)
        if options.dryRun {
            try await runContainer(args, check: false)
        } else {
            try await lifecycleManager.deleteContainer(id: id, force: force)
        }
    }

    /// Treats already-removed containers as absent during teardown.
    func ignoringMissingContainer(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let error where isContainerNotFound(error) {
            return
        }
    }

    /// Returns true when a container lifecycle error or one of its causes is a
    /// runtime not-found response.
    func isContainerNotFound(_ error: any Error) -> Bool {
        guard let containerError = error as? ContainerizationError else {
            return false
        }
        if containerError.code == .notFound {
            return true
        }
        guard let cause = containerError.cause else {
            return false
        }
        return isContainerNotFound(cause)
    }

    /// Returns the stop command arguments for a service container.
    func stopArguments(service: ComposeService, containerName: String, timeout: Int? = nil) -> [String] {
        var args = ["stop"]
        if let signal = service.stopSignal, !signal.isEmpty {
            args.append(contentsOf: ["--signal", signal])
        }
        if let seconds = timeout ?? service.stopGracePeriodSeconds {
            args.append(contentsOf: ["--time", "\(seconds)"])
        }
        args.append(containerName)
        return args
    }

    /// Returns true when a service asks to restart after a dependency that
    /// changed earlier in the current Compose operation.
    func shouldRestartAfterDependencyChange(service: ComposeService, changedServices: Set<String>) -> Bool {
        guard let dependsOn = service.dependsOn else {
            return false
        }
        return dependsOn.contains { dependency in
            dependency.value.restart && changedServices.contains(dependency.key)
        }
    }

    /// Returns an existing container's Compose metadata, if the container exists.
    func inspectContainer(_ name: String) async throws -> ExistingContainer? {
        if options.dryRun {
            try await runContainer(["inspect", name], check: false, emitOutput: false)
            return nil
        }
        guard let container = try await discoveryManager.getContainer(id: name) else {
            return nil
        }
        return ExistingContainer(configHash: container.configHash)
    }

    /// Removes project-scoped containers that are not in the declared set.
    func removeRemainingProjectContainers(
        project: ComposeProject,
        excluding declaredContainers: Set<String>,
        preservingServices serviceNames: Set<String> = [],
        timeout: Int? = nil,
        confirmBeforeRemoval: Bool = false,
    ) async throws {
        let args = ["list", "--format", "json", "--all"]
        if options.dryRun {
            try await runContainer(args)
            return
        }

        let remainingContainers = try await projectContainers(projectName: project.name, all: true)
            .filter { container in
                guard !declaredContainers.contains(container.id) else {
                    return false
                }
                let isPreservedService = container.serviceName.map { serviceNames.contains($0) } ?? false
                return container.isOneOff || !isPreservedService
            }
            .sorted { $0.id < $1.id }
        if confirmBeforeRemoval, !remainingContainers.isEmpty {
            let names = remainingContainers.map(\.id).joined(separator: ", ")
            guard try await options.confirm("Going to remove orphan containers \(names)\nAre you sure? [yN] ") else {
                return
            }
        }
        for container in remainingContainers {
            try await ignoringMissingContainer {
                try await stopRemainingProjectContainer(project: project, container: container, timeout: timeout)
            }
            try await ignoringMissingContainer {
                try await deleteContainer(container.id)
            }
        }
    }

    /// Stops a project-scoped cleanup target with service hooks when its
    /// Compose service still exists in the current model.
    func stopRemainingProjectContainer(
        project: ComposeProject,
        container: ComposeContainerSummary,
        timeout: Int? = nil,
    ) async throws {
        guard let serviceName = container.serviceName,
              let service = project.services[serviceName]
        else {
            try await stopContainer(id: container.id, timeout: timeout)
            return
        }
        try await stopContainer(service: service, containerName: container.id, timeout: timeout)
    }

    /// Lists containers scoped to a Compose project through the direct API.
    func projectContainers(projectName: String, all: Bool) async throws -> [ComposeContainerSummary] {
        let containers = try await discoveryManager.listContainers(all: all)
        return filterProjectContainers(projectName: projectName, containers: containers)
    }

    /// Lists project volume records through the direct resource API.
    func composeVolumeRecords(
        project: ComposeProject,
        services: [ComposeService],
        restrictToSelectedServices: Bool,
    ) async throws -> [ComposeVolumeRecord] {
        let attachedVolumeNames = try serviceAttachedVolumeRuntimeNames(project: project, services: services)
        let volumes = try await resourceManager.listVolumes()
        return volumes
            .filter { volume in
                if restrictToSelectedServices {
                    return attachedVolumeNames.contains(volume.name)
                }
                return volume.labels[projectLabel] == project.name || attachedVolumeNames.contains(volume.name)
            }
            .map { ComposeVolumeRecord(summary: $0) }
            .sorted { $0.name < $1.name }
    }

    /// Returns existing runtime volume names attached by the selected services.
    func serviceAttachedVolumeRuntimeNames(project: ComposeProject, services: [ComposeService]) throws -> Set<String> {
        var names = Set<String>()
        for service in services {
            for mount in try effectiveServiceVolumes(project: project, service: service) where mount.type == "volume" {
                if let source = mount.source, !source.isEmpty {
                    names.insert(volumeRuntimeName(project: project, composeName: source))
                } else if let target = mount.target {
                    names.insert(anonymousVolumeRuntimeName(project: project, target: target))
                    let replicaCount = try serviceReplicaCount(service, scaleOverrides: [:])
                    if replicaCount > 1 {
                        for index in 1 ... replicaCount {
                            names.insert(
                                anonymousVolumeRuntimeName(
                                    project: project,
                                    service: service,
                                    target: target,
                                    containerIndex: index,
                                    replicaCount: replicaCount,
                                ),
                            )
                        }
                    }
                }
            }
        }
        return names
    }

    /// Executes one `container` command or prints it in dry-run mode.
    @discardableResult
    func runContainer(
        _ arguments: [String],
        check: Bool = true,
        emitOutput: Bool = true,
        inheritedIO: Bool = false,
        replaceProcess: Bool = false,
    ) async throws -> CommandResult {
        if options.dryRun {
            options.emit("+ " + shellQuoted([options.containerBinary] + arguments))
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        let commandIO: CommandIO = if replaceProcess {
            .replacingProcess
        } else if inheritedIO {
            .inherited
        } else {
            .captured(input: nil)
        }
        let result = try await runner.run(
            options.environmentLauncher,
            [options.containerBinary] + arguments,
            workingDirectory: nil,
            environment: nil,
            io: commandIO,
        )
        if emitOutput, !inheritedIO {
            print(result.stdout, terminator: result.stdout.hasSuffix("\n") || result.stdout.isEmpty ? "" : "\n")
            fputs(result.stderr, stderr)
        }
        if check, !result.succeeded {
            throw ComposeError.commandFailed(
                command: shellQuoted([options.containerBinary] + arguments),
                status: result.status,
                stderr: result.stderr,
            )
        }
        return result
    }

    /// Runs a runtime command while emitting progress for captured operations.
    @discardableResult
    func runContainerWithProgress(
        _ arguments: [String],
        message: String,
        quiet: Bool = false,
        check: Bool = true,
        emitOutput: Bool = true,
        inheritedIO: Bool = false,
        replaceProcess: Bool = false,
    ) async throws -> CommandResult {
        guard !inheritedIO, !replaceProcess else {
            if !quiet {
                options.progress.handoff(message)
            }
            return try await runContainer(
                arguments,
                check: check,
                emitOutput: emitOutput,
                inheritedIO: inheritedIO,
                replaceProcess: replaceProcess,
            )
        }
        return try await progressActivity(message, quiet: quiet, emitsExternalOutput: emitOutput) {
            try await runContainer(
                arguments,
                check: check,
                emitOutput: emitOutput,
                inheritedIO: inheritedIO,
                replaceProcess: replaceProcess,
            )
        }
    }

    /// Prints a Compose-owned direct runtime operation in dry-run mode.
    func emitComposeRuntimeOperation(_ arguments: [String]) {
        options.emit("+ " + shellQuoted(["compose-runtime"] + arguments))
    }
}
