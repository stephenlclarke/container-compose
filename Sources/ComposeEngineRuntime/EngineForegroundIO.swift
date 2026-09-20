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
import ContainerEngineWire
import Darwin
import Foundation

struct EngineTerminalSize: Equatable, Sendable {
    let width: UInt16
    let height: UInt16
}

/// Host I/O belongs to one launch, not the provider or the container lifetime.
struct EngineForegroundIO: Sendable {
    var read: @Sendable () async throws -> Data?
    var write: @Sendable (DockerStreamFrame) async throws -> Void
    var size: @Sendable () throws -> EngineTerminalSize? = { nil }
    var restore: @Sendable () throws -> Void = {}
    var signalProxy: any ComposeSignalProxying = DispatchComposeSignalProxy()

    static func system(
        terminal: Bool, standardInput: Bool,
        inputDescriptor: Int32 = STDIN_FILENO, outputDescriptor: Int32 = STDOUT_FILENO,
        errorDescriptor: Int32 = STDERR_FILENO
    ) throws -> Self {
        let input = try standardInput ? EngineForegroundInput(descriptor: inputDescriptor) : nil
        let output = try EngineForegroundOutput(descriptor: outputDescriptor)
        let error = try EngineForegroundOutput(descriptor: errorDescriptor)
        let terminal = try terminal && standardInput ? EngineForegroundTerminal(descriptor: inputDescriptor) : nil
        return Self(
            read: { try await input?.read() },
            write: { frame in
                switch frame.channel {
                case .standardOutput: try await output.write(frame.data)
                case .standardError: try await error.write(frame.data)
                default: break
                }
            },
            size: { try terminal?.size() },
            restore: { try terminal?.restore() }
        )
    }
}

/// Raw mode is restored on success, detach, failed start and cancellation.
final class EngineForegroundTerminal: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var original: termios?

    init(descriptor source: Int32 = STDIN_FILENO) throws {
        let owned = fcntl(source, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { throw Self.posixError() }
        do {
            if isatty(owned) == 1 {
                var state = termios()
                guard tcgetattr(owned, &state) == 0 else { throw Self.posixError() }
                var raw = state
                cfmakeraw(&raw)
                guard tcsetattr(owned, TCSANOW, &raw) == 0 else { throw Self.posixError() }
                original = state
            }
        } catch {
            Darwin.close(owned)
            throw error
        }
        descriptor = owned
    }

    deinit {
        try? restore()
        Darwin.close(descriptor)
    }

    func restore() throws {
        try lock.withLock {
            guard var original else { return }
            guard tcsetattr(descriptor, TCSANOW, &original) == 0 else { throw Self.posixError() }
            self.original = nil
        }
    }

    func size() throws -> EngineTerminalSize? {
        try lock.withLock {
            guard original != nil else { return nil }
            var size = winsize()
            guard ioctl(descriptor, TIOCGWINSZ, &size) == 0 else { throw Self.posixError() }
            guard size.ws_col > 0, size.ws_row > 0 else { return nil }
            return EngineTerminalSize(width: size.ws_col, height: size.ws_row)
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
