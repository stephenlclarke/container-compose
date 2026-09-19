// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
@testable import ComposeEngineRuntime
import ComposeRuntimeSPI
import ContainerEngineWire
import Foundation
import Testing

struct EngineServiceImageSelectionTests {
    private let imageID = "sha256:" + String(repeating: "a", count: 64)

    @Test(arguments: ["linux/amd64", "linux/arm64/v7"])
    func preparedSelectionMustStillMatchRequestedPlatform(_ platform: String) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(ServiceImageResponder(recorder: recorder, firstID: imageID, selectedID: imageID))
        try await server.start()
        var plan = preparedPlan()
        plan.imageSelection = .init(reference: imageID, platform: "linux/arm64")
        plan.launchOptions.platform = platform
        await #expect(throws: ComposeError.self) {
            try await EngineRuntimeProvider(socketPath: fixture.socketPath).preparedServiceCreateRequest(plan)
        }
        #expect(await recorder.requests.count == 1)
        try await server.shutdown()
    }

    @Test func preparedSelectionNeverReopensTheMutableTag() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(ServiceImageResponder(
            recorder: recorder, firstID: "sha256:" + String(repeating: "b", count: 64), selectedID: imageID
        ))
        try await server.start()
        do {
            var plan = preparedPlan()
            plan.imageSelection = .init(reference: imageID, platform: "linux/arm64")
            let request = try await EngineRuntimeProvider(socketPath: fixture.socketPath)
                .preparedServiceCreateRequest(plan)
            #expect(request.imageReference == imageID)
            #expect(request.process.command == ["/selected-by-id"])
            let requests = await recorder.requests
            #expect(requests.count == 1)
            #expect(requests[0].target.contains("sha256"))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test(arguments: [nil, "", "linux/arm64"] as [String?])
    func freezesImageIdentityWithoutMutatingTags(_ platform: String?) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(ServiceImageResponder(recorder: recorder, firstID: imageID, selectedID: imageID))
        try await server.start()
        do {
            let provider = EngineRuntimeProvider(socketPath: fixture.socketPath)
            var plan = preparedPlan()
            plan.launchOptions.platform = platform
            let request = try await provider.preparedServiceCreateRequest(plan)
            #expect(request.plan.imageReference == "fixture:mutable")
            #expect(request.imageReference == imageID)
            #expect(request.process.command == ["/selected-by-id"])
            let data = try JSONEncoder().encode(request)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["Image"] as? String == imageID)
            let calls = await recorder.requests
            #expect(calls.count == 2)
            #expect(calls.allSatisfy { $0.method == .get })
            #expect(calls[1].target.contains(provider.escaped(imageID)))
            #expect(calls[1].target.contains("platform="))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test(arguments: ["sha256:short", "sha256:" + String(repeating: "b", count: 64)])
    func mismatchedOrMalformedIdentityCannotPrepareCreate(_ selectedID: String) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let malformed = selectedID == "sha256:short"
        let server = fixture.server(ServiceImageResponder(
            recorder: recorder, firstID: malformed ? selectedID : imageID, selectedID: selectedID
        ))
        try await server.start()
        await #expect(throws: ComposeError.self) {
            try await EngineRuntimeProvider(socketPath: fixture.socketPath).preparedServiceCreateRequest(preparedPlan())
        }
        #expect(await recorder.requests.count == (malformed ? 1 : 2))
        try await server.shutdown()
    }

    @Test(arguments: ["", "sha256:short", "sha256:" + String(repeating: "A", count: 64),
                      "sha256:" + String(repeating: "a", count: 65)])
    func rejectsMalformedIDsAtTheEncodingBoundary(_ value: String) throws {
        let image = try JSONDecoder().decode(EngineImageConfig.self, from: Data(#"{"Cmd":["/bin/true"]}"#.utf8))
        #expect(throws: ComposeError.self) {
            try EngineServiceCreateRequest(plan: preparedPlan(), image: image, resolvedImageID: value)
        }
    }

    @Test(arguments: ["linux/amd64", "linux/arm64/v7", "invalid"])
    func mismatchedPlatformCannotPrepareCreate(_ platform: String) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(ServiceImageResponder(recorder: recorder, firstID: imageID, selectedID: imageID))
        try await server.start()
        var plan = preparedPlan()
        plan.launchOptions.platform = platform
        await #expect(throws: ComposeError.self) {
            try await EngineRuntimeProvider(socketPath: fixture.socketPath).preparedServiceCreateRequest(plan)
        }
        #expect(await recorder.requests.count == (platform == "invalid" ? 0 : 1))
        try await server.shutdown()
    }

    private func preparedPlan() -> ContainerServiceCreatePlan {
        var plan = ContainerServiceCreatePlan(identity: .init(name: "app", imageReference: "fixture:mutable"))
        plan.resolvedMounts = []
        plan.publishedPorts = []
        return plan
    }
}

private struct ServiceImageResponder: DockerHTTPResponder {
    let recorder: RequestRecorder
    let firstID: String
    let selectedID: String

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        await recorder.append(request)
        let byID = request.target.contains("sha256")
        let object: [String: Any] = [
            "Id": byID ? selectedID : firstID, "RepoTags": ["fixture:mutable"], "RepoDigests": [],
            "Architecture": "arm64", "Os": "linux", "Variant": "", "Config": [
                "Cmd": [byID ? "/selected-by-id" : "/mutable-tag-metadata"],
            ],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return DockerHTTPResponse(
                status: 200, headers: ["Content-Type": "application/json"], body: .bytes(data)
            )
        } catch {
            return .empty(status: 500)
        }
    }
}
