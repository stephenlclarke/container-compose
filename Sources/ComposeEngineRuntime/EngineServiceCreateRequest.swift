// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
import ComposeRuntimeSPI
import Foundation

/// A prepared service request. Construction is side-effect free; unsupported
/// native-only policies fail before a gateway request can allocate a container.
struct EngineServiceCreateRequest: Encodable {
    let process: EngineServiceProcess
    let plan: ContainerServiceCreatePlan
    let host: EngineCreateValue
    let networks: EngineCreateValue
    let exposed: EngineCreateValue
    let imageReference: String

    init(
        plan: ContainerServiceCreatePlan, image: EngineImageConfig,
        environmentFileContents: [Data] = [], hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedImageID: String? = nil
    ) throws {
        if let resolvedImageID, !Self.validImageID(resolvedImageID) {
            throw ComposeError.invalidProject("Gateway returned an invalid immutable image ID")
        }
        imageReference = resolvedImageID ?? plan.imageReference
        guard let ports = plan.publishedPorts, let mounts = plan.resolvedMounts else {
            throw ComposeError.invalidProject("Gateway creation requires prepared ports and mounts")
        }
        try Self.validateNativePolicies(plan)
        let overrides = try EngineServiceEnvironment.resolve(
            plan, fileContents: environmentFileContents, hostEnvironment: hostEnvironment
        )
        process = try EngineServiceProcess(overrides, image: image)
        self.plan = plan
        host = try Self.hostConfiguration(plan, ports: ports, mounts: mounts)
        networks = try Self.networkConfiguration(plan.networkAttachments)
        let names = Set(try Self.exposedPortNames(plan.exposedPorts) + ports.map {
            "\($0.containerPort)/\($0.protocolName)"
        })
        exposed = .object(Dictionary(uniqueKeysWithValues: names.map { ($0, .object([:])) }))
    }

    enum CodingKeys: String, CodingKey {
        case image = "Image", labels = "Labels", host = "HostConfig", networks = "NetworkingConfig"
        case hostname = "Hostname", domainname = "Domainname", exposed = "ExposedPorts"
        case stopSignal = "StopSignal", stopTimeout = "StopTimeout", health = "Healthcheck"
        case requestedImageReference = "ContainerImageReference"
    }

    func encode(to encoder: Encoder) throws {
        try process.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(imageReference, forKey: .image)
        if imageReference != plan.imageReference {
            try values.encode(plan.imageReference, forKey: .requestedImageReference)
        }
        try values.encode(plan.labels, forKey: .labels)
        try values.encode(host, forKey: .host)
        try values.encode(networks, forKey: .networks)
        try values.encode(exposed, forKey: .exposed)
        try values.encodeIfPresent(plan.hostname, forKey: .hostname)
        try values.encodeIfPresent(plan.domainname, forKey: .domainname)
        try values.encodeIfPresent(plan.launchOptions.stopSignal, forKey: .stopSignal)
        try values.encodeIfPresent(plan.launchOptions.stopTimeoutSeconds, forKey: .stopTimeout)
        try values.encode(try Self.healthConfiguration(plan.healthCheck), forKey: .health)
    }

    private static func validateNativePolicies(_ plan: ContainerServiceCreatePlan) throws {
        let options = plan.launchOptions
        guard options.initImage == nil, !options.useEngineAPISocket,
              plan.blockIO == nil, plan.restartPolicy.retryDelayInNanoseconds == nil,
              plan.restartPolicy.successfulRunDurationInNanoseconds == nil
        else {
            throw ComposeError.unsupported("Gateway projection lacks a native init/socket/block-IO/restart extension")
        }
        guard options.resources.deviceMappings.isEmpty, options.resources.gpuRequests.isEmpty else {
            throw ComposeError.unsupported("Gateway device projection requires typed device requests")
        }
    }
}

/// A bounded, typed JSON tree used only at the Engine wire boundary.
indirect enum EngineCreateValue: Encodable, Equatable {
    case string(String), integer(Int64), boolean(Bool)
    case array([EngineCreateValue]), object([String: EngineCreateValue])

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(item): try value.encode(item)
        case let .integer(item): try value.encode(item)
        case let .boolean(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        }
    }

    static func strings(_ values: [String]) -> Self { .array(values.map(Self.string)) }
    static func dictionary(_ values: [String: String]) -> Self { .object(values.mapValues(Self.string)) }
}
