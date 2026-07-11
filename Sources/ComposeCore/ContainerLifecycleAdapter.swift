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

import ContainerAPIClient
import ContainerResource

/// Low-level apple/container lifecycle calls used by
/// `ContainerClientLifecycleManager`.
public protocol ContainerLifecycleAPIClienting: Sendable {
    /// Starts container `id`.
    func startContainer(id: String) async throws

    /// Sends `signal` to container `id`.
    func killContainer(id: String, signal: String) async throws

    /// Stops container `id` with fully resolved stop options.
    func stopContainer(id: String, options: ContainerStopOptions) async throws

    /// Pauses container `id`.
    func pauseContainer(id: String) async throws

    /// Resumes paused container `id`.
    func unpauseContainer(id: String) async throws

    /// Waits for container `id`'s init process and returns its exit code.
    func waitContainer(id: String) async throws -> Int32

    /// Returns the current container snapshot for `id`.
    func getContainer(id: String) async throws -> ContainerSnapshot

    /// Deletes container `id`, forcing removal when requested.
    func deleteContainer(id: String, force: Bool) async throws
}

/// Direct apple/container APIs used for service container lifecycle
/// operations.
public protocol ContainerLifecycleManaging: Sendable {
    /// Starts container `id`.
    func startContainer(id: String) async throws

    /// Sends `signal` to container `id`.
    func killContainer(id: String, signal: String) async throws

    /// Stops container `id` with the supplied signal and timeout.
    func stopContainer(id: String, signal: String?, timeoutInSeconds: Int?) async throws

    /// Pauses container `id`.
    func pauseContainer(id: String) async throws

    /// Resumes paused container `id`.
    func unpauseContainer(id: String) async throws

    /// Waits for container `id`'s init process and returns its exit code.
    func waitContainer(id: String) async throws -> Int32

    /// Deletes container `id`, forcing removal when requested.
    func deleteContainer(id: String, force: Bool) async throws
}

/// Thin apple/container client wrapper around lifecycle API calls.
public struct ContainerLifecycleAPIClient: ContainerLifecycleAPIClienting {
    public typealias Start = @Sendable (String) async throws -> Void
    public typealias Kill = @Sendable (String, String) async throws -> Void
    public typealias Stop = @Sendable (String, ContainerStopOptions) async throws -> Void
    public typealias Pause = @Sendable (String) async throws -> Void
    public typealias Unpause = @Sendable (String) async throws -> Void
    public typealias Wait = @Sendable (String) async throws -> Int32
    public typealias Get = @Sendable (String) async throws -> ContainerSnapshot
    public typealias Delete = @Sendable (String, Bool) async throws -> Void

    private let startOperation: Start
    private let killOperation: Kill
    private let stopOperation: Stop
    private let pauseOperation: Pause
    private let unpauseOperation: Unpause
    private let waitOperation: Wait
    private let getOperation: Get
    private let deleteOperation: Delete

    /// Lifecycle operations that mutate container execution state.
    public struct ControlOperations: Sendable {
        public var start: Start
        public var kill: Kill
        public var stop: Stop
        public var pause: Pause
        public var unpause: Unpause

        public init(
            start: @escaping Start = ContainerLifecycleLiveAdapter.start,
            kill: @escaping Kill = { try await ContainerClient().kill(id: $0, signal: $1) },
            stop: @escaping Stop = { try await ContainerClient().stop(id: $0, opts: $1) },
            pause: @escaping Pause = { try await ContainerClient().pause(id: $0) },
            unpause: @escaping Unpause = { try await ContainerClient().unpause(id: $0) }
        ) {
            self.start = start
            self.kill = kill
            self.stop = stop
            self.pause = pause
            self.unpause = unpause
        }
    }

    /// Lifecycle operations that read or remove container state.
    public struct StateOperations: Sendable {
        public var wait: Wait
        public var get: Get
        public var delete: Delete

        public init(
            wait: @escaping Wait = ContainerLifecycleLiveAdapter.wait,
            get: @escaping Get = { try await ContainerClient().get(id: $0) },
            delete: @escaping Delete = { try await ContainerClient().delete(id: $0, force: $1) }
        ) {
            self.wait = wait
            self.get = get
            self.delete = delete
        }
    }

    public init(control: ControlOperations = .init(), state: StateOperations = .init()) {
        startOperation = control.start
        killOperation = control.kill
        stopOperation = control.stop
        pauseOperation = control.pause
        unpauseOperation = control.unpause
        waitOperation = state.wait
        getOperation = state.get
        deleteOperation = state.delete
    }

    /// Starts a container through `ContainerClient`.
    public func startContainer(id: String) async throws {
        try await startOperation(id)
    }

    /// Sends a signal through `ContainerClient`.
    public func killContainer(id: String, signal: String) async throws {
        try await killOperation(id, signal)
    }

    /// Stops a container through `ContainerClient`.
    public func stopContainer(id: String, options: ContainerStopOptions) async throws {
        try await stopOperation(id, options)
    }

    /// Pauses a container through `ContainerClient`.
    public func pauseContainer(id: String) async throws {
        try await pauseOperation(id)
    }

    /// Resumes a paused container through `ContainerClient`.
    public func unpauseContainer(id: String) async throws {
        try await unpauseOperation(id)
    }

    /// Waits for a container init process through `ContainerClient`.
    public func waitContainer(id: String) async throws -> Int32 {
        let exitCode = try await waitOperation(id)
        if exitCode == 255 {
            do {
                if let snapshotExitCode = try await stoppedSnapshotExitCode(id: id) {
                    return snapshotExitCode
                }
            } catch {
                return exitCode
            }
        }
        return exitCode
    }

    /// Returns the container snapshot through `ContainerClient`.
    public func getContainer(id: String) async throws -> ContainerSnapshot {
        try await getOperation(id)
    }

    /// Deletes a container through `ContainerClient`.
    public func deleteContainer(id: String, force: Bool) async throws {
        try await deleteOperation(id, force)
    }

    /// Recovers exit status for short-lived containers whose wait was registered late.
    private func stoppedSnapshotExitCode(id: String) async throws -> Int32? {
        let snapshot = try await getOperation(id)
        guard snapshot.status == .stopped else {
            return nil
        }
        return snapshot.exitCode
    }
}

/// `ContainerClient`-backed lifecycle manager for real service containers.
public struct ContainerClientLifecycleManager: ContainerLifecycleManaging {
    private let client: ContainerLifecycleAPIClienting

    public init(client: ContainerLifecycleAPIClienting = ContainerLifecycleAPIClient()) {
        self.client = client
    }

    /// Starts a container through `ContainerClient.bootstrap(id:stdio:dynamicEnv:)`.
    public func startContainer(id: String) async throws {
        try await client.startContainer(id: id)
    }

    /// Sends a signal through `ContainerClient.kill(id:signal:)`.
    public func killContainer(id: String, signal: String) async throws {
        try await client.killContainer(id: id, signal: signal)
    }

    /// Stops a container through `ContainerClient.stop(id:opts:)`.
    public func stopContainer(id: String, signal: String?, timeoutInSeconds: Int?) async throws {
        let timeout = try stopTimeout(timeoutInSeconds)
        let options = ContainerStopOptions(
            timeoutInSeconds: timeout,
            signal: signal
        )
        try await client.stopContainer(id: id, options: options)
    }

    /// Pauses a running container through `ContainerClient.pause(id:)`.
    public func pauseContainer(id: String) async throws {
        try await client.pauseContainer(id: id)
    }

    /// Resumes a paused container through `ContainerClient.unpause(id:)`.
    public func unpauseContainer(id: String) async throws {
        try await client.unpauseContainer(id: id)
    }

    /// Waits for a running container through `ContainerClient`.
    public func waitContainer(id: String) async throws -> Int32 {
        try await client.waitContainer(id: id)
    }

    /// Deletes a container through `ContainerClient.delete(id:force:)`.
    public func deleteContainer(id: String, force: Bool) async throws {
        try await client.deleteContainer(id: id, force: force)
    }

    /// Converts Compose timeout values to the apple/container API type.
    private func stopTimeout(_ timeoutInSeconds: Int?) throws -> Int32 {
        guard let timeoutInSeconds else {
            return ContainerStopOptions.default.timeoutInSeconds
        }
        guard timeoutInSeconds >= 0, timeoutInSeconds <= Int(Int32.max) else {
            throw ComposeError.invalidProject("stop timeout must be between 0 and \(Int32.max) seconds")
        }
        return Int32(timeoutInSeconds)
    }
}
