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
import ContainerEngineWire
import Foundation

extension EngineRuntimeProvider: ComposeRuntimeContainerLaunching {
    public func launchContainer(_ request: ComposeRuntimeContainerLaunchRequest) async throws -> Int32 {
        let arguments = try await rewriteManagedVolumeMounts(request.arguments)
        let result = try await runner.run(
            environmentLauncher,
            [containerBinary, request.command.rawValue] + arguments,
            workingDirectory: nil,
            environment: nil,
            io: request.command == .run && !arguments.contains("--detach")
                ? .inherited
                : .captured(input: nil)
        )
        return result.status
    }

    private func rewriteManagedVolumeMounts(_ arguments: [String]) async throws -> [String] {
        var result = arguments
        var index = result.startIndex
        while index < result.endIndex {
            if result[index] == "--volume", result.indices.contains(index + 1) {
                if let replacement = try await managedShortVolume(result[index + 1]) {
                    result[index + 1] = replacement
                }
                index += 2
                continue
            }
            if result[index] == "--mount", result.indices.contains(index + 1) {
                let fields = result[index + 1].split(separator: ",", omittingEmptySubsequences: false)
                let type = fields.first { $0.hasPrefix("type=") }?.dropFirst("type=".count)
                let source = fields.first { $0.hasPrefix("source=") }?.dropFirst("source=".count)
                if type == "volume", let source, !source.isEmpty,
                   let replacement = try await managedStructuredVolume(
                       fields: fields,
                       source: String(source)
                   )
                {
                    result[index + 1] = replacement
                }
                index += 2
                continue
            }
            let argument = result[index]
            if Self.containerLaunchValueOptions.contains(argument) {
                index += result.indices.contains(index + 1) ? 2 : 1
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            // The first non-option operand is the image. Everything after it
            // belongs to the container process and must remain byte-for-byte
            // unchanged, even when it resembles a Container CLI mount option.
            break
        }
        return result
    }

    private static let containerLaunchValueOptions: Set<String> = [
        "--add-host", "--annotation", "--blkio", "--cap-add", "--cap-drop",
        "--cgroup-parent", "--cgroupns", "--cpu-period", "--cpu-quota",
        "--cpu-shares", "--cpus", "--cpuset-cpus", "--device",
        "--device-cgroup-rule", "--dns", "--dns-option", "--dns-search",
        "--domainname", "--entrypoint", "--env",
        "--env-file", "--expose", "--gpus", "--group-add", "--hostname",
        "--health-cmd", "--health-interval", "--health-retries",
        "--health-start-interval", "--health-start-period", "--health-timeout",
        "--init-image", "--ipc", "--isolation", "--label", "--log-driver",
        "--log-opt", "--memory", "--memory-reservation", "--memory-swap",
        "--name", "--network", "--oom-score-adj", "--pid", "--pids-limit",
        "--platform", "--publish", "--restart", "--restart-delay",
        "--restart-window", "--runtime", "--security-opt", "--shm-size",
        "--stop-signal", "--stop-timeout", "--sysctl", "--tmpfs", "--ulimit",
        "--user", "--userns", "--uts", "--workdir",
    ]

    private func managedShortVolume(_ value: String) async throws -> String? {
        let fields = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        let source = String(fields[0])
        guard !source.hasPrefix("/"), !source.hasPrefix(".") else { return nil }
        let volume: EngineVolume = try await request(
            .get,
            "/v1.53/volumes/\(escaped(source))"
        )
        guard URL(fileURLWithPath: volume.mountpoint).lastPathComponent == "_data" else {
            return nil
        }
        return "\(volume.mountpoint):\(fields[1])"
            + (fields.count == 3 && fields[2].split(separator: ",").contains("ro") ? ":ro" : "")
    }

    private func managedStructuredVolume(
        fields: [Substring],
        source: String
    ) async throws -> String? {
        let volume: EngineVolume = try await request(
            .get,
            "/v1.53/volumes/\(escaped(source))"
        )
        guard URL(fileURLWithPath: volume.mountpoint).lastPathComponent == "_data" else {
            return nil
        }
        let bindSource = try managedVolumeBindSource(
            fields: fields,
            mountpoint: volume.mountpoint
        )
        return fields.compactMap { field in
            if field == "type=volume" {
                return "type=bind"
            }
            if field.hasPrefix("source=") {
                return "source=\(bindSource)"
            }
            if field.hasPrefix("volume-subpath=") {
                return nil
            }
            return String(field)
        }.joined(separator: ",")
    }

    private func managedVolumeBindSource(
        fields: [Substring],
        mountpoint: String
    ) throws -> String {
        guard let field = fields.first(where: { $0.hasPrefix("volume-subpath=") }) else {
            return mountpoint
        }
        let subpath = String(field.dropFirst("volume-subpath=".count))
        guard !subpath.isEmpty, !subpath.hasPrefix("/") else {
            throw ComposeError.invalidProject("volume subpath must be a non-empty relative path")
        }
        let root = URL(fileURLWithPath: mountpoint, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(subpath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw ComposeError.invalidProject("volume subpath escapes its managed volume")
        }
        return candidate.path
    }
}

extension EngineRuntimeProvider: ComposeRuntimeExecManaging {
    public func execAttached(request: ContainerAttachedExecRequest) async throws -> Int32 {
        let arguments = try await nativeExecArguments(
            id: request.id,
            command: request.command,
            environment: request.environment,
            user: request.user,
            workingDirectory: request.workingDirectory,
            privileged: request.privileged,
            interactive: request.interactive,
            tty: request.tty,
            detached: false
        )
        let result = try await runner.run(
            containerBinary,
            arguments,
            workingDirectory: nil,
            environment: nil,
            io: .inherited
        )
        return result.status
    }

    public func execDetached(
        request: ContainerDetachedExecRequest,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        let arguments = try await nativeExecArguments(
            id: request.id,
            command: request.command,
            environment: request.environment,
            user: request.user,
            workingDirectory: request.workingDirectory,
            privileged: request.privileged,
            interactive: false,
            tty: false,
            detached: true
        )
        let result = try await runner.run(containerBinary, arguments)
        guard result.succeeded else {
            throw ComposeError.commandFailed(
                command: ([containerBinary] + arguments).joined(separator: " "),
                status: result.status,
                stderr: result.stderr
            )
        }
        emit(request.id)
    }

    // swiftlint:disable:next function_parameter_count
    private func nativeExecArguments(
        id: String,
        command: [String],
        environment: [String],
        user: String?,
        workingDirectory: String?,
        privileged: Bool,
        interactive: Bool,
        tty: Bool,
        detached: Bool
    ) async throws -> [String] {
        guard !command.isEmpty else {
            throw ComposeError.invalidProject("exec requires a command")
        }
        guard !privileged else {
            throw ComposeError.unsupported("privileged exec is not supported by stock Apple container")
        }
        let container: EngineContainerIdentity = try await request(
            .get,
            "/v1.53/containers/\(escaped(id))/json"
        )
        let nativeID = container.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !nativeID.isEmpty else {
            throw ComposeError.invalidProject("Engine container '\(id)' has no Apple container name")
        }

        var arguments = ["exec"]
        if detached {
            arguments.append("--detach")
        }
        for value in environment {
            arguments.append(contentsOf: ["--env", value])
        }
        if let user, !user.isEmpty {
            arguments.append(contentsOf: ["--user", user])
        }
        if let workingDirectory, !workingDirectory.isEmpty {
            arguments.append(contentsOf: ["--workdir", workingDirectory])
        }
        if interactive, !detached {
            arguments.append("--interactive")
        }
        if tty, !detached {
            arguments.append("--tty")
        }
        arguments.append(nativeID)
        arguments.append(contentsOf: command)
        return arguments
    }
}

private struct EngineContainerIdentity: Decodable {
    let name: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
    }
}

extension ISO8601DateFormatter {
    static func engineDate(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
