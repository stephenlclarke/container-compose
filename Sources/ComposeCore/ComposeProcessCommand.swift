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

import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Minimal POSIX process primitive used by the Compose command runner.
final class ComposeProcessCommand: @unchecked Sendable {
    struct Attributes {
        var setProcessGroup = false
        var setForegroundProcessGroup = false
    }

    let executable: String
    let arguments: [String]
    let environment: [String]
    let directory: String?
    var stdin: FileHandle?
    var stdout: FileHandle?
    var stderr: FileHandle?
    var attributes = Attributes()

    private let lock = NSLock()
    private var processIdentifier: pid_t = -1

    var pid: pid_t {
        lock.withLock { processIdentifier }
    }

    init(
        _ executable: String,
        arguments: [String],
        environment: [String],
        directory: String?,
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    // The launch sequence deliberately keeps POSIX resource lifetimes visible.
    // swiftlint:disable:next function_body_length
    func start() throws {
        guard lock.withLock({ processIdentifier == -1 }) else {
            throw POSIXError(.EBUSY)
        }

        var fileActions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try Self.duplicate(stdin ?? .standardInput, to: STDIN_FILENO, actions: &fileActions)
        try Self.duplicate(stdout ?? .standardOutput, to: STDOUT_FILENO, actions: &fileActions)
        try Self.duplicate(stderr ?? .standardError, to: STDERR_FILENO, actions: &fileActions)
        if let directory {
            #if canImport(Darwin)
                if #available(macOS 26, *) {
                    try Self.check(posix_spawn_file_actions_addchdir(&fileActions, directory))
                } else {
                    try Self.check(posix_spawn_file_actions_addchdir_np(&fileActions, directory))
                }
            #elseif canImport(Glibc)
                try Self.check(posix_spawn_file_actions_addchdir_np(&fileActions, directory))
            #endif
        }

        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        var flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
            flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        if self.attributes.setProcessGroup {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        }
        try Self.check(posix_spawnattr_setflags(&attributes, flags))

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in 1 ..< NSIG where signal != SIGKILL && signal != SIGSTOP {
            sigaddset(&defaultSignals, signal)
        }
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try Self.check(posix_spawnattr_setsigmask(&attributes, &signalMask))

        var cArguments: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer {
            for value in cArguments {
                free(value)
            }
        }
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            for value in cEnvironment {
                free(value)
            }
        }

        var child: pid_t = 0
        let result = cArguments.withUnsafeMutableBufferPointer { argumentBuffer in
            cEnvironment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawnp(
                    &child,
                    executable,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress,
                )
            }
        }
        try Self.check(result)

        lock.withLock {
            processIdentifier = child
        }
        if self.attributes.setForegroundProcessGroup {
            _ = tcsetpgrp(STDIN_FILENO, child)
        }
    }

    private static func duplicate(
        _ handle: FileHandle,
        to destination: Int32,
        actions: inout posix_spawn_file_actions_t?,
    ) throws {
        try check(posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, destination))
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }
}
