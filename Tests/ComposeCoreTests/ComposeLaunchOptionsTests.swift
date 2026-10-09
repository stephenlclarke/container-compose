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

@testable import ComposeCore
import Foundation
import Testing

struct ComposeLaunchOptionsTests {
    private var orchestrator: ComposeOrchestrator {
        var options = ComposeExecutionOptions(dryRun: true)
        options.initImage = "init:fixture"
        return ComposeOrchestrator(options: options)
    }

    @Test func preservesNamespacesLifecycleAndDNS() async throws {
        let service = composeService(name: "app", image: "fixture:latest") {
            $0.isolation = "dedicated-vm"
            $0.pid = "host"
            $0.cgroup = "host"
            $0.ipc = "host"
            $0.uts = "host"
            $0.usernsMode = "private"
            $0.platform = "linux/arm64"
            $0.runtime = "native"
            $0.stopSignal = "SIGUSR1"
            $0.stopGracePeriodSeconds = 0
            $0.dns = ["192.0.2.1", "2001:db8::1"]
            $0.dnsSearch = ["example.test", "."]
            $0.dnsOptions = ["ndots:2", "timeout:1"]
            $0.initEnabled = true
            $0.useAPISocket = true
        }
        let launch = try await launch(service)
        let options = launch.configuration.launchOptions
        #expect(options.namespaces.isolation == "dedicated-vm")
        #expect(options.namespaces.pid == "host")
        #expect(options.namespaces.cgroup == "host")
        #expect(options.namespaces.ipc == "host")
        #expect(options.namespaces.uts == "host")
        #expect(options.namespaces.user == "private")
        #expect(options.stopTimeoutSeconds == 0)
        #expect(options.dnsServers == service.dns)
        #expect(options.dnsSearch == service.dnsSearch)
        #expect(options.dnsOptions == service.dnsOptions)
        #expect(options.platform == "linux/arm64")
        #expect(options.runtime == "native")
        #expect(options.stopSignal == "SIGUSR1")
        #expect(options.initEnabled && options.useEngineAPISocket)
        #expect(options.initImage == "init:fixture")
        expectOptions(launch.arguments, [
            ("--isolation", "dedicated-vm"), ("--pid", "host"), ("--cgroupns", "host"),
            ("--ipc", "host"), ("--uts", "host"), ("--userns", "private"),
            ("--platform", "linux/arm64"), ("--runtime", "native"), ("--stop-signal", "SIGUSR1"),
            ("--stop-timeout", "0"), ("--dns", "192.0.2.1"), ("--dns", "2001:db8::1"),
            ("--dns-search", "."), ("--dns-option", "ndots:2"), ("--init-image", "init:fixture")
        ])
        #expect(launch.arguments.contains("--init"))
        #expect(launch.arguments.contains("--engine-api-socket"))
        try expectRoundTrip(options)
    }

    @Test func preservesResourceValuesWithoutRounding() async throws {
        let service = composeService(name: "app", image: "fixture:latest") {
            $0.oomScoreAdj = -999
            $0.pidsLimit = 42
            $0.cpuset = "0,2-3"
            $0.cpuPeriod = 100_000
            $0.cpuQuota = -1
            $0.memLimit = "67108864"
            $0.cpus = "0.125"
            $0.shmSize = "16m"
            $0.ulimits = ["nofile=1024:2048", "nproc=64"]
        }
        let launch = try await launch(service)
        let resources = launch.configuration.launchOptions.resources
        #expect(resources.oomScoreAdjustment == -999)
        #expect(resources.pidsLimit == 42)
        #expect(resources.cpuSet == "0,2-3")
        #expect(resources.cpuPeriod == 100_000)
        #expect(resources.cpuQuota == -1)
        #expect(resources.memoryLimit == "67108864")
        #expect(resources.cpus == "0.125")
        #expect(resources.sharedMemorySize == "16m")
        #expect(resources.ulimits == service.ulimits)
        expectOptions(launch.arguments, [
            ("--oom-score-adj", "-999"), ("--pids-limit", "42"), ("--cpuset-cpus", "0,2-3"),
            ("--cpu-period", "100000"), ("--cpu-quota", "-1"), ("--memory", "67108864"),
            ("--cpus", "0.125"), ("--shm-size", "16m"), ("--ulimit", "nofile=1024:2048"),
            ("--ulimit", "nproc=64")
        ])
        try expectRoundTrip(launch.configuration.launchOptions)
    }

    @Test func preservesEffectiveSecurityPolicy() async throws {
        let service = composeService(name: "app", image: "fixture:latest") {
            $0.groupAdd = ["staff", "1001", "staff", "1001"]
            $0.privileged = true
            $0.capAdd = ["NET_ADMIN", "SYS_PTRACE"]
            $0.capDrop = ["MKNOD"]
            $0.securityOpt = ["no-new-privileges", "systempaths:unconfined", "seccomp=unconfined"]
            $0.readOnly = true
        }
        let launch = try await launch(service)
        let security = launch.configuration.launchOptions.security
        #expect(security.supplementalGroups == ["1001", "staff"])
        #expect(security.privileged && security.readOnlyRootFilesystem)
        #expect(security.capabilitiesAdded == service.capAdd)
        #expect(security.capabilitiesDropped == service.capDrop)
        #expect(security.options == ["no-new-privileges:true", "systempaths=unconfined"])
        expectOptions(launch.arguments, [
            ("--group-add", "1001"), ("--group-add", "staff"), ("--cap-add", "NET_ADMIN"),
            ("--cap-add", "SYS_PTRACE"), ("--cap-drop", "MKNOD"),
            ("--security-opt", "no-new-privileges:true"), ("--security-opt", "systempaths=unconfined")
        ])
        #expect(launch.arguments.contains("--privileged"))
        #expect(launch.arguments.contains("--read-only"))
        #expect(!launch.arguments.contains("seccomp=unconfined"))
        try expectRoundTrip(launch.configuration.launchOptions)
    }

    @Test(arguments: [nil, 0, -1] as [Int?])
    func omitsDefaultAndEmptySettings(pids: Int?) throws {
        let service = composeService(name: "app", image: "fixture:latest") {
            $0.isolation = "default"
            $0.pid = "private"
            $0.cgroup = "private"
            $0.ipc = "private"
            $0.uts = "private"
            $0.usernsMode = "host"
            $0.pidsLimit = pids
            $0.cpuPeriod = 0
            $0.cpuQuota = 0
            $0.platform = ""
            $0.runtime = ""
            $0.stopSignal = ""
            $0.memLimit = ""
            $0.cpus = ""
            $0.shmSize = ""
            $0.cpuset = ""
        }
        let options = try ComposeOrchestrator(options: .init(dryRun: true)).serviceLaunchOptions(service: service)
        #expect(options == ComposeLaunchOptions())
        try expectRoundTrip(options)
    }

    @Test func rejectsUnsupportedPolicyBeforeReturningPlan() throws {
        for service in [
            composeService(name: "app", image: "fixture") { $0.securityOpt = ["seccomp=custom.json"] },
            composeService(name: "app", image: "fixture") { $0.pid = "service:database" },
            composeService(name: "app", image: "fixture") { $0.oomScoreAdj = 1001 },
            composeService(name: "app", image: "fixture") { $0.groupAdd = [""] }
        ] {
            #expect(throws: ComposeError.self) { try orchestrator.serviceLaunchOptions(service: service) }
        }
    }

    @Test func preservesDevicesAndInvocationOptions() async throws {
        let service = composeService(name: "app", image: "fixture:latest") {
            $0.devices = [.string("/dev/fuse:/dev/fuse:rw")]
            $0.deviceCgroupRules = ["c 10:229 rw"]
            $0.gpus = [.string("all")]
        }
        let run = RunArgumentOptions {
            $0.detach = true
            $0.envFiles = ["/workspace/settings with spaces.env", "/workspace/override.env"]
        }
        let launch = try await orchestrator.serviceLaunchPlan(
            project: composeProject(name: "test", services: ["app": service]), service: service, options: run
        )
        let plan = launch.configuration
        #expect(plan.detach)
        #expect(plan.environmentFiles == run.envFiles)
        #expect(plan.launchOptions.resources.deviceMappings == ["/dev/fuse:/dev/fuse:rw"])
        #expect(plan.launchOptions.resources.gpuRequests == ["all"])
        #expect(plan.launchOptions.security.deviceCgroupRules == ["c 10:229 rw"])
        #expect(launch.arguments.contains("--detach"))
        expectOptions(launch.arguments, [
            ("--device", "/dev/fuse:/dev/fuse:rw"), ("--device-cgroup-rule", "c 10:229 rw"),
            ("--gpus", "all"), ("--env-file", "/workspace/settings with spaces.env"),
            ("--env-file", "/workspace/override.env")
        ])
        try expectRoundTrip(plan.launchOptions)
    }

    private func launch(_ service: ComposeService) async throws -> ContainerServiceLaunchPlan {
        let result = try await orchestrator.serviceLaunchPlan(
            project: composeProject(name: "test", services: ["app": service]), service: service
        )
        let data = try JSONEncoder().encode(result.configuration)
        #expect(try JSONDecoder().decode(ContainerServiceCreatePlan.self, from: data) == result.configuration)
        return result
    }

    private func expectOptions(_ arguments: [String], _ options: [(String, String)]) {
        for (flag, value) in options {
            #expect(arguments.containsSequence([flag, value]))
        }
    }

    private func expectRoundTrip(_ options: ComposeLaunchOptions) throws {
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(ComposeLaunchOptions.self, from: data) == options)
    }
}
