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

actor ComposeUpExitCode {
    private var storage: Int32?

    var value: Int32? {
        storage
    }

    func set(_ value: Int32) {
        storage = value
    }
}

struct ComposeUpLogSession {
    let project: ComposeProject
    let targets: [ServiceContainerTarget]
    let startedTargets: [ServiceContainerTarget]
    let stopServices: [String]
    let options: ComposeUpOptions
}

private struct ComposeUpSignalContext {
    let project: ComposeProject
    let services: [String]
    let timeout: Int?
}

private struct ComposeUpLogFollowContext {
    let targets: [ServiceContainerTarget]
    let options: RuntimeLogOptions
    let timestamps: Bool
    let noLogPrefix: Bool
    let colorPrefixes: Bool
}

struct UncheckedSendable<Value>: @unchecked Sendable {
    var value: Value
}

extension ComposeOrchestrator {
    /// Follows aggregate service logs for foreground `up` and stops services on interruption.
    func followAttachedUpLogs(session: ComposeUpLogSession) async throws {
        guard !session.targets.isEmpty else { return }
        if options.dryRun {
            emitUpLogDryRun(session)
            return
        }
        let sendableSession = UncheckedSendable(value: session)
        try await withUpSignalProxy(session) { [self, sendableSession] in
            try await upLogFollowOperation(sendableSession.value)()
        }
    }

    /// Follows logs until an `up` exit-control option determines the result.
    func followAttachedUpLogsUntilExitControl(
        session: ComposeUpLogSession,
        exitControlOperation: @escaping @Sendable () async throws -> Int32,
    ) async throws -> Int32 {
        if options.dryRun {
            emitUpLogDryRun(session)
            return try await exitControlOperation()
        }

        let exitCode = ComposeUpExitCode()
        let sendableSession = UncheckedSendable(value: session)
        try await withUpSignalProxy(session) { [self, sendableSession, exitCode, exitControlOperation] in
            let code = try await runUpLogOperationUntilExitControl(
                session: sendableSession.value,
                exitControlOperation: exitControlOperation,
            )
            await exitCode.set(code)
        }
        guard let code = await exitCode.value else {
            throw ComposeError.invalidProject("up exit-control did not produce an exit status")
        }
        return code
    }

    /// Builds the shared foreground logging operation.
    func upLogFollowOperation(_ session: ComposeUpLogSession) -> @Sendable () async throws -> Void {
        let context = UncheckedSendable(value: ComposeUpLogFollowContext(
            targets: session.targets,
            options: upLogRuntimeOptions(session.options),
            timestamps: session.options.timestamps,
            noLogPrefix: session.options.noLogPrefix,
            colorPrefixes: session.options.colorPrefixes,
        ))
        return { [self, context] in
            let values = context.value
            if values.targets.count > 1 {
                try await followLogTargets(values.targets, options: values.options)
                return
            }
            guard let target = values.targets.first else { return }
            try await emitLogs(RuntimeLogRequest(
                id: target.name,
                follow: true,
                tail: nil,
                since: nil,
                until: nil,
                timestamps: values.timestamps,
                emit: logEmitter(
                    for: target,
                    noLogPrefix: values.noLogPrefix,
                    colorPrefixes: values.colorPrefixes,
                ),
            ))
        }
    }

    /// Proxies foreground signals through the Compose lifecycle stop path.
    func withUpSignalProxy(
        _ session: ComposeUpLogSession,
        operation: @escaping @Sendable () async throws -> Void,
    ) async throws {
        let context = UncheckedSendable(value: ComposeUpSignalContext(
            project: session.project,
            services: session.stopServices,
            timeout: session.options.timeout,
        ))
        try await signalProxy.withSignalProxy(
            signals: ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"],
            handler: { [self, context] _ in
                try? await stop(
                    project: context.value.project,
                    services: context.value.services,
                    timeout: context.value.timeout,
                )
            },
            operation: operation,
        )
    }

    /// Emits the foreground log-follow plan for dry runs.
    func emitUpLogDryRun(_ session: ComposeUpLogSession) {
        for target in session.targets {
            emitComposeRuntimeOperation(
                logRuntimeArguments(
                    .init(
                        id: target.name,
                        follow: true,
                        tail: nil,
                        since: nil,
                        until: nil,
                        timestamps: session.options.timestamps,
                    ),
                ),
            )
        }
    }

    /// Returns runtime log options for foreground `up` output.
    func upLogRuntimeOptions(_ options: ComposeUpOptions) -> RuntimeLogOptions {
        RuntimeLogOptions(
            tail: nil,
            since: nil,
            until: nil,
            timestamps: options.timestamps,
            noLogPrefix: options.noLogPrefix,
            colorPrefixes: options.colorPrefixes,
        )
    }

    /// Follows service logs until an exit-control operation decides the `up` result.
    func runUpLogOperationUntilExitControl(
        session: ComposeUpLogSession,
        exitControlOperation: @Sendable @escaping () async throws -> Int32,
    ) async throws -> Int32 {
        let session = UncheckedSendable(value: session)
        let logTask: Task<Void, Error>? = if session.value.targets.isEmpty, !session.value.startedTargets.isEmpty {
            Task { [self, session] in
                try await waitForUpServiceTargets(session.value.startedTargets)
            }
        } else if !session.value.targets.isEmpty {
            Task { [self, session] in
                try await upLogFollowOperation(session.value)()
            }
        } else {
            nil
        }

        let exitControlResult: Result<Int32, Error>
        do {
            exitControlResult = try await .success(exitControlOperation())
        } catch {
            exitControlResult = .failure(error)
        }
        logTask?.cancel()
        if let logTask {
            // `down` naturally terminates the foreground log stream. Exit-control
            // status is authoritative, so that teardown interruption cannot replace
            // a selected service's terminal status with an orchestration failure.
            _ = try? await logTask.value
        }
        return try exitControlResult.get()
    }

    /// Waits for started service containers when no log stream is attached.
    func waitForUpServiceTargets(_ targets: [ServiceContainerTarget]) async throws {
        guard !targets.isEmpty else { return }
        let lifecycleManager = lifecycleManager
        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in targets {
                let name = target.name
                group.addTask { _ = try await lifecycleManager.waitContainer(id: name) }
            }
            try await group.waitForAll()
        }
    }
}
