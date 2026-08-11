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

@testable import ComposeContainerRuntime
#if canImport(Darwin)
    import Darwin
#endif
import ComposeCore
import ComposeRuntimeSPI
import ContainerizationOCI
import ContainerResource
import Foundation
import Testing

@Suite("Container attach adapter")
struct ContainerAttachAdapterTests {
    @Test
    func `emits independent stdout and stderr records`() async throws {
        let client = try RecordingContainerAttachAPIClient(
            container: attachContainer(terminal: false),
            stdout: Data("out\n".utf8),
            stderr: Data("err\n".utf8),
        )
        let records = AttachRecordRecorder()

        try await ContainerClientAttachManager(client: client).attachOutput(
            id: "demo-api-1",
            stdout: true,
            stderr: true,
            mode: .runningProcess,
            onReady: {},
            onStarted: {},
            emit: records.append,
        )

        #expect(await client.requestedIDs == ["demo-api-1"])
        #expect(records.records.sorted(by: { $0.stream.rawValue < $1.stream.rawValue }) == [
            ComposeLogRecord(stream: .stderr, payload: Data("err\n".utf8)),
            ComposeLogRecord(stream: .stdout, payload: Data("out\n".utf8)),
        ])
        #expect(await client.disconnectCount == 1)
    }

    @Test
    func `terminal output is emitted only as stdout`() async throws {
        let client = try RecordingContainerAttachAPIClient(
            container: attachContainer(terminal: true),
            stdout: Data("merged\n".utf8),
            stderr: Data("must-not-be-requested".utf8),
        )
        let records = AttachRecordRecorder()

        try await ContainerClientAttachManager(client: client).attachOutput(
            id: "demo-api-1",
            stdout: true,
            stderr: true,
            mode: .runningProcess,
            onReady: {},
            onStarted: {},
            emit: records.append,
        )

        #expect(records.records == [
            ComposeLogRecord(
                stream: .stdout,
                payload: Data("merged\n".utf8),
                terminal: true,
            ),
        ])
        #expect(await client.requestedStreams == [[false, true, false]])
    }

    @Test
    func `no selected streams performs no runtime calls`() async throws {
        let client = try RecordingContainerAttachAPIClient(
            container: attachContainer(terminal: false),
        )

        try await ContainerClientAttachManager(client: client).attachOutput(
            id: "demo-api-1",
            stdout: false,
            stderr: false,
            mode: .runningProcess,
            onReady: {},
            onStarted: {},
            emit: { _ in },
        )

        #expect(await client.requestedIDs.isEmpty)
        #expect(await client.disconnectCount == 0)
    }

    @Test
    func `created container is bootstrapped and ready before output`() async throws {
        let client = try RecordingContainerAttachAPIClient(
            container: attachContainer(status: .stopped, terminal: false),
            stdout: Data("early\n".utf8),
        )
        let events = AttachEventRecorder()

        try await ContainerClientAttachManager(client: client).attachOutput(
            id: "demo-api-1",
            stdout: true,
            stderr: true,
            mode: .beforeStart,
            onReady: { events.append("ready") },
            onStarted: { events.append("started") },
            emit: { events.append(String(bytes: $0.payload, encoding: .utf8) ?? "<invalid UTF-8>") },
        )

        #expect(await client.attachIDs.isEmpty)
        #expect(await client.bootstrapIDs == ["demo-api-1"])
        #expect(await client.startCount == 1)
        #expect(events.events == ["ready", "started", "early\n"])
    }

    @Test
    func `before-start race attaches without restarting an already-running process`() async throws {
        let client = try RecordingContainerAttachAPIClient(
            container: attachContainer(status: .running, terminal: false),
            stdout: Data("running\n".utf8),
        )
        let events = AttachEventRecorder()

        try await ContainerClientAttachManager(client: client).attachOutput(
            id: "demo-api-1",
            stdout: true,
            stderr: true,
            mode: .beforeStart,
            onReady: { events.append("ready") },
            onStarted: { events.append("started") },
            emit: { events.append(String(bytes: $0.payload, encoding: .utf8) ?? "<invalid UTF-8>") },
        )

        #expect(await client.attachIDs == ["demo-api-1"])
        #expect(await client.bootstrapIDs.isEmpty)
        #expect(await client.startCount == 0)
        #expect(events.events == ["ready", "started", "running\n"])
    }

    @Test
    func `ordinary attach rejects a stopped container without bootstrapping it`() async throws {
        let client = try RecordingContainerAttachAPIClient(
            container: attachContainer(status: .stopped, terminal: false),
        )

        do {
            try await ContainerClientAttachManager(client: client).attachOutput(
                id: "demo-api-1",
                stdout: true,
                stderr: true,
                mode: .runningProcess,
                onReady: {},
                onStarted: {},
                emit: { _ in },
            )
            Issue.record("Expected stopped ordinary attach to fail")
        } catch let error as ComposeError {
            #expect(error == .unsupported("attach: container 'demo-api-1' is stopped"))
        }

        #expect(await client.attachIDs.isEmpty)
        #expect(await client.bootstrapIDs.isEmpty)
        #expect(await client.startCount == 0)
        #expect(await client.disconnectCount == 0)
    }
}

private func attachContainer(
    status: RuntimeStatus = .running,
    terminal: Bool,
) throws -> ContainerSnapshot {
    var configuration = ContainerConfiguration(
        id: "demo-api-1",
        image: ImageDescription(
            reference: "example/api",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                size: 0,
            ),
        ),
        process: ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            terminal: terminal,
        ),
    )
    configuration.platform = Platform(arch: "arm64", os: "linux")
    return ContainerSnapshot(configuration: configuration, status: status, networks: [])
}

private actor RecordingContainerAttachAPIClient: ContainerAttachAPIClienting {
    private let container: ContainerSnapshot
    private let stdout: Data
    private let stderr: Data
    private var ids: [String] = []
    private var streams: [[Bool]] = []
    private var attached: [String] = []
    private var bootstrapped: [String] = []
    private let disconnects = CountRecorder()
    private let starts = CountRecorder()

    init(
        container: ContainerSnapshot,
        stdout: Data = Data(),
        stderr: Data = Data(),
    ) {
        self.container = container
        self.stdout = stdout
        self.stderr = stderr
    }

    var requestedIDs: [String] {
        ids
    }

    var requestedStreams: [[Bool]] {
        streams
    }

    var attachIDs: [String] {
        attached
    }

    var bootstrapIDs: [String] {
        bootstrapped
    }

    var disconnectCount: Int {
        disconnects.count
    }

    var startCount: Int {
        starts.count
    }

    func getContainer(id: String) async throws -> ContainerSnapshot {
        ids.append(id)
        return container
    }

    func attach(id: String, stdio: [FileHandle?]) async throws -> any ContainerOutputAttachSession {
        attached.append(id)
        try writeOutput(stdio: stdio)
        return RecordingContainerOutputAttachSession(disconnects: disconnects, starts: starts)
    }

    func bootstrap(id: String, stdio: [FileHandle?]) async throws -> any ContainerOutputAttachSession {
        bootstrapped.append(id)
        streams.append(stdio.map { $0 != nil })
        return try RecordingContainerOutputAttachSession(
            disconnects: disconnects,
            starts: starts,
            startOutput: StartOutput(stdio: stdio, stdout: stdout, stderr: stderr),
        )
    }

    private func writeOutput(stdio: [FileHandle?]) throws {
        streams.append(stdio.map { $0 != nil })
        if let handle = stdio[1] {
            try handle.write(contentsOf: stdout)
            try handle.close()
        }
        if let handle = stdio[2] {
            try handle.write(contentsOf: stderr)
            try handle.close()
        }
    }
}

private struct RecordingContainerOutputAttachSession: ContainerOutputAttachSession {
    let disconnects: CountRecorder
    let starts: CountRecorder
    var startOutput: StartOutput?

    init(disconnects: CountRecorder, starts: CountRecorder, startOutput: StartOutput? = nil) {
        self.disconnects = disconnects
        self.starts = starts
        self.startOutput = startOutput
    }

    func start() async throws {
        starts.record()
        try startOutput?.write()
    }

    func disconnect() {
        disconnects.record()
    }
}

private final class StartOutput: @unchecked Sendable {
    private let stdio: [FileHandle?]
    private let stdout: Data
    private let stderr: Data

    init(stdio: [FileHandle?], stdout: Data, stderr: Data) throws {
        self.stdio = try stdio.map { handle in
            guard let handle else { return nil }
            let descriptor = dup(handle.fileDescriptor)
            guard descriptor >= 0 else {
                throw POSIXError(.EBADF)
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        self.stdout = stdout
        self.stderr = stderr
    }

    func write() throws {
        if let handle = stdio[1] {
            try handle.write(contentsOf: stdout)
            try handle.close()
        }
        if let handle = stdio[2] {
            try handle.write(contentsOf: stderr)
            try handle.close()
        }
    }
}

private final class CountRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.withLock { storage }
    }

    func record() {
        lock.withLock {
            storage += 1
        }
    }
}

private final class AttachRecordRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ComposeLogRecord] = []

    var records: [ComposeLogRecord] {
        lock.withLock { storage }
    }

    func append(_ record: ComposeLogRecord) {
        lock.withLock {
            storage.append(record)
        }
    }
}

private final class AttachEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock {
            storage.append(event)
        }
    }
}
