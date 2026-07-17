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
        public var oneOffIdentifier: @Sendable () -> String = ComposeExecutionOptions.defaultOneOffIdentifier
        public var currentDate: @Sendable () -> Date = Date.init
        public var hostPortAllocator: @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16 = ComposeExecutionOptions.defaultHostPortAllocator
        public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) } {
            didSet {
                usesDefaultSleep = false
            }
        }

        /// Distinguishes the production clock from deterministic test hooks.
        var usesDefaultSleep = true
        public var confirm: @Sendable (_ prompt: String) async throws -> Bool = ComposeExecutionOptions.defaultConfirmation
        public var emitStatus: @Sendable (String) -> Void = ComposeExecutionOptions.defaultStatusEmitter
        public var emit: @Sendable (String) -> Void = { print($0) }
        public var emitData: (@Sendable (Data) -> Void)?
        public var copyInputArchive: @Sendable () -> FileHandle = { .standardInput }
        public var copyOutputArchive: @Sendable () -> FileHandle = { .standardOutput }

        public init() {
            // Property declarations intentionally provide the production defaults.
        }

        public init(_ configure: (inout RuntimeHooks) -> Void) {
            self.init()
            configure(&self)
        }

        public init(oneOffIdentifier: @escaping @Sendable () -> String, emit: @escaping @Sendable (String) -> Void) {
            self.init {
                $0.oneOffIdentifier = oneOffIdentifier
                $0.emit = emit
            }
        }

        public init(oneOffIdentifier: @escaping @Sendable () -> String) {
            self.init { $0.oneOffIdentifier = oneOffIdentifier }
        }

        public init(currentDate: @escaping @Sendable () -> Date, emit: @escaping @Sendable (String) -> Void) {
            self.init {
                $0.currentDate = currentDate
                $0.emit = emit
            }
        }

        public init(currentDate: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
            self.init {
                $0.currentDate = currentDate
                $0.sleep = sleep
            }
        }

        public init(
            currentDate: @escaping @Sendable () -> Date,
            emit: @escaping @Sendable (String) -> Void,
            emitData: @escaping @Sendable (Data) -> Void,
        ) {
            self.init {
                $0.currentDate = currentDate
                $0.emit = emit
                $0.emitData = emitData
            }
        }

        public init(confirm: @escaping @Sendable (_ prompt: String) async throws -> Bool) {
            self.init { $0.confirm = confirm }
        }

        public init(emit: @escaping @Sendable (String) -> Void) {
            self.init { $0.emit = emit }
        }

        public init(emitData: @escaping @Sendable (Data) -> Void) {
            self.init { $0.emitData = emitData }
        }

        public init(emit: @escaping @Sendable (String) -> Void, emitData: @escaping @Sendable (Data) -> Void) {
            self.init {
                $0.emit = emit
                $0.emitData = emitData
            }
        }

        public init(hostPortAllocator: @escaping @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16) {
            self.init { $0.hostPortAllocator = hostPortAllocator }
        }

        public init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
            self.init { $0.sleep = sleep }
        }

        public init(copyInputArchive: @escaping @Sendable () -> FileHandle) {
            self.init { $0.copyInputArchive = copyInputArchive }
        }

        public init(copyOutputArchive: @escaping @Sendable () -> FileHandle) {
            self.init { $0.copyOutputArchive = copyOutputArchive }
        }
    }

    public var dryRun: Bool
    public var maxParallelism: Int?
    public var serviceContainerNameSeparator: String
    public var removeOrphans: Bool
    public var ignoreOrphans: Bool
    public var reportOrphans: Bool
    public var containerBinary: String
    public var initImage: String?
    public var environmentLauncher: String
    public var oneOffIdentifier: @Sendable () -> String
    public var currentDate: @Sendable () -> Date
    public var hostPortAllocator: @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16
    public var watchPollInterval: Duration
    public var materializedConfigSecretDirectory: URL
    public var sleep: @Sendable (Duration) async throws -> Void {
        didSet {
            usesDefaultSleep = false
        }
    }

    /// Distinguishes the production clock from deterministic test hooks.
    var usesDefaultSleep: Bool
    public var confirm: @Sendable (_ prompt: String) async throws -> Bool
    public var emitStatus: @Sendable (String) -> Void
    public var emit: @Sendable (String) -> Void
    public var emitData: @Sendable (Data) -> Void
    public var copyInputArchive: @Sendable () -> FileHandle
    public var copyOutputArchive: @Sendable () -> FileHandle
    public var progress: ComposeProgressReporter

    public init() {
        dryRun = false
        maxParallelism = nil
        serviceContainerNameSeparator = "-"
        removeOrphans = false
        ignoreOrphans = false
        reportOrphans = false
        containerBinary = ComposeExecutionOptions.defaultContainerBinary()
        initImage = ComposeExecutionOptions.defaultInitImage()
        environmentLauncher = ComposeExecutionOptions.defaultEnvironmentLauncher
        oneOffIdentifier = ComposeExecutionOptions.defaultOneOffIdentifier
        currentDate = Date.init
        hostPortAllocator = ComposeExecutionOptions.defaultHostPortAllocator
        watchPollInterval = .seconds(1)
        materializedConfigSecretDirectory = ComposeExecutionOptions.defaultMaterializedConfigSecretDirectory()
        sleep = { try await Task.sleep(for: $0) }
        usesDefaultSleep = true
        confirm = ComposeExecutionOptions.defaultConfirmation
        emitStatus = ComposeExecutionOptions.defaultStatusEmitter
        emit = { print($0) }
        emitData = ComposeExecutionOptions.defaultLogDataEmitter
        copyInputArchive = { .standardInput }
        copyOutputArchive = { .standardOutput }
        progress = .disabled
    }

    public init(_ configure: (inout ComposeExecutionOptions) -> Void) {
        self.init()
        configure(&self)
    }

    public init(runtimeHooks: RuntimeHooks) {
        self.init()
        apply(runtimeHooks: runtimeHooks)
    }

    public init(dryRun: Bool) {
        self.init()
        self.dryRun = dryRun
    }

    public init(progress: ComposeProgressReporter) {
        self.init()
        self.progress = progress
    }

    public init(dryRun: Bool, runtimeHooks: RuntimeHooks) {
        self.init(runtimeHooks: runtimeHooks)
        self.dryRun = dryRun
    }

    public init(dryRun: Bool, serviceContainerNameSeparator: String, runtimeHooks: RuntimeHooks) {
        self.init(dryRun: dryRun, runtimeHooks: runtimeHooks)
        self.serviceContainerNameSeparator = serviceContainerNameSeparator
    }

    public init(maxParallelism: Int?, runtimeHooks: RuntimeHooks) {
        self.init(runtimeHooks: runtimeHooks)
        self.maxParallelism = maxParallelism
    }

    public init(maxParallelism: Int?) {
        self.init()
        self.maxParallelism = maxParallelism
    }

    /// Resolves Docker Compose's root parallelism controls.
    ///
    /// An explicit `--parallel` value wins over `COMPOSE_PARALLEL_LIMIT`.
    /// Docker Compose uses `-1` when neither control is supplied, which means
    /// that independent engine calls are not locally capped.
    public static func effectiveParallelism(
        explicit: Int?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws -> Int {
        if let explicit {
            return try validateParallelism(explicit, source: "--parallel")
        }
        guard let configured = environment["COMPOSE_PARALLEL_LIMIT"] else {
            return -1
        }
        guard let limit = Int(configured.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ComposeError.invalidProject("COMPOSE_PARALLEL_LIMIT must be -1 or a positive integer")
        }
        return try validateParallelism(limit, source: "COMPOSE_PARALLEL_LIMIT")
    }

    public init(dryRun: Bool = false, emit: @escaping @Sendable (String) -> Void) {
        self.init(
            dryRun: dryRun,
            runtimeHooks: RuntimeHooks(
                emit: emit,
                emitData: { emit(String(decoding: $0, as: UTF8.self)) },
            ),
        )
    }

    public init(hostPortAllocator: @escaping @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16) {
        self.init(runtimeHooks: RuntimeHooks { $0.hostPortAllocator = hostPortAllocator })
    }

    public init(currentDate: @escaping @Sendable () -> Date) {
        self.init(runtimeHooks: RuntimeHooks { $0.currentDate = currentDate })
    }

    public init(environmentLauncher: String) {
        self.init()
        self.environmentLauncher = environmentLauncher
    }

    public init(initImage: String?) {
        self.init()
        self.initImage = initImage
    }

    public init(
        containerBinary: String,
        environmentLauncher: String,
        runtimeHooks: RuntimeHooks = RuntimeHooks(),
    ) {
        self.init(runtimeHooks: runtimeHooks)
        self.containerBinary = containerBinary
        self.environmentLauncher = environmentLauncher
    }

    public init(oneOffIdentifier: @escaping @Sendable () -> String) {
        self.init(runtimeHooks: RuntimeHooks { $0.oneOffIdentifier = oneOffIdentifier })
    }

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.init(runtimeHooks: RuntimeHooks { $0.sleep = sleep })
    }

    public init(
        watchPollInterval: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
    ) {
        self.init(
            runtimeHooks: RuntimeHooks { $0.sleep = sleep },
        )
        self.watchPollInterval = watchPollInterval
    }

    public init(
        dryRun: Bool,
        containerBinary: String,
        emit: @escaping @Sendable (String) -> Void,
    ) {
        self.init(
            dryRun: dryRun,
            emit: emit,
        )
        self.containerBinary = containerBinary
    }

    public init(
        materializedConfigSecretDirectory: URL,
        runtimeHooks: RuntimeHooks = RuntimeHooks(),
    ) {
        self.init(runtimeHooks: runtimeHooks)
        self.materializedConfigSecretDirectory = materializedConfigSecretDirectory
    }

    public init(
        dryRun: Bool,
        materializedConfigSecretDirectory: URL,
        runtimeHooks: RuntimeHooks = RuntimeHooks(),
    ) {
        self.init(runtimeHooks: runtimeHooks)
        self.dryRun = dryRun
        self.materializedConfigSecretDirectory = materializedConfigSecretDirectory
    }

    public init(
        dryRun: Bool,
        hostPortAllocator: @escaping @Sendable (_ hostAddress: String?, _ protocolName: String) throws -> UInt16,
        emit: @escaping @Sendable (String) -> Void,
    ) {
        self.init(
            dryRun: dryRun,
            emit: emit,
        )
        self.hostPortAllocator = hostPortAllocator
    }

    private mutating func apply(runtimeHooks: RuntimeHooks) {
        oneOffIdentifier = runtimeHooks.oneOffIdentifier
        currentDate = runtimeHooks.currentDate
        hostPortAllocator = runtimeHooks.hostPortAllocator
        sleep = runtimeHooks.sleep
        usesDefaultSleep = runtimeHooks.usesDefaultSleep
        confirm = runtimeHooks.confirm
        emitStatus = runtimeHooks.emitStatus
        emit = runtimeHooks.emit
        emitData = runtimeHooks.emitData ?? ComposeExecutionOptions.defaultLogDataEmitter
        copyInputArchive = runtimeHooks.copyInputArchive
        copyOutputArchive = runtimeHooks.copyOutputArchive
    }

    public static func defaultOneOffIdentifier() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    public static func defaultContainerBinary() -> String {
        ProcessInfo.processInfo.environment["CONTAINER_BIN"]
            ?? ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_CONTAINER"]
            ?? "container"
    }

    /// Validates the values accepted by Docker Compose's parallelism controls.
    private static func validateParallelism(_ value: Int, source: String) throws -> Int {
        guard value == -1 || value > 0 else {
            throw ComposeError.invalidProject("\(source) must be -1 or a positive integer")
        }
        return value
    }

    public static func defaultInitImage() -> String? {
        let value = ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_INIT_IMAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
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

    /// Writes Compose-owned status messages without mixing them with service output.
    public static func defaultStatusEmitter(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
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
