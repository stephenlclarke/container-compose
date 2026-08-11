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

final class ComposeOutputAttachReadiness: @unchecked Sendable {
    private let stream: AsyncThrowingStream<Void, any Error>
    private let continuation: AsyncThrowingStream<Void, any Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func ready() {
        continuation.yield()
        continuation.finish()
    }

    func fail(_ error: any Error) {
        continuation.finish(throwing: error)
    }

    func wait() async throws {
        for try await _ in stream {
            return
        }
        throw ComposeError.invalidProject("runtime output attachment ended before it became ready")
    }
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
        let started = ComposeOutputAttachReadiness()
        let attachment = prepareOneOffRunOutputAttachment(
            containerName: containerName,
            started: started,
        )
        defer { attachment.cancel() }
        try await started.wait()
        try await runPostStartHooks(service: service, containerID: containerName)

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
            operation: { [self, attachment, exitCode, signalContext] in
                let status = try await waitForOneOffRunAndOutput(
                    containerName: signalContext.containerName,
                    attachment: attachment,
                )
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

    /// Starts through the prepared output session, then runs caller-owned work.
    func followOneOffRunOutputAndWait(
        containerName: String,
        afterStart: @escaping @Sendable () async throws -> Void,
    ) async throws -> Int32 {
        let started = ComposeOutputAttachReadiness()
        let attachment = prepareOneOffRunOutputAttachment(
            containerName: containerName,
            started: started,
        )
        defer { attachment.cancel() }
        do {
            try await started.wait()
            try await afterStart()
            return try await waitForOneOffRunAndOutput(
                containerName: containerName,
                attachment: attachment,
            )
        } catch {
            attachment.cancel()
            throw error
        }
    }

    /// Starts a prepared one-off with attached output and waits for exit.
    func followOneOffRunOutputAndWait(containerName: String) async throws -> Int32 {
        try await followOneOffRunOutputAndWait(containerName: containerName) {}
    }

    /// Starts an output-only attachment and reports when its descriptors are
    /// registered, without coupling attachment lifetime to log persistence.
    private func prepareOneOffRunOutputAttachment(
        containerName: String,
        started: ComposeOutputAttachReadiness,
    ) -> Task<Void, any Error> {
        let attachManager = attachManager
        let emit = options.emitAttachedData
        return Task {
            do {
                try await attachManager.attachOutput(
                    id: containerName,
                    stdout: true,
                    stderr: true,
                    mode: .beforeStart,
                    onReady: {},
                    onStarted: { started.ready() },
                    emit: { emit($0.payload) },
                )
            } catch {
                started.fail(error)
                throw error
            }
        }
    }

    /// Waits until both the container exits and every attached output byte is
    /// drained, preserving fast-exit output that arrives around process exit.
    private func waitForOneOffRunAndOutput(
        containerName: String,
        attachment: Task<Void, any Error>,
    ) async throws -> Int32 {
        async let exitCode = lifecycleManager.waitContainer(id: containerName)
        async let output: Void = attachment.value
        let status = try await exitCode
        try await output
        return status
    }
}
