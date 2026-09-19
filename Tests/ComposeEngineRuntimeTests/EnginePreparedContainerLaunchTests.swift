// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
@testable import ComposeEngineRuntime
import ComposeRuntimeSPI
import ContainerEngineWire
import Foundation
import Testing

struct EnginePreparedContainerLaunchTests {
    @Test(arguments: [ComposeRuntimeContainerLaunchCommand.create, .run])
    func preparedLaunchUsesGatewayIdentity(_ command: ComposeRuntimeContainerLaunchCommand) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(PreparedLaunchResponder(recorder: recorder))
        try await server.start()
        do {
            let runner = RecordingRunner()
            let provider = EngineRuntimeProvider(socketPath: fixture.socketPath, runner: runner)
            let plan = preparedPlan()
            let status = try await provider.launchContainer(.init(
                command: command, arguments: ["deliberately-not-a-cli-request"], logging: plan.logging,
                configuration: plan
            ))
            #expect(status == 0)
            #expect(runner.commands.isEmpty)
            let calls = await recorder.requests
            #expect(calls.count == (command == .create ? 3 : 4))
            #expect(calls[0].method == .get)
            let create = calls[2]
            #expect(create.target.contains("name=app"))
            let query = URLComponents(string: create.target)?.queryItems
            #expect(query?.first { $0.name == "platform" }?.value == "linux/arm64")
            let object = try #require(JSONSerialization.jsonObject(with: create.body) as? [String: Any])
            #expect(object["Image"] as? String == plan.imageSelection?.reference)
            #expect(object["ContainerImageReference"] as? String == "fixture:mutable")
            #expect(object["StopTimeout"] as? Int == 7)
            #expect(object["Cmd"] as? [String] == ["/bin/true"])
            if command == .run {
                #expect(calls[3].target == "/v1.53/containers/created-id/start")
            }
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test(arguments: ["foreground", "logging", "name"])
    func invalidLaunchFailsBeforeRequest(_ reason: String) async throws {
        let runner = RecordingRunner()
        let provider = EngineRuntimeProvider(socketPath: "/unused", runner: runner)
        var plan = preparedPlan()
        if reason == "foreground" { plan.detach = false }
        if reason == "name" { plan.name = "" }
        let logging = reason == "logging" ? ComposeLogConfiguration(driver: "none") : plan.logging
        await #expect(throws: ComposeError.self) {
            try await provider.launchContainer(.init(
                command: .run, arguments: [], logging: logging, configuration: plan
            ))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test(arguments: [400, 500])
    func createFailureDoesNotStartOrFallback(_ status: Int) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(PreparedLaunchResponder(recorder: recorder, createStatus: status))
        try await server.start()
        let runner = RecordingRunner()
        await #expect(throws: (any Error).self) {
            try await EngineRuntimeProvider(socketPath: fixture.socketPath, runner: runner).launchContainer(.init(
                command: .run, arguments: [], logging: .standard, configuration: preparedPlan()
            ))
        }
        #expect(await recorder.requests.count == 3)
        #expect(runner.commands.isEmpty)
        try await server.shutdown()
    }

    @Test(arguments: ["empty-id", "start-failure"])
    func partialLaunchDoesNotRetryOrDelete(_ failure: String) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(PreparedLaunchResponder(
            recorder: recorder, containerID: failure == "empty-id" ? "" : "created-id", startStatus: 500
        ))
        try await server.start()
        let runner = RecordingRunner()
        await #expect(throws: (any Error).self) {
            try await EngineRuntimeProvider(socketPath: fixture.socketPath, runner: runner).launchContainer(.init(
                command: .run, arguments: [], logging: .standard, configuration: preparedPlan()
            ))
        }
        let requests = await recorder.requests
        #expect(requests.count == (failure == "empty-id" ? 3 : 4))
        #expect(requests.allSatisfy { $0.method != .delete })
        #expect(runner.commands.isEmpty)
        try await server.shutdown()
    }

    @Test(arguments: ["0", "2"])
    func oldOrUnknownGatewayRefusedBeforeImageSelection(_ capability: String) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let recorder = RequestRecorder()
        let server = fixture.server(PreparedLaunchResponder(recorder: recorder, capability: capability))
        try await server.start()
        let runner = RecordingRunner()
        await #expect(throws: ComposeError.self) {
            try await EngineRuntimeProvider(socketPath: fixture.socketPath, runner: runner).launchContainer(.init(
                command: .create, arguments: [], logging: .standard, configuration: preparedPlan()
            ))
        }
        #expect(await recorder.requests.count == 1)
        #expect(runner.commands.isEmpty)
        try await server.shutdown()
    }

    private func preparedPlan() -> ContainerServiceCreatePlan {
        var plan = ContainerServiceCreatePlan(identity: .init(name: "app", imageReference: "fixture:mutable"))
        plan.imageSelection = .init(reference: "sha256:" + String(repeating: "a", count: 64), platform: "linux/arm64")
        plan.resolvedMounts = []
        plan.publishedPorts = []
        plan.detach = true
        plan.launchOptions.stopTimeoutSeconds = 7
        return plan
    }
}

private struct PreparedLaunchResponder: DockerHTTPResponder {
    let recorder: RequestRecorder
    var createStatus = 201
    var containerID = "created-id"
    var startStatus = 204
    var capability = "1"

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        await recorder.append(request)
        let body: String
        let status: Int
        if request.target == "/v1.53/version" {
            status = 200
            body = "{\"Components\":[{\"Name\":\"Engine\",\"Details\":{\"ContainerImageReference\":\"\(capability)\"}}]}"
        } else if request.method == .get {
            status = 200
            body = """
            {"Id":"sha256:\(String(repeating: "a", count: 64))","RepoTags":[],"RepoDigests":[],
            "Architecture":"arm64","Os":"linux","Config":{"Cmd":["/bin/true"]}}
            """
        } else if request.target.contains("/create?") {
            status = createStatus
            body = createStatus == 201 ? "{\"Id\":\"\(containerID)\",\"Warnings\":[]}" : #"{"message":"rejected"}"#
        } else {
            status = startStatus
            body = startStatus == 204 ? "" : #"{"message":"start failed"}"#
        }
        return .init(status: status, headers: ["Content-Type": "application/json"], body: .bytes(Data(body.utf8)))
    }
}
