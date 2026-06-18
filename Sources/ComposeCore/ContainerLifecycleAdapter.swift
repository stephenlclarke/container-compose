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

/// Low-level Apple container lifecycle calls used by
/// `ContainerClientLifecycleManager`.
public protocol ContainerLifecycleAPIClienting: Sendable {
    /// Starts container `id`.
    func startContainer(id: String) async throws

    /// Sends `signal` to container `id`.
    func killContainer(id: String, signal: String) async throws

    /// Stops container `id` with fully resolved stop options.
    func stopContainer(id: String, options: ContainerStopOptions) async throws

    /// Waits for container `id`'s init process and returns its exit code.
    func waitContainer(id: String) async throws -> Int32

    /// Deletes container `id`, forcing removal when requested.
    func deleteContainer(id: String, force: Bool) async throws
}

/// Direct Apple container APIs used for service container lifecycle
/// operations.
public protocol ContainerLifecycleManaging: Sendable {
    /// Starts container `id`.
    func startContainer(id: String) async throws

    /// Sends `signal` to container `id`.
    func killContainer(id: String, signal: String) async throws

    /// Stops container `id` with the supplied signal and timeout.
    func stopContainer(id: String, signal: String?, timeoutInSeconds: Int?) async throws

    /// Waits for container `id`'s init process and returns its exit code.
    func waitContainer(id: String) async throws -> Int32

    /// Deletes container `id`, forcing removal when requested.
    func deleteContainer(id: String, force: Bool) async throws
}

/// Thin Apple `container` client wrapper around lifecycle API calls.
public struct ContainerLifecycleAPIClient: ContainerLifecycleAPIClienting {
    public typealias Start = @Sendable (String) async throws -> Void
    public typealias Kill = @Sendable (String, String) async throws -> Void
    public typealias Stop = @Sendable (String, ContainerStopOptions) async throws -> Void
    public typealias Wait = @Sendable (String) async throws -> Int32
    public typealias Delete = @Sendable (String, Bool) async throws -> Void

    private let startOperation: Start
    private let killOperation: Kill
    private let stopOperation: Stop
    private let waitOperation: Wait
    private let deleteOperation: Delete

    public init(
        start: @escaping Start = ContainerLifecycleLiveAdapter.start,
        kill: @escaping Kill = { try await ContainerClient().kill(id: $0, signal: $1) },
        stop: @escaping Stop = { try await ContainerClient().stop(id: $0, opts: $1) },
        wait: @escaping Wait = ContainerLifecycleLiveAdapter.wait,
        delete: @escaping Delete = { try await ContainerClient().delete(id: $0, force: $1) }
    ) {
        self.startOperation = start
        self.killOperation = kill
        self.stopOperation = stop
        self.waitOperation = wait
        self.deleteOperation = delete
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

    /// Waits for a container init process through `ContainerClient`.
    public func waitContainer(id: String) async throws -> Int32 {
        try await waitOperation(id)
    }

    /// Deletes a container through `ContainerClient`.
    public func deleteContainer(id: String, force: Bool) async throws {
        try await deleteOperation(id, force)
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

    /// Waits for a running container through `ContainerClient`.
    public func waitContainer(id: String) async throws -> Int32 {
        try await client.waitContainer(id: id)
    }

    /// Deletes a container through `ContainerClient.delete(id:force:)`.
    public func deleteContainer(id: String, force: Bool) async throws {
        try await client.deleteContainer(id: id, force: force)
    }

    /// Converts Compose timeout values to the Apple API type.
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
