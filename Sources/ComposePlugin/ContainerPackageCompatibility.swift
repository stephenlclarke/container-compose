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

// Keep the package graph wired to apple/container products that the plugin is
// expected to use as runtime integration matures.
@_exported import ContainerAPIClient
@_exported import ContainerBuild
@_exported import ContainerCommands
@_exported import ContainerLog
@_exported import ContainerResource
import Foundation

/// Validates that runtime-backed Compose commands are using the matching fork-backed stack.
enum ContainerPackageCompatibility {
  static let installGuideURL =
    "https://github.com/stephenlclarke/container-compose/blob/main/INSTALL.md"
  static let containerExecutableEnvironmentKey = "CONTAINER_COMPOSE_CONTAINER"

  private static let requiredContainerSource = "stephenlclarke/container"
  private static let requiredContainerizationSource = "stephenlclarke/containerization"

  private static let runtimeCommands: Set<String> = [
    "attach",
    "build",
    "cp",
    "create",
    "down",
    "events",
    "exec",
    "export",
    "images",
    "kill",
    "logs",
    "ls",
    "pause",
    "port",
    "ps",
    "pull",
    "push",
    "restart",
    "rm",
    "run",
    "scale",
    "start",
    "stats",
    "stop",
    "top",
    "unpause",
    "up",
    "volumes",
    "wait",
    "watch",
  ]

  /// Returns whether this invocation needs the installed runtime stack check.
  static func requiresRuntimeCheck(arguments: [String]) -> Bool {
    guard let command = commandName(in: arguments), runtimeCommands.contains(command) else {
      return false
    }
    if arguments.contains("--dry-run") {
      return false
    }
    if command == "build", arguments.contains("--print") {
      return false
    }
    return true
  }

  /// Checks the installed container stack and returns a user-facing failure when it is incompatible.
  static func compatibilityFailure(
    arguments: [String],
    lane: String,
    run: ([String]) throws -> Data = runContainerCommand
  ) -> String? {
    guard requiresRuntimeCheck(arguments: arguments) else {
      return nil
    }

    do {
      let data = try run(["system", "version", "--format", "json"])
      let components = try decodeComponents(from: data)
      return compatibilityFailure(components: components, lane: lane)
    } catch {
      return installGuidance(
        lane: lane,
        detected: [
          "container: unavailable (\(error.localizedDescription))"
        ]
      )
    }
  }

  /// Checks decoded system-version components for the fork-backed runtime metadata.
  static func compatibilityFailure(components: [ContainerSystemVersionComponent], lane: String)
    -> String?
  {
    guard let container = components.first(where: { $0.appName == "container" }) else {
      return installGuidance(
        lane: lane, detected: ["container: missing from system version output"])
    }

    let containerizationSource = container.containerizationSource
    let isForkBackedContainer =
      container.source == requiredContainerSource
      && container.distribution == "custom"
    let isForkBackedContainerization = containerizationSource == requiredContainerizationSource

    guard isForkBackedContainer, isForkBackedContainerization else {
      return installGuidance(
        lane: lane,
        detected: [
          "container: \(container.source ?? "unknown") (distribution: \(container.distribution ?? "unknown"))",
          "containerization: \(container.containerization ?? "unknown")",
        ]
      )
    }

    return nil
  }

  private static func commandName(in arguments: [String]) -> String? {
    arguments.first { runtimeCommands.contains($0) || $0 == "config" || $0 == "version" }
  }

  private static func decodeComponents(from data: Data) throws -> [ContainerSystemVersionComponent]
  {
    try JSONDecoder().decode([ContainerSystemVersionComponent].self, from: data)
  }

  private static func runContainerCommand(arguments: [String]) throws -> Data {
    let executable =
      ProcessInfo.processInfo.environment[containerExecutableEnvironmentKey] ?? "container"
    let process = Process()
    if executable.hasPrefix("/") {
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [executable] + arguments
    }

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw ContainerPackageCompatibilityError.commandFailed(
        stderr.isEmpty ? "container system version failed" : stderr)
    }
    return data
  }

  private static func installGuidance(lane: String, detected: [String]) -> String {
    let formulae = homebrewFormulae(lane: lane)
    return """
      container-compose requires Stephen Clarke's customized container stack.

      The installed Apple container components do not support the Compose functionality in this plugin.
      Install the corresponding components from Stephen Clarke's Homebrew tap, then run this command again.

        brew tap stephenlclarke/tap
        brew install \(formulae.container) \(formulae.compose)

      Detailed install instructions:
      \(installGuideURL)

      Required components:
      - container: \(requiredContainerSource)
      - containerization: \(requiredContainerizationSource)
      - container-compose: matching \(laneDescription(lane)) formula from stephenlclarke/tap

      Detected components:
      \(detected.map { "- \($0)" }.joined(separator: "\n"))
      """
  }

  private static func homebrewFormulae(lane: String) -> (container: String, compose: String) {
    switch lane {
    case "release":
      return (
        "stephenlclarke/tap/container-release", "stephenlclarke/tap/container-compose-release"
      )
    default:
      return ("stephenlclarke/tap/container", "stephenlclarke/tap/container-compose")
    }
  }

  private static func laneDescription(_ lane: String) -> String {
    lane == "release" ? "release lane" : "main lane"
  }
}

/// Component row emitted by `container system version --format json`.
struct ContainerSystemVersionComponent: Decodable, Equatable {
  var appName: String
  var buildType: String?
  var commit: String?
  var containerization: String?
  var distribution: String?
  var source: String?
  var version: String?

  var containerizationSource: String? {
    guard let containerization else {
      return nil
    }
    guard let source = containerization.split(separator: "@", maxSplits: 1).first else {
      return nil
    }
    return String(source)
  }
}

/// Errors raised while checking the installed container stack.
enum ContainerPackageCompatibilityError: Error, LocalizedError {
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let message):
      message
    }
  }
}
