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

@testable import ComposePlugin
import Foundation
import Testing

@Suite("Compiled runtime readiness")
struct CompiledRuntimeReadinessTests {
    @Test("backend follows the compiled provider")
    func compiledBackend() {
        #if CONTAINER_COMPOSE_ENHANCED_RUNTIME
            #expect(ContainerPackageCompatibility.compiledRuntimeBackend == .nativeAPI)
        #else
            #expect(ContainerPackageCompatibility.compiledRuntimeBackend == .engine)
        #endif
    }

    @Test("default production selection retains the compiled backend")
    func defaultProductionSelection() async throws {
        let selection = ContainerPackageCompatibility.RuntimeSelection()
        #expect(selection.profile == nil)
        #expect(selection.backend == ContainerPackageCompatibility.compiledRuntimeBackend)
        var calls: [[String]] = []
        let failure = try await ContainerPackageCompatibility.compatibilityFailure(
            arguments: ["up"], lane: "main",
            run: { arguments in
                calls.append(arguments)
                #if CONTAINER_COMPOSE_ENHANCED_RUNTIME
                    return try Self.versionData()
                #else
                    return try Self.versionData(mutation: "stock-client")
                #endif
            },
        )
        #expect(failure == nil)
        #if CONTAINER_COMPOSE_ENHANCED_RUNTIME
            #expect(calls == [["system", "version", "--format", "json"]])
        #else
            #expect(calls == [["system", "version", "--format", "json"], ["system", "status"]])
        #endif
    }

    @Test("native live API passes without a gateway and with nonconcrete package pins",
          arguments: [nil, "main", "unspecified", "780a86b995ac4cb0985db97f38875fdc6e33d16b"])
    func liveAPI(expected: String?) async throws {
        var calls: [[String]] = []
        let failure = try await ContainerPackageCompatibility.compatibilityFailure(
            arguments: ["up"], lane: "main",
            runtimeSelection: .init(profile: .enhanced, backend: .nativeAPI),
            expectedRevisions: .init(container: expected),
            run: { arguments in
                calls.append(arguments)
                #expect(arguments == ["system", "version", "--format", "json"])
                return try Self.versionData()
            },
        )
        #expect(failure == nil)
        #expect(calls == [["system", "version", "--format", "json"]])
    }

    @Test("native fails closed on missing duplicate malformed or mismatched live identity",
          arguments: ["missing", "duplicate-server", "duplicate-client", "wrong-commit",
                      "nil-commit", "empty-commit", "unknown-commit", "unspecified-commit",
                      "both-nil-commits", "both-empty-commits", "both-unknown-commits",
                      "both-main-commits", "both-arbitrary-commits", "both-whitespace-commits",
                      "both-malformed-hex-commits",
                      "missing-version", "empty-version", "unknown-version", "missing-build",
                      "wrong-build", "malformed-json", "malformed-commit"])
    func rejectsInvalidLiveAPI(mutation: String) async throws {
        var calls: [[String]] = []
        let failure = try await ContainerPackageCompatibility.compatibilityFailure(
            arguments: ["up"], lane: "main", runtimeSelection: .init(profile: .enhanced, backend: .nativeAPI),
            run: { arguments in
                calls.append(arguments)
                return try Self.versionData(mutation: mutation)
            },
        )
        #expect(failure != nil)
        #expect(calls == [["system", "version", "--format", "json"]])
    }

    @Test("native preserves client provenance capability and exact package pins",
          arguments: ["wrong-source", "wrong-distribution", "wrong-containerization",
                      "missing-capabilities", "wrong-schema", "wrong-pin"])
    func preservesPackageAdmission(mutation: String) async throws {
        let failure = try await ContainerPackageCompatibility.compatibilityFailure(
            arguments: ["up"], lane: "main", runtimeSelection: .init(profile: .enhanced, backend: .nativeAPI),
            expectedRevisions: .init(
                container: "780a86b995ac4cb0985db97f38875fdc6e33d16b",
                containerization: "matched-containerization",
            ),
            run: { _ in try Self.versionData(mutation: mutation) },
        )
        #expect(failure != nil)
    }

    @Test("stock profile cannot change native readiness or admit Apple metadata")
    func stockProfileCannotChangeNativeBackend() async throws {
        let failure = try await ContainerPackageCompatibility.compatibilityFailure(
            arguments: ["up"], lane: "main", runtimeSelection: .init(profile: .stock, backend: .nativeAPI),
            run: { _ in try Self.versionData(mutation: "wrong-source") },
        )
        #expect(failure?.contains("stock cannot select the compiled native API backend") == true)
    }

    @Test("offline commands skip every backend check", arguments: [["config"], ["version"], ["--dry-run", "up"], ["build", "--print"]])
    func offlineCommands(arguments: [String]) async throws {
        let failure = try await ContainerPackageCompatibility.compatibilityFailure(
            arguments: arguments, lane: "main", runtimeSelection: .init(profile: .stock, backend: .nativeAPI),
            run: { _ in
                Issue.record("Offline command must not query runtime")
                throw CancellationError()
            },
        )
        #expect(failure == nil)
    }

    @Test("native health command propagates cancellation")
    func propagatesCancellation() async {
        await #expect(throws: CancellationError.self) {
            try await ContainerPackageCompatibility.compatibilityFailure(
                arguments: ["up"], lane: "main", runtimeSelection: .init(profile: .enhanced, backend: .nativeAPI),
                run: { _ in throw CancellationError() },
            )
        }
    }

    @Test("native health command propagates host signal")
    func propagatesSignal() async {
        do {
            _ = try await ContainerPackageCompatibility.compatibilityFailure(
                arguments: ["up"], lane: "main", runtimeSelection: .init(profile: .enhanced, backend: .nativeAPI),
                run: { _ in throw ContainerPackagePreflightInterruption(signal: "SIGINT") },
            )
            Issue.record("Expected host signal propagation")
        } catch let interruption as ContainerPackagePreflightInterruption {
            #expect(interruption.exitStatus == 130)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func versionData(mutation: String = "") throws -> Data {
        var client: [String: Any] = [
            "appName": "container", "commit": "780a86b995ac4cb0985db97f38875fdc6e33d16b", "buildType": "release",
            "version": "homebrew-main", "source": "stephenlclarke/container", "distribution": "custom",
            "containerization": "stephenlclarke/containerization@matched-containerization",
            "runtimeCapabilitySchemaVersion": ComposeRuntimeCapabilityManifest.required.schemaVersion,
            "runtimeCapabilities": ComposeRuntimeCapabilityManifest.required.identifiers,
        ]
        var server: [String: Any] = [
            "appName": "container-apiserver", "commit": "780a86b995ac4cb0985db97f38875fdc6e33d16b",
            "buildType": "release", "version": "1.4.1",
        ]
        mutate(client: &client, server: &server, mutation: mutation)
        if mutation == "malformed-json" {
            return Data("{broken".utf8)
        }
        var rows = [client, server]
        if mutation == "missing" {
            rows = [client]
        }
        if mutation == "duplicate-server" {
            rows.append(server)
        }
        if mutation == "duplicate-client" {
            rows.append(client)
        }
        return try JSONSerialization.data(withJSONObject: rows)
    }

    // Mutation table intentionally covers malformed wire representations at one fixture boundary.
    // swiftlint:disable:next cyclomatic_complexity
    private static func mutate(client: inout [String: Any], server: inout [String: Any], mutation: String) {
        switch mutation {
        case "wrong-commit": server["commit"] = "880a86b995ac4cb0985db97f38875fdc6e33d16b"
        case "nil-commit": server.removeValue(forKey: "commit")
        case "empty-commit": server["commit"] = " "
        case "unknown-commit": server["commit"] = "unknown"
        case "unspecified-commit": server["commit"] = "unspecified"
        case "both-nil-commits": client.removeValue(forKey: "commit"); server.removeValue(forKey: "commit")
        case "both-empty-commits": client["commit"] = " "; server["commit"] = " "
        case "both-unknown-commits": client["commit"] = "unknown"; server["commit"] = "unknown"
        case "both-main-commits":
            client["commit"] = "main"; server["commit"] = "main"
        case "both-arbitrary-commits":
            client["commit"] = "not-a-commit"; server["commit"] = "not-a-commit"
        case "both-whitespace-commits":
            client["commit"] = " 780a86b995ac4cb0985db97f38875fdc6e33d16b "
            server["commit"] = client["commit"]
        case "both-malformed-hex-commits":
            client["commit"] = "g80a86b995ac4cb0985db97f38875fdc6e33d16b"; server["commit"] = client["commit"]
        case "missing-version": server.removeValue(forKey: "version")
        case "empty-version": server["version"] = " "
        case "unknown-version": server["version"] = "unknown"
        case "missing-build": server.removeValue(forKey: "buildType")
        case "wrong-build": server["buildType"] = "invalid"
        case "malformed-commit": server["commit"] = 123
        case "stock-client":
            client["source"] = "apple/container"
            client["distribution"] = "apple"
            client["containerization"] = "apple/containerization@stock-containerization"
        case "wrong-source": client["source"] = "apple/container"
        case "wrong-distribution": client["distribution"] = "apple"
        case "wrong-containerization": client["containerization"] = "apple/containerization@matched-containerization"
        case "missing-capabilities": client["runtimeCapabilities"] = [] as [String]
        case "wrong-schema": client["runtimeCapabilitySchemaVersion"] = 999
        case "wrong-pin":
            client["commit"] = "880a86b995ac4cb0985db97f38875fdc6e33d16b"
            server["commit"] = client["commit"]
        default: break
        }
    }

}
