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

@Suite("Container package preflight process", .serialized)
struct ContainerPackagePreflightProcessTests {
  @Test("preflight drains large stdout and stderr while the command runs")
  func drainsLargeOutput() async throws {
    let data = try await ContainerPackageCompatibility.captureCommand(
      executable: "/bin/sh",
      arguments: [
        "-c",
        """
        python3 - <<'PY'
        import os
        os.write(1, b"o" * 307200)
        os.write(2, b"e" * 307200)
        PY
        """,
      ],
      displayArguments: ["container", "system", "version"]
    )

    #expect(data.count == 307_200)
    #expect(data.allSatisfy { $0 == UInt8(ascii: "o") })
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

private enum ContainerPackagePreflightTestError: Error {
  case pidFileTimedOut
}
