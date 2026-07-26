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

private enum ComposeRunLifecycleOperationResult {
    case logsFinished
    case exitCode(Int32)
}

enum ComposeRunAttachmentResult: Equatable {
    case exited(Int32)
    case detached
}

private actor ComposeRunLifecycleExitCode {
    private var storage: Int32?

    var value: Int32? {
        storage
    }

    func set(_ value: Int32) {
        storage = value
    }
}

private actor ComposeRunLifecycleSignalStopGate {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else {
            return false
        }
        claimed = true
        return true
    }
}

private struct ComposeRunLifecycleSignalContext: @unchecked Sendable {
    let service: ComposeService
    let containerName: String
}

extension ComposeOrchestrator {
    /// Reattaches an interactive lifecycle-managed one-off container while
    /// keeping Compose in-process so signal handling can run `pre_stop`.
    func attachForegroundOneOffRun(
        service: ComposeService,
        containerName: String,
    ) async throws -> ComposeRunAttachmentResult {
        let arguments = ["attach", "--sig-proxy=false", containerName]
        if options.dryRun {
            let status = try await runContainer(
                arguments,
                check: false,
                inheritedIO: true,
            ).status
            return .exited(status)
        }

        let signalContext = ComposeRunLifecycleSignalContext(
            service: service,
            containerName: containerName,
        )
        let exitCode = ComposeRunLifecycleExitCode()
        let stopGate = ComposeRunLifecycleSignalStopGate()
        try await signalProxy.withSignalProxy(
            signals: ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"],
            handler: { [self, signalContext, stopGate] _ in
                guard await stopGate.claim() else {
                    return
                }
                await stopLifecycleManagedRunOnSignal(
                    context: signalContext,
                )
            },
            operation: { [self, exitCode] in
                let result = try await runContainer(
                    arguments,
                    check: false,
                    inheritedIO: true,
                )
                await exitCode.set(result.status)
            },
        )
        guard let status = await exitCode.value else {
            throw ComposeError.invalidProject("interactive foreground compose run did not produce an exit status")
        }
        let container = try await discoveryManager.getContainer(id: containerName)
        if let container, ["running", "paused"].contains(container.status.lowercased()) {
            return .detached
        }
        return .exited(status)
    }

    /// Follows a non-interactive one-off run and returns its container exit status.
    func followForegroundOneOffRun(
        service: ComposeService,
        containerName: String,
    ) async throws -> Int32 {
        let signalContext = ComposeRunLifecycleSignalContext(service: service, containerName: containerName)
        let exitCode = ComposeRunLifecycleExitCode()
        let stopGate = ComposeRunLifecycleSignalStopGate()
        try await signalProxy.withSignalProxy(
            signals: ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"],
            handler: { [self, signalContext, stopGate] _ in
                guard await stopGate.claim() else {
                    return
                }
                await stopLifecycleManagedRunOnSignal(
                    context: signalContext,
                )
            },
            operation: { [self, exitCode] in
                let status = try await followOneOffRunLogsAndWait(containerName: containerName)
                await exitCode.set(status)
            },
        )
        guard let status = await exitCode.value else {
            throw ComposeError.invalidProject("foreground compose run did not produce an exit status")
        }
        return status
    }

    /// Runs `pre_stop` before signal-driven stop, then falls back to a direct
    /// runtime stop so a failed hook cannot strand an attached one-off.
    private func stopLifecycleManagedRunOnSignal(
        context: ComposeRunLifecycleSignalContext,
    ) async {
        do {
            try await stopContainer(
                service: context.service,
                containerName: context.containerName,
            )
        } catch {
            try? await lifecycleManager.stopContainer(
                id: context.containerName,
                signal: context.service.stopSignal,
                timeoutInSeconds: context.service.stopGracePeriodSeconds,
            )
        }
    }

    /// Streams raw one-off output while waiting for the direct runtime exit status.
    func followOneOffRunLogsAndWait(containerName: String) async throws -> Int32 {
        let logManager = logManager
        let lifecycleManager = lifecycleManager
        let emit = options.emitData
        return try await withThrowingTaskGroup(of: ComposeRunLifecycleOperationResult.self) { group in
            group.addTask {
                try await logManager.logs(
                    id: containerName,
                    tail: nil,
                    follow: true,
                    since: nil,
                    until: nil,
                    timestamps: false,
                    emit: emit,
                )
                return .logsFinished
            }
            group.addTask {
                try await .exitCode(lifecycleManager.waitContainer(id: containerName))
            }

            var exitCode: Int32?
            var logsFinished = false
            while let result = try await group.next() {
                switch result {
                case .logsFinished:
                    logsFinished = true
                case let .exitCode(status):
                    exitCode = status
                }
                if logsFinished, let exitCode {
                    return exitCode
                }
            }
            throw ComposeError.invalidProject("foreground compose run did not produce an exit status")
        }
    }
}
