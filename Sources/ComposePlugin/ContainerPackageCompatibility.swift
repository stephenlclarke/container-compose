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
// Keep the package graph wired to apple/container products that the plugin is
// expected to use as runtime integration matures.
@_exported import ContainerAPIClient
@_exported import ContainerBuild
@_exported import ContainerCommands
@_exported import ContainerLog
@_exported import ContainerResource
import Foundation

/// Retains the first host signal received while a preflight child is active.
private actor ContainerPackagePreflightSignalState {
  private var cancellationRequested = false
  private var commandTask: Task<CommandResult, Error>?
  private var result: CommandResult?
  private(set) var signal: String?

  func record(_ signal: String) {
    if self.signal == nil {
      self.signal = signal
    }
    cancel()
  }

  func attach(_ commandTask: Task<CommandResult, Error>) {
    self.commandTask = commandTask
    if cancellationRequested {
      commandTask.cancel()
    }
  }

  func complete(_ result: CommandResult) {
    self.result = result
    commandTask = nil
  }

  func cancel() {
    cancellationRequested = true
    commandTask?.cancel()
  }

  func completedResult() -> CommandResult? {
    result
  }
}

/// Validates that runtime-backed Compose commands are using the matching fork-backed stack.
enum ContainerPackageCompatibility {
  static let installGuideURLEnvironmentKey = "CONTAINER_COMPOSE_INSTALL_GUIDE_URL"
  static let containerExecutableEnvironmentKey = "CONTAINER_COMPOSE_CONTAINER"
  static let envExecutableEnvironmentKey = "CONTAINER_COMPOSE_ENV_EXECUTABLE"

  private static let maximumDiagnosticBytes = 64 * 1024
  private static let maximumCapturedOutputBytes = maximumDiagnosticBytes + 3
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
    run: ([String]) async throws -> Data = runContainerCommand
  ) async throws -> String? {
    guard requiresRuntimeCheck(arguments: arguments) else {
      return nil
    }

    do {
      let data = try await run(["system", "version", "--format", "json"])
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
        _ = try await run(["system", "status"])
      } catch let interruption as ContainerPackagePreflightInterruption {
        throw interruption
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return serviceGuidance(
          lane: lane,
          detected: [
            "container system status: \(error.localizedDescription)"
          ])
      }
      return nil
    } catch let interruption as ContainerPackagePreflightInterruption {
      throw interruption
    } catch is CancellationError {
      throw CancellationError()
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
    if let expectedContainerRef,
      let apiserver,
      !refsMatch(apiserver.commit, expectedContainerRef)
    {
      detected.append(
        "container-apiserver: \(apiserver.commit ?? "unknown") (expected \(expectedContainerRef))"
      )
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

  private static func runContainerCommand(arguments: [String]) async throws -> Data {
    let executable =
      ProcessInfo.processInfo.environment[containerExecutableEnvironmentKey] ?? "container"
    if executable.hasPrefix("/") {
      return try await captureCommand(
        executable: executable,
        arguments: arguments,
        displayArguments: ["container"] + arguments
      )
    }

    return try await captureCommand(
      executable: envExecutablePath,
      arguments: [executable] + arguments,
      displayArguments: ["container"] + arguments
    )
  }

  /// Runs one preflight command while draining both output streams concurrently.
  static func captureCommand(
    executable: String,
    arguments: [String],
    displayArguments: [String],
    signalProxy: ComposeSignalProxying = DispatchComposeSignalProxy()
  ) async throws -> Data {
    let result = try await captureCommandResult(
      executable: executable,
      arguments: arguments,
      signalProxy: signalProxy
    )
    guard result.succeeded else {
      let stderr = boundedDiagnostic(
        result.stderrData,
        omittedByteCount: result.stderrOmittedByteCount
      )
      let stdout = boundedDiagnostic(
        result.stdoutData,
        omittedByteCount: result.stdoutOmittedByteCount
      )
      let command = displayArguments.joined(separator: " ")
      let message = stderr.isEmpty ? stdout : stderr
      throw ContainerPackageCompatibilityError.commandFailed(
        message.isEmpty ? "\(command) failed" : message
      )
    }
    guard
      result.stdoutOmittedByteCount == 0,
      result.stdoutData.count <= maximumDiagnosticBytes
    else {
      let command = displayArguments.joined(separator: " ")
      let byteCount = result.stdoutData.count + result.stdoutOmittedByteCount
      throw ContainerPackageCompatibilityError.commandFailed(
        "\(command) returned \(byteCount) bytes; the preflight limit is \(maximumDiagnosticBytes)"
      )
    }
    return result.stdoutData
  }

  private static func captureCommandResult(
    executable: String,
    arguments: [String],
    signalProxy: ComposeSignalProxying
  ) async throws -> CommandResult {
    let signalState = ContainerPackagePreflightSignalState()
    do {
      return try await withTaskCancellationHandler {
        try await signalProxy.withSignalProxy(
          signals: ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"],
          handler: { signal in
            await signalState.record(signal)
          },
          operation: {
            let commandTask = Task {
              try await ProcessRunner().runCapturingOutputPrefix(
                executable,
                arguments,
                input: Data(),
                maximumOutputBytes: maximumCapturedOutputBytes
              )
            }
            await signalState.attach(commandTask)
            let result = try await commandTask.value
            await signalState.complete(result)
          }
        )
        if let signal = await signalState.signal {
          throw ContainerPackagePreflightInterruption(signal: signal)
        }
        guard let result = await signalState.completedResult() else {
          throw CancellationError()
        }
        return result
      } onCancel: {
        Task {
          await signalState.cancel()
        }
      }
    } catch is CancellationError {
      if let signal = await signalState.signal {
        throw ContainerPackagePreflightInterruption(signal: signal)
      }
      throw CancellationError()
    }
  }

  private static func boundedDiagnostic(_ data: Data, omittedByteCount: Int) -> String {
    data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      var rawStart: Int?
      var rawEnd: Int?
      var consumedRawEnd: Int?
      var rendered = ""
      var index = 0

      while index < bytes.count {
        let decoded = decodeUTF8Scalar(in: bytes, at: index)
        let unitEnd = index + decoded.length
        let isWhitespace = decoded.scalar?.properties.isWhitespace == true

        if rawStart == nil {
          if isWhitespace {
            index = unitEnd
            continue
          }
          rawStart = index
        }

        if !isWhitespace {
          rawEnd = unitEnd
        }

        if let rawStart, unitEnd - rawStart <= maximumDiagnosticBytes {
          rendered.append(contentsOf: decoded.scalar.map(String.init) ?? "\u{fffd}")
          consumedRawEnd = unitEnd
        }
        index = unitEnd
      }

      guard
        let rawEnd,
        let consumedRawEnd
      else {
        return ""
      }
      let sourceEnd = omittedByteCount == 0 ? rawEnd : data.count + omittedByteCount
      guard consumedRawEnd < sourceEnd else {
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let totalOmittedByteCount = sourceEnd - consumedRawEnd
      let byteLabel = totalOmittedByteCount == 1 ? "byte" : "bytes"
      return "\(rendered)\n[truncated \(totalOmittedByteCount) \(byteLabel)]"
    }
  }

  private static func decodeUTF8Scalar(
    in bytes: UnsafeBufferPointer<UInt8>,
    at index: Int
  ) -> (length: Int, scalar: Unicode.Scalar?) {
    let first = bytes[index]
    if first < 0x80 {
      return (1, Unicode.Scalar(first))
    }

    if first >= 0xc2, first <= 0xdf,
      hasContinuationBytes(1, in: bytes, after: index)
    {
      let value = UInt32(first & 0x1f) << 6
        | UInt32(bytes[index + 1] & 0x3f)
      return (2, Unicode.Scalar(value))
    }

    if first >= 0xe0, first <= 0xef,
      hasContinuationBytes(2, in: bytes, after: index)
    {
      let second = bytes[index + 1]
      let validSecond =
        (first == 0xe0 && second >= 0xa0)
        || (first == 0xed && second <= 0x9f)
        || (first != 0xe0 && first != 0xed)
      if validSecond {
        let value = UInt32(first & 0x0f) << 12
          | UInt32(second & 0x3f) << 6
          | UInt32(bytes[index + 2] & 0x3f)
        return (3, Unicode.Scalar(value))
      }
    }

    if first >= 0xf0, first <= 0xf4,
      hasContinuationBytes(3, in: bytes, after: index)
    {
      let second = bytes[index + 1]
      let validSecond =
        (first == 0xf0 && second >= 0x90)
        || (first == 0xf4 && second <= 0x8f)
        || (first != 0xf0 && first != 0xf4)
      if validSecond {
        let value = UInt32(first & 0x07) << 18
          | UInt32(second & 0x3f) << 12
          | UInt32(bytes[index + 2] & 0x3f) << 6
          | UInt32(bytes[index + 3] & 0x3f)
        return (4, Unicode.Scalar(value))
      }
    }
    // One malformed byte per unit keeps every replacement tied to an exact raw range.
    return (1, nil)
  }

  private static func hasContinuationBytes(
    _ count: Int,
    in bytes: UnsafeBufferPointer<UInt8>,
    after index: Int
  ) -> Bool {
    guard index + count < bytes.count else {
      return false
    }
    for offset in 1...count where bytes[index + offset] & 0xc0 != 0x80 {
      return false
    }
    return true
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

/// A host signal received while Compose owns an isolated preflight child.
struct ContainerPackagePreflightInterruption: Error {
  let signal: String

  var exitStatus: Int32 {
    switch signal {
    case "SIGHUP":
      129
    case "SIGINT":
      130
    case "SIGQUIT":
      131
    case "SIGTERM":
      143
    default:
      1
    }
  }
}
