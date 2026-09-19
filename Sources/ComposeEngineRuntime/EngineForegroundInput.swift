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

// Original work Copyright 2026 devcontainer project authors. Apache-2.0.
// Adapted from devcontainer 263ec4e; retained here to keep Compose independent.

import Darwin
import Foundation

/// A cancellation-aware single reader for the frontend's inherited stdin.
/// Polling bounds cancellation without changing the parent's descriptor flags.
final class EngineForegroundInput: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private let readLock = NSLock()
    private var cancelled = false

    init(descriptor: Int32 = STDIN_FILENO) throws {
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { throw Self.posixError() }
        self.descriptor = owned
    }

    deinit { Darwin.close(descriptor) }

    func read() async throws -> Data? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuation.resume(with: Result { try readLock.withLock { try readBlocking() } })
                }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
        }
    }

    private func readBlocking() throws -> Data? {
        while true {
            try checkCancellation()
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&item, 1, 100)
            if result == 0 || (result < 0 && errno == EINTR) {
                continue
            }
            guard result > 0 else { throw Self.posixError() }
            try checkCancellation()
            guard item.revents & Int16(POLLNVAL) == 0 else { throw POSIXError(.EBADF) }
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            try checkCancellation()
            if count == 0 {
                return nil
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { throw Self.posixError() }
            return Data(bytes.prefix(count))
        }
    }

    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) {
            throw CancellationError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
