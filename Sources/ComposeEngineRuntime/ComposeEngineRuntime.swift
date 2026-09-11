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
import ComposeRuntimeSPI
import ContainerEngineWire
import ContainerUnixHTTPClient
import Darwin
import Foundation

/// Wires Compose to the runtime-neutral, current-user Container Engine socket.
///
/// The adapter speaks the Engine HTTP protocol but neither imports nor invokes
/// Docker software. Container creation remains on the selected Apple
/// `container` CLI so an unmodified stock installation can own VM lifecycle.
public enum ComposeEngineRuntime {
    public static let socketEnvironmentVariable = "CONTAINER_COMPOSE_ENGINE_SOCKET"
    public static let volumeInitializerEnvironmentVariable =
        "CONTAINER_COMPOSE_VOLUME_INITIALIZER"

    public static func dependencies(
        runner: CommandRunning = ProcessRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> ComposeOrchestratorDependencies {
        let provider = EngineRuntimeProvider(
            socketPath: environment[socketEnvironmentVariable] ?? defaultSocketPath(),
            volumeInitializerPath: environment[volumeInitializerEnvironmentVariable],
            runner: runner,
            containerBinary: options.containerBinary,
            environmentLauncher: options.environmentLauncher,
        )
        return ComposeOrchestratorDependencies(
            runner: runner,
            options: options,
            commands: .init(execManager: provider, launchManager: provider),
            runtime: ComposeOrchestratorRuntimeDependencies(
                services: .init(
                    imageVolumeInitializer: provider,
                    lifecycleManager: provider,
                    resourceManager: provider,
                ),
                discoveryManager: provider,
            ),
            imageManager: provider,
        )
    }

    public static func defaultSocketPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/devcontainer/engine.sock")
            .path
    }

}

public final class EngineRuntimeProvider: @unchecked Sendable {
    private let client: Result<ContainerUnixHTTPClient, any Error>
    private static let volumeInitializations = EngineVolumeInitializationCoordinator()
    private let volumeInitializerPathOverride: String?
    let runner: CommandRunning
    let containerBinary: String
    let environmentLauncher: String

    public init(
        socketPath: String,
        volumeInitializerPath: String? = nil,
        runner: CommandRunning = ProcessRunner(),
        containerBinary: String = ComposeExecutionOptions.defaultContainerBinary(),
        environmentLauncher: String = ComposeExecutionOptions.defaultEnvironmentLauncher
    ) {
        client = Result { try ContainerUnixHTTPClient(socketPath: socketPath) }
        volumeInitializerPathOverride = volumeInitializerPath
        self.runner = runner
        self.containerBinary = containerBinary
        self.environmentLauncher = environmentLauncher
    }

    func request<Response: Decodable>(
        _ method: DockerHTTPMethod,
        _ target: String,
        body: (any Encodable)? = nil,
        maximumBodyBytes: Int = 16 * 1024 * 1024,
    ) async throws -> Response {
        let payload: Data
        let headers: DockerHTTPHeaders
        if let body {
            payload = try JSONEncoder.engine.encode(AnyEncodable(body))
            headers = try DockerHTTPHeaders(uniqueFields: ["Content-Type": "application/json"])
        } else {
            payload = Data()
            headers = DockerHTTPHeaders()
        }
        let response = try await client.get().send(
            DockerHTTPRequest(method: method, target: target, headers: headers, body: payload),
            maximumBodyBytes: maximumBodyBytes,
        )
        return try JSONDecoder.engine.decode(Response.self, from: response.body)
    }

    func request(
        _ method: DockerHTTPMethod,
        _ target: String,
        body: (any Encodable)? = nil,
        rawBody: Data = Data(),
        contentType: String? = nil,
        maximumBodyBytes: Int = 16 * 1024 * 1024,
    ) async throws {
        let payload: Data = if let body {
            try JSONEncoder.engine.encode(AnyEncodable(body))
        } else {
            rawBody
        }
        let headers = try DockerHTTPHeaders(uniqueFields: contentType.map { ["Content-Type": $0] }
            ?? (body == nil ? [:] : ["Content-Type": "application/json"]))
        _ = try await client.get().send(
            DockerHTTPRequest(method: method, target: target, headers: headers, body: payload),
            maximumBodyBytes: maximumBodyBytes,
        )
    }

    func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathSegmentAllowed) ?? component
    }

    func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }

    private func target(_ path: String, queryFields: [(String, String?)]) -> String {
        let fields = queryFields.compactMap { key, value in
            value.map { "\(key)=\(query($0))" }
        }
        return fields.isEmpty ? path : path + "?" + fields.joined(separator: "&")
    }
}

extension EngineRuntimeProvider: ComposeRuntimeDiscoveryManaging {
    public func listContainers(all: Bool) async throws -> [ComposeContainerSummary] {
        let values: [EngineContainerListItem] = try await request(
            .get,
            "/v1.53/containers/json?all=\(all ? 1 : 0)",
        )
        return values.map(\.composeSummary)
    }

    public func getContainer(id: String) async throws -> ComposeContainerSummary? {
        do {
            let value: EngineContainerInspect = try await request(
                .get,
                "/v1.53/containers/\(escaped(id))/json",
            )
            return value.composeSummary
        } catch ContainerUnixHTTPClientError.server(status: 404, message: _) {
            return nil
        }
    }
}

extension EngineRuntimeProvider: ComposeRuntimeLifecycleManaging {
    public func startContainer(id: String) async throws {
        try await request(.post, "/v1.53/containers/\(escaped(id))/start")
    }

    public func killContainer(id: String, signal: String) async throws {
        try await request(.post, "/v1.53/containers/\(escaped(id))/kill?signal=\(query(signal))")
    }

    public func stopContainer(id: String, signal: String?, timeoutInSeconds: Int?) async throws {
        var fields: [String] = []
        if let signal {
            fields.append("signal=\(query(signal))")
        }
        if let timeoutInSeconds {
            fields.append("t=\(timeoutInSeconds)")
        }
        let suffix = fields.isEmpty ? "" : "?" + fields.joined(separator: "&")
        try await request(.post, "/v1.53/containers/\(escaped(id))/stop\(suffix)")
    }

    public func restartContainer(id: String, signal: String?, timeoutInSeconds: Int?) async throws {
        var fields: [String] = []
        if let signal {
            fields.append("signal=\(query(signal))")
        }
        if let timeoutInSeconds {
            fields.append("t=\(timeoutInSeconds)")
        }
        let suffix = fields.isEmpty ? "" : "?" + fields.joined(separator: "&")
        try await request(.post, "/v1.53/containers/\(escaped(id))/restart\(suffix)")
    }

    public func pauseContainer(id: String) async throws {
        try await request(.post, "/v1.53/containers/\(escaped(id))/pause")
    }

    public func unpauseContainer(id: String) async throws {
        try await request(.post, "/v1.53/containers/\(escaped(id))/unpause")
    }

    public func waitContainer(id: String) async throws -> Int32 {
        let value: EngineWaitResponse = try await request(
            .post,
            "/v1.53/containers/\(escaped(id))/wait?condition=not-running",
        )
        return value.statusCode
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        try await request(.delete, "/v1.53/containers/\(escaped(id))?force=\(force ? 1 : 0)&v=1")
    }
}

extension EngineRuntimeProvider: ComposeRuntimeResourceManaging {
    public func createNetwork(_ request: ComposeNetworkCreateRequest) async throws {
        let addressing = EngineIPAMConfig(
            subnet: request.ipv4Subnet,
            range: request.ipv4AllocationRange,
            gateway: request.ipv4Gateway,
            reserved: request.ipv4ReservedAddresses,
        )
        let payload = EngineNetworkCreateRequest(
            name: request.name,
            internalNetwork: request.isInternal,
            enableIPv4: request.enableIPv4,
            enableIPv6: request.enableIPv6,
            options: request.driverOpts,
            labels: request.labels,
            ipam: addressing.isEmpty ? nil : EngineIPAM(config: [addressing]),
        )
        let _: EngineNetworkCreateResponse = try await self.request(.post, "/v1.53/networks/create", body: payload)
    }

    public func deleteNetwork(id: String) async throws {
        try await request(.delete, "/v1.53/networks/\(escaped(id))")
    }

    public func createVolume(_ request: ComposeVolumeCreateRequest) async throws {
        let payload = EngineVolumeCreateRequest(
            name: request.name,
            driver: request.resolvedDriver,
            options: request.driverOpts,
            labels: request.labels,
        )
        let _: EngineVolume = try await self.request(.post, "/v1.53/volumes/create", body: payload)
    }

    public func listVolumes() async throws -> [ComposeVolumeSummary] {
        let response: EngineVolumeListResponse = try await request(.get, "/v1.53/volumes")
        return response.volumes.map {
            ComposeVolumeSummary(
                name: $0.name,
                driver: $0.driver,
                source: $0.mountpoint,
                labels: $0.labels,
                options: $0.options,
            )
        }
    }

    public func deleteVolume(name: String) async throws {
        try await request(.delete, "/v1.53/volumes/\(escaped(name))")
    }
}

extension EngineRuntimeProvider: ComposeRuntimeImageVolumeInitializing {
    public func initializeImageVolume(_ request: ComposeImageVolumeInitializationRequest) async throws {
        await Self.volumeInitializations.acquire(request.volumeName)
        do {
            try await initializeSerializedImageVolume(request)
            await Self.volumeInitializations.release(request.volumeName)
        } catch {
            await Self.volumeInitializations.release(request.volumeName)
            throw error
        }
    }

    private func initializeSerializedImageVolume(_ request: ComposeImageVolumeInitializationRequest) async throws {
        let volume: EngineVolume = try await self.request(
            .get,
            "/v1.53/volumes/\(escaped(request.volumeName))",
        )
        let destination = URL(fileURLWithPath: volume.mountpoint, isDirectory: true)
        let fileLock = try await EngineVolumeInitializationFileLock.acquire(
            volumeMountpoint: destination
        )
        defer { withExtendedLifetime(fileLock) {} }
        let pendingTransaction = try EngineVolumeInitializationTransaction.load(
            volumeMountpoint: destination
        )
        guard try pendingTransaction != nil || volumeIsEmpty(destination) else {
            return
        }
        let volumeInitializerPath = try volumeInitializerPath(for: request.platform)
        guard FileManager.default.isExecutableFile(atPath: volumeInitializerPath) else {
            throw ComposeError.invalidProject(
                "Docker-free image-volume initializer is not executable at \(volumeInitializerPath)"
            )
        }

        let helperImage = try await volumeInitializerImage(
            sourceImage: request.image,
            platform: request.platform,
            volumeMountpoint: destination,
            imageSubpath: request.imageSubpath
        )
        let transaction = try pendingTransaction
            ?? EngineVolumeInitializationTransaction.create(
                volumeMountpoint: destination
            )
        let helper = try await createVolumeInitializationHelper(
            request,
            image: helperImage.tag,
            helperPath: helperImage.helperPath,
            transaction: transaction
        )
        try await runVolumeInitializationHelper(helper.id)
        try transaction.complete()
    }

    private func createVolumeInitializationHelper(
        _ request: ComposeImageVolumeInitializationRequest,
        image: String,
        helperPath: String,
        transaction: EngineVolumeInitializationTransaction
    ) async throws -> EngineContainerCreateResponse {
        let helperName = "compose-volume-init-\(UUID().uuidString.lowercased())"
        let helperMountPath = try Self.helperMountPath(imageSubpath: request.imageSubpath)
        return try await self.request(
            .post,
            target(
                "/v1.53/containers/create",
                queryFields: [("name", helperName), ("platform", request.platform)],
            ),
            body: EngineContainerCreateRequest(
                image: image,
                labels: ["com.apple.container.compose.internal": "image-volume-init"],
                user: "0",
                entrypoint: [helperPath],
                command: [request.imageSubpath, helperMountPath, transaction.identifier],
                hostConfig: .init(mounts: [
                    .init(
                        type: "volume",
                        source: request.volumeName,
                        target: helperMountPath,
                        readOnly: false
                    ),
                ]),
            ),
        )
    }

    private func volumeInitializerImage(
        sourceImage: String,
        platform: String?,
        volumeMountpoint: URL,
        imageSubpath: String
    ) async throws -> EngineVolumeInitializerImageBuild {
        guard !sourceImage.contains(where: \.isWhitespace) else {
            throw ComposeError.invalidProject(
                "image reference for Docker-free volume initialization contains whitespace"
            )
        }
        let helperURL = URL(
            fileURLWithPath: try volumeInitializerPath(for: platform)
        )
        let helper = try Data(
            contentsOf: helperURL,
            options: [.mappedIfSafe]
        )
        let buildLock = try await EngineVolumeInitializationFileLock.acquire(
            path: Self.volumeInitializerBuildLockPath(volumeMountpoint)
        )
        defer { withExtendedLifetime(buildLock) {} }
        for _ in 0 ..< 3 {
            let image = try await inspectImage(sourceImage, platform: platform)
            let build = try Self.volumeInitializerBuild(
                image: image,
                platform: platform,
                helper: helper,
                helperName: helperURL.lastPathComponent,
                imageSubpath: imageSubpath
            )
            guard try await !imageExists(build.tag) else {
                return build
            }
            if let digest = image.repoDigests.first {
                try await buildVolumeInitializerImage(
                    sourceImage: digest,
                    build: build
                )
                return build
            }
            if try await buildFromVerifiedLocalImage(
                sourceReference: sourceImage,
                sourceID: image.id,
                build: build,
                platform: platform
            ) {
                return build
            }
        }
        throw ComposeError.commandFailed(
            command: "Engine image-volume initializer source snapshot",
            status: 1,
            stderr: "image reference changed repeatedly while creating an immutable build alias"
        )
    }

    private static func volumeInitializerBuild(
        image: EngineImageInspect,
        platform: String?,
        helper: Data,
        helperName: String,
        imageSubpath: String
    ) throws -> EngineVolumeInitializerImageBuild {
        let sourceDigest = image.repoDigests.first ?? image.id
        let helperPath = try helperExecutablePath(
            sourceDigest: sourceDigest,
            platform: platform,
            helperName: helperName,
            helper: helper,
            imageSubpath: imageSubpath
        )
        return EngineVolumeInitializerImageBuild.make(
            sourceDigest: sourceDigest,
            platform: platform,
            helper: helper,
            helperName: helperName,
            helperPath: helperPath
        )
    }

    private func volumeInitializerPath(for platform: String?) throws -> String {
        if let volumeInitializerPathOverride, !volumeInitializerPathOverride.isEmpty {
            return volumeInitializerPathOverride
        }
        return try ComposeEngineRuntime.volumeInitializerPath(platform: platform)
    }

    private static func volumeInitializerBuildLockPath(_ volumeMountpoint: URL) -> String {
        volumeMountpoint.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".compose-volume-initializer-image.lock")
            .path
    }

    private func buildFromVerifiedLocalImage(
        sourceReference: String,
        sourceID: String,
        build: EngineVolumeInitializerImageBuild,
        platform: String?
    ) async throws -> Bool {
        let aliasTag = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let alias = "devcontainer-volume-source:\(aliasTag)"
        try await tagImage(source: sourceReference, repository: "devcontainer-volume-source", tag: aliasTag)
        do {
            let aliased = try await inspectImage(alias, platform: platform)
            guard aliased.id == sourceID else {
                try await deleteImageReference(alias)
                return false
            }
            try await buildVolumeInitializerImage(
                sourceImage: alias,
                build: build
            )
            try await deleteImageReference(alias)
            return true
        } catch {
            try? await deleteImageReference(alias)
            throw error
        }
    }

    private func buildVolumeInitializerImage(
        sourceImage: String,
        build: EngineVolumeInitializerImageBuild
    ) async throws {
        let context = try await EngineVolumeInitializerBuildContext.make(
            sourceImage: sourceImage,
            helper: build.helper,
            helperName: build.helperName,
            helperPath: build.helperPath
        )
        try await request(
            .post,
            target(
                "/v1.53/build",
                queryFields: [
                    ("t", build.tag),
                    ("dockerfile", "Dockerfile"),
                    ("platform", build.platform),
                ]
            ),
            rawBody: context,
            contentType: "application/x-tar",
            maximumBodyBytes: 64 * 1024 * 1024
        )
    }

    private func tagImage(source: String, repository: String, tag: String) async throws {
        try await request(
            .post,
            target(
                "/v1.53/images/\(escaped(source))/tag",
                queryFields: [("repo", repository), ("tag", tag)]
            )
        )
    }

    private func deleteImageReference(_ reference: String) async throws {
        try await request(.delete, "/v1.53/images/\(escaped(reference))?force=0")
    }

    private func runVolumeInitializationHelper(_ helperID: String) async throws {
        do {
            try await request(
                .post,
                "/v1.53/containers/\(escaped(helperID))/start"
            )
            let wait: EngineWaitResponse = try await request(
                .post,
                "/v1.53/containers/\(escaped(helperID))/wait?condition=not-running"
            )
            guard wait.statusCode == 0 || wait.statusCode == 44 || wait.statusCode == 45 else {
                throw ComposeError.commandFailed(
                    command: "Engine image-volume initialization helper",
                    status: wait.statusCode,
                    stderr: "runtime-side image volume copy failed",
                )
            }
            try await removeInitializationHelper(helperID)
        } catch {
            try? await removeInitializationHelper(helperID)
            throw error
        }
    }

    private func removeInitializationHelper(_ id: String) async throws {
        try await request(.delete, "/v1.53/containers/\(escaped(id))?force=1&v=1")
    }

    private func volumeIsEmpty(_ destination: URL) throws -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ComposeError.invalidProject("runtime volume mountpoint is not a directory")
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        guard entries == ["lost+found"] else {
            return entries.isEmpty
        }
        let recovery = destination.appendingPathComponent("lost+found", isDirectory: true)
        let values = try recovery.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            return false
        }
        return try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty
    }

}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private extension Result {
    func get() throws -> Success {
        switch self {
        case let .success(value): value
        case let .failure(error): throw error
        }
    }
}

private extension JSONEncoder {
    static var engine: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var engine: JSONDecoder {
        JSONDecoder()
    }
}

private extension CharacterSet {
    static let urlPathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()

    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct EngineContainerListItem: Decodable {
    let id: String
    let names: [String]
    let image: String
    let imageID: String
    let state: String
    let status: String
    let ports: [EnginePort]
    let labels: [String: String]
    let mounts: [EngineMount]

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", imageID = "ImageID"
        case state = "State", status = "Status", ports = "Ports", labels = "Labels", mounts = "Mounts"
    }

    var composeSummary: ComposeContainerSummary {
        ComposeContainerSummary(
            id: id,
            name: names.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            status: state,
            labels: labels,
            image: .init(reference: image, digest: imageID),
            resources: .init(
                publishedPorts: ports.compactMap(\.composePort),
                mounts: mounts.map(\.composeMount),
            ),
        )
    }
}

private struct EngineContainerInspect: Decodable {
    let id: String
    let name: String
    let image: String
    let state: EngineContainerState
    let config: EngineContainerConfig
    let mounts: [EngineMount]
    let networkSettings: EngineNetworkSettings

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", image = "Image", state = "State", config = "Config"
        case mounts = "Mounts", networkSettings = "NetworkSettings"
    }

    var composeSummary: ComposeContainerSummary {
        ComposeContainerSummary(
            id: id,
            name: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            status: state.status,
            labels: config.labels,
            image: .init(reference: config.image, digest: image),
            resources: .init(
                publishedPorts: networkSettings.composePorts,
                mounts: mounts.map(\.composeMount),
                networks: networkSettings.networks.map {
                    .init(
                        network: $0.key,
                        ipv4Address: $0.value.ipAddress.nilIfEmpty,
                    )
                },
            ),
            state: .init(
                exitCode: state.exitCode,
                exitedDate: ISO8601DateFormatter.engineDate(from: state.finishedAt),
                health: state.health?.status,
            ),
        )
    }
}

private struct EngineContainerState: Decodable {
    let status: String
    let exitCode: Int32
    let finishedAt: String
    let health: EngineHealthStatus?

    enum CodingKeys: String, CodingKey {
        case status = "Status", exitCode = "ExitCode", finishedAt = "FinishedAt", health = "Health"
    }
}

private struct EngineHealthStatus: Decodable {
    let status: String
    enum CodingKeys: String, CodingKey { case status = "Status" }
}

private struct EngineContainerConfig: Decodable {
    let image: String
    let labels: [String: String]
    enum CodingKeys: String, CodingKey { case image = "Image", labels = "Labels" }
}

private struct EnginePort: Decodable {
    let address: String
    let privatePort: UInt16
    let publicPort: UInt16?
    let type: String
    enum CodingKeys: String, CodingKey {
        case address = "IP", privatePort = "PrivatePort", publicPort = "PublicPort", type = "Type"
    }

    var composePort: ComposeContainerPublishedPort? {
        guard let publicPort else { return nil }
        return .init(hostAddress: address, hostPort: publicPort, containerPort: privatePort, protocolName: type)
    }
}

private struct EngineMount: Decodable {
    let type: String
    let name: String
    let source: String
    let destination: String
    let readWrite: Bool
    enum CodingKeys: String, CodingKey {
        case type = "Type", name = "Name", source = "Source", destination = "Destination", readWrite = "RW"
    }

    var composeMount: ComposeMount {
        ComposeMount(
            type: type,
            source: name.isEmpty ? source : name,
            target: destination,
            readOnly: !readWrite,
        )
    }
}

private struct EngineNetworkSettings: Decodable {
    let ports: [String: [EnginePortBinding]?]
    let networks: [String: EngineEndpoint]
    enum CodingKeys: String, CodingKey { case ports = "Ports", networks = "Networks" }
    var composePorts: [ComposeContainerPublishedPort] {
        ports.flatMap { key, bindings -> [ComposeContainerPublishedPort] in
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard let containerPort = UInt16(parts.first ?? ""), let bindings else { return [] }
            return bindings.compactMap { binding in
                guard let hostPort = UInt16(binding.hostPort) else { return nil }
                return .init(
                    hostAddress: binding.hostIP,
                    hostPort: hostPort,
                    containerPort: containerPort,
                    protocolName: parts.count > 1 ? parts[1] : "tcp",
                )
            }
        }
    }
}

private struct EnginePortBinding: Decodable {
    let hostIP: String
    let hostPort: String
    enum CodingKeys: String, CodingKey { case hostIP = "HostIp", hostPort = "HostPort" }
}

private struct EngineEndpoint: Decodable {
    let ipAddress: String
    enum CodingKeys: String, CodingKey { case ipAddress = "IPAddress" }
}

private struct EngineWaitResponse: Decodable {
    let statusCode: Int32
    enum CodingKeys: String, CodingKey { case statusCode = "StatusCode" }
}

private struct EngineNetworkCreateRequest: Encodable {
    let name: String
    let internalNetwork: Bool
    let enableIPv4: Bool?
    let enableIPv6: Bool?
    let options: [String: String]
    let labels: [String: String]
    let ipam: EngineIPAM?
    enum CodingKeys: String, CodingKey {
        case name = "Name", internalNetwork = "Internal", enableIPv4 = "EnableIPv4", enableIPv6 = "EnableIPv6"
        case options = "Options", labels = "Labels", ipam = "IPAM"
    }
}

private struct EngineIPAM: Encodable {
    let config: [EngineIPAMConfig]
    enum CodingKeys: String, CodingKey { case config = "Config" }
}

private struct EngineIPAMConfig: Encodable {
    let subnet: String?
    let range: String?
    let gateway: String?
    let reserved: [String]
    var isEmpty: Bool {
        subnet == nil && range == nil && gateway == nil && reserved.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case subnet = "Subnet", range = "IPRange", gateway = "Gateway", reserved = "AuxiliaryAddresses"
    }
}

private struct EngineNetworkCreateResponse: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

private struct EngineVolumeCreateRequest: Encodable {
    let name: String
    let driver: String
    let options: [String: String]
    let labels: [String: String]
    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", options = "DriverOpts", labels = "Labels"
    }
}

private struct EngineVolumeListResponse: Decodable {
    let volumes: [EngineVolume]
    enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
}

struct EngineVolume: Decodable {
    let driver: String
    let labels: [String: String]
    let mountpoint: String
    let name: String
    let options: [String: String]
    enum CodingKeys: String, CodingKey {
        case driver = "Driver", labels = "Labels", mountpoint = "Mountpoint", name = "Name", options = "Options"
    }
}

private struct EngineContainerCreateRequest: Encodable {
    let image: String
    let labels: [String: String]
    let user: String
    let entrypoint: [String]
    let command: [String]
    let hostConfig: EngineContainerHostConfig

    enum CodingKeys: String, CodingKey {
        case image = "Image", labels = "Labels", user = "User"
        case entrypoint = "Entrypoint", command = "Cmd", hostConfig = "HostConfig"
    }
}

private struct EngineContainerHostConfig: Encodable {
    let mounts: [EngineContainerMount]
    enum CodingKeys: String, CodingKey { case mounts = "Mounts" }
}

private struct EngineContainerMount: Encodable {
    let type: String
    let source: String
    let target: String
    let readOnly: Bool
    enum CodingKeys: String, CodingKey {
        case type = "Type", source = "Source", target = "Target", readOnly = "ReadOnly"
    }
}

private struct EngineContainerCreateResponse: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

struct EngineImageInspect: Decodable {
    let id: String
    let repoTags: [String]
    let repoDigests: [String]
    let architecture: String
    let variant: String?
    let operatingSystem: String
    let config: EngineImageConfig
    enum CodingKeys: String, CodingKey {
        case architecture = "Architecture"
        case id = "Id"
        case operatingSystem = "Os"
        case variant = "Variant"
        case repoTags = "RepoTags"
        case repoDigests = "RepoDigests"
        case config = "Config"
    }

    var healthCheck: ComposeImageHealthCheck? {
        config.healthCheck.map {
            ComposeImageHealthCheck(
                test: $0.test,
                intervalInNanoseconds: $0.interval,
                timeoutInNanoseconds: $0.timeout,
                startPeriodInNanoseconds: $0.startPeriod,
                retries: $0.retries,
            )
        }
    }
}

struct EngineImageConfig: Decodable {
    let user: String
    let environment: [String]
    let entrypoint: [String]?
    let command: [String]?
    let labels: [String: String]
    let workingDirectory: String
    let exposedPorts: [String: EmptyObject]
    let volumes: [String: EmptyObject]
    let stopSignal: String?
    let healthCheck: EngineHealthCheck?
    enum CodingKeys: String, CodingKey {
        case user = "User", environment = "Env", entrypoint = "Entrypoint", command = "Cmd", labels = "Labels"
        case workingDirectory = "WorkingDir", exposedPorts = "ExposedPorts", volumes = "Volumes"
        case stopSignal = "StopSignal", healthCheck = "Healthcheck"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        user = try values.decodeIfPresent(String.self, forKey: .user) ?? ""
        environment = try values.decodeIfPresent([String].self, forKey: .environment) ?? []
        entrypoint = try values.decodeIfPresent([String].self, forKey: .entrypoint)
        command = try values.decodeIfPresent([String].self, forKey: .command)
        labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        exposedPorts = try values.decodeIfPresent([String: EmptyObject].self, forKey: .exposedPorts) ?? [:]
        volumes = try values.decodeIfPresent([String: EmptyObject].self, forKey: .volumes) ?? [:]
        stopSignal = try values.decodeIfPresent(String.self, forKey: .stopSignal)
        healthCheck = try values.decodeIfPresent(EngineHealthCheck.self, forKey: .healthCheck)
    }
}

struct EmptyObject: Decodable {}

struct EngineHealthCheck: Decodable {
    let test: [String]?
    let interval: Int64?
    let timeout: Int64?
    let startPeriod: Int64?
    let retries: Int?
    enum CodingKeys: String, CodingKey {
        case test = "Test", interval = "Interval", timeout = "Timeout", startPeriod = "StartPeriod", retries = "Retries"
    }
}

struct EngineImageSummary: Decodable {
    let containers: Int64
    let created: Int64
    let id: String
    let labels: [String: String]
    let parentID: String
    let repoDigests: [String]
    let repoTags: [String]
    let sharedSize: Int64
    let size: UInt64
    enum CodingKeys: String, CodingKey {
        case containers = "Containers", created = "Created", id = "Id", labels = "Labels", parentID = "ParentId"
        case repoDigests = "RepoDigests", repoTags = "RepoTags", sharedSize = "SharedSize", size = "Size"
    }
}
