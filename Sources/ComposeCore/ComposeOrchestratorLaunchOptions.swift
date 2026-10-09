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

extension ComposeOrchestrator {
    func serviceLaunchOptions(service: ComposeService) throws -> ComposeLaunchOptions {
        var result = ComposeLaunchOptions()
        result.namespaces = try serviceNamespaceOptions(service: service)
        result.resources = try serviceResourceOptions(service: service)
        result.security = try serviceSecurityOptions(service: service)
        result.platform = nonEmptyLaunchValue(service.platform)
        result.runtime = nonEmptyLaunchValue(service.runtime)
        result.stopSignal = nonEmptyLaunchValue(service.stopSignal)
        result.stopTimeoutSeconds = service.stopGracePeriodSeconds
        result.dnsServers = service.dns ?? []
        result.dnsSearch = service.dnsSearch ?? []
        result.dnsOptions = service.dnsOptions ?? []
        result.initEnabled = service.initEnabled == true
        result.initImage = nonEmptyLaunchValue(options.initImage)
        result.useEngineAPISocket = service.useAPISocket == true
        return result
    }

    private func serviceNamespaceOptions(service: ComposeService) throws -> ComposeNamespaceOptions {
        var result = ComposeNamespaceOptions()
        result.isolation = try runtimeIsolationArgument(service: service)
        result.pid = try runtimePIDArgument(service: service)
        result.cgroup = try runtimeCgroupNamespaceArgument(service: service)
        result.ipc = try runtimeIPCNamespaceArgument(service: service)
        result.uts = try runtimeUTSNamespaceArgument(service: service)
        result.user = try runtimeUserNamespaceArgument(service: service)
        return result
    }

    private func serviceResourceOptions(service: ComposeService) throws -> ComposeResourceOptions {
        var result = ComposeResourceOptions()
        result.oomScoreAdjustment = try runtimeOOMScoreAdj(service: service)
        // Compose local mode does not project non-positive PID limits to the engine.
        result.pidsLimit = service.pidsLimit.flatMap { $0 > 0 ? $0 : nil }
        result.cpuSet = nonEmptyLaunchValue(service.cpuset)
        result.cpuPeriod = service.cpuPeriod.flatMap { $0 != 0 ? $0 : nil }
        result.cpuQuota = service.cpuQuota.flatMap { $0 != 0 ? $0 : nil }
        result.memoryLimit = nonEmptyLaunchValue(service.memLimit)
        result.cpus = nonEmptyLaunchValue(service.cpus)
        result.sharedMemorySize = nonEmptyLaunchValue(service.shmSize)
        result.ulimits = service.ulimits ?? []
        result.deviceMappings = try runtimeDeviceArguments(service: service)
        result.gpuRequests = try runtimeGPUArguments(service: service)
        return result
    }

    private func serviceSecurityOptions(service: ComposeService) throws -> ComposeSecurityOptions {
        var result = ComposeSecurityOptions()
        result.supplementalGroups = try runtimeSupplementalGroupArguments(service: service)
        result.privileged = service.privileged == true
        result.capabilitiesAdded = service.capAdd ?? []
        result.capabilitiesDropped = service.capDrop ?? []
        result.options = try runtimeSecurityOptionArguments(service: service)
        result.deviceCgroupRules = try runtimeDeviceCgroupRuleArguments(service: service)
        result.readOnlyRootFilesystem = service.readOnly == true
        return result
    }

    private func nonEmptyLaunchValue(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
