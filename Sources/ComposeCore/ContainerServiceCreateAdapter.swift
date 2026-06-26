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
import ContainerizationOCI

/// User-visible service identity fields for create planning.
public struct ContainerServiceCreateIdentity: Sendable {
    public var name: String
    public var imageReference: String
    public var oneOff: Bool
    public var autoRemove: Bool
    public var labels: [String: String]

    public init(
        name: String,
        imageReference: String,
        oneOff: Bool = false,
        autoRemove: Bool = false,
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.imageReference = imageReference
        self.oneOff = oneOff
        self.autoRemove = autoRemove
        self.labels = labels
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
    public var initProcess: ProcessConfiguration
    public var logging: ContainerLogConfiguration
    public var healthCheck: ContainerHealthCheck?
    public var restartPolicy: ContainerRestartPolicy
    public var hostname: String?
    public var domainname: String?
    public var hosts: [ContainerConfiguration.HostEntry]
    public var sysctls: [String: String]
    public var blockIO: LinuxBlockIO?

    public init(
        identity: ContainerServiceCreateIdentity,
        runtime: ContainerServiceCreateRuntime = ContainerServiceCreateRuntime()
    ) {
        self.name = identity.name
        self.imageReference = identity.imageReference
        self.oneOff = identity.oneOff
        self.autoRemove = identity.autoRemove
        self.labels = identity.labels
        self.initProcess = runtime.initProcess
        self.logging = runtime.logging
        self.healthCheck = runtime.healthCheck
        self.restartPolicy = runtime.restartPolicy
        self.hostname = runtime.hostname
        self.domainname = runtime.domainname
        self.hosts = runtime.hosts
        self.sysctls = runtime.sysctls
        self.blockIO = runtime.blockIO
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
        resolveHealthCheck: Bool = true
    ) {
        self.name = name
        self.oneOff = oneOff
        self.autoRemove = autoRemove
        self.includeRestartPolicy = includeRestartPolicy
        self.resolveHealthCheck = resolveHealthCheck
    }
}
