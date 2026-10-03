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
import Darwin
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct EngineForegroundIOTests {
    @Test(arguments: [false, true])
    func systemIORoutesOwnedDescriptors(_ inputEnabled: Bool) async throws {
        let input = Pipe(), output = Pipe(), error = Pipe()
        defer {
            for pipe in [input, output, error] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        let io = try EngineForegroundIO.system(
            terminal: true, standardInput: inputEnabled,
            inputDescriptor: input.fileHandleForReading.fileDescriptor,
            outputDescriptor: output.fileHandleForWriting.fileDescriptor,
            errorDescriptor: error.fileHandleForWriting.fileDescriptor
        )
        let bytes = Data([0, 255, 10, 42])
        try input.fileHandleForWriting.write(contentsOf: bytes)
        #expect(try await io.read() == (inputEnabled ? bytes : nil))
        try await io.write(.init(channel: .standardOutput, data: bytes))
        try await io.write(.init(channel: .standardError, data: bytes))
        #expect(try output.fileHandleForReading.read(upToCount: bytes.count) == bytes)
        #expect(try error.fileHandleForReading.read(upToCount: bytes.count) == bytes)
        #expect(try io.size() == nil)
        try io.restore()
    }

    @Test
    func idleInputCancellationJoinsAndPreservesCallerFlags() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        let input = try EngineForegroundInput(descriptor: descriptor)
        let task = Task { try await input.read() }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(fcntl(descriptor, F_GETFL) == flags)
        #expect(throws: POSIXError.self) { try EngineForegroundInput(descriptor: -1) }
    }

    @Test
    func binaryInputAndEofAreUnchanged() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let input = try EngineForegroundInput(descriptor: pipe.fileHandleForReading.fileDescriptor)
        let bytes = Data([0, 255, 10, 42])
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        #expect(try await input.read() == bytes)
        try pipe.fileHandleForWriting.close()
        #expect(try await input.read() == nil)
    }

    @Test
    func blockedOutputCancellationJoinsWithoutChangingCallerFlags() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        var byte: UInt8 = 0
        #expect(Darwin.write(descriptor, &byte, 1) == 1)
        #expect(Darwin.read(pipe.fileHandleForReading.fileDescriptor, &byte, 1) == 1)
        let flags = fcntl(descriptor, F_GETFL)
        let signalFlags = fcntl(descriptor, F_GETNOSIGPIPE)
        let output = try EngineForegroundOutput(descriptor: descriptor)
        let task = Task { try await output.write(Data(repeating: 97, count: 1024 * 1024)) }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(fcntl(descriptor, F_GETFL) == flags)
        #expect(fcntl(descriptor, F_GETNOSIGPIPE) == signalFlags)
    }

    @Test
    func outputPreservesPipeBytes() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let output = try EngineForegroundOutput(descriptor: pipe.fileHandleForWriting.fileDescriptor)
        let bytes = Data([0, 255, 10, 42])
        try await output.write(Data())
        try await output.write(bytes)
        #expect(try pipe.fileHandleForReading.read(upToCount: bytes.count) == bytes)
        #expect(throws: POSIXError.self) { try EngineForegroundOutput(descriptor: -1) }
    }

    @Test
    func outputReportsWriteShutdownWithoutSignallingCaller() async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        let output = try EngineForegroundOutput(descriptor: descriptors[0])
        // Disable writes on the shared endpoint, not just one descriptor. This
        // remains deterministic even when concurrent process creation copies it.
        try #require(shutdown(descriptors[0], SHUT_WR) == 0)
        var state = pollfd(fd: descriptors[0], events: Int16(POLLOUT), revents: 0)
        try #require(poll(&state, 1, 0) == 1)
        try #require(state.revents & Int16(POLLERR | POLLHUP) != 0)
        await #expect(throws: POSIXError(.EPIPE)) { try await output.write(Data([42])) }
    }

    @Test
    func rawTerminalRestoresModeAndReportsSize() throws {
        var controller: Int32 = -1
        var terminalFD: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        try #require(openpty(&controller, &terminalFD, nil, nil, &size) == 0)
        defer { Darwin.close(controller); Darwin.close(terminalFD) }
        var before = termios()
        #expect(tcgetattr(terminalFD, &before) == 0)
        let terminal = try EngineForegroundTerminal(descriptor: terminalFD)
        #expect(try terminal.size() == EngineTerminalSize(width: 80, height: 24))
        var raw = termios()
        #expect(tcgetattr(terminalFD, &raw) == 0)
        #expect(raw.c_lflag & tcflag_t(ICANON | ECHO) == 0)
        try terminal.restore()
        try terminal.restore()
        #expect(try terminal.size() == nil)
        var after = termios()
        #expect(tcgetattr(terminalFD, &after) == 0)
        #expect(after.c_iflag == before.c_iflag)
        #expect(after.c_oflag == before.c_oflag)
        // XNU sets PENDIN when restoring canonical mode to retype pending input.
        #expect(after.c_lflag & ~tcflag_t(PENDIN) == before.c_lflag & ~tcflag_t(PENDIN))
        #expect(after.c_cflag == before.c_cflag)
        #expect(throws: POSIXError.self) { try EngineForegroundTerminal(descriptor: -1) }
    }

    @Test
    func nonTerminalAndZeroSizeDoNotInventDimensions() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let nonTerminal = try EngineForegroundTerminal(descriptor: pipe.fileHandleForReading.fileDescriptor)
        #expect(try nonTerminal.size() == nil)
        try nonTerminal.restore()
        var controller: Int32 = -1
        var terminalFD: Int32 = -1
        var size = winsize()
        try #require(openpty(&controller, &terminalFD, nil, nil, &size) == 0)
        defer { Darwin.close(controller); Darwin.close(terminalFD) }
        var before = termios()
        #expect(tcgetattr(terminalFD, &before) == 0)
        do {
            let terminal = try EngineForegroundTerminal(descriptor: terminalFD)
            #expect(try terminal.size() == nil)
        }
        var after = termios()
        #expect(tcgetattr(terminalFD, &after) == 0)
        #expect(after.c_lflag & ~tcflag_t(PENDIN) == before.c_lflag & ~tcflag_t(PENDIN))
    }
}
