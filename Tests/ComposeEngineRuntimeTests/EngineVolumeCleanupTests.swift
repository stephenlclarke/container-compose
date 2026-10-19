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
import ContainerUnixHTTPServer
import Foundation
import Testing

@Suite("Engine volume cleanup", .serialized)
struct EngineVolumeCleanupTests {
    @Test("missing volume is absent only when inventory confirms it")
    func repeatedDelete() async throws {
        try await check(mode: "absent", succeeds: true)
    }

    @Test("successful delete does not need an inventory query")
    func successfulDelete() async throws {
        try await check(mode: "success", succeeds: true)
    }

    @Test("cleanup preserves existing, forbidden and unavailable failures",
          arguments: ["existing", "forbidden", "delete-unavailable", "unavailable", "malformed"])
    func failure(mode: String) async throws {
        try await check(mode: mode, succeeds: false)
    }

    private func check(mode: String, succeeds: Bool) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let responder = VolumeCleanupResponder(mode: mode)
        let server = fixture.server(responder)
        try await server.start()
        let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
        do {
            try await provider.deleteVolume(name: "owned_state")
            #expect(succeeds)
        } catch {
            #expect(!succeeds)
        }
        let targets = await responder.targets
        #expect(targets.first == "DELETE /v1.53/volumes/owned_state")
        if ["success", "forbidden", "delete-unavailable"].contains(mode) {
            #expect(targets.count == 1)
        }
        try await server.shutdown()
    }
}

private actor VolumeCleanupResponder: DockerHTTPResponder {
    let mode: String
    var targets: [String] = []
    init(mode: String) {
        self.mode = mode
    }

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        targets.append("\(request.method.rawValue) \(request.target)")
        if request.method == .delete {
            if mode == "success" {
                return .empty(status: 204)
            }
            if mode == "delete-unavailable" {
                return json(503, #"{"message":"unavailable"}"#)
            }
            return json(mode == "forbidden" ? 403 : 404,
                        #"{"message":"managed volume owned_state was not found"}"#)
        }
        if mode == "unavailable" {
            return json(503, #"{"message":"unavailable"}"#)
        }
        if mode == "malformed" {
            return json(200, "invalid")
        }
        let volume = #"{"Driver":"local","Labels":{},"Mountpoint":"/owned","Name":"owned_state","Options":{}}"#
        return json(200, mode == "existing" ? "{\"Volumes\":[\(volume)]}" : #"{"Volumes":[]}"#)
    }

    private func json(_ status: Int, _ body: String) -> DockerHTTPResponse {
        DockerHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: .bytes(Data(body.utf8)))
    }
}
