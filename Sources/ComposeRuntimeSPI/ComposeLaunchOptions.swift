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

/// Effective launch settings, after Compose validation and default omission.
/// Values retain native quantity/security syntax; they are not a CLI argument vector.
public struct ComposeLaunchOptions: Codable, Equatable, Sendable {
    public var namespaces = ComposeNamespaceOptions()
    public var resources = ComposeResourceOptions()
    public var security = ComposeSecurityOptions()
    public var platform: String?
    public var runtime: String?
    public var stopSignal: String?
    public var stopTimeoutSeconds: Int?
    public var dnsServers: [String] = []
    public var dnsSearch: [String] = []
    public var dnsOptions: [String] = []
    public var initEnabled = false
    public var initImage: String?
    public var useEngineAPISocket = false

    /// Defaults request no additional runtime policy.
    public init() {}
}

/// Nil selects the existing native default for that namespace or isolation mode.
public struct ComposeNamespaceOptions: Codable, Equatable, Sendable {
    public var isolation: String?
    public var pid: String?
    public var cgroup: String?
    public var ipc: String?
    public var uts: String?
    public var user: String?

    public init() {}
}

/// Additional resource settings not already carried by the service create plan.
public struct ComposeResourceOptions: Codable, Equatable, Sendable {
    public var oomScoreAdjustment: Int?
    public var pidsLimit: Int?
    public var cpuSet: String?
    public var cpuPeriod: Int?
    public var cpuQuota: Int?
    public var memoryLimit: String?
    public var cpus: String?
    public var sharedMemorySize: String?
    public var ulimits: [String] = []
    /// Validated native field syntax, not whole-command argument parsing.
    public var deviceMappings: [String] = []
    public var gpuRequests: [String] = []

    public init() {}
}

/// Validated effective policy; unsupported security profiles never reach this model.
public struct ComposeSecurityOptions: Codable, Equatable, Sendable {
    public var supplementalGroups: [String] = []
    public var privileged = false
    public var capabilitiesAdded: [String] = []
    public var capabilitiesDropped: [String] = []
    public var options: [String] = []
    public var deviceCgroupRules: [String] = []
    public var readOnlyRootFilesystem = false

    public init() {}
}
