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
    /// Returns distinct explicit helper images in declaration scope.
    func explicitPreStartImages(services: [ComposeService]) -> [String] {
        Array(Set(services.flatMap { service in
            (service.preStart ?? []).compactMap { nonEmpty($0.image) }
        })).sorted()
    }

    /// Returns distinct runtime images governed by one service pull policy.
    func serviceRuntimeImages(_ service: ComposeService) -> [String] {
        Array(Set(
            service.image.map { [$0] } ?? []
                + explicitPreStartImages(services: [service]),
        )).sorted()
    }

    /// Starts every stopped replica and runs `pre_start` once when the whole
    /// service is stopped, matching Docker Compose's service-level lifecycle.
    func startServiceTargets(
        project: ComposeProject,
        service: ComposeService,
        targets: [ServiceContainerTarget],
    ) async throws {
        try validateLifecycleHookSupport(service: service)
        let orderedTargets = targets.sorted { $0.index < $1.index }
        let targetsToStart = hasPreStartHooks(service)
            ? orderedTargets.filter { !isStartedServiceTarget($0) }
            : orderedTargets
        guard !targetsToStart.isEmpty else {
            return
        }

        if hasPreStartHooks(service), targetsToStart.count == orderedTargets.count {
            try await runPreStartHooks(
                project: project,
                service: service,
                target: targetsToStart[0],
            )
        }
        for target in targetsToStart {
            try await startContainer(
                service: service,
                containerName: target.name,
            )
        }
    }

    /// Treats Apple `paused` as Docker's running state for start convergence.
    func isStartedServiceTarget(_ target: ServiceContainerTarget) -> Bool {
        guard let status = target.status?.lowercased() else {
            return false
        }
        return status == "running" || status == "paused"
    }

    /// Executes `pre_start` helpers sequentially against the lowest-numbered
    /// non-running replica. A non-zero helper status gates service startup.
    func runPreStartHooks(
        project: ComposeProject,
        service: ComposeService,
        target: ServiceContainerTarget,
    ) async throws {
        try validateLifecycleHookSupport(service: service)
        for (index, hook) in (service.preStart ?? []).enumerated() {
            try await runPreStartHook(
                project: project,
                service: service,
                target: target,
                index: index,
                hook: hook,
            )
        }
    }

    /// Runs one ephemeral helper with the service environment, target mounts,
    /// and service networks, then removes it after logs and status are drained.
    func runPreStartHook(
        project: ComposeProject,
        service: ComposeService,
        target: ServiceContainerTarget,
        index: Int,
        hook: ComposeServiceHook,
    ) async throws {
        guard let command = hook.command, !command.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' pre_start[\(index)] requires a command")
        }
        guard let image = nonEmpty(hook.image) ?? serviceImage(project: project, service: service) else {
            throw ComposeError.invalidProject("service '\(service.name)' pre_start[\(index)] has no image")
        }

        let helperName = preStartHelperContainerName(
            project: project,
            service: service,
            index: index,
            identifier: options.oneOffIdentifier(),
        )
        let helperService = preStartHookService(
            service: service,
            target: target,
            hook: hook,
            image: image,
            command: command,
        )
        let createArguments = try await preStartHelperCreateArguments(
            project: project,
            service: service,
            containerIndex: target.index,
            helperService: helperService,
            helperName: helperName,
        )
        try await runContainerWithProgress(
            createArguments,
            message: "Running \(service.name) pre_start[\(index)]",
        )

        if options.dryRun {
            try await renderPreStartHelperLifecycle(helperName)
            return
        }

        let status: Int32
        do {
            status = try await followOneOffRunOutputAndWait(containerName: helperName)
        } catch {
            try? await lifecycleManager.deleteContainer(id: helperName, force: true)
            throw error
        }
        try await lifecycleManager.deleteContainer(id: helperName, force: false)
        guard status == 0 else {
            throw ComposeError.commandFailed(
                command: shellQuoted(command),
                status: status,
                stderr: "pre_start hook failed for service '\(service.name)'",
            )
        }
    }

    /// Emits the helper lifecycle commands used by Compose dry-run output.
    private func renderPreStartHelperLifecycle(_ helperName: String) async throws {
        emitComposeRuntimeOperation(["attach", "--no-stdin", helperName])
        try await runContainer(["start", helperName])
        try await runContainer(["wait", helperName])
        try await runContainer(["delete", helperName])
    }

    /// Builds the ephemeral helper create invocation and resolves inherited mounts.
    private func preStartHelperCreateArguments(
        project: ComposeProject,
        service: ComposeService,
        containerIndex: Int,
        helperService sourceService: ComposeService,
        helperName: String,
    ) async throws -> [String] {
        var helperService = sourceService
        var helperProject = project
        let externalVolumeMounts: ExternalVolumeMounts
        if options.dryRun {
            helperService.volumes = try effectiveServiceVolumes(
                project: project,
                service: service,
            )
            helperService.volumesFrom = nil
            externalVolumeMounts = [:]
        } else {
            helperProject.services[helperService.name] = helperService
            externalVolumeMounts = try await resolveExternalVolumeMounts(
                project: helperProject,
                services: [helperService],
            )
        }
        helperProject.services[helperService.name] = helperService

        let imageHealthCheckCache = ComposeImageHealthCheckCache()
        return try await runArguments(
            project: helperProject,
            service: helperService,
            options: RunArgumentOptions {
                $0.command = "create"
                $0.oneOff = true
                $0.containerIndex = containerIndex
                $0.containerNameOverride = helperName
            },
            externalVolumeMounts: externalVolumeMounts,
            imageHealthCheckCache: imageHealthCheckCache,
        )
    }

    /// Produces a deterministic helper name within apple/container's 63-byte
    /// DNS-label-compatible container-name boundary.
    func preStartHelperContainerName(
        project: ComposeProject,
        service: ComposeService,
        index: Int,
        identifier: String,
    ) -> String {
        let separator = options.serviceContainerNameSeparator
        let candidate = [
            project.name,
            service.name,
            "pre-start",
            "\(index)",
            identifier,
        ].map(slug).joined(separator: separator)
        guard candidate.count > 63 else {
            return candidate
        }

        let suffix = [
            "pre-start",
            "\(index)",
            String(stableHash(candidate).prefix(12)),
        ].joined(separator: separator)
        let prefixBudget = max(1, 63 - separator.count - suffix.count)
        let identityPrefix = [project.name, service.name]
            .map(slug)
            .joined(separator: separator)
        return "\(identityPrefix.prefix(prefixBudget))\(separator)\(suffix)"
    }

    /// Projects only the Docker Compose fields inherited by a `pre_start`
    /// helper, keeping the runtime adapter isolated from the service model.
    func preStartHookService(
        service: ComposeService,
        target: ServiceContainerTarget,
        hook: ComposeServiceHook,
        image: String,
        command: [String],
    ) -> ComposeService {
        var environment = service.environment ?? [:]
        for (key, value) in hook.environment ?? [:] {
            environment[key] = value
        }

        var helper = ComposeService(name: service.name, image: image)
        helper.command = command
        helper.environment = environment
        helper.networks = service.networks
        helper.networkOptions = service.networkOptions
        helper.networkMode = service.networkMode
        helper.platform = service.platform
        helper.user = nonEmpty(hook.user)
        helper.workingDir = nonEmpty(hook.workingDir)
        helper.privileged = hook.privileged == true
        helper.volumesFrom = ["container:\(target.name)"]
        return helper
    }
}
