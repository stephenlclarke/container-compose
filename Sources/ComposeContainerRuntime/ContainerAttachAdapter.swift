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

import ComposeCore
import ComposeRuntimeSPI
import ContainerAPIClient
import ContainerResource
import Foundation

/// One client-owned attachment session whose disconnect never stops the guest
/// process or its persistent logging pipeline.
protocol ContainerOutputAttachSession: Sendable {
    func start() async throws
    func disconnect()
}

/// Low-level apple/container calls used by `ContainerClientAttachManager`.
protocol ContainerAttachAPIClienting: Sendable {
    func getContainer(id: String) async throws -> ContainerSnapshot
    func attach(id: String, stdio: [FileHandle?]) async throws -> any ContainerOutputAttachSession
    func bootstrap(id: String, stdio: [FileHandle?]) async throws -> any ContainerOutputAttachSession
}

private struct ContainerClientOutputAttachSession: ContainerOutputAttachSession {
    let process: any ClientProcess

    func start() async throws {
        try await process.start()
    }

    func disconnect() {
        process.disconnect()
    }
}

/// Thin apple/container client wrapper around output-only attach calls.
struct ContainerAttachAPIClient: ContainerAttachAPIClienting {
    private let controlClient: ContainerClientProvider
    private let makeSessionClient: ContainerClientProvider

    init(
        controlClient: @escaping ContainerClientProvider = { ContainerClient() },
        makeSessionClient: @escaping ContainerClientProvider = { ContainerClient() },
    ) {
        self.controlClient = controlClient
        self.makeSessionClient = makeSessionClient
    }

    func getContainer(id: String) async throws -> ContainerSnapshot {
        try await controlClient().get(id: id)
    }

    func attach(id: String, stdio: [FileHandle?]) async throws -> any ContainerOutputAttachSession {
        try await ContainerClientOutputAttachSession(
            process: makeSessionClient().attach(id: id, stdio: stdio),
        )
    }

    func bootstrap(id: String, stdio: [FileHandle?]) async throws -> any ContainerOutputAttachSession {
        var dynamicEnvironment: [String: String] = [:]
        if let sshAuthSocket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            dynamicEnvironment["SSH_AUTH_SOCK"] = sshAuthSocket
        }
        return try await ContainerClientOutputAttachSession(
            process: makeSessionClient().bootstrap(
                id: id,
                stdio: stdio,
                dynamicEnv: dynamicEnvironment,
            ),
        )
    }
}

/// `ContainerClient`-backed output attachment independent of log persistence.
public struct ContainerClientAttachManager: ComposeRuntimeAttachManaging {
    private let client: any ContainerAttachAPIClienting

    public init() {
        client = ContainerAttachAPIClient()
    }

    init(client: any ContainerAttachAPIClienting) {
        self.client = client
    }

    // swiftlint:disable function_body_length function_parameter_count
    public func attachOutput(
        id: String,
        stdout: Bool,
        stderr: Bool,
        mode: ComposeOutputAttachmentMode,
        onReady: @escaping @Sendable () -> Void,
        onStarted: @escaping @Sendable () -> Void,
        emit: @escaping @Sendable (ComposeLogRecord) -> Void,
    ) async throws {
        guard stdout || stderr else {
            onReady()
            onStarted()
            return
        }

        let container = try await client.getContainer(id: id)
        let terminal = container.configuration.initProcess.terminal
        let stdoutPipe = stdout ? Pipe() : nil
        let stderrPipe = stderr && !terminal ? Pipe() : nil
        guard stdoutPipe != nil || stderrPipe != nil else {
            onReady()
            onStarted()
            return
        }

        let stdio = [
            nil,
            stdoutPipe?.fileHandleForWriting,
            stderrPipe?.fileHandleForWriting,
        ]
        let session: any ContainerOutputAttachSession
        let startsPreparedProcess: Bool
        switch (container.status, mode) {
        case (.stopped, .beforeStart):
            session = try await client.bootstrap(id: id, stdio: stdio)
            startsPreparedProcess = true
        case (.running, _), (.paused, _):
            session = try await client.attach(id: id, stdio: stdio)
            startsPreparedProcess = false
        default:
            throw ComposeError.unsupported(
                "attach: container '\(id)' is \(container.status.rawValue)",
            )
        }
        try? stdoutPipe?.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()
        onReady()
        defer {
            session.disconnect()
            try? stdoutPipe?.fileHandleForReading.close()
            try? stderrPipe?.fileHandleForReading.close()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            if let handle = stdoutPipe?.fileHandleForReading {
                group.addTask {
                    try await emitAttachedChunks(from: handle, stream: .stdout, terminal: terminal, emit: emit)
                }
            }
            if let handle = stderrPipe?.fileHandleForReading {
                group.addTask {
                    try await emitAttachedChunks(from: handle, stream: .stderr, terminal: false, emit: emit)
                }
            }
            if startsPreparedProcess {
                group.addTask {
                    try await session.start()
                    onStarted()
                }
            } else {
                onStarted()
            }
            try await group.waitForAll()
        }
    }
    // swiftlint:enable function_body_length function_parameter_count
}

private func emitAttachedChunks(
    from handle: FileHandle,
    stream: ComposeLogStream,
    terminal: Bool,
    emit: @escaping @Sendable (ComposeLogRecord) -> Void,
) async throws {
    try await withTaskCancellationHandler {
        for try await data in attachedChunks(from: handle) where !data.isEmpty {
            try Task.checkCancellation()
            emit(ComposeLogRecord(stream: stream, payload: data, terminal: terminal))
        }
    } onCancel: {
        handle.readabilityHandler = nil
        try? handle.close()
    }
}

private func attachedChunks(from handle: FileHandle) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
        handle.readabilityHandler = { source in
            let data = source.availableData
            guard !data.isEmpty else {
                source.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(data)
        }
        continuation.onTermination = { _ in
            handle.readabilityHandler = nil
        }
    }
}
