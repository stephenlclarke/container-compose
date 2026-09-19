// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
import ComposeRuntimeSPI

extension EngineServiceCreateRequest {
    static func networkConfiguration(_ attachments: [ComposeNetworkCreateAttachment]) throws -> EngineCreateValue {
        var endpoints: [String: EngineCreateValue] = [:]
        for attachment in attachments {
            if ["none", "host", "default"].contains(attachment.network) {
                guard attachment == ComposeNetworkCreateAttachment(network: attachment.network),
                      attachments.count == 1 else {
                    throw ComposeError.invalidProject("Special network mode cannot carry endpoint settings")
                }
                continue
            }
            guard endpoints[attachment.network] == nil else {
                throw ComposeError.invalidProject("Duplicate prepared network attachment")
            }
            guard attachment.scopedAliasMappings.isEmpty, attachment.mtu == nil,
                  attachment.interfaceName == nil
            else {
                throw ComposeError.unsupported(
                    "Gateway network projection lacks scoped aliases, MTU and interface naming"
                )
            }
            var ipam: [String: EngineCreateValue] = ["LinkLocalIPs": .strings(attachment.linkLocalAddresses)]
            ipam["IPv4Address"] = attachment.ipv4Address.map(EngineCreateValue.string)
            ipam["IPv6Address"] = attachment.ipv6Address.map(EngineCreateValue.string)
            var endpoint: [String: EngineCreateValue] = [
                "Aliases": .strings(attachment.aliases), "IPAMConfig": .object(ipam),
            ]
            endpoint["MacAddress"] = attachment.macAddress.map(EngineCreateValue.string)
            endpoints[attachment.network] = .object(endpoint)
        }
        return .object(["EndpointsConfig": .object(endpoints)])
    }

    static func portBindings(_ ports: [ComposePublishedPortBinding]) throws -> EngineCreateValue {
        var bindings: [String: [EngineCreateValue]] = [:]
        for port in ports {
            let key = "\(port.containerPort)/\(port.protocolName)"
            var binding: [String: EngineCreateValue] = ["HostPort": .string(String(port.hostPort))]
            if let address = port.hostAddress {
                if address.hasPrefix("[") {
                    guard address.hasSuffix("]"), address.dropFirst().dropLast().contains(":") else {
                        throw ComposeError.invalidProject("Invalid bracketed bind address")
                    }
                    binding["HostIp"] = .string(String(address.dropFirst().dropLast()))
                } else {
                    guard !address.contains("[") && !address.contains("]") else {
                        throw ComposeError.invalidProject("Invalid bind address brackets")
                    }
                    binding["HostIp"] = .string(address)
                }
            }
            bindings[key, default: []].append(.object(binding))
        }
        return .object(bindings.mapValues(EngineCreateValue.array))
    }

    static func exposedPortNames(_ values: [String]) throws -> [String] {
        try values.flatMap { value in
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { throw ComposeError.invalidProject("Invalid exposed port") }
            let proto = parts.count == 2 ? String(parts[1]) : "tcp"
            let range = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard ["tcp", "udp", "sctp"].contains(proto), (1...2).contains(range.count),
                  let lower = UInt16(range[0]), lower > 0,
                  let upper = UInt16(range[range.count - 1]), upper >= lower else {
                throw ComposeError.invalidProject("Invalid exposed port range or protocol")
            }
            return (lower...upper).map { "\($0)/\(proto)" }
        }
    }
}
