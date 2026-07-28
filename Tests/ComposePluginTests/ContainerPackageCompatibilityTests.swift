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
import Foundation
import Testing

@testable import ComposePlugin

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private let appleSystemVersionJSON = """
  [
    {
      "appName": "container",
      "buildType": "release",
      "commit": "abc123",
      "containerization": "apple/containerization@main",
      "distribution": "apple",
      "source": "apple/container",
      "version": "0.5.0"
    }
  ]
  """

private let matchingSystemVersionJSON = """
  [
    {
      "appName": "container",
      "buildType": "release",
      "commit": "matched-container",
      "containerization": "stephenlclarke/containerization@matched-containerization",
      "distribution": "custom",
      "source": "stephenlclarke/container",
      "version": "homebrew-main"
    }
  ]
  """

@Suite("Container package compatibility")
struct ContainerPackageCompatibilityTests {
  @Test("runtime commands require installed stack check")
  func runtimeCommandsRequireInstalledStackCheck() {
    #expect(ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["up"]))
    #expect(ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["run", "api"]))
    #expect(ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["build", "api"]))
    #expect(ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["ps"]))
    #expect(
      ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["alpha", "scale", "api=2"]))
    #expect(
      ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["alpha", "watch", "api"]))

    #expect(!ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["version"]))
    #expect(!ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["config"]))
    #expect(!ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["up", "--dry-run"]))
    #expect(
      !ContainerPackageCompatibility.requiresRuntimeCheck(arguments: [
        "alpha", "dry-run", "--", "up", "api",
      ]))
    #expect(
      !ContainerPackageCompatibility.requiresRuntimeCheck(arguments: ["build", "--print", "api"]))
  }

  @Test("custom stephenlclarke stack passes compatibility check")
  func customStephenlclarkeStackPassesCompatibilityCheck() {
    let components = [
      ContainerSystemVersionComponent(
        appName: "container",
        buildType: "release",
        commit: "abc123",
        containerization: "stephenlclarke/containerization@main",
        distribution: "custom",
        source: "stephenlclarke/container",
        version: "homebrew-main"
      )
    ]

    #expect(
      ContainerPackageCompatibility.compatibilityFailure(components: components, lane: "main")
        == nil)
  }

  @Test("Apple stack reports install guidance")
  func appleStackReportsInstallGuidance() throws {
    let components = [
      ContainerSystemVersionComponent(
        appName: "container",
        buildType: "release",
        commit: "abc123",
        containerization: "apple/containerization@main",
        distribution: "apple",
        source: "apple/container",
        version: "0.5.0"
      )
    ]

    let message = try #require(
      ContainerPackageCompatibility.compatibilityFailure(components: components, lane: "main"))
    #expect(
      message.contains("container-compose requires the matching stephenlclarke container stack."))
    #expect(
      message.contains(
        "The installed container components do not match the Compose functionality in this plugin."
      ))
    #expect(
      message.contains(
        "brew upgrade stephenlclarke/tap/container stephenlclarke/tap/container-compose"
      ))
    #expect(message.contains("brew postinstall stephenlclarke/tap/container"))
    #expect(message.contains("brew services restart stephenlclarke/tap/container"))
    #expect(message.contains(ContainerPackageCompatibility.installGuideURL))
    #expect(message.contains("- container: stephenlclarke/container"))
    #expect(message.contains("- containerization: stephenlclarke/containerization"))
    #expect(message.contains("- container: apple/container (distribution: apple)"))
    #expect(message.contains("- containerization: apple/containerization@main"))
  }

  @Test("mismatched package pins report install guidance")
  func mismatchedPackagePinsReportInstallGuidance() throws {
    let components = [
      ContainerSystemVersionComponent(
        appName: "container",
        buildType: "release",
        commit: "new-container",
        containerization: "stephenlclarke/containerization@new-containerization",
        distribution: "custom",
        source: "stephenlclarke/container",
        version: "homebrew-main"
      )
    ]

    let message = try #require(
      ContainerPackageCompatibility.compatibilityFailure(
        components: components,
        lane: "main",
        expectedContainerRef: "old-container",
        expectedContainerizationRef: "old-containerization"
      ))
    #expect(
      message.contains("container-compose requires the matching stephenlclarke container stack."))
    #expect(
      message.contains(
        "- container: stephenlclarke/container@new-container (expected old-container)"))
    #expect(
      message.contains(
        "- containerization: stephenlclarke/containerization@new-containerization (expected old-containerization)"
      ))
    #expect(
      message.contains(
        "brew upgrade stephenlclarke/tap/container stephenlclarke/tap/container-compose"
      ))
  }

  @Test("single-row release system version can satisfy exact package pins")
  func singleRowReleaseSystemVersionCanSatisfyExactPackagePins() {
    let components = [
      ContainerSystemVersionComponent(
        appName: "container",
        buildType: "release",
        commit: "d03f81b4968d9f33914db1d77e00ce9f43178d00",
        containerization:
          "stephenlclarke/containerization@d8b9585a9855b1c0958d423a2d08b564eb6f8626",
        distribution: "custom",
        source: "stephenlclarke/container",
        version: "homebrew-main-114-d82fc5c24d48-1-gd03f81b"
      )
    ]

    #expect(
      ContainerPackageCompatibility.compatibilityFailure(
        components: components,
        lane: "main",
        expectedContainerRef: "d03f81b4968d9f33914db1d77e00ce9f43178d00",
        expectedContainerizationRef: "d8b9585a9855b1c0958d423a2d08b564eb6f8626"
      ) == nil)
  }

  @Test("stale API server reports install guidance")
  func staleAPIServerReportsInstallGuidance() throws {
    let components = [
      ContainerSystemVersionComponent(
        appName: "container",
        buildType: "release",
        commit: "matched-container",
        containerization: "stephenlclarke/containerization@matched-containerization",
        distribution: "custom",
        source: "stephenlclarke/container",
        version: "homebrew-main"
      ),
      ContainerSystemVersionComponent(
        appName: "container-apiserver",
        buildType: "release",
        commit: "stale-container",
        containerization: nil,
        distribution: nil,
        source: nil,
        version: "container-apiserver version stale-container"
      ),
    ]

    let message = try #require(
      ContainerPackageCompatibility.compatibilityFailure(
        components: components,
        lane: "main",
        expectedContainerRef: "matched-container",
        expectedContainerizationRef: "matched-containerization"
      ))
    #expect(
      message.contains(
        "container-apiserver: stale-container (expected matched-container)"))
  }

  @Test("release lane guidance points at release formulae")
  func releaseLaneGuidancePointsAtReleaseFormulae() throws {
    let message = try #require(
      ContainerPackageCompatibility.compatibilityFailure(components: [], lane: "release"))

    #expect(
      message.contains(
        "brew upgrade stephenlclarke/tap/container-release stephenlclarke/tap/container-compose-release"
      ))
    #expect(message.contains("matching release lane formula from stephenlclarke/tap"))
  }

  @Test("unavailable container command reports install guidance")
  func unavailableContainerCommandReportsInstallGuidance() async throws {
    let message = try #require(
      try await ContainerPackageCompatibility.compatibilityFailure(
        arguments: ["up"],
        lane: "main",
        run: { _ in
          throw ContainerPackageCompatibilityError.commandFailed("container: command not found")
        }
      )
    )

    #expect(
      message.contains("container-compose requires the matching stephenlclarke container stack."))
    #expect(message.contains("container: unavailable (container: command not found)"))
    #expect(message.contains(ContainerPackageCompatibility.installGuideURL))
  }
}

@Suite("Container system service readiness")
struct ContainerSystemServiceReadinessTests {
  @Test("package mismatch skips service readiness check")
  func packageMismatchSkipsServiceReadinessCheck() async throws {
    var calls: [[String]] = []

    let message = try #require(
      try await ContainerPackageCompatibility.compatibilityFailure(
        arguments: ["up"],
        lane: "main",
        run: { arguments in
          calls.append(arguments)
          return Data(appleSystemVersionJSON.utf8)
        }
      )
    )

    #expect(calls == [["system", "version", "--format", "json"]])
    #expect(message.contains("The installed container components do not match"))
  }

  @Test("stopped system service reports service readiness guidance")
  func stoppedSystemServiceReportsServiceReadinessGuidance() async throws {
    var calls: [[String]] = []

    let message = try #require(
      try await ContainerPackageCompatibility.compatibilityFailure(
        arguments: ["up"],
        lane: "main",
        expectedContainerRef: "matched-container",
        expectedContainerizationRef: "matched-containerization",
        run: { arguments in
          calls.append(arguments)
          if arguments == ["system", "status"] {
            throw ContainerPackageCompatibilityError.commandFailed(
              "apiserver is not running and not registered with launchd")
          }
          return Data(matchingSystemVersionJSON.utf8)
        }
      )
    )

    #expect(calls == [["system", "version", "--format", "json"], ["system", "status"]])
    #expect(
      message.contains(
        "container-compose requires the matching stephenlclarke container system service to be running."
      ))
    #expect(message.contains("The installed container components match this plugin"))
    #expect(message.contains("container system start"))
    #expect(message.contains("brew postinstall stephenlclarke/tap/container"))
    #expect(message.contains("brew services restart stephenlclarke/tap/container"))
    #expect(message.contains("container system status: apiserver is not running"))
    #expect(message.contains(ContainerPackageCompatibility.installGuideURL))
  }

  @Test("running system service passes runtime preflight")
  func runningSystemServicePassesRuntimePreflight() async throws {
    var calls: [[String]] = []

    let message = try await ContainerPackageCompatibility.compatibilityFailure(
      arguments: ["up"],
      lane: "main",
      expectedContainerRef: "matched-container",
      expectedContainerizationRef: "matched-containerization",
      run: { arguments in
        calls.append(arguments)
        if arguments == ["system", "status"] {
          return Data("apiserver is running\n".utf8)
        }
        return Data(matchingSystemVersionJSON.utf8)
      }
    )

    #expect(message == nil)
    #expect(calls == [["system", "version", "--format", "json"], ["system", "status"]])
  }

  @Test("version preflight preserves cancellation")
  func versionPreflightPreservesCancellation() async {
    await #expect(throws: CancellationError.self) {
      try await ContainerPackageCompatibility.compatibilityFailure(
        arguments: ["up"],
        lane: "main",
        run: { _ in
          throw CancellationError()
        }
      )
    }
  }

  @Test("service readiness preflight preserves cancellation")
  func serviceReadinessPreflightPreservesCancellation() async {
    await #expect(throws: CancellationError.self) {
      try await ContainerPackageCompatibility.compatibilityFailure(
        arguments: ["up"],
        lane: "main",
        expectedContainerRef: "matched-container",
        expectedContainerizationRef: "matched-containerization",
        run: { arguments in
          if arguments == ["system", "status"] {
            throw CancellationError()
          }
          return Data(matchingSystemVersionJSON.utf8)
        }
      )
    }
  }
}

@Suite("Container package preflight diagnostic priority")
struct PreflightDiagnosticPriorityTests {
  @Test("preflight failures retain stderr priority when its prefix is whitespace")
  func whitespacePrefixedFailureRetainsStandardErrorPriority() async {
    do {
      _ = try await ContainerPackageCompatibility.captureCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          """
          python3 - <<'PY'
          import os
          os.write(1, b"stdout fallback")
          os.write(2, b" " * 65539 + b"hidden stderr")
          PY
          exit 23
          """,
        ],
        displayArguments: ["container", "system", "version"]
      )
      Issue.record("Expected the preflight command to fail")
    } catch {
      #expect(error.localizedDescription == "[truncated 65552 bytes]")
    }
  }

  @Test("preflight diagnostic limit includes trimmed leading bytes")
  func failureTextBoundsUTF8FromRawStreamStart() async {
    do {
      _ = try await ContainerPackageCompatibility.captureCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          """
          python3 - <<'PY'
          import os
          os.write(2, b" " * 4 + b"e" * 65532 + "\\U0001f600".encode())
          PY
          exit 23
          """,
        ],
        displayArguments: ["container", "system", "version"]
      )
      Issue.record("Expected the preflight command to fail")
    } catch {
      let message = error.localizedDescription
      let renderedPrefix = message.split(separator: "\n", omittingEmptySubsequences: false)[0]
      #expect(renderedPrefix.utf8.count == 65_532)
      #expect(!message.contains("\u{fffd}"))
      #expect(message.hasSuffix("[truncated 4 bytes]"))
    }
  }
}

@Suite("Container package preflight process", .serialized)
struct ContainerPackagePreflightProcessTests {
  private struct PreflightMeasurement {
    let status: Int32
    let diagnostic: String
    let maximumResidentBytes: UInt64
  }

  @Test(
    "preflight drains oversized successful output before rejecting it",
    arguments: [65_537, 307_200]
  )
  func drainsLargeOutput(byteCount: Int) async throws {
    do {
      _ = try await ContainerPackageCompatibility.captureCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          """
          python3 - <<'PY'
          import os
          os.write(1, b"o" * \(byteCount))
          os.write(2, b"e" * \(byteCount))
          PY
          """,
        ],
        displayArguments: ["container", "system", "version"]
      )
      Issue.record("Expected oversized successful output to fail")
    } catch {
      #expect(
        error.localizedDescription
          == "container system version returned \(byteCount) bytes; the preflight limit is 65536"
      )
    }
  }

  @Test("preflight failures prefer stderr after draining both streams")
  func failureTextPrefersStandardError() async {
    do {
      _ = try await ContainerPackageCompatibility.captureCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "python3 -c 'import os; os.write(1, b\"o\" * 307200); os.write(2, b\"preferred stderr\")'; exit 23",
        ],
        displayArguments: ["container", "system", "version"]
      )
      Issue.record("Expected the preflight command to fail")
    } catch {
      #expect(error.localizedDescription == "preferred stderr")
    }
  }

  @Test("preflight failures bound large diagnostics after draining")
  func failureTextIsBounded() async {
    do {
      _ = try await ContainerPackageCompatibility.captureCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "python3 -c 'import os; os.write(2, b\"e\" * 307200)'; exit 23",
        ],
        displayArguments: ["container", "system", "version"]
      )
      Issue.record("Expected the preflight command to fail")
    } catch {
      let message = error.localizedDescription
      #expect(message.hasSuffix("[truncated 241664 bytes]"))
      #expect(message.utf8.count < 65_600)
    }
  }

  @Test("preflight bounds large diagnostics without per-byte retention")
  func failureTextScansLargeDiagnosticsIncrementally() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let fakeContainer = try makeLargeDiagnosticContainer(in: directory)
    let measurement = try measureLargeDiagnosticPreflight(
      fakeContainer: fakeContainer,
      directory: directory
    )

    #expect(measurement.status == 1)
    #expect(measurement.diagnostic.contains("[truncated 16711680 bytes]"))
    #expect(measurement.diagnostic.utf8.count < 67_000)
    #expect(measurement.maximumResidentBytes < 320 * 1024 * 1024)
  }

  private func makeLargeDiagnosticContainer(in directory: URL) throws -> URL {
    let executable = directory.appendingPathComponent("container")
    try """
    #!/bin/sh
    if [ "$*" = "system version --format json" ]; then
      python3 -c 'import os; os.write(2, b"e" * (16 * 1024 * 1024))'
      exit 23
    fi
    exit 2
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    return executable
  }

  private func measureLargeDiagnosticPreflight(
    fakeContainer: URL,
    directory: URL
  ) throws -> PreflightMeasurement {
    let metrics = directory.appendingPathComponent("time.txt")
    let stdout = directory.appendingPathComponent("stdout.txt")
    let stderr = directory.appendingPathComponent("stderr.txt")
    FileManager.default.createFile(atPath: stdout.path, contents: nil)
    FileManager.default.createFile(atPath: stderr.path, contents: nil)
    let stdoutHandle = try FileHandle(forWritingTo: stdout)
    let stderrHandle = try FileHandle(forWritingTo: stderr)
    defer {
      try? stdoutHandle.close()
      try? stderrHandle.close()
    }

    let composeExecutable = URL(fileURLWithPath: ".build/debug/compose")
    #expect(FileManager.default.isExecutableFile(atPath: composeExecutable.path))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/time")
    process.arguments = [
      "-l",
      "-o",
      metrics.path,
      composeExecutable.path,
      "ps",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["CONTAINER_COMPOSE_CONTAINER": fakeContainer.path]
    ) { _, new in new }
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    try process.run()
    process.waitUntilExit()
    try stdoutHandle.close()
    try stderrHandle.close()

    let diagnostic = try String(contentsOf: stderr, encoding: .utf8)
    let measurements = try String(contentsOf: metrics, encoding: .utf8)
    let residentLine = try #require(
      measurements.split(separator: "\n")
        .first { $0.contains("maximum resident set size") }
    )
    let residentBytes = try #require(
      UInt64(residentLine.split(whereSeparator: \.isWhitespace)[0])
    )
    return PreflightMeasurement(
      status: process.terminationStatus,
      diagnostic: diagnostic,
      maximumResidentBytes: residentBytes
    )
  }

  @Test("preflight diagnostic limit preserves UTF-8 scalar boundaries")
  func failureTextPreservesUTF8Boundaries() async {
    do {
      _ = try await ContainerPackageCompatibility.captureCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "python3 -c 'import os; os.write(2, b\"e\" * 65535 + \"é\".encode())'; exit 23",
        ],
        displayArguments: ["container", "system", "version"]
      )
      Issue.record("Expected the preflight command to fail")
    } catch {
      let message = error.localizedDescription
      #expect(message.hasSuffix("[truncated 2 bytes]"))
      #expect(!message.contains("\u{fffd}"))
    }
  }

  @Test("preflight diagnostic limit counts malformed raw bytes")
  func failureTextCountsMalformedRawBytes() async {
    do {
      _ = try await ContainerPackageCompatibility.captureCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "python3 -c 'import os; os.write(2, b\"\\xff\" + b\"e\" * 65536)'; exit 23",
        ],
        displayArguments: ["container", "system", "version"]
      )
      Issue.record("Expected the preflight command to fail")
    } catch {
      let message = error.localizedDescription
      #expect(message.hasPrefix("\u{fffd}"))
      #expect(message.hasSuffix("[truncated 1 byte]"))
      #expect(message.utf8.count < 65_600)
    }
  }

  @Test("cancelling a preflight terminates its child process")
  func cancellationTerminatesChild() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let pidFile = directory.appendingPathComponent("preflight.pid")
    let task = Task {
      try await ContainerPackageCompatibility.captureCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "printf '%s' \"$$\" > \"$1\"; trap '' TERM; while :; do :; done",
          "container-package-preflight",
          pidFile.path,
        ],
        displayArguments: ["container", "system", "version"]
      )
    }
    let processIdentifier = try await waitForPreflightProcessIdentifier(at: pidFile)
    let clock = ContinuousClock()
    let cancellationStarted = clock.now
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(clock.now - cancellationStarted < .seconds(2))
    errno = 0
    #expect(kill(processIdentifier, 0) == -1)
    #expect(errno == ESRCH)
  }

  @Test("preflight starts its child only after the signal proxy is active")
  func signalProxyPrecedesChildLaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let marker = directory.appendingPathComponent("preflight-started")
    let observation = PreflightProxyLaunchObservation()
    let data = try await ContainerPackageCompatibility.captureCommand(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "printf started > \"$1\"; printf ok",
        "container-package-preflight",
        marker.path,
      ],
      displayArguments: ["container", "system", "version"],
      signalProxy: DelayedPreflightSignalProxy(
        marker: marker,
        observation: observation
      )
    )

    #expect(data == Data("ok".utf8))
    #expect(await !observation.childStartedBeforeOperation)
    #expect(FileManager.default.fileExists(atPath: marker.path))
  }
}

private actor PreflightProxyLaunchObservation {
  private(set) var childStartedBeforeOperation = false

  func record(childStarted: Bool) {
    childStartedBeforeOperation = childStarted
  }
}

/// Delays its operation so a child created before proxy installation is observable.
private struct DelayedPreflightSignalProxy: ComposeSignalProxying {
  let marker: URL
  let observation: PreflightProxyLaunchObservation

  func withSignalProxy(
    signals _: [String],
    handler _: @escaping @Sendable (String) async -> Void,
    operation: @escaping @Sendable () async throws -> Void
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(200)
    while clock.now < deadline,
      !FileManager.default.fileExists(atPath: marker.path)
    {
      try await Task.sleep(for: .milliseconds(5))
    }
    await observation.record(
      childStarted: FileManager.default.fileExists(atPath: marker.path)
    )
    try await operation()
  }
}

@Suite("Container package preflight signals", .serialized)
struct ContainerPackagePreflightSignalTests {
  @Test("interrupting the CLI preflight terminates its child process")
  func interruptTerminatesChild() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let pidFile = directory.appendingPathComponent("preflight.pid")
    let fakeContainer = try makeInterruptibleContainer(in: directory)
    let process = try makeInterruptedPreflightProcess(
      fakeContainer: fakeContainer,
      pidFile: pidFile
    )
    defer {
      if process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
    }

    let preflightIdentifier = try await waitForPreflightProcessIdentifier(at: pidFile)
    defer {
      if kill(preflightIdentifier, 0) == 0 {
        _ = kill(-preflightIdentifier, SIGKILL)
      }
    }

    let clock = ContinuousClock()
    let interruptionStarted = clock.now
    guard kill(process.processIdentifier, SIGINT) == 0 else {
      throw ContainerPackagePreflightTestError.signalFailed
    }
    try await waitForPreflightCLIExit(process)

    #expect(clock.now - interruptionStarted < .seconds(2))
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 130)
    errno = 0
    #expect(kill(preflightIdentifier, 0) == -1)
    #expect(errno == ESRCH)
  }
}

/// Creates a fake runtime preflight that records its PID and ignores TERM.
private func makeInterruptibleContainer(in directory: URL) throws -> URL {
  let executable = directory.appendingPathComponent("container")
  try """
  #!/bin/sh
  if [ "$*" = "system version --format json" ]; then
    printf '%s' "$$" > "$CONTAINER_COMPOSE_PREFLIGHT_PID_FILE"
    trap '' TERM
    while :; do :; done
  fi
  exit 2
  """.write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: executable.path
  )
  return executable
}

/// Starts the real Compose CLI against an interruptible fake runtime.
private func makeInterruptedPreflightProcess(
  fakeContainer: URL,
  pidFile: URL
) throws -> Process {
  let composeExecutable = URL(fileURLWithPath: ".build/debug/compose")
  #expect(FileManager.default.isExecutableFile(atPath: composeExecutable.path))
  let process = Process()
  process.executableURL = composeExecutable
  process.arguments = ["ps"]
  process.environment = ProcessInfo.processInfo.environment.merging([
    "CONTAINER_COMPOSE_CONTAINER": fakeContainer.path,
    "CONTAINER_COMPOSE_PREFLIGHT_PID_FILE": pidFile.path,
  ]) { _, new in new }
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  return process
}

/// Waits for the preflight child to publish its PID before cancellation.
private func waitForPreflightProcessIdentifier(at pidFile: URL) async throws -> pid_t {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(3)
  while clock.now < deadline {
    if let data = FileManager.default.contents(atPath: pidFile.path),
      let value = String(data: data, encoding: .utf8),
      let processIdentifier = pid_t(value)
    {
      return processIdentifier
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw ContainerPackagePreflightTestError.pidFileTimedOut
}

/// Waits for an interrupted Compose CLI to finish child cleanup and exit.
private func waitForPreflightCLIExit(_ process: Process) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(3)
  while clock.now < deadline {
    if !process.isRunning {
      process.waitUntilExit()
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw ContainerPackagePreflightTestError.composeProcessTimedOut
}

private enum ContainerPackagePreflightTestError: Error {
  case composeProcessTimedOut
  case pidFileTimedOut
  case signalFailed
}
