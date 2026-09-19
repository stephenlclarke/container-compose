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
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct EngineForegroundLaunchTests {
    @Test
    func missingExitCapabilityRefusesBeforeCreation() async throws {
        try await withFixture(failure: "wait-capability") { provider, responder, plan in
            let output = ForegroundTestIO()
            await #expect(throws: ComposeError.self) {
                try await provider.launchPreparedContainer(
                    .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                    foregroundIO: output.io
                )
            }
            #expect(await responder.requests.map(\.target) == ["/v1.53/version"])
            #expect(!output.restored)
        }
    }

    @Test(arguments: [false, true])
    func attachesBeforeStartAndPreservesChannelsAndExit(_ terminal: Bool) async throws {
        try await withFixture(terminal: terminal) { provider, responder, plan in
            let output = ForegroundTestIO()
            let code = try await provider.launchPreparedContainer(
                .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                foregroundIO: output.io
            )
            #expect(code == 7)
            #expect(await responder.attachedBeforeStart)
            #expect(await responder.waitRegisteredBeforeStart)
            let frames = output.frames
            #expect(frames.filter { $0.channel == .standardOutput }.reduce(Data()) { $0 + $1.data }
                == Data((terminal ? "out\nerr\n" : "out\n").utf8))
            #expect(frames.filter { $0.channel == .standardError }.reduce(Data()) { $0 + $1.data }
                == Data((terminal ? "" : "err\n").utf8))
            #expect(output.restored)
            #expect(await responder.requests.filter { $0.target.contains("/wait?") }.count == 1)
        }
    }

    @Test
    func stdinEofIsForwardedAndStdinOnceIsSet() async throws {
        try await withFixture(input: true) { provider, responder, plan in
            let input = Data([0, 255, 10, 42])
            let output = ForegroundTestIO(input: [input])
            let code = try await provider.launchPreparedContainer(
                .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                foregroundIO: output.io
            )
            #expect(code == 7)
            #expect(await responder.session.input == input)
            #expect(await responder.session.closedInput)
            let create = try #require(await responder.requests.first { $0.target.contains("/create?") })
            let object = try #require(JSONSerialization.jsonObject(with: create.body) as? [String: Any])
            #expect(object["StdinOnce"] as? Bool == true)
            #expect(output.restored)
        }
    }

    @Test(arguments: [false, true])
    func ttyDetachDoesNotWaitForContainerExit(_ eof: Bool) async throws {
        try await withFixture(terminal: true, input: true, keepRunning: true) { provider, responder, plan in
            let output = ForegroundTestIO(input: eof ? [] : [Data([16]), Data([17])])
            let code = try await provider.launchPreparedContainer(
                .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                foregroundIO: output.io
            )
            #expect(code == 0)
            #expect(await responder.requests.filter { $0.target.contains("/wait?") }.count == 1)
            #expect(await responder.requests.allSatisfy { $0.method != .delete })
            #expect(output.restored)
        }
    }

    @Test(arguments: ["create", "identity", "attach", "wait-register", "start", "wait", "invalid-exit", "malformed-exit"])
    func failureRestoresHostAndNeverRetriesOrDeletes(_ phase: String) async throws {
        try await withFixture(failure: phase) { provider, responder, plan in
            let output = ForegroundTestIO()
            await #expect(throws: (any Error).self) {
                try await provider.launchPreparedContainer(
                    .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                    foregroundIO: output.io
                )
            }
            let requests = await responder.requests
            #expect(requests.filter { $0.target.contains("/create?") }.count == 1)
            let beforeStart = ["create", "identity", "attach", "wait-register"].contains(phase)
            #expect(requests.filter { $0.target.hasSuffix("/start") }.count == (beforeStart ? 0 : 1))
            #expect(requests.allSatisfy { $0.method != .delete })
            #expect(output.restored)
        }
    }

    @Test
    func autoRemovedContainerKeepsItsNonzeroExit() async throws {
        try await withFixture(failure: "auto-remove") { provider, responder, configured in
            var plan = configured
            plan.autoRemove = true
            let output = ForegroundTestIO()
            let code = try await provider.launchPreparedContainer(
                .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                foregroundIO: output.io
            )
            #expect(code == 7)
            #expect(await responder.waitRegisteredBeforeStart)
            #expect(output.restored)
        }
    }

    @Test
    func cancellationClosesQuietAttachmentAndRestoresHost() async throws {
        try await withFixture(keepRunning: true) { provider, responder, plan in
            let output = ForegroundTestIO()
            let task = Task {
                try await provider.launchPreparedContainer(
                    .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                    foregroundIO: output.io
                )
            }
            defer { task.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await responder.attachedBeforeStart), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(await responder.attachedBeforeStart)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(output.restored)
            #expect(await responder.requests.allSatisfy { $0.method != .delete })
        }
    }

    @Test
    func cancellationAfterOutputEofCancelsPendingExitWait() async throws {
        try await withFixture(failure: "closed-output-running") { provider, responder, plan in
            let output = ForegroundTestIO()
            let task = Task {
                try await provider.launchPreparedContainer(
                    .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                    foregroundIO: output.io
                )
            }
            defer { task.cancel() }
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while output.byteCount < 8, ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(output.byteCount == 8)
            // Give the already-ended attachment time to deliver socket EOF.
            // The separate native wait deliberately remains unresolved.
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !output.restored, ContinuousClock.now < cancellationDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(output.restored)
            // Bound the regression even before the fix; this is fixture cleanup,
            // not a retry or an invented native exit used for the assertion.
            await responder.releaseExitBarrier()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await responder.requests.allSatisfy { $0.method != .delete })
        }
    }

    @Test(arguments: ["resize-removed", "resize-removed-after-conflict"])
    func ttyAutoRemovalUsesRegisteredExit(_ phase: String) async throws {
        try await withFixture(terminal: true, keepRunning: true, failure: phase) { provider, responder, configured in
            var plan = configured
            plan.autoRemove = true
            let output = ForegroundTestIO()
            var io = output.io
            io.size = { EngineTerminalSize(width: 80, height: 24) }
            let code = try await provider.launchPreparedContainer(
                .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                foregroundIO: io
            )
            #expect(code == 7)
            #expect(await responder.waitRegisteredBeforeStart)
            #expect(output.restored)
        }
    }

    @Test
    func outputDrainsBeforeDelayedStartResponse() async throws {
        try await withFixture { provider, responder, plan in
            let output = ForegroundTestIO()
            let payload = Data(repeating: 97, count: 20 * 1024 * 1024)
            await responder.delayStartResponse(payload: payload) {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while output.byteCount < payload.count + 8, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                return output.byteCount == payload.count + 8
            }
            let code = try await provider.launchPreparedContainer(
                .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                foregroundIO: output.io
            )
            #expect(code == 7)
            #expect(await responder.drainConfirmedBeforeStartResponse)
        }
    }

    @Test(arguments: [true, false])
    func resizeConflictRequiresObservedExit(_ exited: Bool) async throws {
        let failure = exited ? "resize-race" : "resize-error"
        try await withFixture(terminal: true, keepRunning: true, failure: failure) { provider, responder, plan in
            let output = ForegroundTestIO()
            var io = output.io
            io.size = { EngineTerminalSize(width: 80, height: 24) }
            let configuredIO = io
            if exited {
                let code = try await provider.launchPreparedContainer(
                    .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                    foregroundIO: configuredIO
                )
                #expect(code == 7)
            } else {
                await #expect(throws: (any Error).self) {
                    try await provider.launchPreparedContainer(
                        .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                        foregroundIO: configuredIO
                    )
                }
            }
            #expect(await responder.requests.contains { $0.target.contains("/resize?") })
            #expect(output.restored)
        }
    }

    @Test
    func outputFailureRestoresHostWithoutRemovingContainer() async throws {
        try await withFixture(keepRunning: true) { provider, responder, plan in
            let output = ForegroundTestIO()
            var io = output.io
            io.write = { _ in throw POSIXError(.EPIPE) }
            let configuredIO = io
            await #expect(throws: POSIXError.self) {
                try await provider.launchPreparedContainer(
                    .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                    foregroundIO: configuredIO
                )
            }
            #expect(output.restored)
            #expect(await responder.requests.allSatisfy { $0.method != .delete })
        }
    }

    @Test
    func terminalSizeChangesAreForwardedWithoutDuplicateResize() async throws {
        try await withFixture(terminal: true, keepRunning: true) { provider, responder, plan in
            let output = ForegroundTestIO()
            let sizes = ForegroundTestSizes()
            var io = output.io
            io.size = { sizes.next() }
            let configuredIO = io
            let code = try await provider.launchPreparedContainer(
                .init(command: .run, arguments: [], logging: plan.logging), configuration: plan,
                foregroundIO: configuredIO
            )
            #expect(code == 7)
            let requests = await responder.requests.filter { $0.target.contains("/resize?") }
            #expect(requests.map(\.target) == [
                "/v1.53/containers/created-id/resize?w=80&h=24",
                "/v1.53/containers/created-id/resize?w=100&h=40",
            ])
            #expect(output.restored)
        }
    }

}

private extension EngineForegroundLaunchTests {
    func withFixture(
        terminal: Bool = false, input: Bool = false, keepRunning: Bool = false, failure: String? = nil,
        operation: (EngineRuntimeProvider, ForegroundResponder, ContainerServiceCreatePlan) async throws -> Void
    ) async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanup() }
        let responder = ForegroundResponder(
            terminal: terminal, input: input, keepRunning: keepRunning, failure: failure
        )
        let server = fixture.server(responder)
        try await server.start()
        do {
            let runner = RecordingRunner()
            let provider = EngineRuntimeProvider(socketPath: fixture.socketPath, runner: runner)
            var plan = ContainerServiceCreatePlan(identity: .init(name: "app", imageReference: "fixture:latest"))
            plan.imageSelection = .init(
                reference: "sha256:" + String(repeating: "a", count: 64), platform: "linux/arm64"
            )
            plan.resolvedMounts = []
            plan.publishedPorts = []
            plan.detach = false
            plan.processOverrides.terminal = terminal
            plan.processOverrides.openStandardInput = input
            try await operation(provider, responder, plan)
            #expect(runner.commands.isEmpty)
        } catch {
            await responder.releaseExitBarrier()
            await responder.session.cancel()
            try? await server.shutdown()
            throw error
        }
        await responder.releaseExitBarrier()
        await responder.session.cancel()
        try await server.shutdown()
    }
}

private final class ForegroundTestSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> EngineTerminalSize? {
        lock.withLock {
            count += 1
            return count < 3 ? .init(width: 80, height: 24) : .init(width: 100, height: 40)
        }
    }
}

private final class ForegroundTestIO: @unchecked Sendable {
    private let lock = NSLock()
    private var input: [Data]
    private var storage: [DockerStreamFrame] = []
    private var didRestore = false
    init(input: [Data] = []) {
        self.input = input
    }

    var frames: [DockerStreamFrame] {
        lock.withLock { storage }
    }

    var byteCount: Int {
        lock.withLock { storage.reduce(0) { $0 + $1.data.count } }
    }

    var restored: Bool {
        lock.withLock { didRestore }
    }

    var io: EngineForegroundIO {
        .init(read: { self.lock.withLock { self.input.isEmpty ? nil : self.input.removeFirst() } },
              write: { frame in self.lock.withLock { self.storage.append(frame) } },
              restore: { self.lock.withLock { self.didRestore = true } })
    }
}

private actor ForegroundResponder: DockerHTTPResponder {
    let terminal: Bool
    let session: ForegroundSession
    let failure: String?
    var requests: [DockerHTTPRequest] = []
    var attachedBeforeStart = false
    var waitRegisteredBeforeStart = false
    private var waitRegistered = false
    private var attached = false
    private var burst = Data()
    private var startBarrier: (@Sendable () async throws -> Bool)?
    var drainConfirmedBeforeStartResponse = false
    private let exitBarrier = ForegroundExitBarrier()

    func releaseExitBarrier() {
        exitBarrier.release()
    }

    func delayStartResponse(payload: Data, barrier: @escaping @Sendable () async throws -> Bool) {
        burst = payload
        startBarrier = barrier
    }

    init(terminal: Bool, input: Bool, keepRunning: Bool, failure: String?) {
        self.terminal = terminal
        self.failure = failure
        session = ForegroundSession(input: input, keepRunning: keepRunning)
    }

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        requests.append(request)
        if request.target == "/v1.53/version" {
            return versionResponse()
        }
        if request.target.contains("/images/") {
            return .text("""
            {"Id":"sha256:\(String(repeating: "a", count: 64))","RepoTags":[],"RepoDigests":[],"Architecture":"arm64","Os":"linux",
            "Config":{"Cmd":["/bin/true"]}}
            """, contentType: "application/json")
        }
        if request.target.contains("/create?") {
            return createResponse()
        }
        if request.target.contains("/attach?") {
            if failure == "attach" {
                return .text("attach failed", status: 500)
            }
            attached = true
            return .init(status: 101, headers: ["Connection": "Upgrade", "Upgrade": "tcp"],
                         body: .hijack(session, terminal: terminal))
        }
        if request.target.hasSuffix("/start") {
            return await startResponse()
        }
        if request.target.contains("/resize?") {
            return await resizeResponse(request)
        }
        if request.target == "/v1.53/containers/created-id/json" {
            return await inspectResponse()
        }
        if request.target.contains("/wait?") {
            return waitResponse(request)
        }
        return .text("unexpected request", status: 400)
    }

    private func inspectResponse() async -> DockerHTTPResponse {
        if failure == "resize-removed-after-conflict" {
            finishRemovedContainerOutput()
            return .text("container was automatically removed", status: 404)
        }
        let state = failure == "resize-race" ? "exited" : "running"
        if state == "exited" {
            await session.cancel()
        }
        return .text("""
        {"Id":"created-id","Name":"/app","Image":"sha256:a",
        "Config":{"Image":"fixture:latest","Labels":{}},"Mounts":[],
        "State":{"Status":"\(state)","ExitCode":7,"FinishedAt":"2026-09-19T12:00:00Z"},
        "NetworkSettings":{"Ports":{},"Networks":{}}}
        """, contentType: "application/json")
    }

    private func versionResponse() -> DockerHTTPResponse {
        let supported = failure == "wait-capability" ? "0" : "1"
        return .text("""
        {"Components":[{"Name":"Engine","Details":{
        "ContainerImageReference":"1","ContainerExitWaitRegistration":"\(supported)"}}]}
        """, contentType: "application/json")
    }

    private func createResponse() -> DockerHTTPResponse {
        if failure == "create" {
            return .text("create failed", status: 500)
        }
        let body = failure == "identity" ? #"{"Id":""}"# : #"{"Id":"created-id"}"#
        return .text(body, contentType: "application/json")
    }

    private func startResponse() async -> DockerHTTPResponse {
        attachedBeforeStart = attached
        waitRegisteredBeforeStart = waitRegistered
        if failure == "start" {
            return .text("start failed", status: 500)
        }
        await session.start(burst: burst)
        if let startBarrier {
            drainConfirmedBeforeStartResponse = (try? await startBarrier()) == true
            if !drainConfirmedBeforeStartResponse {
                return .text("undrained startup output", status: 500)
            }
        }
        return .empty(status: 204)
    }

    private func resizeResponse(_ request: DockerHTTPRequest) async -> DockerHTTPResponse {
        if failure == "resize-removed" {
            finishRemovedContainerOutput()
            return .text("container was automatically removed", status: 404)
        }
        if failure == "resize-removed-after-conflict" {
            return .text("process is not running", status: 409)
        }
        if failure == "resize-race" || failure == "resize-error" {
            return .text("process is not running", status: 409)
        }
        if request.target.contains("w=100&h=40") {
            await session.cancel()
        }
        return .empty(status: 200)
    }

    private func finishRemovedContainerOutput() {
        let session = session
        Task {
            // Removal is observable before the attachment's final drain. Do not
            // let immediate output EOF hide a failure in the resize response.
            try? await Task.sleep(for: .milliseconds(80))
            await session.cancel()
        }
    }

    private func waitResponse(_ request: DockerHTTPRequest) -> DockerHTTPResponse {
        if failure == "wait-register" {
            return .text("registration failed", status: 500)
        }
        if failure == "auto-remove", attachedBeforeStart {
            return .text("container was automatically removed", status: 404)
        }
        guard request.target.hasSuffix("condition=next-exit") else {
            return .text("unregistered wait", status: 400)
        }
        waitRegistered = true
        let body = switch failure {
        case "invalid-exit": #"{"StatusCode":256}"#
        case "malformed-exit": #"{"StatusCode":"7"}"#
        case "wait": #"{"StatusCode":0,"Error":{"Message":"wait failed"}}"#
        default: #"{"StatusCode":7}"#
        }
        let session = session
        let barrier = failure == "closed-output-running" ? exitBarrier : nil
        return .init(status: 200, headers: ["Content-Type": "application/json"], body: .stream(
            AsyncThrowingStream { continuation in
                let task = Task {
                    if let barrier {
                        await barrier.wait()
                    } else {
                        _ = await session.wait()
                    }
                    continuation.yield(Data(body.utf8))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        ))
    }
}

private final class ForegroundExitBarrier: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }

    func release() {
        continuation.finish()
    }
}

private actor ForegroundSession: DockerHijackSession {
    nonisolated let frames: AsyncThrowingStream<DockerStreamFrame, any Error>
    private let continuation: AsyncThrowingStream<DockerStreamFrame, any Error>.Continuation
    let expectsInput: Bool
    let keepRunning: Bool
    var input = Data()
    var closedInput = false
    private var started = false
    private var completed = false
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(input: Bool, keepRunning: Bool) {
        (frames, continuation) = AsyncThrowingStream.makeStream()
        expectsInput = input
        self.keepRunning = keepRunning
    }

    func start(burst: Data = Data()) {
        started = true
        continuation.yield(.init(channel: .standardOutput, data: Data("out\n".utf8)))
        continuation.yield(.init(channel: .standardError, data: Data("err\n".utf8)))
        for offset in stride(from: 0, to: burst.count, by: 65536) {
            let bytes = burst.subdata(in: offset ..< min(offset + 65536, burst.count))
            continuation.yield(.init(channel: .standardOutput, data: bytes))
        }
        finishWhenReady()
    }

    func write(_ bytes: Data) {
        input.append(bytes)
    }

    func closeStandardInput() {
        closedInput = true; finishWhenReady()
    }

    func wait() async -> Int32 {
        if completed {
            return 7
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func cancel() {
        continuation.finish()
        completed = true
        for waiter in waiters {
            waiter.resume(returning: 7)
        }
        waiters.removeAll()
    }

    private func finishWhenReady() {
        if started, !keepRunning, !expectsInput || closedInput {
            cancel()
        }
    }
}
