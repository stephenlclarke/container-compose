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

@testable import ComposeContainerRuntime
import ComposeCore
import ComposeRuntimeSPI
import ContainerizationOCI
import ContainerResource
import Testing

@Suite("Container service create projection")
struct ContainerServiceCreateProjectionTests {
    @Test
    // This single projection assertion intentionally covers every neutral runtime field.
    // swiftlint:disable:next function_body_length
    func `projects every neutral create-plan runtime field`() throws {
        let process = ComposeProcessConfiguration(
            executable: "/usr/bin/worker",
            arguments: ["--serve"],
            environment: ["A=1"],
            workingDirectory: "/srv",
            terminal: true,
            user: .raw(userString: "app:staff"),
            runtimeOptions: .init(
                supplementalGroups: [10, 20],
                supplementalGroupNames: ["video"],
                rlimits: [.init(limit: "RLIMIT_NOFILE", soft: 1024, hard: 2048)],
                oomScoreAdj: -50,
                privileged: true,
                noNewPrivileges: true,
            ),
        )
        var runtime = ContainerServiceCreateRuntime()
        runtime.initProcess = process
        runtime.logging = ComposeLogConfiguration(
            storage: .none,
            maxSizeInBytes: 4096,
            maxFileCount: 3,
        )
        runtime.healthCheck = ComposeHealthCheck(
            process: process,
            intervalInNanoseconds: 11,
            timeoutInNanoseconds: 12,
            startPeriodInNanoseconds: 13,
            startIntervalInNanoseconds: 14,
            retries: 15,
        )
        runtime.restartPolicy = ComposeRestartPolicy(
            mode: .onFailure,
            maximumRetryCount: 4,
            retryDelayInNanoseconds: 5,
            successfulRunDurationInNanoseconds: 6,
        )
        runtime.hostname = "api"
        runtime.domainname = "example.test"
        runtime.hosts = [
            ComposeHostEntry(ipAddress: "192.0.2.1", hostnames: ["api", "api.local"]),
            ComposeHostEntry(ipAddress: ComposeHostEntry.hostGatewayAddress, hostnames: ["host"]),
        ]
        runtime.sysctls = ["net.ipv4.ip_forward": "1"]
        runtime.blockIO = ComposeLinuxBlockIO(
            weight: 100,
            leafWeight: 200,
            weightDevice: [
                ComposeLinuxWeightDevice(major: 1, minor: 2, weight: 300, leafWeight: 400),
            ],
            throttleReadBpsDevice: [
                ComposeLinuxThrottleDevice(major: 3, minor: 4, rate: 5),
            ],
            throttleWriteBpsDevice: [
                ComposeLinuxThrottleDevice(major: 6, minor: 7, rate: 8),
            ],
            throttleReadIOPSDevice: [
                ComposeLinuxThrottleDevice(major: 9, minor: 10, rate: 11),
            ],
            throttleWriteIOPSDevice: [
                ComposeLinuxThrottleDevice(major: 12, minor: 13, rate: 14),
            ],
        )
        runtime.cpuShares = 512
        runtime.cgroupParent = "compose/demo"
        runtime.memoryReservationInBytes = 268_435_456
        runtime.memorySwapLimitInBytes = 536_870_912
        let plan = ContainerServiceCreatePlan(
            identity: ContainerServiceCreateIdentity(name: "demo-api-1", imageReference: "example/api"),
            runtime: runtime,
        )

        let projection = plan.containerRuntimeProjection

        expectProcess(projection.initProcess)
        #expect(projection.logging == ContainerLogConfiguration(
            storage: .none,
            maxSizeInBytes: 4096,
            maxFileCount: 3,
        ))
        let healthCheck = try #require(projection.healthCheck)
        expectProcess(healthCheck.process)
        #expect(healthCheck.intervalInNanoseconds == 11)
        #expect(healthCheck.timeoutInNanoseconds == 12)
        #expect(healthCheck.startPeriodInNanoseconds == 13)
        #expect(healthCheck.startIntervalInNanoseconds == 14)
        #expect(healthCheck.retries == 15)
        #expect(projection.restartPolicy == ContainerRestartPolicy(
            mode: .onFailure,
            maximumRetryCount: 4,
            retryDelayInNanoseconds: 5,
            successfulRunDurationInNanoseconds: 6,
        ))
        #expect(projection.hostname == "api")
        #expect(projection.domainname == "example.test")
        #expect(projection.hosts == [
            ContainerConfiguration.HostEntry(ipAddress: "192.0.2.1", hostnames: ["api", "api.local"]),
            ContainerConfiguration.HostEntry(ipAddress: "host-gateway", hostnames: ["host"]),
        ])
        #expect(projection.sysctls == ["net.ipv4.ip_forward": "1"])
        let blockIO = try #require(projection.blockIO)
        #expect(blockIO.weight == 100)
        #expect(blockIO.leafWeight == 200)
        #expect(blockIO.weightDevice.count == 1)
        #expect(blockIO.weightDevice[0].major == 1)
        #expect(blockIO.weightDevice[0].minor == 2)
        #expect(blockIO.weightDevice[0].weight == 300)
        #expect(blockIO.weightDevice[0].leafWeight == 400)
        expectThrottle(blockIO.throttleReadBpsDevice, major: 3, minor: 4, rate: 5)
        expectThrottle(blockIO.throttleWriteBpsDevice, major: 6, minor: 7, rate: 8)
        expectThrottle(blockIO.throttleReadIOPSDevice, major: 9, minor: 10, rate: 11)
        expectThrottle(blockIO.throttleWriteIOPSDevice, major: 12, minor: 13, rate: 14)
        #expect(projection.cpuShares == 512)
        #expect(projection.cgroupParent == "compose/demo")
        #expect(projection.memoryReservationInBytes == 268_435_456)
        #expect(projection.memorySwapLimitInBytes == 536_870_912)
    }

    @Test(
        arguments: [
            (ComposeRestartPolicy.Mode.no, ContainerRestartPolicy.Mode.no),
            (.onFailure, .onFailure),
            (.always, .always),
            (.unlessStopped, .unlessStopped),
        ],
    )
    func `projects every restart mode`(
        composeMode: ComposeRestartPolicy.Mode,
        containerMode: ContainerRestartPolicy.Mode,
    ) {
        #expect(ComposeRestartPolicy(mode: composeMode).containerRestartPolicy.mode == containerMode)
    }

    @Test
    func `projects numeric process users and local logging`() {
        let process = ComposeProcessConfiguration(
            executable: "/bin/true",
            arguments: [],
            environment: [],
            user: .id(uid: 501, gid: 20),
        ).containerProcessConfiguration

        #expect(process.user == .id(uid: 501, gid: 20))
        #expect(ComposeLogConfiguration.standard.containerLogConfiguration == .default)
    }

    private func expectProcess(_ process: ProcessConfiguration) {
        #expect(process.executable == "/usr/bin/worker")
        #expect(process.arguments == ["--serve"])
        #expect(process.environment == ["A=1"])
        #expect(process.workingDirectory == "/srv")
        #expect(process.terminal)
        #expect(process.user == .raw(userString: "app:staff"))
        #expect(process.supplementalGroups == [10, 20])
        #expect(process.supplementalGroupNames == ["video"])
        #expect(process.rlimits.count == 1)
        #expect(process.rlimits[0].limit == "RLIMIT_NOFILE")
        #expect(process.rlimits[0].soft == 1024)
        #expect(process.rlimits[0].hard == 2048)
        #expect(process.oomScoreAdj == -50)
        #expect(process.privileged)
        #expect(process.noNewPrivileges)
    }

    private func expectThrottle(
        _ devices: [ContainerizationOCI.LinuxThrottleDevice],
        major: Int64,
        minor: Int64,
        rate: UInt64,
    ) {
        #expect(devices.count == 1)
        #expect(devices[0].major == major)
        #expect(devices[0].minor == minor)
        #expect(devices[0].rate == rate)
    }
}
