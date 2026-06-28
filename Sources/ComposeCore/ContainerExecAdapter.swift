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
import Logging

/// Compose exec request that can run without attached terminal IO.
public struct ContainerDetachedExecRequest: Sendable, Equatable {
    public var id: String
    public var command: [String]
    public var environment: [String]
    public var user: String?
    public var workingDirectory: String?
    public var privileged: Bool

    public init(
        id: String,
        command: [String],
        environment: [String] = [],
        user: String? = nil,
        workingDirectory: String? = nil,
        privileged: Bool = false
    ) {
        self.id = id
        self.command = command
        self.environment = environment
        self.user = user
        self.workingDirectory = workingDirectory
        self.privileged = privileged
    }
}

/// Compose exec request that attaches local terminal IO to the process.
public struct ContainerAttachedExecRequest: Sendable, Equatable {
    public var id: String
    public var command: [String]
    public var environment: [String]
    public var user: String?
    public var workingDirectory: String?
    public var privileged: Bool
    public var interactive: Bool
    public var tty: Bool

    public init(
        id: String,
        command: [String],
        environment: [String] = [],
        user: String? = nil,
        workingDirectory: String? = nil,
        privileged: Bool = false,
        interactive: Bool = true,
        tty: Bool = true
    ) {
        self.id = id
        self.command = command
        self.environment = environment
        self.user = user
        self.workingDirectory = workingDirectory
        self.privileged = privileged
        self.interactive = interactive
        self.tty = tty
    }
}

/// Low-level apple/container process calls used by `ContainerClientExecManager`.
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

    /// Creates an attached process and returns its exit status.
    func runAttachedProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        interactive: Bool,
        tty: Bool
    ) async throws -> Int32
}

/// Direct apple/container APIs used for detached Compose exec.
public protocol ContainerExecManaging: Sendable {
    /// Runs an attached process inside a service container and returns its status.
    func execAttached(request: ContainerAttachedExecRequest) async throws -> Int32

    /// Runs a detached process inside a service container and emits its container id.
    func execDetached(
        request: ContainerDetachedExecRequest,
        emit: @escaping @Sendable (String) -> Void
    ) async throws
}

/// Thin apple/container client wrapper around process APIs.
public struct ContainerExecAPIClient: ContainerExecAPIClienting {
    public typealias Get = @Sendable (String) async throws -> ContainerSnapshot
    public typealias CreateAndStart = @Sendable (String, String, ProcessConfiguration, [FileHandle?]) async throws -> Void
    public typealias RunAttached = @Sendable (String, String, ProcessConfiguration, Bool, Bool) async throws -> Int32

    private let getOperation: Get
    private let createAndStartOperation: CreateAndStart
    private let runAttachedOperation: RunAttached

    public init(
        get: @escaping Get = { try await ContainerClient().get(id: $0) },
        createAndStart: @escaping CreateAndStart = ContainerExecLiveAdapter.createAndStartProcess,
        runAttached: @escaping RunAttached = ContainerExecLiveAdapter.runAttachedProcess
    ) {
        self.getOperation = get
        self.createAndStartOperation = createAndStart
        self.runAttachedOperation = runAttached
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

    /// Runs an attached process through `ContainerClient`.
    public func runAttachedProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        interactive: Bool,
        tty: Bool
    ) async throws -> Int32 {
        try await runAttachedOperation(containerId, processId, configuration, interactive, tty)
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

    /// Creates and starts an attached process with apple/container process APIs.
    public func execAttached(request: ContainerAttachedExecRequest) async throws -> Int32 {
        let (container, configuration) = try await processConfiguration(
            id: request.id,
            command: request.command,
            environment: request.environment,
            user: request.user,
            workingDirectory: request.workingDirectory,
            privileged: request.privileged,
            terminal: request.tty
        )

        return try await client.runAttachedProcess(
            containerId: container.id,
            processId: processIdentifier(),
            configuration: configuration,
            interactive: request.interactive,
            tty: request.tty
        )
    }

    /// Creates and starts a detached process with apple/container process APIs.
    public func execDetached(
        request: ContainerDetachedExecRequest,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        let (container, configuration) = try await processConfiguration(
            id: request.id,
            command: request.command,
            environment: request.environment,
            user: request.user,
            workingDirectory: request.workingDirectory,
            privileged: request.privileged,
            terminal: false
        )

        try await client.createAndStartProcess(
            containerId: container.id,
            processId: processIdentifier(),
            configuration: configuration,
            stdio: []
        )
        emit(container.id)
    }

    private func processConfiguration(
        id: String,
        command: [String],
        environment: [String],
        user: String?,
        workingDirectory: String?,
        privileged: Bool,
        terminal: Bool
    ) async throws -> (ContainerSnapshot, ProcessConfiguration) {
        guard let executable = command.first else {
            throw ComposeError.invalidProject("exec requires a command")
        }

        let container = try await client.getContainer(id: id)
        guard container.status == .running else {
            throw ComposeError.invalidProject("container '\(id)' is not running")
        }

        var configuration = container.configuration.initProcess
        configuration.executable = executable
        configuration.arguments = Array(command.dropFirst())
        configuration.terminal = terminal
        configuration.privileged = privileged
        configuration.environment.append(
            contentsOf: try Parser.allEnv(
                imageEnvs: [],
                envFiles: [],
                envs: environment
            )
        )
        if let workingDirectory {
            configuration.workingDirectory = workingDirectory
        }
        let (parsedUser, additionalGroups) = Parser.user(
            user: user,
            uid: nil,
            gid: nil,
            defaultUser: configuration.user
        )
        configuration.user = parsedUser
        configuration.supplementalGroups.append(contentsOf: additionalGroups)

        return (container, configuration)
    }
}
