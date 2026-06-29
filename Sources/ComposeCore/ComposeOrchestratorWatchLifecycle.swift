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
    /// Formats one validated `develop.watch` trigger for dry-run output.
    func watchDryRunLine(service: ComposeService, trigger: ComposeDevelopWatch) -> String {
        let action = trigger.action.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = ["compose: watch", service.name, action, "path=\(trigger.path)"]
        if let target = nonEmpty(trigger.target) {
            fields.append("target=\(target)")
        }
        if let include = trigger.include, !include.isEmpty {
            fields.append("include=\(include.joined(separator: ","))")
        }
        if let ignore = trigger.ignore, !ignore.isEmpty {
            fields.append("ignore=\(ignore.joined(separator: ","))")
        }
        if trigger.initialSync == true {
            fields.append("initial-sync=true")
        }
        if let execCommand = trigger.exec?.command, !execCommand.isEmpty {
            fields.append("exec=\(shellQuoted(execCommand))")
        }
        return fields.joined(separator: " ")
    }

    /// Creates executable watch plans with an initial filesystem snapshot.
    func watchPlans(project: ComposeProject, services: [ComposeService]) throws -> [ComposeWatchPlan] {
        try services.flatMap { service in
            try (service.develop?.watch ?? []).map { trigger in
                try ComposeWatchPlan(
                    service: service,
                    trigger: trigger,
                    snapshot: watchSnapshot(project: project, trigger: trigger),
                )
            }
        }
    }

    /// Applies `initial_sync` for sync-oriented watch triggers before polling.
    func performInitialWatchSync(project: ComposeProject, plans: [ComposeWatchPlan], quiet: Bool) async throws {
        for plan in plans where plan.trigger.initialSync == true && plan.action.hasPrefix("sync") {
            guard !plan.snapshot.isEmpty else {
                continue
            }
            try await syncWatchEntries(
                project: project,
                service: plan.service,
                trigger: plan.trigger,
                entries: Array(plan.snapshot.values).sorted(by: { $0.relativePath < $1.relativePath }),
                quiet: quiet,
            )
        }
    }

    /// Polls watched paths until the task is cancelled.
    func runWatchLoop(project: ComposeProject, plans: inout [ComposeWatchPlan], options watch: ComposeWatchOptions) async throws {
        if !watch.quiet {
            options.emit("compose: watch started")
        }
        while !Task.isCancelled {
            try await options.sleep(options.watchPollInterval)
            for index in plans.indices {
                let latest = try watchSnapshot(project: project, trigger: plans[index].trigger)
                let changes = watchChanges(previous: plans[index].snapshot, latest: latest)
                plans[index].snapshot = latest
                guard !changes.isEmpty else {
                    continue
                }
                try await performWatchAction(
                    project: project,
                    service: plans[index].service,
                    trigger: plans[index].trigger,
                    changes: changes,
                    options: watch,
                )
            }
        }
    }

    /// Executes one Compose watch action against the matching service containers.
    func performWatchAction(
        project: ComposeProject,
        service: ComposeService,
        trigger: ComposeDevelopWatch,
        changes: [ComposeWatchChange],
        options watch: ComposeWatchOptions,
    ) async throws {
        switch trigger.action.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "sync":
            try await syncWatchChanges(project: project, service: service, trigger: trigger, changes: changes, quiet: watch.quiet)
        case "sync+restart":
            try await syncWatchChanges(project: project, service: service, trigger: trigger, changes: changes, quiet: watch.quiet)
            try await restartWatchService(project: project, service: service, quiet: watch.quiet)
        case "sync+exec":
            try await syncWatchChanges(project: project, service: service, trigger: trigger, changes: changes, quiet: watch.quiet)
            try await execWatchHook(project: project, service: service, trigger: trigger, quiet: watch.quiet)
        case "restart":
            try await restartWatchService(project: project, service: service, quiet: watch.quiet)
        case "rebuild":
            try await rebuildWatchService(project: project, service: service, options: watch)
        default:
            try validateWatchTrigger(trigger, service: service)
        }
    }

    /// Copies changed files and removes deleted files for a sync action.
    func syncWatchChanges(
        project: ComposeProject,
        service: ComposeService,
        trigger: ComposeDevelopWatch,
        changes: [ComposeWatchChange],
        quiet: Bool,
    ) async throws {
        let upserts = changes.compactMap(\.entry)
        if !upserts.isEmpty {
            try await syncWatchEntries(project: project, service: service, trigger: trigger, entries: upserts, quiet: quiet)
        }
        let deletes = changes.compactMap(\.deletedRelativePath)
        if !deletes.isEmpty {
            try await deleteWatchEntries(project: project, service: service, trigger: trigger, relativePaths: deletes, quiet: quiet)
        }
    }

    /// Copies local watch entries into every running service replica.
    func syncWatchEntries(
        project: ComposeProject,
        service: ComposeService,
        trigger: ComposeDevelopWatch,
        entries: [ComposeWatchEntry],
        quiet: Bool,
    ) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [service])
        for target in targets {
            for entry in entries {
                let destination = try watchTargetPath(trigger: trigger, relativePath: entry.relativePath)
                if !quiet {
                    options.emit("compose: watch sync \(service.name)[\(target.index)] \(entry.sourcePath) -> \(destination)")
                }
                try await copier.copyIntoContainer(id: target.name, source: entry.sourcePath, destination: destination, options: ContainerCopyTransferOptions())
            }
        }
    }

    /// Removes deleted watched paths from service replicas through direct exec.
    func deleteWatchEntries(
        project: ComposeProject,
        service: ComposeService,
        trigger: ComposeDevelopWatch,
        relativePaths: [String],
        quiet: Bool,
    ) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [service])
        for target in targets {
            for relativePath in relativePaths.sorted() {
                let destination = try watchTargetPath(trigger: trigger, relativePath: relativePath)
                if !quiet {
                    options.emit("compose: watch delete \(service.name)[\(target.index)] \(destination)")
                }
                try await runWatchExec(
                    service: service,
                    containerID: target.name,
                    command: ["sh", "-c", "rm -rf -- \(shellQuoted([destination]))"],
                    user: nil,
                    workingDirectory: nil,
                    environment: [],
                    privileged: false,
                )
            }
        }
    }

    /// Restarts every service replica affected by a watch trigger.
    func restartWatchService(project: ComposeProject, service: ComposeService, quiet: Bool) async throws {
        let targets = try await serviceContainerTargets(project: project, services: [service])
        for target in targets {
            if !quiet {
                options.emit("compose: watch restart \(service.name)[\(target.index)]")
            }
            try await restartContainer(service: service, containerName: target.name)
        }
    }

    /// Rebuilds and recreates a service after a rebuild watch trigger.
    func rebuildWatchService(project: ComposeProject, service: ComposeService, options watch: ComposeWatchOptions) async throws {
        if !watch.quiet {
            options.emit("compose: watch rebuild \(service.name)")
        }
        try await up(
            project: project,
            options: ComposeUpOptions {
                $0.services = [service.name]
                $0.build = true
                $0.detach = true
                $0.forceRecreate = true
                $0.quietBuild = watch.quiet
            },
        )
        if watch.prune {
            try await runContainer(["image", "prune"])
        }
    }

    /// Runs the command attached to a `sync+exec` trigger on each service replica.
    func execWatchHook(project: ComposeProject, service: ComposeService, trigger: ComposeDevelopWatch, quiet: Bool) async throws {
        let hook = try watchExecHook(trigger: trigger, service: service)
        let targets = try await serviceContainerTargets(project: project, services: [service])
        for target in targets {
            if !quiet {
                options.emit("compose: watch exec \(service.name)[\(target.index)] \(shellQuoted(hook.command))")
            }
            try await runWatchExec(
                service: service,
                containerID: target.name,
                command: hook.command,
                user: hook.user,
                workingDirectory: hook.workingDirectory,
                environment: hook.environment,
                privileged: hook.privileged,
            )
        }
    }

    /// Resolves and validates sync+exec hook metadata.
    func watchExecHook(trigger: ComposeDevelopWatch, service: ComposeService) throws -> ComposeWatchExecHook {
        guard let exec = trigger.exec else {
            throw ComposeError.invalidProject("service '\(service.name)' develop.watch action 'sync+exec' requires exec metadata")
        }
        guard let command = exec.command, !command.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' develop.watch action 'sync+exec' requires an exec command")
        }
        return ComposeWatchExecHook(
            command: command,
            user: nonEmpty(exec.user),
            workingDirectory: nonEmpty(exec.workingDir),
            environment: environmentArguments(exec.environment ?? [:]),
            privileged: exec.privileged == true,
        )
    }

    /// Runs a non-interactive direct exec request for watch actions.
    func runWatchExec(
        service: ComposeService,
        containerID: String,
        command: [String],
        user: String?,
        workingDirectory: String?,
        environment: [String],
        privileged: Bool,
    ) async throws {
        let status = try await execManager.execAttached(
            request: ContainerAttachedExecRequest(
                id: containerID,
                command: command,
                environment: environment,
                user: user,
                workingDirectory: workingDirectory,
                privileged: privileged,
                terminal: .init(interactive: false, tty: false),
            ),
        )
        if status != 0 {
            throw ComposeError.commandFailed(
                command: shellQuoted(command),
                status: status,
                stderr: "watch exec failed for service '\(service.name)'",
            )
        }
    }

    /// Runs all `post_start` hooks for a service container.
    func runPostStartHooks(service: ComposeService, containerID: String) async throws {
        try await runLifecycleHooks(service: service, containerID: containerID, hooks: service.postStart ?? [], composeName: "post_start")
    }

    /// Runs all `pre_stop` hooks for a service container.
    func runPreStopHooks(service: ComposeService, containerID: String) async throws {
        try await runLifecycleHooks(service: service, containerID: containerID, hooks: service.preStop ?? [], composeName: "pre_stop")
    }

    /// Executes Compose service lifecycle hooks with the direct exec API.
    func runLifecycleHooks(
        service: ComposeService,
        containerID: String,
        hooks: [ComposeServiceHook],
        composeName: String,
    ) async throws {
        for (index, hook) in hooks.enumerated() {
            guard let command = hook.command, !command.isEmpty else {
                throw ComposeError.invalidProject("service '\(service.name)' \(composeName)[\(index)] requires a command")
            }
            let environment = environmentArguments(hook.environment ?? [:])
            let args = lifecycleHookExecArguments(
                containerID: containerID,
                command: command,
                user: nonEmpty(hook.user),
                workingDirectory: nonEmpty(hook.workingDir),
                environment: environment,
                privileged: hook.privileged == true,
            )
            if options.dryRun {
                try await runContainer(args)
                continue
            }
            let status = try await execManager.execAttached(
                request: ContainerAttachedExecRequest(
                    id: containerID,
                    command: command,
                    environment: environment,
                    user: nonEmpty(hook.user),
                    workingDirectory: nonEmpty(hook.workingDir),
                    privileged: hook.privileged == true,
                    terminal: .init(interactive: false, tty: false),
                ),
            )
            if status != 0 {
                throw ComposeError.commandFailed(
                    command: shellQuoted([options.containerBinary] + args),
                    status: status,
                    stderr: "\(composeName) hook failed for service '\(service.name)'",
                )
            }
        }
    }

    /// Builds a dry-run `container exec` command for service lifecycle hooks.
    func lifecycleHookExecArguments(
        containerID: String,
        command: [String],
        user: String?,
        workingDirectory: String?,
        environment: [String],
        privileged: Bool,
    ) -> [String] {
        var args = ["exec"]
        for value in environment {
            args.append(contentsOf: ["--env", value])
        }
        if let user {
            args.append(contentsOf: ["--user", user])
        }
        if let workingDirectory {
            args.append(contentsOf: ["--workdir", workingDirectory])
        }
        if privileged {
            args.append("--privileged")
        }
        args.append(containerID)
        args.append(contentsOf: command)
        return args
    }
}
