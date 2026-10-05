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
@testable import ComposeEngineRuntime
import ComposeRuntimeSPI
import ContainerEngineWire
import ContainerUnixHTTPClient
import ContainerUnixHTTPServer
import Foundation
import Testing

@Suite("Engine owned-container cleanup", .serialized)
struct EngineContainerCleanupTests {
    @Test("down completes when its owned container already auto-removed")
    func missingOwnedTarget() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let responder = CleanupResponder(mode: "missing", failingOperation: "stop")
        let server = fixture.server(responder)
        try await server.start()
        do {
            let dependencies = ComposeEngineRuntime.dependencies(environment: [
                ComposeEngineRuntime.socketEnvironmentVariable: fixture.socketPath,
            ])
            let orchestrator = ComposeOrchestrator(dependencies: dependencies)
            let project = ComposeProject(name: "owned", services: ["app": ComposeService(name: "app", image: "alpine")])
            try await orchestrator.down(project: project, options: ComposeDownOptions())
            let requests = await responder.requests
            #expect(requests.contains("POST /v1.53/containers/owned-app-1/stop"))
            #expect(requests.contains("DELETE /v1.53/containers/owned-app-1?force=0&v=1"))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test("cleanup rejects other failures and mismatched missing identities",
          arguments: ["stop", "delete"], ["wrong-target", "malformed", "forbidden", "conflict", "unavailable"])
    func preservesFailures(operation: String, mode: String) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let server = fixture.server(CleanupResponder(mode: mode, failingOperation: operation))
        try await server.start()
        let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
        do {
            await #expect(throws: ContainerUnixHTTPClientError.self) {
                if operation == "stop" {
                    try await provider.stopContainer(id: "owned-app-1", signal: nil, timeoutInSeconds: nil)
                } else {
                    try await provider.deleteContainer(id: "owned-app-1", force: false)
                }
            }
        }
        try await server.shutdown()
    }

    @Test("ordinary start preserves matching not-found errors")
    func startStillFails() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let server = fixture.server(CleanupResponder(mode: "missing", failingOperation: "start"))
        try await server.start()
        let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
        await #expect(throws: ContainerUnixHTTPClientError.self) {
            try await provider.startContainer(id: "owned-app-1")
        }
        try await server.shutdown()
    }
}

private actor CleanupResponder: DockerHTTPResponder {
    let mode: String
    let failingOperation: String
    var requests: [String] = []

    init(mode: String, failingOperation: String) {
        self.mode = mode
        self.failingOperation = failingOperation
    }

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        requests.append("\(request.method.rawValue) \(request.target)")
        if request.target.hasPrefix("/v1.53/containers/json") {
            return json(status: 200, body: "[]")
        }
        if request.target.hasPrefix("/v1.53/networks/") {
            return .empty(status: 204)
        }
        let operation = request.method == .delete ? "delete" : request.target.components(separatedBy: "/").last ?? ""
        let selectedMode = operation == failingOperation ? mode : "missing"
        let status: Int
        let message: String
        switch selectedMode {
        case "wrong-target": status = 404; message = "container foreign-app-1 was not found"
        case "malformed": status = 404; message = "unknown route"
        case "forbidden": status = 403; message = "container owned-app-1 was not found"
        case "conflict": status = 409; message = "container owned-app-1 was not found"
        case "unavailable": status = 500; message = "container owned-app-1 was not found"
        default: status = 404; message = "container owned-app-1 was not found"
        }
        return json(status: status, body: "{\"message\":\"\(message)\"}")
    }

    private func json(status: Int, body: String) -> DockerHTTPResponse {
        DockerHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: .bytes(Data(body.utf8)))
    }
}
