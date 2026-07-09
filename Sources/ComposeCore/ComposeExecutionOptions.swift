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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

/// Runtime settings used while translating Compose operations to `container`.
public struct ComposeExecutionOptions {
    public static let defaultEnvironmentLauncher = ["", "usr", "bin", "env"].joined(separator: "/")

    /// Runtime hooks that make orchestration deterministic and testable.
    public struct RuntimeHooks {
        public var oneOffIdentifier: @Sendable () -> String
        public var currentDate: @Sendable () -> Date
        public var hostPortAllocator: @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16
        public var sleep: @Sendable (Duration) async throws -> Void
        public var confirm: @Sendable (_ prompt: String) async throws -> Bool
        public var emit: @Sendable (String) -> Void
        public var emitData: (@Sendable (Data) -> Void)?

        public init(
            oneOffIdentifier: @escaping @Sendable () -> String = ComposeExecutionOptions.defaultOneOffIdentifier,
            currentDate: @escaping @Sendable () -> Date = Date.init,
            hostPortAllocator: @escaping @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16 = ComposeExecutionOptions.defaultHostPortAllocator,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            confirm: @escaping @Sendable (_ prompt: String) async throws -> Bool = ComposeExecutionOptions.defaultConfirmation,
            emit: @escaping @Sendable (String) -> Void = { print($0) },
            emitData: (@Sendable (Data) -> Void)? = nil,
        ) {
            self.oneOffIdentifier = oneOffIdentifier
            self.currentDate = currentDate
            self.hostPortAllocator = hostPortAllocator
            self.sleep = sleep
            self.confirm = confirm
            self.emit = emit
            self.emitData = emitData
        }
    }

    public var dryRun: Bool
    public var maxParallelism: Int?
    public var containerBinary: String
    public var environmentLauncher: String
    public var oneOffIdentifier: @Sendable () -> String
    public var currentDate: @Sendable () -> Date
    public var hostPortAllocator: @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16
    public var watchPollInterval: Duration
    public var materializedConfigSecretDirectory: URL
    public var sleep: @Sendable (Duration) async throws -> Void
    public var confirm: @Sendable (_ prompt: String) async throws -> Bool
    public var emit: @Sendable (String) -> Void
    public var emitData: @Sendable (Data) -> Void
    public var progress: ComposeProgressReporter

    public init(
        dryRun: Bool = false,
        maxParallelism: Int? = nil,
        containerBinary: String = ProcessInfo.processInfo.environment["CONTAINER_BIN"] ?? "container",
        environmentLauncher: String = ComposeExecutionOptions.defaultEnvironmentLauncher,
        watchPollInterval: Duration = .seconds(1),
        materializedConfigSecretDirectory: URL = ComposeExecutionOptions.defaultMaterializedConfigSecretDirectory(),
        progress: ComposeProgressReporter = .disabled,
        runtimeHooks: RuntimeHooks = RuntimeHooks(),
    ) {
        self.dryRun = dryRun
        self.maxParallelism = maxParallelism
        self.containerBinary = containerBinary
        self.environmentLauncher = environmentLauncher
        oneOffIdentifier = runtimeHooks.oneOffIdentifier
        currentDate = runtimeHooks.currentDate
        hostPortAllocator = runtimeHooks.hostPortAllocator
        self.watchPollInterval = watchPollInterval
        self.materializedConfigSecretDirectory = materializedConfigSecretDirectory
        sleep = runtimeHooks.sleep
        confirm = runtimeHooks.confirm
        emit = runtimeHooks.emit
        emitData = runtimeHooks.emitData ?? ComposeExecutionOptions.defaultLogDataEmitter
        self.progress = progress
    }

    public init(dryRun: Bool = false, emit: @escaping @Sendable (String) -> Void) {
        self.init(dryRun: dryRun, runtimeHooks: RuntimeHooks(emit: emit, emitData: { emit(String(decoding: $0, as: UTF8.self)) }))
    }

    public init(hostPortAllocator: @escaping @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16) {
        self.init(runtimeHooks: RuntimeHooks(hostPortAllocator: hostPortAllocator))
    }

    public init(currentDate: @escaping @Sendable () -> Date) {
        self.init(runtimeHooks: RuntimeHooks(currentDate: currentDate))
    }

    public init(environmentLauncher: String) {
        self.init(environmentLauncher: environmentLauncher, runtimeHooks: RuntimeHooks())
    }

    public init(oneOffIdentifier: @escaping @Sendable () -> String) {
        self.init(runtimeHooks: RuntimeHooks(oneOffIdentifier: oneOffIdentifier))
    }

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.init(runtimeHooks: RuntimeHooks(sleep: sleep))
    }

    public init(
        watchPollInterval: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
    ) {
        self.init(
            watchPollInterval: watchPollInterval,
            runtimeHooks: RuntimeHooks(sleep: sleep),
        )
    }

    public init(
        dryRun: Bool,
        containerBinary: String,
        emit: @escaping @Sendable (String) -> Void,
    ) {
        self.init(
            dryRun: dryRun,
            containerBinary: containerBinary,
            runtimeHooks: RuntimeHooks(emit: emit, emitData: { emit(String(decoding: $0, as: UTF8.self)) }),
        )
    }

    public init(
        dryRun: Bool,
        hostPortAllocator: @escaping @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16,
        emit: @escaping @Sendable (String) -> Void,
    ) {
        self.init(
            dryRun: dryRun,
            runtimeHooks: RuntimeHooks(hostPortAllocator: hostPortAllocator, emit: emit, emitData: { emit(String(decoding: $0, as: UTF8.self)) }),
        )
    }

    public static func defaultOneOffIdentifier() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    public static func defaultConfirmation(_ prompt: String) async throws -> Bool {
        FileHandle.standardError.write(Data(prompt.utf8))
        guard let response = readLine() else {
            return false
        }
        switch response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "y", "yes":
            return true
        default:
            return false
        }
    }

    /// Returns the per-user root for local config and secret materialization.
    public static func defaultMaterializedConfigSecretDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".container-compose", isDirectory: true)
            .appendingPathComponent("config-secrets", isDirectory: true)
    }

    /// Writes log bytes directly so container output can preserve non-UTF-8 payloads.
    public static func defaultLogDataEmitter(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([UInt8(ascii: "\n")]))
    }

    /// Allocates an ephemeral host port compatible with apple/container's
    /// explicit `--publish` requirement.
    public static func defaultHostPortAllocator(hostAddress: String?, protocolName: String) throws -> UInt16 {
        try HostPortAllocator(hostAddress: hostAddress, protocolName: protocolName).allocate()
    }
}

/// Allocates ephemeral host ports for Compose target-only published ports.
private struct HostPortAllocator {
    var hostAddress: String?
    var protocolName: String

    func allocate() throws -> UInt16 {
        let socketKind = try socketKind()
        if normalizedHostAddress.contains(":") {
            return try allocateIPv6(socketKind: socketKind)
        }
        return try allocateIPv4(socketKind: socketKind)
    }

    private var normalizedHostAddress: String {
        let value = hostAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.hasPrefix("["), value.hasSuffix("]") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private func socketKind() throws -> Int32 {
        switch protocolName.lowercased() {
        case "tcp":
            return SOCK_STREAM
        case "udp":
            return SOCK_DGRAM
        default:
            throw ComposeError.invalidProject("dynamic host-port allocation supports tcp and udp protocols, got '\(protocolName)'")
        }
    }

    private func allocateIPv4(socketKind: Int32) throws -> UInt16 {
        let descriptor = socket(AF_INET, socketKind, 0)
        guard descriptor >= 0 else {
            throw allocationError("socket")
        }
        defer {
            close(descriptor)
        }

        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        if normalizedHostAddress.isEmpty {
            address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        } else {
            guard inet_pton(AF_INET, normalizedHostAddress, &address.sin_addr) == 1 else {
                throw ComposeError.invalidProject("dynamic host-port allocation requires an IPv4 or IPv6 literal host address, got '\(normalizedHostAddress)'")
            }
        }

        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                guard bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
                    throw allocationError("bind")
                }
            }
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &bound) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                guard getsockname(descriptor, rebound, &length) == 0 else {
                    throw allocationError("getsockname")
                }
            }
        }
        return UInt16(bigEndian: bound.sin_port)
    }

    private func allocateIPv6(socketKind: Int32) throws -> UInt16 {
        let descriptor = socket(AF_INET6, socketKind, 0)
        guard descriptor >= 0 else {
            throw allocationError("socket")
        }
        defer {
            close(descriptor)
        }

        var address = sockaddr_in6()
        #if canImport(Darwin)
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        if normalizedHostAddress.isEmpty {
            address.sin6_addr = in6addr_any
        } else {
            guard inet_pton(AF_INET6, normalizedHostAddress, &address.sin6_addr) == 1 else {
                throw ComposeError.invalidProject("dynamic host-port allocation requires an IPv4 or IPv6 literal host address, got '\(normalizedHostAddress)'")
            }
        }

        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                guard bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 else {
                    throw allocationError("bind")
                }
            }
        }

        var bound = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        try withUnsafeMutablePointer(to: &bound) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                guard getsockname(descriptor, rebound, &length) == 0 else {
                    throw allocationError("getsockname")
                }
            }
        }
        return UInt16(bigEndian: bound.sin6_port)
    }

    private func allocationError(_ operation: String) -> ComposeError {
        ComposeError.invalidProject("failed to allocate dynamic host port during \(operation): \(String(cString: strerror(errno)))")
    }
}
