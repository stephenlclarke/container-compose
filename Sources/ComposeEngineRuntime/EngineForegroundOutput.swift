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

/// The frontend is the sole writer of its stdout/stderr streams. Poll before
/// writes no larger than POSIX's minimum PIPE_BUF, so an undrained pipe remains
/// cancellable without setting O_NONBLOCK on the parent's open-file description.
/// SIGPIPE is masked only on the blocking worker while it writes. Descriptor
/// flags and process-wide signal disposition remain the caller's property.
final class EngineForegroundOutput: @unchecked Sendable {
    private let descriptor: Int32
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var cancelled = false

    init(descriptor: Int32) throws {
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { throw Self.posixError() }
        self.descriptor = owned
    }

    deinit { Darwin.close(descriptor) }

    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuation.resume(with: Result { try writeLock.withLock { try writeBlocking(data) } })
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        stateLock.withLock { cancelled = true }
    }

    private func writeBlocking(_ data: Data) throws {
        try withBlockedPipeSignal { generatedPipeSignal in
            try self.writeBytes(data, generatedPipeSignal: &generatedPipeSignal)
        }
    }

    private func withBlockedPipeSignal(_ operation: (inout Bool) throws -> Void) throws {
        var pipeSignal = sigset_t()
        sigemptyset(&pipeSignal)
        sigaddset(&pipeSignal, SIGPIPE)
        var previous = sigset_t()
        let result = pthread_sigmask(SIG_BLOCK, &pipeSignal, &previous)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        var pending = sigset_t()
        sigpending(&pending)
        let wasPending = sigismember(&pending, SIGPIPE) == 1
        var generatedPipeSignal = false
        defer {
            // Consume only a newly pending signal from our EPIPE write before
            // restoring this worker's mask. Preserve pre-existing pending work.
            if generatedPipeSignal, !wasPending {
                sigpending(&pending)
                if sigismember(&pending, SIGPIPE) == 1 {
                    var signal: Int32 = 0
                    sigwait(&pipeSignal, &signal)
                }
            }
            pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        try operation(&generatedPipeSignal)
    }

    private func writeBytes(_ data: Data, generatedPipeSignal: inout Bool) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try checkCancellation()
                var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&item, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) {
                    continue
                }
                guard ready > 0 else { throw Self.posixError() }
                try checkCancellation()
                guard item.revents & Int16(POLLNVAL) == 0 else { throw POSIXError(.EBADF) }
                guard item.revents & Int16(POLLERR | POLLHUP) == 0 else { throw POSIXError(.EPIPE) }
                let count = Darwin.write(descriptor, base.advanced(by: offset), min(512, bytes.count - offset))
                let code = errno
                if count < 0, code == EPIPE {
                    generatedPipeSignal = true
                }
                try checkCancellation()
                if count < 0, code == EINTR {
                    continue
                }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                offset += count
            }
        }
    }

    private func checkCancellation() throws {
        if stateLock.withLock({ cancelled }) {
            throw CancellationError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
