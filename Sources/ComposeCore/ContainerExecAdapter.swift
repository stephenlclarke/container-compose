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
import Foundation

/// Compose exec request that can run without attached terminal IO.
public struct ContainerDetachedExecRequest: Sendable, Equatable {
    public var id: String
    public var command: [String]
    public var environment: [String]
    public var user: String?
    public var workingDirectory: String?

    public init(
        id: String,
        command: [String],
        environment: [String] = [],
        user: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.command = command
        self.environment = environment
        self.user = user
        self.workingDirectory = workingDirectory
    }
}

/// Low-level Apple process calls used by `ContainerClientExecManager`.
public protocol ContainerExecAPIClienting: Sendable {
    /// Returns the current container snapshot for `id`.
    func getContainer(id: String) async throws -> ContainerSnapshot

    /// Creates and starts a detached process inside an already running container.
    func createAndStartProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws
}

/// Direct Apple container APIs used for detached Compose exec.
public protocol ContainerExecManaging: Sendable {
    /// Runs a detached process inside a service container and emits its container id.
    func execDetached(
        request: ContainerDetachedExecRequest,
        emit: @escaping @Sendable (String) -> Void
    ) async throws
}

/// Thin Apple `container` client wrapper around process APIs.
public struct ContainerExecAPIClient: ContainerExecAPIClienting {
    public typealias Get = @Sendable (String) async throws -> ContainerSnapshot
    public typealias CreateAndStart = @Sendable (String, String, ProcessConfiguration, [FileHandle?]) async throws -> Void

    private let getOperation: Get
    private let createAndStartOperation: CreateAndStart

    public init(
        get: @escaping Get = { try await ContainerClient().get(id: $0) },
        createAndStart: @escaping CreateAndStart = ContainerExecLiveAdapter.createAndStartProcess
    ) {
        self.getOperation = get
        self.createAndStartOperation = createAndStart
    }

    /// Returns the container snapshot through `ContainerClient`.
    public func getContainer(id: String) async throws -> ContainerSnapshot {
        try await getOperation(id)
    }

    /// Creates and starts a process through `ContainerClient`.
    public func createAndStartProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        try await createAndStartOperation(containerId, processId, configuration, stdio)
    }
}

/// `ContainerClient`-backed manager for detached service-container exec.
public struct ContainerClientExecManager: ContainerExecManaging {
    private let client: ContainerExecAPIClienting
    private let processIdentifier: @Sendable () -> String

    public init(
        client: ContainerExecAPIClienting = ContainerExecAPIClient(),
        processIdentifier: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.client = client
        self.processIdentifier = processIdentifier
    }

    /// Creates and starts a detached process with Apple runtime process APIs.
    public func execDetached(
        request: ContainerDetachedExecRequest,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let executable = request.command.first else {
            throw ComposeError.invalidProject("exec requires a command")
        }

        let container = try await client.getContainer(id: request.id)
        guard container.status == .running else {
            throw ComposeError.invalidProject("container '\(request.id)' is not running")
        }

        var configuration = container.configuration.initProcess
        configuration.executable = executable
        configuration.arguments = Array(request.command.dropFirst())
        configuration.terminal = false
        configuration.environment.append(
            contentsOf: try Parser.allEnv(
                imageEnvs: [],
                envFiles: [],
                envs: request.environment
            )
        )
        if let workingDirectory = request.workingDirectory {
            configuration.workingDirectory = workingDirectory
        }
        let (user, additionalGroups) = Parser.user(
            user: request.user,
            uid: nil,
            gid: nil,
            defaultUser: configuration.user
        )
        configuration.user = user
        configuration.supplementalGroups.append(contentsOf: additionalGroups)

        try await client.createAndStartProcess(
            containerId: request.id,
            processId: processIdentifier(),
            configuration: configuration,
            stdio: []
        )
        emit(request.id)
    }
}
