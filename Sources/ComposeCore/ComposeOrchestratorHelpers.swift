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

import ContainerResource
import CryptoKit
import Foundation

func reconcileProgressMessage(service: ComposeService, command: String) -> String {
    command == "create" ? "Creating \(service.name)" : "Starting \(service.name)"
}

/// Minimal inspect result needed to decide whether an existing service
/// container can be reused.
struct ExistingContainer {
    var configHash: String?
}

extension ComposeNetworkOptions {
    /// Names the Compose fields that need runtime attachment support.
    func unsupportedFieldNames() throws -> [String] {
        var fields: [String] = []
        if let driverOpts, driverOpts.contains(where: { !networkMTUDriverOptionKeys.contains($0.key) }) {
            fields.append("driver_opts")
        }
        _ = try networkMTU()
        if let gatewayPriority, gatewayPriority != 0 {
            fields.append("gw_priority")
        }
        if let interfaceName, !interfaceName.isEmpty {
            fields.append("interface_name")
        }
        if let ipv4Address, !ipv4Address.isEmpty {
            fields.append("ipv4_address")
        }
        if let ipv6Address, !ipv6Address.isEmpty {
            fields.append("ipv6_address")
        }
        if let linkLocalIPs, !linkLocalIPs.isEmpty {
            fields.append("link_local_ips")
        }
        if let priority, priority != 0 {
            fields.append("priority")
        }
        return fields
    }

    /// Returns the supported MTU driver option value accepted by apple/container.
    func networkMTU() throws -> String? {
        let values = networkMTUDriverOptionKeys.compactMap { key -> (key: String, value: String)? in
            guard let value = driverOpts?[key] else {
                return nil
            }
            return (key, value)
        }
        guard let first = values.first else {
            return nil
        }
        if values.contains(where: { $0.value != first.value }) {
            throw ComposeError.invalidProject("network MTU driver options must not conflict")
        }
        guard let mtu = Int(first.value), mtu > 0 else {
            throw ComposeError.invalidProject("network MTU driver option '\(first.key)' must be a positive integer")
        }
        return String(mtu)
    }
}

/// Stable service/resource snapshot used to derive the recreate config hash.
struct ServiceConfigFingerprint: Encodable {
    var service: ComposeService
    var networks: [String: String]
    var volumes: [String: String]
}

/// One label override passed to `compose run`.
struct ComposeLabelOverride {
    var key: String
    var value: String?

    var rawValue: String {
        guard let value else {
            return key
        }
        return "\(key)=\(value)"
    }
}

let projectLabel = "com.apple.container.compose.project"
let serviceLabel = "com.apple.container.compose.service"
let oneOffLabel = "com.apple.container.compose.oneoff"
let configHashLabel = "com.apple.container.compose.config-hash"
let workingDirectoryLabel = "com.apple.container.compose.project.working-directory"
let configFilesLabel = "com.apple.container.compose.project.config-files"
let configFilesHashLabel = "com.apple.container.compose.project.config-files-hash"
let reservedComposeLabelPrefix = "com.apple.container.compose."
let reservedDockerComposeLabelPrefix = "com.docker.compose."
let reservedComposeLabelPrefixes = [reservedComposeLabelPrefix, reservedDockerComposeLabelPrefix]
let supportedHealthCheckKeys = Set([
    "disable",
    "interval",
    "retries",
    "start_interval",
    "start_period",
    "test",
    "timeout",
])
let healthCheckDurationFields = [
    (composeName: "interval", runtimeName: "--health-interval"),
    (composeName: "timeout", runtimeName: "--health-timeout"),
    (composeName: "start_period", runtimeName: "--health-start-period"),
    (composeName: "start_interval", runtimeName: "--health-start-interval"),
]
let networkMTUDriverOptionKeys = [
    "com.docker.network.driver.mtu",
    "mtu",
]
let rfc1123LabelPattern = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"#

extension ComposeContainerSummary {
    /// Compose project label attached to a runtime container.
    var projectName: String? {
        labels[projectLabel]
    }

    /// Compose service label attached to a runtime container.
    var serviceName: String? {
        labels[serviceLabel]
    }

    /// Whether this container was created by `compose run`.
    var isOneOff: Bool {
        labels[oneOffLabel] == "true"
    }

    /// Compose config hash label used for recreate decisions.
    var configHash: String? {
        labels[configHashLabel]
    }
}

extension ComposeProject {
    /// Returns a copy scoped to explicitly selected services for `compose config`.
    func filtered(to selected: [String]) throws -> ComposeProject {
        guard !selected.isEmpty else {
            return self
        }
        var copy = self
        let selectedServices = try selected.map { name in
            guard let service = services[name] else {
                throw ComposeError.invalidProject("unknown service '\(name)'")
            }
            return (name, service)
        }
        copy.services = Dictionary(uniqueKeysWithValues: selectedServices)

        let networkNames = Set(selectedServices.flatMap { _, service in service.networks ?? [] })
        copy.networks = copy.networks.filter { networkNames.contains($0.key) }

        let volumeNames = Set(selectedServices.flatMap { _, service in
            (service.volumes ?? []).compactMap { mount -> String? in
                guard mount.type == nil || mount.type == "volume",
                      let source = mount.source,
                      !source.hasPrefix("/")
                else {
                    return nil
                }
                return source
            }
        })
        copy.volumes = copy.volumes.filter { volumeNames.contains($0.key) }

        return copy
    }
}

/// Returns whether a service pull policy can be implemented with local runtime primitives.
func isSupportedServicePullPolicy(_ policy: String) -> Bool {
    ["always", "missing", "if_not_present", "never", "build"].contains(policy) || stalePullPolicyInterval(policy) != nil
}

/// Returns the refresh interval for Compose time-window pull policies.
func stalePullPolicyInterval(_ policy: String) -> TimeInterval? {
    switch policy {
    case "daily":
        return 24 * 60 * 60
    case "weekly":
        return 7 * 24 * 60 * 60
    default:
        guard policy.hasPrefix("every_") else {
            return nil
        }
        return parsePullPolicyDuration(String(policy.dropFirst("every_".count))).map(TimeInterval.init)
    }
}

/// Parses Compose duration suffixes such as `1h30m` into seconds.
func parsePullPolicyDuration(_ value: String) -> Int? {
    guard !value.isEmpty else {
        return nil
    }
    var index = value.startIndex
    var total = 0
    while index < value.endIndex {
        let digitStart = index
        while index < value.endIndex, value[index].isNumber {
            index = value.index(after: index)
        }
        guard digitStart < index,
              let amount = Int(value[digitStart ..< index]),
              index < value.endIndex,
              let multiplier = pullPolicyDurationMultiplier(value[index])
        else {
            return nil
        }
        total += amount * multiplier
        index = value.index(after: index)
    }
    return total > 0 ? total : nil
}

/// Returns the seconds represented by one Compose pull-policy duration unit.
func pullPolicyDurationMultiplier(_ unit: Character) -> Int? {
    switch unit {
    case "w":
        7 * 24 * 60 * 60
    case "d":
        24 * 60 * 60
    case "h":
        60 * 60
    case "m":
        60
    case "s":
        1
    default:
        nil
    }
}

/// Returns the runtime resource name for a project-scoped network or volume.
func resourceName(project: String, name: String) -> String {
    "\(slug(project))_\(slug(name))"
}

/// Resolves a Compose network reference to the name used by `container`.
func networkRuntimeName(project: ComposeProject, composeName: String) -> String {
    guard let network = project.networks[composeName] else {
        return resourceName(project: project.name, name: composeName)
    }
    return networkRuntimeName(project: project, composeName: composeName, network: network)
}

/// Builds the single network attachment value accepted by apple/container.
func networkAttachmentArgument(project: ComposeProject, service: ComposeService, network: String) throws -> String {
    var argument = networkRuntimeName(project: project, composeName: network)
    var options: [String] = []
    for alias in try networkAliasValues(service: service, network: network) {
        options.append("alias=\(alias)")
    }
    if let macAddress = networkMACAddress(service: service, network: network) {
        options.append("mac=\(macAddress)")
    }
    if let mtu = try service.networkOptions?[network]?.networkMTU() {
        options.append("mtu=\(mtu)")
    }
    if !options.isEmpty {
        argument += "," + options.joined(separator: ",")
    }
    return argument
}

/// Resolves the effective MAC address for a supported single-network service.
func networkMACAddress(service: ComposeService, network: String) -> String? {
    nonEmpty(service.networkOptions?[network]?.macAddress) ?? nonEmpty(service.macAddress)
}

/// Returns canonical network aliases for a supported single-network attachment.
func networkAliasValues(service: ComposeService, network: String) throws -> [String] {
    var aliases: [String] = []
    var seen = Set<String>()
    for raw in service.networkAliases?[network] ?? [] {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let alias = canonicalRFC1123Hostname(value) else {
            throw invalidRFC1123HostnameError(raw, field: "network alias", service: service)
        }
        if seen.insert(alias).inserted {
            aliases.append(alias)
        }
    }
    return aliases
}

/// Canonicalizes a Docker-compatible RFC1123 hostname.
func canonicalRFC1123Hostname(_ raw: String) -> String? {
    let hostname = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
    guard !hostname.isEmpty, hostname.utf8.count <= 253 else {
        return nil
    }
    for label in hostname.split(separator: ".", omittingEmptySubsequences: false) {
        guard label.range(of: rfc1123LabelPattern, options: .regularExpression) != nil else {
            return nil
        }
    }
    return hostname
}

/// Builds the shared invalid-hostname error used by hostname-like Compose fields.
func invalidRFC1123HostnameError(_ raw: String, field: String, service: ComposeService) -> ComposeError {
    .invalidProject("service '\(service.name)' \(field) '\(raw)' is not a valid RFC1123 hostname")
}

/// Returns a string value only when it contains meaningful content.
func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    return value
}

/// Config or secret kind used by service file-grant mount rendering.
enum ComposeFileMountKind {
    case config
    case secret

    var singularName: String {
        switch self {
        case .config:
            "config"
        case .secret:
            "secret"
        }
    }

    var pluralName: String {
        switch self {
        case .config:
            "configs"
        case .secret:
            "secrets"
        }
    }

    func targetPath(source: String, target: String?) -> String {
        guard let target = nonEmpty(target?.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            switch self {
            case .config:
                return "/\(source)"
            case .secret:
                return "/run/secrets/\(source)"
            }
        }
        if target.hasPrefix("/") {
            return target
        }
        switch self {
        case .config:
            return "/\(target)"
        case .secret:
            return "/run/secrets/\(target)"
        }
    }

    var defaultMaterializedPermissions: Int {
        switch self {
        case .config:
            0o444
        case .secret:
            0o444
        }
    }

    var supportedDefinitionFields: String {
        switch self {
        case .config:
            "file, environment, or content"
        case .secret:
            "file or environment"
        }
    }
}

/// Service-level config or secret grant after reading Compose's short or long
/// syntax from the normalized JSON model.
struct ComposeFileGrant {
    var source: String
    var target: String?
    var uid: String?
    var gid: String?
    var mode: ComposeValue?
}

/// Project-local file content staged for runtime config or secret bind mounts.
struct ComposeMaterializedFile {
    var url: URL
    var contents: String
    var permissions: Int

    /// Creates the backing file with restrictive directory permissions.
    func write() throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = Data(contents.utf8)
        if fileManager.fileExists(atPath: url.path) {
            if try Data(contentsOf: url) != data {
                try data.write(to: url, options: .atomic)
            }
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            return
        }
        guard fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: permissions],
        ) else {
            throw ComposeError.invalidProject("failed to materialize Compose config or secret at '\(url.path)'")
        }
    }
}

extension ComposeValue {
    var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var intValue: Int? {
        switch self {
        case let .number(value):
            let number = NSDecimalNumber(decimal: value)
            guard number.decimalValue == value else {
                return nil
            }
            let int = number.intValue
            return Decimal(int) == value ? int : nil
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }
}
