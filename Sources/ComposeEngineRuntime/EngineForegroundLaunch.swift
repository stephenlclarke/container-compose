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

import ContainerEngineWire
import ContainerUnixHTTPClient
import Foundation

extension EngineRuntimeProvider {
    /// The subscription is acknowledged before start. No CLI fallback, retry,
    /// removal or container-wide stdin closure follows a transport failure.
    func runAttachedContainer(
        id: String, terminal: Bool, standardInput: Bool, io: EngineForegroundIO
    ) async throws -> Int32 {
        let path = "/v1.53/containers/\(escaped(id))"
        let client = try attachmentClient.get()
        let connection = try await client.openDuplex(.init(
            method: .post,
            target: path + "/attach?logs=0&stream=1&stdin=\(standardInput ? 1 : 0)&stdout=1&stderr=1"
        ))
        defer { connection.close() }
        if !standardInput {
            try await connection.finishInput()
        }
        let exit = try await EngineForegroundExitWait.prepare(client: client, path: path)
        defer { exit.cancel() }
        let detachment = ForegroundDetachment()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ForegroundEvent.self) { group in
                defer { exit.cancel(); group.cancelAll() }
                group.addTask {
                    _ = try await exit.value
                    return .exitReady
                }
                group.addTask {
                    try await Self.copyOutput(connection, terminal: terminal, io: io)
                    return .outputEnded
                }
                // Drain while the start response is pending: init may emit more
                // than the bounded attachment queues before native confirmation.
                try await startContainer(id: id)
                if standardInput {
                    group.addTask {
                        try await Self.copyInput(connection, terminal: terminal, io: io, detachment: detachment)
                    }
                }
                if terminal {
                    group.addTask { [self] in
                        try await monitorTerminalSize(id: id, path: path, io: io, exit: exit)
                        return .resizeEnded
                    }
                }
                return try await Self.waitForForegroundEnd(group: &group, exit: exit, detachment: detachment)
            }
        } onCancel: {
            // Task.value does not inherit its waiter's cancellation. The outer
            // launch owns this request; cancelling a sibling output/resize task
            // during normal drainage must not discard the authentic exit.
            exit.cancel()
        }
    }

    private static func waitForForegroundEnd(
        group: inout ThrowingTaskGroup<ForegroundEvent, any Error>,
        exit: EngineForegroundExitWait, detachment: ForegroundDetachment
    ) async throws -> Int32 {
        while let event = try await group.next() {
            switch event {
            case .inputEnded, .resizeEnded, .exitReady: continue
            case .detached: return 0
            case .outputEnded:
                if detachment.requested {
                    return 0
                }
                group.cancelAll()
                return try await exit.value
            }
        }
        throw CancellationError()
    }

    private func monitorTerminalSize(
        id: String, path: String, io: EngineForegroundIO, exit: EngineForegroundExitWait
    ) async throws {
        var previous: EngineTerminalSize?
        while true {
            try Task.checkCancellation()
            if let size = try io.size(), size != previous {
                do {
                    try await request(.post, path + "/resize?w=\(size.width)&h=\(size.height)")
                } catch let ContainerUnixHTTPClientError.server(status: status, message: message)
                    where status == 404 || status == 409
                {
                    // Native resize requires a running generation. A stopped
                    // immutable ID is a normal race; its wait response still
                    // supplies the exit code. Other conflicts remain failures.
                    if status == 409, let current = try await getContainer(id: id) {
                        if current.id == id, ["stopped", "exited"].contains(current.status.lowercased()) {
                            return
                        }
                        throw ContainerUnixHTTPClientError.server(status: status, message: message)
                    }
                    // Auto-removal can win both resize and inspect. Only the
                    // already-registered native exit can validate that race;
                    // absence by itself never invents a successful status.
                    _ = try await exit.value
                    return
                }
                previous = size
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func copyOutput(
        _ connection: ContainerUnixHTTPConnection, terminal: Bool, io: EngineForegroundIO
    ) async throws {
        var decoder = EngineStreamDecoder()
        while let data = try await connection.read() {
            try Task.checkCancellation()
            let frames = terminal
                ? [DockerStreamFrame(channel: .standardOutput, data: data)] : try decoder.consume(data)
            for frame in frames {
                try await io.write(frame)
            }
        }
        try Task.checkCancellation()
        if !terminal {
            try decoder.finish()
        }
    }

    private static func copyInput(
        _ connection: ContainerUnixHTTPConnection, terminal: Bool, io: EngineForegroundIO,
        detachment: ForegroundDetachment
    ) async throws -> ForegroundEvent {
        var previousControlP = false
        while let bytes = try await io.read() {
            try Task.checkCancellation()
            // The gateway applies the same default detach sequence. Detect it
            // locally too so detachment does not turn into a wait for init exit.
            var detached = false
            if terminal {
                for byte in bytes {
                    if previousControlP, byte == 17 {
                        detached = true; break
                    }
                    // Match Moby's escape proxy: a mismatch flushes both bytes.
                    previousControlP = !previousControlP && byte == 16
                }
            }
            if detached {
                detachment.mark()
            }
            try await connection.write(bytes)
            if detached {
                return .detached
            }
        }
        try Task.checkCancellation()
        if terminal {
            detachment.mark()
        }
        try await connection.finishInput()
        return terminal ? .detached : .inputEnded
    }
}

private enum ForegroundEvent: Sendable {
    case inputEnded, outputEnded, detached, resizeEnded, exitReady
}

private final class ForegroundDetachment: @unchecked Sendable {
    private let lock = NSLock()
    private var detached = false
    var requested: Bool {
        lock.withLock { detached }
    }

    func mark() {
        lock.withLock { detached = true }
    }
}
