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

@testable import ComposeEngineRuntime
import ContainerEngineWire
import ContainerUnixHTTPClient
import ContainerUnixHTTPServer
import Foundation
import Testing

@Suite("Engine network lifecycle", .serialized)
struct EngineNetworkLifecycleTests {
    @Test("repeated create reuses only the matching owned network")
    func repeatedCreate() async throws {
        try await check(mode: "owned", operation: "create", succeeds: true)
    }

    @Test("same owned network survives generated Compose file provenance changes")
    func changedFileProvenance() async throws {
        try await check(mode: "provenance", operation: "create", succeeds: true)
    }

    @Test("repeated delete succeeds only after inventory proves absence")
    func repeatedDelete() async throws {
        try await check(mode: "absent", operation: "delete", succeeds: true)
    }

    @Test("create refuses foreign, ambiguous and malformed identities",
          arguments: ["foreign", "network", "directory", "custom", "internal", "ambiguous", "malformed", "absent", "unavailable"])
    func preserveCreateFailures(mode: String) async throws {
        try await check(mode: mode, operation: "create", succeeds: false)
    }

    @Test("delete refuses ambiguous and malformed identities",
          arguments: ["owned", "ambiguous", "malformed", "unavailable", "forbidden"])
    func preserveDeleteFailures(mode: String) async throws {
        try await check(mode: mode, operation: "delete", succeeds: false)
    }

    private func check(mode: String, operation: String, succeeds: Bool) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let responder = NetworkLifecycleResponder(mode: mode)
        let server = fixture.server(responder)
        try await server.start()
        let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
        do {
            if operation == "create" {
                try await provider.createNetwork(.init(
                    name: "owned_default",
                    labels: [
                        "com.apple.container.compose.project": "owned",
                        "com.apple.container.compose.network": "default",
                        "com.apple.container.compose.project.working-directory": "/owned/workspace",
                        "com.apple.container.compose.version": "1",
                        "user.owner": "expected",
                        "com.apple.container.compose.project.config-files": "compose.yaml",
                        "com.apple.container.compose.project.config-files-hash": "one-file",
                    ],
                ))
            } else {
                try await provider.deleteNetwork(id: "owned_default")
            }
            #expect(succeeds)
        } catch {
            #expect(!succeeds)
        }
        let targets = await responder.targets
        if mode == "absent", operation == "delete" {
            #expect(targets == ["DELETE /v1.53/networks/owned_default", "GET /v1.53/networks"])
        }
        try await server.shutdown()
    }
}

private actor NetworkLifecycleResponder: DockerHTTPResponder {
    let mode: String
    var targets: [String] = []
    init(mode: String) {
        self.mode = mode
    }

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        targets.append("\(request.method.rawValue) \(request.target)")
        if request.method == .delete {
            return json(mode == "forbidden" ? 403 : 404, #"{"message":"network reference is missing or ambiguous"}"#)
        }
        if request.method == .post {
            return json(409, #"{"message":"network already exists"}"#)
        }
        if mode == "unavailable" {
            return json(503, #"{"message":"unavailable"}"#)
        }
        let id = mode == "malformed" ? "" : "network-generation"
        let changedProvenance = ["provenance", "foreign", "network", "directory", "custom", "internal"].contains(mode)
        let workingDirectory = mode == "directory" ? "/foreign" : "/owned/workspace"
        let configFiles = changedProvenance ? "compose.yaml,generated.yml" : "compose.yaml"
        let labels = [
            "com.apple.container.compose.project": mode == "foreign" ? "foreign" : "owned",
            "com.apple.container.compose.network": mode == "network" ? "foreign" : "default",
            "com.apple.container.compose.project.working-directory": workingDirectory,
            "com.apple.container.compose.version": "1",
            "user.owner": mode == "custom" ? "foreign" : "expected",
            "com.apple.container.compose.project.config-files": configFiles,
            "com.apple.container.compose.project.config-files-hash": changedProvenance ? "two-files" : "one-file",
        ]
        let row: [String: Any] = [
            "Id": id, "Name": "owned_default", "Labels": labels, "Internal": mode == "internal",
        ]
        let rows = mode == "absent" ? [] : mode == "ambiguous" ? [row, row] : [row]
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let body = String(data: data, encoding: .utf8)
        else { return .empty(status: 500) }
        return json(200, body)
    }

    private func json(_ status: Int, _ body: String) -> DockerHTTPResponse {
        DockerHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: .bytes(Data(body.utf8)))
    }
}
