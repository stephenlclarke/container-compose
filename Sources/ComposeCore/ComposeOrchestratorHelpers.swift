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

import ContainerizationExtras
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

let projectLabel = ComposeRuntimeLabels.project
let imageVolumeAnonymousLabel = "com.apple.container.compose.image-volume"
let imageVolumeContainerLabel = "com.apple.container.compose.image-volume.container"
let imageVolumeServiceLabel = "com.apple.container.compose.image-volume.service"
let serviceLabel = ComposeRuntimeLabels.service
let oneOffLabel = ComposeRuntimeLabels.oneOff
let configHashLabel = "com.apple.container.compose.config-hash"
let workingDirectoryLabel = "com.apple.container.compose.project.working-directory"
let configFilesLabel = "com.apple.container.compose.project.config-files"
let configFilesHashLabel = "com.apple.container.compose.project.config-files-hash"
let reservedComposeLabelPrefix = ComposeRuntimeLabels.reservedPrefix
let reservedDockerComposeLabelPrefix = ComposeRuntimeLabels.reservedDockerComposePrefix
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
    func filtered(to selected: [String], allResources: Bool = false) throws -> ComposeProject {
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
        if allResources {
            return copy
        }

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
        let configNames = Set(selectedServices.flatMap { _, service in referencedComposeResources(service.configs) })
        copy.configs = filteredComposeResourceMap(copy.configs, referencedBy: configNames)
        let secretNames = Set(selectedServices.flatMap { _, service in referencedComposeResources(service.secrets) })
        copy.secrets = filteredComposeResourceMap(copy.secrets, referencedBy: secretNames)

        return copy
    }

    private func referencedComposeResources(_ resources: [ComposeValue]?) -> [String] {
        resources?.compactMap { resource in
            switch resource {
            case let .string(name):
                return name
            case let .object(fields):
                if case let .string(source)? = fields["source"] {
                    return source
                }
                return nil
            default:
                return nil
            }
        } ?? []
    }

    private func filteredComposeResourceMap<T>(_ resources: [String: T]?, referencedBy names: Set<String>) -> [String: T]? {
        guard let resources else {
            return nil
        }
        let filtered = resources.filter { names.contains($0.key) }
        return filtered.isEmpty ? nil : filtered
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

/// Builds one network attachment value accepted by apple/container.
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
    if let interfaceName = try networkGuestInterfaceName(service: service, network: network) {
        options.append("interface=\(interfaceName)")
    }
    try options.append(contentsOf: networkStaticAddressOptions(project: project, service: service, network: network))
    for address in try networkLinkLocalIPValues(service: service, network: network) {
        options.append("address=\(address)")
    }
    if !options.isEmpty {
        argument += "," + options.joined(separator: ",")
    }
    return argument
}

/// Orders network attachments so the runtime's first interface has the selected gateway.
func orderedNetworkAttachments(service: ComposeService) -> [String] {
    let attachments = service.networks ?? []
    return attachments.enumerated().sorted { lhs, rhs in
        let lhsPriority = service.networkOptions?[lhs.element]?.gatewayPriority ?? 0
        let rhsPriority = service.networkOptions?[rhs.element]?.gatewayPriority ?? 0
        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }
        return lhs.offset < rhs.offset
    }.map(\.element)
}

/// Returns the network selected for a service-level MAC address by `priority`.
func serviceMACAddressNetwork(service: ComposeService) -> String? {
    guard let firstNetwork = service.networks?.first else {
        return nil
    }
    return service.networks?.dropFirst().reduce(firstNetwork) { selected, network in
        let selectedPriority = service.networkOptions?[selected]?.priority ?? 0
        let networkPriority = service.networkOptions?[network]?.priority ?? 0
        return networkPriority > selectedPriority ? network : selected
    }
}

/// Resolves the effective MAC address for a supported network attachment.
func networkMACAddress(service: ComposeService, network: String) -> String? {
    if let macAddress = nonEmpty(service.networkOptions?[network]?.macAddress) {
        return macAddress
    }
    guard serviceMACAddressNetwork(service: service) == network else {
        return nil
    }
    return nonEmpty(service.macAddress)
}

/// Returns an interface name that is safe to encode in a runtime attachment.
func networkGuestInterfaceName(service: ComposeService, network: String) throws -> String? {
    guard let interfaceName = nonEmpty(service.networkOptions?[network]?.interfaceName) else {
        return nil
    }
    guard !interfaceName.contains(",") else {
        throw ComposeError.invalidProject(
            "service '\(service.name)' interface_name '\(interfaceName)' cannot contain ','",
        )
    }
    return interfaceName
}

/// Returns Compose link-local IP values that are safe to encode in a runtime attachment.
func networkLinkLocalIPValues(service: ComposeService, network: String) throws -> [String] {
    let addresses = service.networkOptions?[network]?.linkLocalIPs ?? []
    for address in addresses {
        guard !address.contains(",") else {
            throw ComposeError.invalidProject(
                "service '\(service.name)' link_local_ips value '\(address)' cannot contain ','",
            )
        }
        do {
            let parsed = try IPAddress(address)
            guard !parsed.isUnspecified else {
                throw ComposeError.invalidProject(
                    "service '\(service.name)' link_local_ips value '\(address)' must not be unspecified",
                )
            }
        } catch let error as ComposeError {
            throw error
        } catch {
            throw ComposeError.invalidProject(
                "service '\(service.name)' link_local_ips value '\(address)' must be a valid IPv4 or IPv6 address",
            )
        }
    }
    return addresses
}

/// Returns static primary-address options that are safe to encode in a runtime attachment.
func networkStaticAddressOptions(project: ComposeProject, service: ComposeService, network: String) throws -> [String] {
    guard let options = service.networkOptions?[network] else {
        return []
    }
    guard (service.networks ?? []).contains(network) else {
        if nonEmpty(options.ipv4Address) != nil || nonEmpty(options.ipv6Address) != nil {
            throw ComposeError.unsupported("service '\(service.name)' sets a static address on unattached network '\(network)'")
        }
        return []
    }

    var runtimeOptions: [String] = []
    if let rawIPv4Address = nonEmpty(options.ipv4Address) {
        try runtimeOptions.append(staticIPv4AddressOption(
            rawIPv4Address,
            project: project,
            service: service,
            network: network,
        ))
    }
    if let rawIPv6Address = nonEmpty(options.ipv6Address) {
        try runtimeOptions.append(staticIPv6AddressOption(
            rawIPv6Address,
            project: project,
            service: service,
            network: network,
        ))
    }
    return runtimeOptions
}

private func staticIPv4AddressOption(
    _ rawAddress: String,
    project: ComposeProject,
    service: ComposeService,
    network: String,
) throws -> String {
    guard !rawAddress.contains(",") else {
        throw ComposeError.invalidProject("service '\(service.name)' ipv4_address '\(rawAddress)' cannot contain ','")
    }
    let address: IPv4Address
    do {
        address = try IPv4Address(rawAddress)
    } catch {
        throw ComposeError.invalidProject("service '\(service.name)' ipv4_address '\(rawAddress)' must be a valid IPv4 address")
    }
    guard !address.isUnspecified else {
        throw ComposeError.invalidProject("service '\(service.name)' ipv4_address '\(rawAddress)' must not be unspecified")
    }
    try validateStaticIPv4Address(address, project: project, service: service, network: network)
    return "ip=\(address)"
}

private func staticIPv6AddressOption(
    _ rawAddress: String,
    project: ComposeProject,
    service: ComposeService,
    network: String,
) throws -> String {
    guard !rawAddress.contains(",") else {
        throw ComposeError.invalidProject("service '\(service.name)' ipv6_address '\(rawAddress)' cannot contain ','")
    }
    let address: IPv6Address
    do {
        address = try IPv6Address(rawAddress)
    } catch {
        throw ComposeError.invalidProject("service '\(service.name)' ipv6_address '\(rawAddress)' must be a valid IPv6 address")
    }
    guard address.zone == nil else {
        throw ComposeError.invalidProject("service '\(service.name)' ipv6_address '\(rawAddress)' must not include a zone identifier")
    }
    guard !address.isUnspecified else {
        throw ComposeError.invalidProject("service '\(service.name)' ipv6_address '\(rawAddress)' must not be unspecified")
    }
    try validateStaticIPv6Address(address, project: project, service: service, network: network)
    return "ip6=\(address)"
}

private func validateStaticIPv4Address(
    _ address: IPv4Address,
    project: ComposeProject,
    service: ComposeService,
    network: String,
) throws {
    guard let configuration = project.networks[network] else {
        throw ComposeError.invalidProject(
            "service '\(service.name)' ipv4_address on network '\(network)' requires a declared network",
        )
    }
    guard configuration.external != true else {
        return
    }
    let subnet = try staticIPv4Subnet(configuration, service: service, network: network)
    try validateStaticIPv4AddressRange(address, subnet: subnet, service: service, network: network)
    try validateStaticIPv4Gateway(address, configuration: configuration, service: service, network: network)
    try validateStaticIPv4ReservedAddresses(address, configuration: configuration, service: service, network: network)
}

private func staticIPv4Subnet(
    _ configuration: ComposeNetwork,
    service: ComposeService,
    network: String,
) throws -> CIDRv4 {
    guard let subnetText = nonEmpty(configuration.ipv4Subnet) else {
        throw ComposeError.invalidProject(
            "service '\(service.name)' ipv4_address on network '\(network)' requires an IPv4 IPAM subnet",
        )
    }
    do {
        return try CIDRv4(subnetText)
    } catch {
        throw ComposeError.invalidProject("network '\(network)' IPv4 IPAM subnet '\(subnetText)' is invalid")
    }
}

private func validateStaticIPv4AddressRange(
    _ address: IPv4Address,
    subnet: CIDRv4,
    service: ComposeService,
    network: String,
) throws {
    let lower = UInt64(subnet.lower.value) + 2
    let upper = UInt64(subnet.upper.value)
    guard upper >= 4, UInt64(address.value) >= lower, UInt64(address.value) <= upper - 2 else {
        throw ComposeError.invalidProject(
            "service '\(service.name)' ipv4_address '\(address)' is not an allocatable host address in network '\(network)'",
        )
    }
}

private func validateStaticIPv4Gateway(
    _ address: IPv4Address,
    configuration: ComposeNetwork,
    service: ComposeService,
    network: String,
) throws {
    if let gatewayText = nonEmpty(configuration.ipv4Gateway) {
        let gateway: IPv4Address
        do {
            gateway = try IPv4Address(gatewayText)
        } catch {
            throw ComposeError.invalidProject("network '\(network)' IPv4 IPAM gateway '\(gatewayText)' is invalid")
        }
        guard address != gateway else {
            throw ComposeError.invalidProject(
                "service '\(service.name)' ipv4_address '\(address)' is the gateway for network '\(network)'",
            )
        }
    }
}

private func validateStaticIPv4ReservedAddresses(
    _ address: IPv4Address,
    configuration: ComposeNetwork,
    service: ComposeService,
    network: String,
) throws {
    for reservedAddressText in configuration.ipv4ReservedAddresses ?? [] {
        let reservedAddress: IPv4Address
        do {
            reservedAddress = try IPv4Address(reservedAddressText)
        } catch {
            throw ComposeError.invalidProject("network '\(network)' IPv4 IPAM reserved address '\(reservedAddressText)' is invalid")
        }
        guard address != reservedAddress else {
            throw ComposeError.invalidProject(
                "service '\(service.name)' ipv4_address '\(address)' is reserved on network '\(network)'",
            )
        }
    }
}

/// Validates the optional IPv4 IPAM gateway before creating any project resource.
func validateNetworkIPv4Gateway(_ network: ComposeNetwork, name: String) throws {
    guard let gatewayText = nonEmpty(network.ipv4Gateway) else {
        return
    }
    guard let subnetText = nonEmpty(network.ipv4Subnet) else {
        throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM gateway requires an IPv4 IPAM subnet")
    }
    let subnet: CIDRv4
    let gateway: IPv4Address
    do {
        subnet = try CIDRv4(subnetText)
        gateway = try IPv4Address(gatewayText)
    } catch {
        throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM gateway '\(gatewayText)' is invalid")
    }
    guard subnet.contains(gateway), gateway != subnet.lower, gateway != subnet.upper else {
        throw ComposeError.invalidProject(
            "network '\(name)' IPv4 IPAM gateway '\(gateway)' must be an allocatable host address in subnet '\(subnet)'",
        )
    }
}

/// Validates the optional IPv4 IPAM allocation range before creating any project resource.
func validateNetworkIPv4AllocationRange(_ network: ComposeNetwork, name: String) throws {
    guard let allocationRangeText = nonEmpty(network.ipv4AllocationRange) else {
        return
    }
    guard let subnetText = nonEmpty(network.ipv4Subnet) else {
        throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM allocation range requires an IPv4 IPAM subnet")
    }
    let subnet: CIDRv4
    do {
        subnet = try CIDRv4(subnetText)
    } catch {
        throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM subnet '\(subnetText)' is invalid")
    }
    let allocationRange: CIDRv4
    do {
        allocationRange = try CIDRv4(allocationRangeText)
    } catch {
        throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM allocation range '\(allocationRangeText)' is invalid")
    }
    guard subnet.contains(allocationRange.lower), subnet.contains(allocationRange.upper) else {
        throw ComposeError.invalidProject(
            "network '\(name)' IPv4 IPAM allocation range '\(allocationRange)' must be contained in subnet '\(subnet)'",
        )
    }
    guard subnet.upper.value - subnet.lower.value >= 4 else {
        throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM subnet '\(subnet)' has no allocatable host addresses")
    }
    let allocationLower = max(subnet.lower.value + 2, allocationRange.lower.value)
    let allocationUpper = min(subnet.upper.value - 2, allocationRange.upper.value)
    guard allocationLower <= allocationUpper else {
        throw ComposeError.invalidProject(
            "network '\(name)' IPv4 IPAM allocation range '\(allocationRange)' contains no allocatable host addresses in subnet '\(subnet)'",
        )
    }
}

/// Validates IPv4 addresses reserved from allocation before creating any project resource.
func validateNetworkIPv4ReservedAddresses(_ network: ComposeNetwork, name: String) throws {
    guard let reservedAddressTexts = network.ipv4ReservedAddresses, !reservedAddressTexts.isEmpty else {
        return
    }
    guard let subnetText = nonEmpty(network.ipv4Subnet) else {
        throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM reserved addresses require an IPv4 IPAM subnet")
    }
    let subnet: CIDRv4
    do {
        subnet = try CIDRv4(subnetText)
    } catch {
        throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM subnet '\(subnetText)' is invalid")
    }
    guard subnet.upper.value - subnet.lower.value >= 4 else {
        throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM subnet '\(subnet)' has no allocatable host addresses")
    }
    let allocationLower = subnet.lower.value + 2
    let allocationUpper = subnet.upper.value - 2
    var reservedAddresses = Set<IPv4Address>()
    for addressText in reservedAddressTexts {
        let address: IPv4Address
        do {
            address = try IPv4Address(addressText)
        } catch {
            throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM reserved address '\(addressText)' is invalid")
        }
        guard address.value >= allocationLower, address.value <= allocationUpper else {
            throw ComposeError.invalidProject(
                "network '\(name)' IPv4 IPAM reserved address '\(address)' must be an allocatable host address in subnet '\(subnet)'",
            )
        }
        guard reservedAddresses.insert(address).inserted else {
            throw ComposeError.invalidProject("network '\(name)' IPv4 IPAM reserved addresses must be unique")
        }
    }
}

private func validateStaticIPv6Address(
    _ address: IPv6Address,
    project: ComposeProject,
    service: ComposeService,
    network: String,
) throws {
    guard let configuration = project.networks[network] else {
        throw ComposeError.invalidProject(
            "service '\(service.name)' ipv6_address on network '\(network)' requires a declared network",
        )
    }
    guard configuration.external != true else {
        return
    }
    guard let subnetText = nonEmpty(configuration.ipv6Subnet) else {
        throw ComposeError.invalidProject(
            "service '\(service.name)' ipv6_address on network '\(network)' requires an IPv6 IPAM subnet",
        )
    }
    let subnet: CIDRv6
    do {
        subnet = try CIDRv6(subnetText)
    } catch {
        throw ComposeError.invalidProject("network '\(network)' IPv6 IPAM subnet '\(subnetText)' is invalid")
    }
    guard subnet.contains(address) else {
        throw ComposeError.invalidProject(
            "service '\(service.name)' ipv6_address '\(address)' is not in network '\(network)' IPv6 IPAM subnet",
        )
    }
    if let gatewayText = nonEmpty(configuration.ipv6Gateway) {
        let gateway: IPv6Address
        do {
            gateway = try IPv6Address(gatewayText)
        } catch {
            throw ComposeError.invalidProject("network '\(network)' IPv6 IPAM gateway '\(gatewayText)' is invalid")
        }
        guard address != gateway else {
            throw ComposeError.invalidProject(
                "service '\(service.name)' ipv6_address '\(address)' is the gateway for network '\(network)'",
            )
        }
    }
}

/// Validates the optional IPv6 IPAM gateway before creating any project resource.
func validateNetworkIPv6Gateway(_ network: ComposeNetwork, name: String) throws {
    guard network.enableIPv6 != false, let gatewayText = nonEmpty(network.ipv6Gateway) else {
        return
    }
    guard let subnetText = nonEmpty(network.ipv6Subnet) else {
        throw ComposeError.invalidProject("network '\(name)' IPv6 IPAM gateway requires an IPv6 IPAM subnet")
    }
    let subnet: CIDRv6
    let gateway: IPv6Address
    do {
        subnet = try CIDRv6(subnetText)
        gateway = try IPv6Address(gatewayText)
    } catch {
        throw ComposeError.invalidProject("network '\(name)' IPv6 IPAM gateway '\(gatewayText)' is invalid")
    }
    guard gateway.zone == nil, !gateway.isUnspecified, subnet.contains(gateway) else {
        throw ComposeError.invalidProject(
            "network '\(name)' IPv6 IPAM gateway '\(gateway)' must be a usable address in subnet '\(subnet)'",
        )
    }
}

/// Returns canonical network aliases for an attachment.
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
    var contents: Data
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
        let data = contents
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
