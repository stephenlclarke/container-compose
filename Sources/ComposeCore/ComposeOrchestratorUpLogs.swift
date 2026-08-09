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
    let outputAttachments: [ComposeUpOutputAttachment]
    let startedTargets: [ServiceContainerTarget]
    let stopServices: [String]
    let options: ComposeUpOptions
}

/// One live service-output attachment retained across `up` reconciliation.
struct ComposeUpOutputAttachment: Sendable {
    let containerName: String
    let task: Task<Void, any Error>?

    func cancel() {
        task?.cancel()
    }

    func wait() async throws {
        try await task?.value
    }
}

private struct ComposeUpSignalContext {
    let project: ComposeProject
    let services: [String]
    let timeout: Int?
}

struct UncheckedSendable<Value>: @unchecked Sendable {
    var value: Value
}

extension ComposeOrchestrator {
    /// Follows aggregate service logs for foreground `up` and stops services on interruption.
    func followAttachedUpLogs(session: ComposeUpLogSession) async throws {
        guard !session.outputAttachments.isEmpty else { return }
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
        let attachments = session.outputAttachments
        return {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for attachment in attachments {
                    group.addTask {
                        try await attachment.wait()
                    }
                }
                try await group.waitForAll()
            }
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
            emitComposeRuntimeOperation(["attach", "--no-stdin", target.name])
        }
    }

    /// Follows service logs until an exit-control operation decides the `up` result.
    func runUpLogOperationUntilExitControl(
        session: ComposeUpLogSession,
        exitControlOperation: @Sendable @escaping () async throws -> Int32,
    ) async throws -> Int32 {
        let session = UncheckedSendable(value: session)
        let logTask: Task<Void, Error>? = if session.value.outputAttachments.isEmpty,
                                             !session.value.startedTargets.isEmpty
        {
            Task { [self, session] in
                try await waitForUpServiceTargets(session.value.startedTargets)
            }
        } else if !session.value.outputAttachments.isEmpty {
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

    /// Adds live attachment tasks for targets that were already running when
    /// reconciliation began; newly created targets already carry prepared tasks.
    func completeUpOutputAttachments(
        targets: [ServiceContainerTarget],
        prepared: [ComposeUpOutputAttachment],
        options upOptions: ComposeUpOptions,
    ) async throws -> [ComposeUpOutputAttachment] {
        var attachmentsByName = Dictionary(uniqueKeysWithValues: prepared.map { ($0.containerName, $0) })
        do {
            for target in targets where attachmentsByName[target.name] == nil {
                attachmentsByName[target.name] = try await prepareUpOutputAttachment(
                    target: target,
                    mode: .runningProcess,
                    options: upOptions,
                )
            }
        } catch {
            for attachment in attachmentsByName.values {
                attachment.cancel()
            }
            throw error
        }
        return targets.compactMap { attachmentsByName[$0.name] }
    }

    /// Starts one output attachment and waits until its descriptors are ready.
    func prepareUpOutputAttachment(
        target: ServiceContainerTarget,
        mode: ComposeOutputAttachmentMode,
        options upOptions: ComposeUpOptions,
    ) async throws -> ComposeUpOutputAttachment {
        guard !options.dryRun else {
            return ComposeUpOutputAttachment(containerName: target.name, task: nil)
        }

        let started = ComposeOutputAttachReadiness()
        let attachManager = attachManager
        let containerName = target.name
        let renderer = ComposeUpAttachedOutputRenderer(
            target: target,
            timestamps: upOptions.timestamps,
            noLogPrefix: upOptions.noLogPrefix,
            colorPrefixes: upOptions.colorPrefixes,
            currentDate: options.currentDate,
            emit: options.emitAttachedData,
        )
        let task = Task {
            do {
                try await attachManager.attachOutput(
                    id: containerName,
                    stdout: true,
                    stderr: true,
                    mode: mode,
                    onReady: {},
                    onStarted: { started.ready() },
                    emit: { renderer.append($0) },
                )
                renderer.flush()
            } catch {
                started.fail(error)
                throw error
            }
        }
        do {
            try await started.wait()
            return ComposeUpOutputAttachment(containerName: containerName, task: task)
        } catch {
            task.cancel()
            throw error
        }
    }
}

/// Incrementally frames attach chunks so Compose prefixes exactly once per
/// logical line, including blank and unterminated final lines.
private final class ComposeUpAttachedOutputRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: Data
    private let timestamps: Bool
    private let currentDate: @Sendable () -> Date
    private let emit: @Sendable (Data) -> Void
    private let timestampFormatter: ISO8601DateFormatter
    private var pending: [ComposeLogStream: Data] = [:]

    init(
        target: ServiceContainerTarget,
        timestamps: Bool,
        noLogPrefix: Bool,
        colorPrefixes: Bool,
        currentDate: @escaping @Sendable () -> Date,
        emit: @escaping @Sendable (Data) -> Void,
    ) {
        if noLogPrefix {
            prefix = Data()
        } else {
            let value = colorPrefixes
                ? "\u{001B}[\(ComposeUpAttachedOutputRenderer.colorCode(for: target))m\(Self.name(for: target))\u{001B}[0m"
                : Self.name(for: target)
            prefix = Data("\(value) | ".utf8)
        }
        self.timestamps = timestamps
        self.currentDate = currentDate
        self.emit = emit
        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func append(_ record: ComposeLogRecord) {
        lock.lock()
        var buffer = pending[record.stream] ?? Data()
        buffer.append(record.payload)
        let lines = Self.completeLines(in: &buffer)
        pending[record.stream] = buffer
        let rendered = lines.map { render($0, timestamp: record.timestamp, terminated: true) }
        lock.unlock()
        for line in rendered {
            emit(line)
        }
    }

    func flush() {
        lock.lock()
        let lines = [ComposeLogStream.stdout, .stderr].compactMap { stream -> Data? in
            guard let data = pending[stream], !data.isEmpty else { return nil }
            return render(data, timestamp: nil, terminated: false)
        }
        pending.removeAll()
        lock.unlock()
        for line in lines {
            emit(line)
        }
    }

    private func render(_ line: Data, timestamp: Date?, terminated: Bool) -> Data {
        var output = prefix
        if timestamps {
            output.append(Data("\(timestampFormatter.string(from: timestamp ?? currentDate())) ".utf8))
        }
        output.append(line)
        if terminated {
            output.append(UInt8(ascii: "\n"))
        }
        return output
    }

    private static func completeLines(in data: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            var line = Data(data[..<newline])
            if line.last == UInt8(ascii: "\r") {
                line.removeLast()
            }
            lines.append(line)
            data.removeSubrange(...newline)
        }
        return lines
    }

    private static func name(for target: ServiceContainerTarget) -> String {
        if let containerName = target.service.containerName, !containerName.isEmpty {
            return containerName
        }
        return target.index == Int.max ? target.name : "\(target.service.name)-\(target.index)"
    }

    private static func colorCode(for target: ServiceContainerTarget) -> String {
        let palette = ["36", "32", "33", "35", "34", "31"]
        let replicaSeed = target.index == Int.max ? 0 : target.index
        let seed = target.service.name.unicodeScalars.reduce(replicaSeed) { partial, scalar in
            partial + Int(scalar.value)
        }
        return palette[seed % palette.count]
    }
}
