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
  static let installGuideURLEnvironmentKey = "CONTAINER_COMPOSE_INSTALL_GUIDE_URL"
  static let containerExecutableEnvironmentKey = "CONTAINER_COMPOSE_CONTAINER"
  static let envExecutableEnvironmentKey = "CONTAINER_COMPOSE_ENV_EXECUTABLE"

  private static let requiredContainerSource = "stephenlclarke/container"
  private static let requiredContainerizationSource = "stephenlclarke/containerization"
  private static let defaultInstallGuideURLComponents = [
    "https:", "", "github.com", "stephenlclarke", "container-compose", "blob", "main",
    "INSTALL.md",
  ]
  private static let defaultEnvExecutableComponents = ["", "usr", "bin", "env"]

  static var installGuideURL: String {
    ProcessInfo.processInfo.environment[installGuideURLEnvironmentKey]
      ?? defaultInstallGuideURLComponents.joined(separator: "/")
  }

  private static var envExecutablePath: String {
    ProcessInfo.processInfo.environment[envExecutableEnvironmentKey]
      ?? defaultEnvExecutableComponents.joined(separator: "/")
  }

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
    if isAlphaDryRun(arguments: arguments) {
      return false
    }
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

  private static func isAlphaDryRun(arguments: [String]) -> Bool {
    guard let alphaIndex = arguments.firstIndex(of: "alpha") else {
      return false
    }
    let nestedIndex = arguments.index(after: alphaIndex)
    return arguments.indices.contains(nestedIndex) && arguments[nestedIndex] == "dry-run"
  }
}

extension ContainerPackageCompatibility {
  /// Checks the installed container stack and returns a user-facing failure when it is incompatible.
  static func compatibilityFailure(
    arguments: [String],
    lane: String,
    expectedContainerRef: String? = nil,
    expectedContainerizationRef: String? = nil,
    run: ([String]) throws -> Data = runContainerCommand
  ) -> String? {
    guard requiresRuntimeCheck(arguments: arguments) else {
      return nil
    }

    do {
      let data = try run(["system", "version", "--format", "json"])
      let components = try decodeComponents(from: data)
      if let failure = compatibilityFailure(
        components: components,
        lane: lane,
        expectedContainerRef: expectedContainerRef,
        expectedContainerizationRef: expectedContainerizationRef
      ) {
        return failure
      }
      do {
        _ = try run(["system", "status"])
      } catch {
        return serviceGuidance(
          lane: lane,
          detected: [
            "container system status: \(error.localizedDescription)"
          ])
      }
      return nil
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
  static func compatibilityFailure(
    components: [ContainerSystemVersionComponent],
    lane: String,
    expectedContainerRef: String? = nil,
    expectedContainerizationRef: String? = nil
  ) -> String? {
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

    let expectedContainerRef = concreteRef(expectedContainerRef)
    let expectedContainerizationRef = concreteRef(expectedContainerizationRef)
    if expectedContainerRef != nil || expectedContainerizationRef != nil {
      let detected = packageMismatchDetails(
        container: container,
        apiserver: components.first(where: { $0.appName == "container-apiserver" }),
        expectedContainerRef: expectedContainerRef,
        expectedContainerizationRef: expectedContainerizationRef
      )
      if !detected.isEmpty {
        return installGuidance(lane: lane, detected: detected)
      }
    }

    return nil
  }

  private static func packageMismatchDetails(
    container: ContainerSystemVersionComponent,
    apiserver: ContainerSystemVersionComponent?,
    expectedContainerRef: String?,
    expectedContainerizationRef: String?
  ) -> [String] {
    var detected: [String] = []
    if let expectedContainerRef,
      !refsMatch(container.commit, expectedContainerRef)
    {
      detected.append(
        "container: \(container.source ?? "unknown")@\(container.commit ?? "unknown") (expected \(expectedContainerRef))"
      )
    }
    if let expectedContainerRef {
      if let apiserver, !refsMatch(apiserver.commit, expectedContainerRef) {
        detected.append(
          "container-apiserver: \(apiserver.commit ?? "unknown") (expected \(expectedContainerRef))"
        )
      }
    }
    if let expectedContainerizationRef,
      !refsMatch(container.containerizationRef, expectedContainerizationRef)
    {
      detected.append(
        "containerization: \(container.containerization ?? "unknown") (expected \(expectedContainerizationRef))"
      )
    }
    return detected
  }

  private static func concreteRef(_ ref: String?) -> String? {
    guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines),
      !ref.isEmpty,
      ref != "unspecified",
      ref != "main"
    else {
      return nil
    }
    return ref
  }

  private static func refsMatch(_ actual: String?, _ expected: String) -> Bool {
    guard let actual = actual?.trimmingCharacters(in: .whitespacesAndNewlines),
      !actual.isEmpty,
      actual != "unspecified"
    else {
      return false
    }
    return actual == expected
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
      process.executableURL = URL(fileURLWithPath: envExecutablePath)
      process.arguments = [executable] + arguments
    }

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = error.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      let stderr = (String(bytes: errorData, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let stdout = (String(bytes: data, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let command = (["container"] + arguments).joined(separator: " ")
      let message = stderr.isEmpty ? stdout : stderr
      throw ContainerPackageCompatibilityError.commandFailed(
        message.isEmpty ? "\(command) failed" : message)
    }
    return data
  }

  private static func serviceGuidance(lane: String, detected: [String]) -> String {
    let formulae = homebrewFormulae(lane: lane)
    return """
      container-compose requires the matching stephenlclarke container system service to be running.

      The installed container components match this plugin, but the container system service is not ready.
      Start or restart the service, then run this command again.

        container system start

      For Homebrew-managed installs:

        brew postinstall \(formulae.container)
        brew services restart \(formulae.container)

      Detailed install instructions:
      \(installGuideURL)

      Detected service status:
      \(detected.map { "- \($0)" }.joined(separator: "\n"))
      """
  }

  private static func installGuidance(lane: String, detected: [String]) -> String {
    let formulae = homebrewFormulae(lane: lane)
    return """
      container-compose requires the matching stephenlclarke container stack.

      The installed container components do not match the Compose functionality in this plugin.
      Upgrade the corresponding components from stephenlclarke/tap, then run this command again.

        brew tap stephenlclarke/tap
        brew update
        brew upgrade \(formulae.container) \(formulae.compose) || brew install --formula \(formulae.compose)
        brew postinstall \(formulae.container)
        brew services restart \(formulae.container)

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
    if lane == "release" {
      return (
        "stephenlclarke/tap/container-release", "stephenlclarke/tap/container-compose-release"
      )
    }
    return ("stephenlclarke/tap/container", "stephenlclarke/tap/container-compose")
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

  var containerizationRef: String? {
    guard let containerization else {
      return nil
    }
    let parts = containerization.split(separator: "@", maxSplits: 1)
    guard parts.count == 2 else {
      return nil
    }
    return String(parts[1])
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
