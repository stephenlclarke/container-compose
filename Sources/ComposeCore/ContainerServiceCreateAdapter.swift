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

import ContainerizationOCI
import ContainerResource

/// User-visible service identity fields for create planning.
public struct ContainerServiceCreateIdentity: Sendable {
    public var name: String
    public var imageReference: String
    public var oneOff: Bool
    public var autoRemove: Bool
    public var labels: [String: String]
    public var annotations: [String: String]

    public init(
        name: String,
        imageReference: String,
        oneOff: Bool = false,
        autoRemove: Bool = false,
        labels: [String: String] = [:],
        annotations: [String: String] = [:],
    ) {
        self.name = name
        self.imageReference = imageReference
        self.oneOff = oneOff
        self.autoRemove = autoRemove
        self.labels = labels
        self.annotations = annotations
    }
}

/// Runtime-specific service create fields.
public struct ContainerServiceCreateRuntime: Sendable {
    public var initProcess: ProcessConfiguration
    public var logging: ContainerLogConfiguration
    public var healthCheck: ContainerHealthCheck?
    public var restartPolicy: ContainerRestartPolicy
    public var hostname: String?
    public var domainname: String?
    public var hosts: [ContainerConfiguration.HostEntry]
    public var sysctls: [String: String]
    public var blockIO: LinuxBlockIO?
    public var cpuShares: UInt64?
    public var cgroupParent: String?
    public var memoryReservationInBytes: Int64?
    public var memorySwapLimitInBytes: Int64?

    public init() {
        initProcess = ComposeRuntimeDefaults.shellProcess()
        logging = ContainerLogConfiguration.default
        healthCheck = nil
        restartPolicy = ContainerRestartPolicy.no
        hostname = nil
        domainname = nil
        hosts = []
        sysctls = [:]
        blockIO = nil
        cpuShares = nil
        cgroupParent = nil
        memoryReservationInBytes = nil
        memorySwapLimitInBytes = nil
    }
}

/// Compose-owned typed create-time values for a service container.
///
/// This is the boundary that lets Docker/Compose syntax stay in
/// `container-compose` while later execution code can create containers through
/// apple/container typed APIs instead of Docker-shaped CLI flags.
public struct ContainerServiceCreatePlan: Sendable {
    public var name: String
    public var imageReference: String
    public var oneOff: Bool
    public var autoRemove: Bool
    public var labels: [String: String]
    public var annotations: [String: String]
    public var initProcess: ProcessConfiguration
    public var logging: ContainerLogConfiguration
    public var healthCheck: ContainerHealthCheck?
    public var restartPolicy: ContainerRestartPolicy
    public var hostname: String?
    public var domainname: String?
    public var hosts: [ContainerConfiguration.HostEntry]
    public var sysctls: [String: String]
    public var blockIO: LinuxBlockIO?
    public var cpuShares: UInt64?
    public var cgroupParent: String?
    public var memoryReservationInBytes: Int64?
    public var memorySwapLimitInBytes: Int64?

    public init(
        identity: ContainerServiceCreateIdentity,
        runtime: ContainerServiceCreateRuntime = ContainerServiceCreateRuntime(),
    ) {
        name = identity.name
        imageReference = identity.imageReference
        oneOff = identity.oneOff
        autoRemove = identity.autoRemove
        labels = identity.labels
        annotations = identity.annotations
        initProcess = runtime.initProcess
        logging = runtime.logging
        healthCheck = runtime.healthCheck
        restartPolicy = runtime.restartPolicy
        hostname = runtime.hostname
        domainname = runtime.domainname
        hosts = runtime.hosts
        sysctls = runtime.sysctls
        blockIO = runtime.blockIO
        cpuShares = runtime.cpuShares
        cgroupParent = runtime.cgroupParent
        memoryReservationInBytes = runtime.memoryReservationInBytes
        memorySwapLimitInBytes = runtime.memorySwapLimitInBytes
    }
}

/// Public planning options for service-container create projections.
public struct ContainerServiceCreatePlanOptions: Sendable {
    public var name: String?
    public var oneOff: Bool
    public var autoRemove: Bool
    public var includeRestartPolicy: Bool
    public var resolveHealthCheck: Bool

    public init(
        name: String? = nil,
        oneOff: Bool = false,
        autoRemove: Bool = false,
        includeRestartPolicy: Bool = true,
        resolveHealthCheck: Bool = true,
    ) {
        self.name = name
        self.oneOff = oneOff
        self.autoRemove = autoRemove
        self.includeRestartPolicy = includeRestartPolicy
        self.resolveHealthCheck = resolveHealthCheck
    }
}
