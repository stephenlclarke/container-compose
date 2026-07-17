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

/// Runtime copy options that apply to one source-to-destination transfer.
public struct ContainerCopyTransferOptions: Equatable, Sendable {
    public var followSymlink = false
    public var preserveOwnership = false

    public init(followSymlink: Bool = false, preserveOwnership: Bool = false) {
        self.followSymlink = followSymlink
        self.preserveOwnership = preserveOwnership
    }
}

/// Filesystem operations provided by a Compose runtime backend.
public protocol ComposeRuntimeCopying: Sendable {
    /// Copies `source` from the local filesystem into `destination` inside container `id`.
    func copyIntoContainer(id: String, source: String, destination: String, options: ContainerCopyTransferOptions) async throws

    /// Copies `source` from container `id` to `destination` on the local filesystem.
    func copyFromContainer(id: String, source: String, destination: String, options: ContainerCopyTransferOptions) async throws

    /// Copies `source` from one container to `destination` inside another container.
    func copyBetweenContainers(
        sourceID: String,
        source: String,
        destinationID: String,
        destination: String,
        options: ContainerCopyTransferOptions,
    ) async throws
}

/// Container filesystem export operation provided by a Compose runtime backend.
public protocol ComposeRuntimeExporting: Sendable {
    /// Exports `id` as a tar archive. `live` requests a running-container snapshot;
    /// `noFreeze` requests a writable best-effort snapshot.
    func exportContainer(id: String, output: String?, live: Bool, noFreeze: Bool) async throws
}

public extension ComposeRuntimeExporting {
    /// Exports a container with the runtime's default snapshot behavior.
    func exportContainer(id: String, output: String?, live: Bool) async throws {
        try await exportContainer(id: id, output: output, live: live, noFreeze: false)
    }
}

/// Compose exec request that can run without attached terminal I/O.
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
        privileged: Bool = false,
    ) {
        self.id = id
        self.command = command
        self.environment = environment
        self.user = user
        self.workingDirectory = workingDirectory
        self.privileged = privileged
    }
}

/// Terminal attachment mode for a Compose exec process.
public struct ContainerAttachedExecTerminal: Sendable, Equatable {
    public var interactive: Bool
    public var tty: Bool

    public init(interactive: Bool = true, tty: Bool = true) {
        self.interactive = interactive
        self.tty = tty
    }
}

/// Compose exec request that attaches local terminal I/O to the process.
public struct ContainerAttachedExecRequest: Sendable, Equatable {
    public var id: String
    public var command: [String]
    public var environment: [String]
    public var user: String?
    public var workingDirectory: String?
    public var privileged: Bool
    public var interactive: Bool
    public var tty: Bool
    public var terminal: ContainerAttachedExecTerminal {
        ContainerAttachedExecTerminal(interactive: interactive, tty: tty)
    }

    public init(
        id: String,
        command: [String],
        environment: [String] = [],
        user: String? = nil,
        workingDirectory: String? = nil,
        privileged: Bool = false,
        terminal: ContainerAttachedExecTerminal = ContainerAttachedExecTerminal(),
    ) {
        self.id = id
        self.command = command
        self.environment = environment
        self.user = user
        self.workingDirectory = workingDirectory
        self.privileged = privileged
        interactive = terminal.interactive
        tty = terminal.tty
    }
}

/// Process execution operations provided by a Compose runtime backend.
public protocol ComposeRuntimeExecManaging: Sendable {
    /// Runs an attached process inside a service container and returns its status.
    func execAttached(request: ContainerAttachedExecRequest) async throws -> Int32

    /// Runs a detached process inside a service container and emits its container id.
    func execDetached(
        request: ContainerDetachedExecRequest,
        emit: @escaping @Sendable (String) -> Void,
    ) async throws
}

/// Event output formats supported by `compose events`.
public enum ComposeEventsOutputFormat: Sendable, Equatable {
    case text
    case json
}

/// One Docker Compose-style event rendered by `compose events --json`.
public struct ComposeEventRecord: Sendable, Equatable, Codable {
    public var time: Date
    public var type: String
    public var service: String
    public var id: String
    public var action: String
    public var attributes: [String: String]

    public init(
        time: Date,
        type: String,
        service: String,
        id: String,
        action: String,
        attributes: [String: String],
    ) {
        self.time = time
        self.type = type
        self.service = service
        self.id = id
        self.action = action
        self.attributes = attributes
    }
}

/// Compose project event operations provided by a runtime backend.
public protocol ComposeRuntimeEventsManaging: Sendable {
    // swiftlint:disable function_parameter_count
    /// Emits Docker Compose-style event records for selected services.
    func events(
        projectName: String,
        services: [String],
        format: ComposeEventsOutputFormat,
        since: Date?,
        until: Date?,
        emit: @escaping @Sendable (String) -> Void,
    ) async throws
    // swiftlint:enable function_parameter_count
}

/// Lifecycle operations provided by a Compose runtime backend.
public protocol ComposeRuntimeLifecycleManaging: Sendable {
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

/// Container identity and status needed before collecting runtime stats.
public struct ComposeStatsTarget: Sendable, Equatable {
    public var id: String
    public var status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

/// Statistics operations provided by a Compose runtime backend.
public protocol ComposeRuntimeStatsManaging: Sendable {
    // swiftlint:disable function_parameter_count
    /// Emits stats for the requested service container ids.
    func stats(
        ids: [String],
        format: String,
        noStream: Bool,
        noTrunc: Bool,
        includeStopped: Bool,
        emit: @escaping @Sendable (String) -> Void,
    ) async throws
    // swiftlint:enable function_parameter_count
}

/// Service container selected for Compose process listing.
public struct ComposeTopTarget: Sendable, Equatable {
    public var service: String
    public var containerID: String

    public init(service: String, containerID: String) {
        self.service = service
        self.containerID = containerID
    }
}

/// Process-listing operations provided by a Compose runtime backend.
public protocol ComposeRuntimeTopManaging: Sendable {
    /// Emits process information for the selected service containers.
    func top(targets: [ComposeTopTarget], emit: @escaping @Sendable (String) -> Void) async throws
}

/// Log operations provided by a Compose runtime backend.
public protocol ComposeRuntimeLogManaging: Sendable {
    // swiftlint:disable function_parameter_count
    /// Emits logs for container `id`, optionally following appended lines.
    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        emit: @escaping @Sendable (Data) -> Void,
    ) async throws
    // swiftlint:enable function_parameter_count
}

public extension ComposeRuntimeLogManaging {
    // swiftlint:disable function_parameter_count
    /// Emits logs through a string callback for tests and non-binary consumers.
    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        emit: @escaping @Sendable (String) -> Void,
    ) async throws {
        try await logs(
            id: id,
            tail: tail,
            follow: follow,
            since: since,
            until: until,
            timestamps: timestamps,
            emit: {
                // Preserve every byte from a runtime stream, including malformed UTF-8.
                // swiftlint:disable:next optional_data_string_conversion
                emit(String(decoding: $0, as: UTF8.self))
            },
        )
    }

    // swiftlint:enable function_parameter_count

    /// Emits logs without timestamp filters through a string callback.
    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        emit: @escaping @Sendable (String) -> Void,
    ) async throws {
        try await logs(
            id: id,
            tail: tail,
            follow: follow,
            since: nil,
            until: nil,
            timestamps: false,
            emit: emit,
        )
    }

    /// Emits logs without timestamp filters through a byte callback.
    func logs(
        id: String,
        tail: Int?,
        follow: Bool,
        emit: @escaping @Sendable (Data) -> Void,
    ) async throws {
        try await logs(
            id: id,
            tail: tail,
            follow: follow,
            since: nil,
            until: nil,
            timestamps: false,
            emit: emit,
        )
    }
}

/// Reads immutable, non-secret configuration content from a Compose runtime backend.
public protocol ComposeRuntimeConfigReading: Sendable {
    /// Returns the stored bytes for a named external configuration.
    func readConfig(name: String) async throws -> Data
}

/// Reads opaque secret content from a Compose runtime backend.
public protocol ComposeRuntimeSecretReading: Sendable {
    /// Returns the stored bytes for a named external secret.
    func readSecret(name: String) async throws -> Data
}
