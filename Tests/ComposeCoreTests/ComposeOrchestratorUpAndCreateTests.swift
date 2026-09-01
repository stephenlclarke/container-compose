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

import ComposeContainerRuntime
@testable import ComposeCore
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import Testing

extension ComposeOrchestratorTests {
    @Test("up creates resources and runs services with compose labels")
    func upCreatesResourcesAndRunsServicesWithComposeLabels() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let attachManager = RecordingContainerAttachManager()
        let logManager = RecordingContainerLogManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
                $0.resourceManager = resourceManager
                $0.attachManager = attachManager
                $0.logManager = logManager
            }
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.command = ["serve"]
                    $0.environment = ["LOG_LEVEL": "debug"]
                    $0.ports = ["8080:80"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    $0.networks = ["default"]
                    $0.platform = "linux/amd64"
                    $0.labels = ["com.example.role": "api"]
                    $0.deployLabels = ["com.example.service": "api"]
                },
            ]
        ) {
            $0.workingDirectory = "/tmp/demo"
            $0.composeFiles = ["/tmp/compose.yml"]
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.allSatisfy { $0.executable == "/usr/bin/env" })
        #expect(runner.commands.allSatisfy { $0.arguments.first == "container" })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])

        let resources = await resourceManager.requests
        #expect(resources.count == 2)
        if case let .createNetwork(request) = resources[0] {
            #expect(request.name == "demo_default")
            #expect(request.isInternal == false)
            #expect(request.ipv4Subnet == nil)
            #expect(request.ipv4Gateway == nil)
            #expect(request.ipv6Subnet == nil)
            #expect(request.driverOpts == [:])
            #expect(request.labels["com.apple.container.compose.project.working-directory"] == "/tmp/demo")
            #expect(request.labels["com.apple.container.compose.project.config-files-hash"] != nil)
        } else {
            Issue.record("Expected network creation through direct API")
        }
        if case let .createVolume(request) = resources[1] {
            #expect(request.name == "demo_cache")
            #expect(request.driver == nil)
            #expect(request.driverOpts == [:])
            #expect(request.labels["com.apple.container.compose.project.working-directory"] == "/tmp/demo")
            #expect(request.labels["com.apple.container.compose.project.config-files-hash"] != nil)
        } else {
            Issue.record("Expected volume creation through direct API")
        }

        let run = runner.commands[0].arguments
        #expect(run.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!run.contains("--detach"))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.project.working-directory=/tmp/demo"]))
        #expect(run.containsLabel(withPrefix: "com.apple.container.compose.project.config-files-hash="))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.oneoff=false"]))
        #expect(run.containsSequence(["--label", "com.example.role=api"]))
        #expect(!run.containsSequence(["--label", "com.example.service=api"]))
        #expect(run.containsSequence(["--env", "LOG_LEVEL=debug"]))
        #expect(run.containsSequence(["--publish", "8080:80"]))
        #expect(run.containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(run.containsSequence(["--network", "demo_default"]))
        #expect(run.containsSequence(["--platform", "linux/amd64"]))
        #expect(Array(run.suffix(2)) == ["example/api:latest", "serve"])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up creates volume driver options through direct API")
    func upCreatesVolumeDriverOptionsThroughDirectAPI() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = [
                "cache": ComposeVolume(
                    name: "cache",
                    driver: "local",
                    driverOpts: [
                        "journal": "ordered",
                        "size": "64m",
                    ],
                    labels: ["com.example.volume": "cache"]
                ),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let requests = await resourceManager.requests
        let request = try #require(requests.compactMap { event -> ComposeVolumeCreateRequest? in
            if case let .createVolume(request) = event {
                return request
            }
            return nil
        }.first)
        #expect(request.name == "demo_cache")
        #expect(request.driver == "local")
        #expect(request.resolvedDriver == "local")
        #expect(request.driverOpts == [
            "journal": "ordered",
            "size": "64m",
        ])
        #expect(request.labels["com.apple.container.compose.project"] == "demo")
        #expect(request.labels["com.apple.container.compose.project.config-files-hash"] != nil)
        #expect(request.labels["com.example.volume"] == "cache")
    }

    @Test("up treats named service volume labels as config metadata")
    func upKeepsNamedServiceVolumeLabelsOutOfVolumeCreate() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            source: "cache",
                            target: "/cache",
                            options: .init(volume: .init(labels: ["com.example.mount": "service"]))
                        ),
                    ]
                },
            ]
        ) {
            $0.volumes = [
                "cache": ComposeVolume(
                    name: "cache",
                    labels: ["com.example.volume": "project"]
                ),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let request = try #require(await resourceManager.requests.compactMap { event -> ComposeVolumeCreateRequest? in
            if case let .createVolume(request) = event {
                return request
            }
            return nil
        }.first)
        #expect(request.name == "demo_cache")
        #expect(request.labels["com.example.volume"] == "project")
        #expect(request.labels["com.example.mount"] == nil)
    }

    @Test("up creates labeled anonymous volumes before container create")
    func upCreatesLabeledAnonymousVolumesBeforeContainerCreate() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            target: "/scratch",
                            options: .init(volume: .init(labels: ["com.example.mount": "anonymous"]))
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let request = try #require(await resourceManager.requests.compactMap { event -> ComposeVolumeCreateRequest? in
            if case let .createVolume(request) = event {
                return request
            }
            return nil
        }.first)
        #expect(request.name.hasPrefix("demo_anon-"))
        #expect(request.labels["com.apple.container.compose.project"] == "demo")
        #expect(request.labels["com.example.mount"] == "anonymous")

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--volume", "\(request.name):/scratch"]))
    }

    @Test("up dry run renders labeled anonymous volume create")
    func upDryRunRendersLabeledAnonymousVolumeCreate() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            target: "/scratch",
                            options: .init(volume: .init(labels: ["com.example.mount": "anonymous"]))
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }))
            .up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages.contains { message in
            message.contains("container volume create")
                && message.contains("--label com.example.mount=anonymous")
                && message.contains("demo_anon-")
        })
    }

    @Test("run creates labeled anonymous volumes before one-off container")
    func runCreatesLabeledAnonymousVolumesBeforeOneOffContainer() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            target: "/scratch",
                            options: .init(volume: .init(labels: ["com.example.mount": "run"]))
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            resourceManager: resourceManager
        ).run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"])
        )

        let request = try #require(await resourceManager.requests.compactMap { event -> ComposeVolumeCreateRequest? in
            if case let .createVolume(request) = event {
                return request
            }
            return nil
        }.first)
        #expect(request.name.hasPrefix("demo_anon-"))
        #expect(request.labels["com.example.mount"] == "run")

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--volume", "\(request.name):/scratch"]))
        #expect(Array(command.suffix(2)) == ["alpine", "true"])
    }

    @Test("up maps list entrypoint to executable and command prefix")
    func upMapsListEntrypointToExecutableAndCommandPrefix() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine:3.20") {
                    $0.entrypoint = ["/bin/sh", "-c"]
                    $0.command = ["printf ready"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--entrypoint", "/bin/sh"]))
        #expect(!command.containsSequence(["--entrypoint", "/bin/sh -c"]))
        #expect(Array(command.suffix(3)) == ["alpine:3.20", "-c", "printf ready"])
    }

    @Test("up maps an empty entrypoint to the generic clear runtime option")
    func upMapsEmptyEntrypointToClearRuntimeOption() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine:3.20") {
                    $0.command = []
                    $0.entrypoint = []
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains("--clear-entrypoint"))
        #expect(!command.contains("--entrypoint"))
        #expect(Array(command.suffix(1)) == ["alpine:3.20"])
    }

    @Test("up dry run renders volume driver options")
    func upDryRunRendersVolumeDriverOptions() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = [
                "cache": ComposeVolume(
                    name: "cache",
                    driver: "local",
                    driverOpts: [
                        "journal": "ordered",
                        "size": "64m",
                    ]
                ),
            ]
        }

        try await ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }))
            .up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages.contains { message in
            message.contains("container volume create --opt journal=ordered --opt size=64m")
        })
    }

    @Test("up creates IPAM networks through direct API with static IPv4 outside allocation range")
    func upCreatesIPAMNetworksThroughDirectAPIWithStaticIPv4OutsideAllocationRange() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(addressing: .init(ipv4Address: "10.77.0.20")),
                    ]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: ComposeNetwork.Options(
                        isInternal: true,
                        labels: ["com.example.network": "backend"],
                        subnets: ComposeNetwork.Subnets(
                            ipv4Subnet: "10.77.0.0/24",
                            ipv4Gateway: "10.77.0.254",
                            ipv4AllocationRange: "10.77.0.128/25",
                            ipv4ReservedAddresses: ["10.77.0.10", "10.77.0.11"],
                            ipv6Subnet: "fd77::/64",
                            ipv6Gateway: "fd77::53"
                        )
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let resources = await resourceManager.requests
        #expect(resources.count == 1)
        if case let .createNetwork(request) = resources[0] {
            #expect(request.name == "demo_backend")
            #expect(request.isInternal == true)
            #expect(request.ipv4Subnet == "10.77.0.0/24")
            #expect(request.ipv4Gateway == "10.77.0.254")
            #expect(request.ipv4AllocationRange == "10.77.0.128/25")
            #expect(request.ipv4ReservedAddresses == ["10.77.0.10", "10.77.0.11"])
            #expect(request.ipv6Subnet == "fd77::/64")
            #expect(request.ipv6Gateway == "fd77::53")
            #expect(request.enableIPv6 == nil)
            #expect(request.driverOpts == [:])
            #expect(request.labels["com.apple.container.compose.project"] == "demo")
            #expect(request.labels["com.apple.container.compose.project.config-files-hash"] != nil)
            #expect(request.labels["com.example.network"] == "backend")
        } else {
            Issue.record("Expected network creation through direct API")
        }
        #expect(runner.commands.map(\.arguments)[0].containsSequence(["--network", "demo_backend,ip=10.77.0.20"]))
    }

    @Test("up creates network driver options through direct API")
    func upCreatesNetworkDriverOptionsThroughDirectAPI() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: ComposeNetwork.Options(
                        driverOpts: [
                            "com.docker.network.bridge.host_binding_ipv4": "127.0.0.1",
                            "com.docker.network.driver.mtu": "1450",
                        ]
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let resources = await resourceManager.requests
        #expect(resources.count == 1)
        if case let .createNetwork(request) = resources[0] {
            #expect(request.name == "demo_backend")
            #expect(request.driverOpts == [
                "com.docker.network.bridge.host_binding_ipv4": "127.0.0.1",
                "com.docker.network.driver.mtu": "1450",
            ])
        } else {
            Issue.record("Expected network creation through direct API")
        }
        #expect(runner.commands.map(\.arguments)[0].containsSequence(["--network", "demo_backend"]))
    }

    @Test("up dry run renders internal IPAM network create")
    func upDryRunRendersInternalIPAMNetworkCreate() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: ComposeNetwork.Options(
                        isInternal: true,
                        subnets: ComposeNetwork.Subnets(
                            ipv4Subnet: "10.77.0.0/24",
                            ipv4Gateway: "10.77.0.254",
                            ipv4AllocationRange: "10.77.0.128/25",
                            ipv4ReservedAddresses: ["10.77.0.10", "10.77.0.11"],
                            ipv6Subnet: "fd77::/64",
                            ipv6Gateway: "fd77::53"
                        )
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }))
            .up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages.contains { message in
            message.contains("container network create --internal --subnet 10.77.0.0/24 --gateway 10.77.0.254 --ip-range 10.77.0.128/25 --reserve-ip 10.77.0.10 --reserve-ip 10.77.0.11 --subnet-v6 fd77::/64 --gateway-v6 fd77::53")
        })
    }

    @Test("up dry run renders network driver options")
    func upDryRunRendersNetworkDriverOptions() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: ComposeNetwork.Options(
                        driverOpts: [
                            "com.docker.network.bridge.host_binding_ipv4": "127.0.0.1",
                            "com.docker.network.driver.mtu": "1450",
                        ]
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }))
            .up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages.contains { message in
            message.contains("container network create --option com.docker.network.bridge.host_binding_ipv4=127.0.0.1 --option com.docker.network.driver.mtu=1450")
        })
    }

    @Test("up maps IPv6 disablement through the runtime abstraction")
    func upMapsIPv6DisablementThroughRuntimeAbstraction() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(
                        enableIPv6: false,
                        subnets: .init(ipv6Subnet: "fd00:10::/64")
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let resources = await resourceManager.requests
        #expect(resources.count == 1)
        if case let .createNetwork(request) = resources[0] {
            #expect(request.name == "demo_backend")
            #expect(request.enableIPv6 == false)
            #expect(request.ipv6Subnet == "fd00:10::/64")
        } else {
            Issue.record("Expected network creation through direct API")
        }
    }

    @Test("up dry run renders IPv6 disablement without a conflicting IPv6 subnet")
    func upDryRunRendersIPv6Disablement() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(
                        enableIPv6: false,
                        subnets: .init(ipv6Subnet: "fd00:10::/64")
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }))
            .up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages.contains { message in
            message.contains("container network create")
                && message.contains("--disable-ipv6")
                && message.contains("demo_backend")
                && !message.contains("--subnet-v6")
        })
    }

    @Test("up dry run renders IPv4 disablement without conflicting IPv4 addressing")
    func upDryRunRendersIPv4Disablement() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(
                        enableIPv4: false,
                        enableIPv6: true,
                        subnets: .init(
                            ipv4Subnet: "10.10.0.0/24",
                            ipv4Gateway: "10.10.0.1",
                            ipv6Subnet: "fd00:10::/64",
                            ipv6Gateway: "fd00:10::1"
                        )
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }))
            .up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages.contains { message in
            message.contains("container network create")
                && message.contains("--disable-ipv4")
                && message.contains("--subnet-v6 fd00:10::/64")
                && message.contains("demo_backend")
                && !message.contains("--subnet 10.10.0.0/24")
                && !message.contains("--gateway 10.10.0.1")
        })
    }

    @Test("up accepts attachable project network metadata")
    func upAcceptsAttachableProjectNetworkMetadata() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: ComposeNetwork.Options(isAttachable: true)
                ),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let resources = await resourceManager.requests
        #expect(resources.count == 1)
        if case let .createNetwork(request) = resources[0] {
            #expect(request.name == "demo_backend")
        } else {
            Issue.record("Expected network creation through direct API")
        }
        #expect(runner.commands.map(\.arguments)[0].containsSequence(["--network", "demo_backend"]))
    }

    @Test("up accepts attachable project networks and rejects the remaining unsupported options before side effects")
    func upAcceptsAttachableProjectNetworksAndRejectsRemainingUnsupportedOptionsBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        var networkOptions = ComposeNetwork.Options(isAttachable: true)
        networkOptions.unsupportedFields = ["driver"]
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: networkOptions
                ),
            ]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported project network options error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("network 'backend' uses unsupported fields driver; supported project network fields are name, external, internal, attachable, enable_ipv4, enable_ipv6, labels, driver_opts, the default bridge driver, and one IPv4 IPAM subnet with optional gateway, allocation range, and reserved addresses plus one IPv6 IPAM subnet with an optional gateway"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects invalid project network gateways before side effects")
    func upRejectsInvalidProjectNetworkGatewaysBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(subnets: .init(
                        ipv4Subnet: "10.77.0.0/24",
                        ipv4Gateway: "10.77.0.0"
                    ))
                ),
            ]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid project network gateway error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "network 'backend' IPv4 IPAM gateway '10.77.0.0' must be an allocatable host address in subnet '10.77.0.0/24'"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects invalid project network allocation ranges before side effects")
    func upRejectsInvalidProjectNetworkAllocationRangesBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(subnets: .init(
                        ipv4Subnet: "10.77.0.0/24",
                        ipv4AllocationRange: "10.78.0.0/24"
                    ))
                ),
            ]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid project network allocation range error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "network 'backend' IPv4 IPAM allocation range '10.78.0.0/24' must be contained in subnet '10.77.0.0/24'"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects invalid project network reserved addresses before side effects")
    func upRejectsInvalidProjectNetworkReservedAddressesBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(subnets: .init(
                        ipv4Subnet: "10.77.0.0/24",
                        ipv4ReservedAddresses: ["10.77.0.10", "10.77.0.10"]
                    ))
                ),
            ]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid project network reserved address error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("network 'backend' IPv4 IPAM reserved addresses must be unique"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects static endpoint addresses that reuse a project network gateway")
    func upRejectsStaticEndpointAddressMatchingNetworkGatewayBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(addressing: .init(ipv4Address: "10.77.0.20")),
                    ]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(subnets: .init(
                        ipv4Subnet: "10.77.0.0/24",
                        ipv4Gateway: "10.77.0.20"
                    ))
                ),
            ]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected static address gateway collision error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "service 'api' ipv4_address '10.77.0.20' is the gateway for network 'backend'"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects static endpoint addresses that reuse a project network reserved address")
    func upRejectsStaticEndpointAddressMatchingNetworkReservedAddressBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(addressing: .init(ipv4Address: "10.77.0.20")),
                    ]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(subnets: .init(
                        ipv4Subnet: "10.77.0.0/24",
                        ipv4ReservedAddresses: ["10.77.0.20"]
                    ))
                ),
            ]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected static address reservation collision error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "service 'api' ipv4_address '10.77.0.20' is reserved on network 'backend'"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up surfaces network create failures before starting containers")
    func upSurfacesNetworkCreateFailuresBeforeStartingContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            networkCreateError: ComposeError.invalidProject("network create failed")
        )
        let project = projectWithBackendNetwork(serviceName: "api", image: "example/api")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected network create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("network create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
    }

    @Test("up surfaces volume create failures before starting containers")
    func upSurfacesVolumeCreateFailuresBeforeStartingContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            volumeCreateError: ComposeError.invalidProject("volume create failed")
        )
        let project = projectWithCacheVolume(serviceName: "api", image: "example/api")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected volume create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("volume create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_cache"])
    }

    @Test("up maps network mode none to no network attachment")
    func upMapsNetworkModeNoneToNoNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networkMode = "none"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "none"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up maps network mode host to runtime host networking")
    func upMapsNetworkModeHostToRuntimeHostNetworking() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networkMode = "host"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "host"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up maps network mode bridge to the built-in runtime network")
    func upMapsNetworkModeBridgeToBuiltinRuntimeNetwork() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networkMode = "bridge"
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "default"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up maps shared VM isolation to the built-in runtime network")
    func upMapsSharedVMIsolationToBuiltinRuntimeNetwork() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.isolation = "shared-vm"
                    $0.networkMode = "bridge"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "default"]))
        #expect(command.containsSequence(["--isolation", "shared-vm"]))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up maps pid host to container pid argument")
    func upMapsPIDHostToContainerPIDArgument() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.pid = "host"
                    $0.networks = ["default"]
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "demo_default"]))
        #expect(command.containsSequence(["--pid", "host"]))
        #expect(await resourceManager.requests.map(\.name) == ["demo_default"])
    }

    @Test("up accepts explicit private PID mode without a redundant runtime argument")
    func upAcceptsPrivatePIDModeWithoutRuntimeArgument() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.pid = "private"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--pid"))
    }

    @Test("up maps cgroup host to container cgroup namespace argument")
    func upMapsCgroupHostToContainerCgroupNamespaceArgument() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.cgroup = "host"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--cgroupns", "host"]))
    }

    @Test("up accepts explicit private cgroup mode without redundant runtime argument")
    func upAcceptsPrivateCgroupModeWithoutRuntimeArgument() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.cgroup = "private"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--cgroupns"))
    }

    @Test("up maps IPC and UTS host to container namespace arguments")
    func upMapsIPCAndUTSHostToContainerNamespaceArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.ipc = "host"
                    $0.uts = "host"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--ipc", "host"]))
        #expect(command.containsSequence(["--uts", "host"]))
    }

    @Test("up accepts explicit private IPC and UTS modes without redundant runtime arguments")
    func upAcceptsPrivateIPCAndUTSModesWithoutRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.ipc = "private"
                    $0.uts = "private"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--ipc"))
        #expect(!command.contains("--uts"))
    }

    @Test("up starts present optional dependencies in dependency order")
    func upStartsPresentOptionalDependenciesInDependencyOrder() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["optional": ComposeDependency(condition: "service_started", required: false)]
                },
                "optional": ComposeService(name: "optional", image: "example/optional:latest"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-optional-1"]))
        #expect(!commands[0].contains("--detach"))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands[1].contains("--detach"))
        #expect(await discoveryManager.getRequests == ["demo-optional-1", "demo-api-1"])
    }

    @Test("up starts independent services concurrently")
    func upStartsIndependentServicesConcurrently() async throws {
        let runner = DelayedBuildRunner(delay: .milliseconds(50))
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
                "cache": ComposeService(name: "cache", image: "example/cache:latest"),
                "worker": ComposeService(name: "worker", image: "example/worker:latest"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(maxParallelism: -1),
            discoveryManager: discoveryManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.detach = true
            }
        )

        #expect(await runner.commands.count == 3)
        #expect(await runner.maximumActiveOperations == 3)
    }

    @Test("up honors the configured parallel engine call limit")
    func upHonorsConfiguredParallelEngineCallLimit() async throws {
        let runner = DelayedBuildRunner(delay: .milliseconds(50))
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
                "cache": ComposeService(name: "cache", image: "example/cache:latest"),
                "worker": ComposeService(name: "worker", image: "example/worker:latest"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(maxParallelism: 2),
            discoveryManager: discoveryManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.detach = true
            }
        )

        #expect(await runner.commands.count == 3)
        #expect(await runner.maximumActiveOperations == 2)
    }

    @Test("up completes dependency layers before starting dependents")
    func upCompletesDependencyLayersBeforeStartingDependents() async throws {
        let runner = DelayedBuildRunner(delay: .milliseconds(50))
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["database": ComposeDependency(condition: "service_started")]
                },
                "database": ComposeService(name: "database", image: "example/database:latest"),
                "worker": composeService(name: "worker", image: "example/worker:latest") {
                    $0.dependsOn = ["database": ComposeDependency(condition: "service_started")]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(maxParallelism: -1),
            discoveryManager: discoveryManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.detach = true
            }
        )

        let commands = await runner.commands
        #expect(commands.count == 3)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-database-1"]))
        #expect(await runner.maximumActiveOperations == 2)
    }

    @Test("up skips missing optional dependencies")
    func upSkipsMissingOptionalDependencies() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["optional": ComposeDependency(condition: "service_healthy", required: false)]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-optional-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up waits for running service-completed dependencies before starting dependents")
    func upWaitsForRunningServiceCompletedDependenciesBeforeStartingDependents() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-job-1": 0])
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-job-1": [
                nil,
                ComposeContainerSummary(id: "demo-job-1", status: "running"),
            ],
            "demo-api-1": [nil],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": ComposeDependency(condition: "service_completed_successfully")]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-job-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-job-1"),
        ])
        #expect(await discoveryManager.getRequests == ["demo-job-1", "demo-job-1", "demo-api-1"])
    }

    @Test("up replays stored exit codes for completed dependencies")
    func upReplaysStoredExitCodesForCompletedDependencies() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-job-1": [
                nil,
                ComposeContainerSummary(id: "demo-job-1", status: "stopped", exitCode: 0),
            ],
            "demo-api-1": [nil],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": ComposeDependency(condition: "service_completed_successfully")]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-job-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("up accepts exited service-completed dependencies")
    func upAcceptsExitedServiceCompletedDependencies() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-job-1": [
                nil,
                ComposeContainerSummary(id: "demo-job-1", status: "exited", exitCode: 0),
            ],
            "demo-api-1": [nil],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": ComposeDependency(condition: "service_completed_successfully")]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-job-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("up waits for healthy dependencies before starting dependents")
    func upWaitsForHealthyDependenciesBeforeStartingDependents() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-db-1": [
                nil,
                ComposeContainerSummary(id: "demo-db-1", status: "running", health: "starting"),
                ComposeContainerSummary(id: "demo-db-1", status: "running", health: "healthy"),
            ],
            "demo-api-1": [nil],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "db": ComposeService(name: "db", image: "postgres:16"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy")]
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.discoveryManager = discoveryManager
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { _ in }),
            dependencies: dependencies
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-db-1", "demo-db-1", "demo-api-1"])
    }

    @Test("up rejects unhealthy dependencies before starting dependents")
    func upRejectsUnhealthyDependenciesBeforeStartingDependents() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-db-1": [
                nil,
                ComposeContainerSummary(id: "demo-db-1", status: "running", health: "unhealthy"),
            ],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "db": ComposeService(name: "db", image: "postgres:16"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy")]
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.discoveryManager = discoveryManager
        }

        do {
            try await ComposeOrchestrator(
                runner: runner,
                options: ComposeExecutionOptions(sleep: { _ in }),
                dependencies: dependencies
            ).up(
                project: project,
                options: ComposeUpOptions {
                    $0.services = ["api"]
                }
            )
            Issue.record("Expected unhealthy dependency to stop dependent startup")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' dependency 'db' container 'demo-db-1' is unhealthy"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-db-1"])
    }

    @Test("up rejects failed service-completed dependencies before starting dependents")
    func upRejectsFailedServiceCompletedDependenciesBeforeStartingDependents() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-job-1": [
                nil,
                ComposeContainerSummary(id: "demo-job-1", status: "stopped", exitCode: 2),
            ],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": ComposeDependency(condition: "service_completed_successfully")]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: runner,
                discoveryManager: discoveryManager,
                lifecycleManager: lifecycleManager
            ).up(
                project: project,
                options: ComposeUpOptions {
                    $0.services = ["api"]
                }
            )
            Issue.record("Expected failed dependency to stop dependent startup")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' dependency 'job' container 'demo-job-1' exited with status 2"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-job-1"]))
        #expect(await lifecycleManager.requests.isEmpty)
        #expect(await discoveryManager.getRequests == ["demo-job-1", "demo-job-1"])
    }

    @Test("create creates resources and service containers without starting them")
    func createCreatesResourcesAndServiceContainersWithoutStartingThem() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let progress = LockedStringRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.command = ["serve"]
                    $0.environment = ["LOG_LEVEL": "debug"]
                    $0.ports = ["8080:80"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    $0.networks = ["default"]
                    $0.platform = "linux/amd64"
                    $0.dnsOptions = ["use-vc"]
                    $0.hostname = "custom-api"
                    $0.domainName = "example.test"
                    $0.extraHosts = ["db=10.0.0.5", "myhostv6=[::1]"]
                    $0.privileged = true
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.resourceManager = resourceManager
            }
        ).create(project: project, options: ComposeCreateOptions())

        let commands = runner.commands.map(\.arguments)
        let resources = await resourceManager.requests
        #expect(resources.count == 2)
        #expect(resources.map(\.name) == ["demo_default", "demo_cache"])
        #expect(resources.allSatisfy { $0.labels["com.apple.container.compose.project"] == "demo" })
        #expect(resources.allSatisfy { $0.labels["com.apple.container.compose.project.config-files-hash"]?.count == 64 })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(progress.snapshot.joined() == "⠓ Creating api\n✓ Creating api\n")

        let create = commands[0]
        #expect(create.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!create.contains("--detach"))
        #expect(create.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(create.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(create.containsSequence(["--label", "com.apple.container.compose.oneoff=false"]))
        #expect(create.containsSequence(["--env", "LOG_LEVEL=debug"]))
        #expect(create.containsSequence(["--publish", "8080:80"]))
        #expect(create.containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(create.containsSequence(["--network", "demo_default"]))
        #expect(create.containsSequence(["--platform", "linux/amd64"]))
        #expect(create.containsSequence(["--dns-option", "use-vc"]))
        #expect(create.containsSequence(["--hostname", "custom-api"]))
        #expect(create.containsSequence(["--domainname", "example.test"]))
        #expect(create.containsSequence(["--add-host", "db:10.0.0.5"]))
        #expect(create.containsSequence(["--add-host", "myhostv6:::1"]))
        #expect(create.contains("--privileged"))
        #expect(Array(create.suffix(2)) == ["example/api:latest", "serve"])
    }

    @Test("create initializes image volumes before creating a container")
    func createInitializesImageVolumesBeforeCreatingContainer() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(imageVolumeTargets: [
            "example/api": ["/image-data"],
        ])
        let resourceManager = RecordingContainerResourceManager()
        let initializer = RecordingContainerImageVolumeInitializer()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.imageVolumeInitializer = initializer
                $0.resourceManager = resourceManager
            },
        ).create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains { $0.hasPrefix("demo_anon-api-1-") && $0.hasSuffix(":/image-data") })
        #expect(
            await imageManager.requests == [
                .healthCheck(reference: "example/api", platform: nil),
                .volumeTargets(reference: "example/api", platform: nil),
            ]
        )
        #expect(await resourceManager.requests.count == 2)
        let request = try #require((await initializer.requests).first)
        #expect(request.image == "example/api")
        #expect(request.imageSubpath == "/image-data")
        #expect(request.volumeName.hasPrefix("demo_anon-api-1-"))
    }

    @Test("create maps legacy links to source-scoped DNS aliases after creating dependencies")
    func createMapsLegacyLinksToSourceScopedDNSAliasesAfterCreatingDependencies() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-db-1": [nil],
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "db": composeService(name: "db", image: "postgres:18") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["db:database"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).create(project: project, options: ComposeCreateOptions())

        let dependencyCommand = try #require(runner.commands.first?.arguments)
        let createCommand = try #require(runner.commands.last?.arguments)
        #expect(dependencyCommand.containsSequence(["--name", "demo-db-1"]))
        #expect(createCommand.containsSequence(["--network", "demo_backend,dns-alias=database:demo-db-1"]))
        #expect(!createCommand.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
    }

    @Test("create maps disabled logging driver to runtime policy")
    func createMapsDisabledLoggingDriverToRuntimePolicy() async throws {
        for testCase in disabledServiceLoggingFieldCases() {
            let runner = RecordingRunner(responses: [.success])
            let discoveryManager = RecordingContainerDiscoveryManager()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
                .create(project: project, options: ComposeCreateOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
            #expect(command.containsSequence(["--log-driver", "none"]))
            #expect(!command.contains("--log-opt"))
        }
    }

    @Test("create maps cpu_shares to runtime arguments")
    func createMapsCPUSharesToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cpuShares = 512
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--cpu-shares", "512"]))
    }

    @Test("create maps cgroup_parent to runtime arguments")
    func createMapsCgroupParentToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cgroupParent = "workloads/build"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--cgroup-parent", "workloads/build"]))
    }

    @Test("create maps cpuset to runtime arguments")
    func createMapsCPUSetToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cpuset = "0-1,3"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--cpuset-cpus", "0-1,3"]))
    }

    @Test("create omits an empty cpuset")
    func createOmitsEmptyCPUSetRuntimeArgument() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cpuset = ""
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--cpuset-cpus"))
    }

    @Test("create maps fractional cpus to runtime arguments")
    func createMapsFractionalCPUsToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cpus = "0.25"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--cpus", "0.25"]))
    }

    @Test("create maps zero cpus to an unlimited runtime argument")
    func createMapsUnlimitedCPUsToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cpus = "0"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--cpus", "0"]))
    }

    @Test("create maps cpu_period and cpu_quota to runtime arguments")
    func createMapsCPUQuotaAndPeriodToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cpuPeriod = 200_000
                    $0.cpuQuota = 50_000
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--cpu-period", "200000"]))
        #expect(command.containsSequence(["--cpu-quota", "50000"]))
    }

    @Test("create maps mem_reservation to runtime arguments")
    func createMapsMemoryReservationToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.memReservation = "268435456"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--memory-reservation", "268435456"]))
    }

    @Test("create maps memswap_limit to runtime arguments")
    func createMapsMemorySwapLimitToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.memLimit = "536870912"
                    $0.memSwapLimit = "-1"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--memory-swap", "-1"]))
    }

    @Test("create maps bind propagation to volume options")
    func createMapsBindPropagationToVolumeOptions() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(
                            type: "bind",
                            source: directory.path,
                            target: "/host",
                            options: .init(readOnly: true, bind: .init(propagation: "rshared"))
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .create(project: project, options: ComposeCreateOptions())

        let create = try #require(runner.commands.first?.arguments)
        #expect(create.containsSequence(["--volume", "\(directory.path):/host:ro,rshared"]))
    }

    @Test("create maps local logging options to runtime policy")
    func createMapsLocalLoggingOptionsToRuntimePolicy() async throws {
        for testCase in supportedLocalServiceLoggingOptionCases() {
            let runner = RecordingRunner(responses: [.success])
            let discoveryManager = RecordingContainerDiscoveryManager()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                    },
                ]
            )

            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
                .create(project: project, options: ComposeCreateOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
            #expect(!command.contains("--log-driver"))
            for option in testCase.expectedOptions {
                #expect(command.containsSequence(["--log-opt", option]))
            }
        }
    }

    @Test("service create plan maps logging to typed policy")
    func serviceCreatePlanMapsLoggingToTypedPolicy() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.logging = ComposeLogConfiguration(
                        driver: "local",
                        options: ["max-file": "3"],
                    )
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "api")

        #expect(plan.name == "demo-api-1")
        #expect(plan.imageReference == "example/api")
        #expect(plan.logging.driver == "local")
        #expect(plan.logging.options == ["max-file": "3"])
    }

    @Test("service create plan maps disabled logging to typed policy")
    func serviceCreatePlanMapsDisabledLoggingToTypedPolicy() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.logging = ComposeLogConfiguration(driver: "none")
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "api")

        #expect(plan.logging.driver == "none")
        #expect(plan.logging.options.isEmpty)
    }

    @Test("service create plan preserves arbitrary logging and structured precedence")
    func serviceCreatePlanPreservesArbitraryLoggingAndStructuredPrecedence() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.logging = ComposeLogConfiguration(
                        driver: "example/provider",
                        options: ["custom": "structured", "cache-disabled": "true"],
                    )
                    $0.logDriver = "none"
                    $0.logOptions = ["custom": "legacy", "max-file": "2"]
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "api")

        #expect(plan.logging == ComposeLogConfiguration(
            driver: "example/provider",
            options: ["custom": "structured", "cache-disabled": "true"],
        ))
    }

    @Test("service create plan maps create-time runtime primitives")
    func serviceCreatePlanMapsCreateTimeRuntimePrimitives() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.restart = "on-failure:3"
                    $0.hostname = "api-01"
                    $0.domainName = "example.test"
                    $0.extraHosts = ["db:10.0.0.5"]
                    $0.sysctls = ["net.core.somaxconn": "1024"]
                    $0.annotations = ["com.example.owner": "platform"]
                    $0.privileged = true
                    $0.blkioConfig = ComposeBlkioConfig(
                        weight: 300,
                        weightDevice: [ComposeBlkioWeightDevice(path: "8:0", weight: 700)],
                        deviceReadIOps: [ComposeBlkioThrottleDevice(path: "8:0", rate: "1000")]
                    )
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "api")

        #expect(plan.restartPolicy.mode == .onFailure)
        #expect(plan.restartPolicy.maximumRetryCount == 3)
        #expect(plan.hostname == "api-01")
        #expect(plan.domainname == "example.test")
        #expect(plan.hosts.map(\.ipAddress) == ["10.0.0.5"])
        #expect(plan.hosts.flatMap(\.hostnames) == ["db"])
        #expect(plan.sysctls == ["net.core.somaxconn": "1024"])
        #expect(plan.annotations == ["com.example.owner": "platform"])
        #expect(plan.initProcess.privileged)
        #expect(plan.blockIO?.weight == 300)
        #expect(plan.blockIO?.weightDevice.first?.major == 8)
        #expect(plan.blockIO?.weightDevice.first?.minor == 0)
        #expect(plan.blockIO?.weightDevice.first?.weight == 700)
        #expect(plan.blockIO?.throttleReadIOPSDevice.first?.rate == 1000)
    }

    @Test("service create plan maps entrypoint and command to init process")
    func serviceCreatePlanMapsEntrypointAndCommandToInitProcess() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.entrypoint = ["/bin/sh", "-c"]
                    $0.command = ["printf ready"]
                    $0.environment = [
                        "EMPTY": nil,
                        "LOG_LEVEL": "debug",
                    ]
                    $0.workingDir = "/work"
                    $0.user = "1000:1000"
                    $0.groupAdd = ["1000", "video", "1001", "staff", "1000", "video"]
                    $0.oomScoreAdj = -250
                    $0.cpuShares = 512
                    $0.memReservation = "268435456"
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")

        #expect(plan.initProcess.executable == "/bin/sh")
        #expect(plan.initProcess.arguments == ["-c", "printf ready"])
        #expect(plan.initProcess.environment == ["EMPTY", "LOG_LEVEL=debug"])
        #expect(plan.initProcess.workingDirectory == "/work")
        #expect(plan.initProcess.user.description == "1000:1000")
        #expect(plan.initProcess.supplementalGroups == [1000, 1001])
        #expect(plan.initProcess.supplementalGroupNames == ["video", "staff"])
        #expect(plan.initProcess.oomScoreAdj == -250)
        #expect(plan.cpuShares == 512)
        #expect(plan.memoryReservationInBytes == 268_435_456)
    }

    @Test("service create plan maps explicit healthcheck to typed policy")
    func serviceCreatePlanMapsExplicitHealthcheckToTypedPolicy() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.command = ["serve"]
                    $0.environment = ["LOG_LEVEL": "debug"]
                    $0.workingDir = "/srv"
                    $0.user = "1000:1000"
                    $0.groupAdd = ["1000", "video"]
                    $0.oomScoreAdj = -250
                    $0.healthcheck = .object([
                        "test": .array([.string("CMD-SHELL"), .string("test -f /tmp/ready")]),
                        "interval": .string("5s"),
                        "retries": .number(2),
                    ])
                },
            ]
        )

        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "api")
        let healthCheck = try #require(plan.healthCheck)

        #expect(healthCheck.process.executable == "/bin/sh")
        #expect(healthCheck.process.arguments == ["-c", "test -f /tmp/ready"])
        #expect(healthCheck.process.environment == ["LOG_LEVEL=debug"])
        #expect(healthCheck.process.workingDirectory == "/srv")
        #expect(healthCheck.process.user.description == "1000:1000")
        #expect(healthCheck.process.supplementalGroups == [1000])
        #expect(healthCheck.process.supplementalGroupNames == ["video"])
        #expect(healthCheck.process.oomScoreAdj == -250)
        #expect(healthCheck.intervalInNanoseconds == 5_000_000_000)
        #expect(healthCheck.retries == 2)
    }

    @Test("service create plan rejects malformed supplemental group IDs")
    func serviceCreatePlanRejectsMalformedSupplementalGroupIDs() async throws {
        for (group, expectedMessage) in [
            ("", "service 'job' uses an empty group_add value"),
            ("4294967296", "service 'job' uses group_add numeric ID '4294967296' outside the UInt32 range"),
        ] {
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        $0.groupAdd = [group]
                    },
                ]
            )

            do {
                _ = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")
                Issue.record("Expected group_add validation failure for '\(group)'")
            } catch let error as ComposeError {
                #expect(error == .invalidProject(expectedMessage))
            }
        }
    }

    @Test("service create plan rejects out-of-range OOM score adjustments")
    func serviceCreatePlanRejectsOutOfRangeOOMScoreAdjustment() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.oomScoreAdj = 1001
                },
            ]
        )

        await #expect(throws: ComposeError.invalidProject("service 'job' uses oom_score_adj '1001' outside the supported range -1000...1000")) {
            _ = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")
        }
    }

    @Test("service create plan validates CPU shares")
    func serviceCreatePlanValidatesCPUShares() async throws {
        for (cpuShares, expectedMessage) in [
            (0, nil),
            (2, nil),
            (512, nil),
            (1, "service 'job' uses cpu_shares '1'; cpu_shares must be 0 or at least 2"),
            (-1, "service 'job' uses cpu_shares '-1'; cpu_shares must be 0 or at least 2"),
        ] {
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        $0.cpuShares = cpuShares
                    },
                ]
            )

            if let expectedMessage {
                await #expect(throws: ComposeError.invalidProject(expectedMessage)) {
                    _ = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")
                }
            } else {
                let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")
                #expect(plan.cpuShares == (cpuShares == 0 ? nil : UInt64(cpuShares)))
            }
        }
    }

    @Test("service create plan maps and validates cgroup_parent")
    func serviceCreatePlanMapsAndValidatesCgroupParent() async throws {
        let validProject = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.cgroupParent = "workloads/build"
                },
            ]
        )
        let plan = try await ComposeOrchestrator().serviceCreatePlan(project: validProject, serviceName: "job")
        #expect(plan.cgroupParent == "workloads/build")

        for parent in ["/root", ".", "..", "workloads/../escape", "workloads//build", "workloads/"] {
            let invalidProject = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        $0.cgroupParent = parent
                    },
                ]
            )
            await #expect(throws: ComposeError.invalidProject("service 'job' uses invalid cgroup_parent '\(parent)'; expected a non-empty relative path without empty, '.' or '..' components")) {
                _ = try await ComposeOrchestrator().serviceCreatePlan(project: invalidProject, serviceName: "job")
            }
        }
    }

    @Test("service create plan validates memory reservations")
    func serviceCreatePlanValidatesMemoryReservations() async throws {
        let cases: [(reservation: String?, memoryLimit: String?, expectedMessage: String?)] = [
            (nil, nil, nil),
            ("0", nil, nil),
            ("268435456", nil, nil),
            ("268435456", "536870912", nil),
            ("-1", nil, "service 'job' uses invalid mem_reservation '-1'; expected a non-negative byte value"),
            ("invalid", nil, "service 'job' uses invalid mem_reservation 'invalid'; expected a non-negative byte value"),
            ("536870912", "536870912", "service 'job' uses mem_reservation '536870912'; mem_reservation must be lower than mem_limit '536870912'"),
            ("536870913", "536870912", "service 'job' uses mem_reservation '536870913'; mem_reservation must be lower than mem_limit '536870912'"),
        ]

        for testCase in cases {
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        $0.memReservation = testCase.reservation
                        $0.memLimit = testCase.memoryLimit
                    },
                ]
            )

            if let expectedMessage = testCase.expectedMessage {
                await #expect(throws: ComposeError.invalidProject(expectedMessage)) {
                    _ = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")
                }
            } else {
                let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")
                let expectedReservation = testCase.reservation.flatMap(Int64.init).flatMap { $0 == 0 ? nil : $0 }
                #expect(plan.memoryReservationInBytes == expectedReservation)
            }
        }
    }

    @Test("service create plan validates memory swap limits")
    func serviceCreatePlanValidatesMemorySwapLimits() async throws {
        let cases: [(swapLimit: String?, memoryLimit: String?, expectedLimit: Int64?, expectedMessage: String?)] = [
            (nil, nil, nil, nil),
            ("0", nil, nil, nil),
            (nil, "536870912", 1_073_741_824, nil),
            ("0", "536870912", 1_073_741_824, nil),
            ("-1", "536870912", -1, nil),
            ("1073741824", "536870912", 1_073_741_824, nil),
            ("-1", nil, nil, "service 'job' uses memswap_limit; memswap_limit requires a positive mem_limit"),
            ("268435456", nil, nil, "service 'job' uses memswap_limit; memswap_limit requires a positive mem_limit"),
            ("-2", "536870912", nil, "service 'job' uses invalid memswap_limit '-2'; expected -1, 0, or a positive byte value"),
            ("268435456", "536870912", nil, "service 'job' uses memswap_limit '268435456'; memswap_limit must be at least mem_limit '536870912'"),
            (nil, "9223372036854775807", nil, "service 'job' uses mem_limit '9223372036854775807'; Docker-compatible default memswap_limit exceeds the runtime range"),
        ]

        for testCase in cases {
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        $0.memSwapLimit = testCase.swapLimit
                        $0.memLimit = testCase.memoryLimit
                    },
                ]
            )

            if let expectedMessage = testCase.expectedMessage {
                await #expect(throws: ComposeError.invalidProject(expectedMessage)) {
                    _ = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")
                }
            } else {
                let plan = try await ComposeOrchestrator().serviceCreatePlan(project: project, serviceName: "job")
                #expect(plan.memorySwapLimitInBytes == testCase.expectedLimit)
            }
        }
    }

    @Test("create surfaces network create failures before creating containers")
    func createSurfacesNetworkCreateFailuresBeforeCreatingContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            networkCreateError: ComposeError.invalidProject("network create failed")
        )
        let project = projectWithBackendNetwork(serviceName: "api", image: "example/api")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .create(project: project, options: ComposeCreateOptions())
            Issue.record("Expected network create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("network create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
    }

    @Test("create surfaces volume create failures before creating containers")
    func createSurfacesVolumeCreateFailuresBeforeCreatingContainers() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager(
            volumeCreateError: ComposeError.invalidProject("volume create failed")
        )
        let project = projectWithCacheVolume(serviceName: "api", image: "example/api")

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .create(project: project, options: ComposeCreateOptions())
            Issue.record("Expected volume create failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("volume create failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.map(\.name) == ["demo_cache"])
    }

    @Test("create maps network mode none to no network attachment")
    func createMapsNetworkModeNoneToNoNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networkMode = "none"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--network", "none"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("create maps network mode host to runtime host networking")
    func createMapsNetworkModeHostToRuntimeHostNetworking() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networkMode = "host"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--network", "host"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("create maps network mode bridge to the built-in runtime network")
    func createMapsNetworkModeBridgeToBuiltinRuntimeNetwork() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networkMode = "bridge"
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--network", "default"]))
        #expect(!command.contains("demo_default"))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("create maps pid host to container pid argument")
    func createMapsPIDHostToContainerPIDArgument() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.pid = "host"
                    $0.networks = ["default"]
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--network", "demo_default"]))
        #expect(command.containsSequence(["--pid", "host"]))
        #expect(await resourceManager.requests.map(\.name) == ["demo_default"])
    }

    @Test("create maps cgroup host to container cgroup namespace argument")
    func createMapsCgroupHostToContainerCgroupNamespaceArgument() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.cgroup = "host"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--cgroupns", "host"]))
    }

    @Test("create maps IPC and UTS host to container namespace arguments")
    func createMapsIPCAndUTSHostToContainerNamespaceArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.ipc = "host"
                    $0.uts = "host"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--ipc", "host"]))
        #expect(command.containsSequence(["--uts", "host"]))
    }

    @Test("create skips missing optional dependencies")
    func createSkipsMissingOptionalDependencies() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["optional": ComposeDependency(condition: "service_healthy", required: false)]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.services = ["api"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-optional-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("create applies build pull policy before creating containers")
    func createAppliesBuildPullPolicyBeforeCreatingContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.pullPolicy = "build"
            }
        )

        let commands = runner.commands.map(\.arguments)
        let apiBuild = try #require(commands.first { $0.containsSequence(["container", "build", "--tag", "example/api"]) })
        let workerBuild = try #require(commands.first { $0.containsSequence(["container", "build", "--tag", "demo_worker:latest"]) })
        let firstCreateIndex = try #require(commands.firstIndex { $0.starts(with: ["container", "create"]) })
        #expect(apiBuild.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
        #expect(workerBuild.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("worker").standardizedFileURL.path)
        #expect(commands[..<firstCreateIndex].allSatisfy { $0.starts(with: ["container", "build"]) })
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-api-1"]) })
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-worker-1"]) })
        #expect(await discoveryManager.getRequests.sorted() == ["demo-api-1", "demo-worker-1"])
    }

    @Test("create applies service build pull policy before creating containers")
    func createAppliesServiceBuildPullPolicyBeforeCreatingContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                    $0.pullPolicy = "build"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions()
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/api"]))
        #expect(commands[0].last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("create pull if not present pulls only absent images")
    func createPullIfNotPresentPullsOnlyAbsentImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager(imageMetadata: [
            "example/api": ComposeImageMetadata(reference: "example/api") {
                $0.environment = ["PATH=/usr/bin", "LOG_LEVEL=info"]
                $0.command = ["base"]
                $0.exposedPorts = ["9090/tcp"]
            },
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.pullPolicy = "if_not_present"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(await imageManager.requests == [
            .pullMissing("example/api"),
            .pullMissing("postgres"),
            .healthCheck(reference: "example/api", platform: nil),
            .healthCheck(reference: "postgres", platform: nil),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-db-1"])
    }

    @Test("create build with missing pull builds buildable images and pulls only runtime images")
    func createBuildWithMissingPullBuildsBuildableImagesAndPullsOnlyRuntimeImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.build = true
                $0.pullPolicy = "missing"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/api"]))
        #expect(commands[0].last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[2].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(await imageManager.requests == [
            .pullMissing("postgres"),
            .healthCheck(reference: "example/api", platform: nil),
            .healthCheck(reference: "postgres", platform: nil),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-db-1"])
    }

    @Test("create quiet-pull dry run disables pull progress")
    func createQuietPullDryRunDisablesPullProgress() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "alpine")]
        )

        try await orchestrator.create(
            project: project,
            options: ComposeCreateOptions {
                $0.pullPolicy = "always"
                $0.quietPull = true
            }
        )

        let messages = emitted.messages
        #expect(messages.contains("+ container image pull --progress none alpine"))
        #expect(messages.contains { $0.hasPrefix("+ container create ") })
    }

    @Test("create auto builds build-only services by default")
    func createAutoBuildsBuildOnlyServicesByDefault() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(project: project, options: ComposeCreateOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "demo_worker:latest"]))
        #expect(commands[0].last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("worker").standardizedFileURL.path)
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("create no-build skips auto build for build-only service")
    func createNoBuildSkipsAutoBuildForBuildOnlyService() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.noBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(!commands.contains { $0.containsSequence(["container", "build"]) })
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(commands[0].last == "demo_worker:latest")
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("create reuses or recreates existing containers according to policy")
    func createReusesOrRecreatesExistingContainersAccordingToPolicy() async throws {
        let emitted = MessageRecorder()
        let reuseRunner = RecordingRunner()
        let reuseDiscovery = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running"),
        ])
        try await ComposeOrchestrator(
            runner: reuseRunner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            discoveryManager: reuseDiscovery
        )
        .create(
            project: ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")]),
            options: ComposeCreateOptions {
                $0.noRecreate = true
            }
        )

        #expect(reuseRunner.commands.isEmpty)
        #expect(await reuseDiscovery.getRequests == ["demo-api-1"])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])

        let recreateRunner = RecordingRunner(responses: [
            .success,
        ])
        let recreateDiscovery = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: "stale"]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: recreateRunner,
            discoveryManager: recreateDiscovery,
            lifecycleManager: lifecycleManager
        ).create(project: project, options: ComposeCreateOptions())

        #expect(recreateRunner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(recreateRunner.commands[0].arguments.containsSequence(["--stop-signal", "SIGUSR1"]))
        #expect(recreateRunner.commands[0].arguments.containsSequence(["--stop-timeout", "9"]))
        #expect(await recreateDiscovery.getRequests == ["demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("create validates incompatible options and invalid scale before side effects")
    func createValidatesIncompatibleOptionsAndInvalidScaleBeforeSideEffects() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        let incompatibleOptionCases: [(options: ComposeCreateOptions, message: String)] = [
            (
                ComposeCreateOptions {
                    $0.build = true
                    $0.noBuild = true
                },
                "--build and --no-build are incompatible"
            ),
            (
                ComposeCreateOptions {
                    $0.forceRecreate = true
                    $0.noRecreate = true
                },
                "--force-recreate and --no-recreate are incompatible"
            ),
        ]

        for testCase in incompatibleOptionCases {
            let runner = RecordingRunner()
            do {
                try await ComposeOrchestrator(runner: runner).create(project: project, options: testCase.options)
                Issue.record("Expected invalid create option combination")
            } catch let error as ComposeError {
                #expect(error == .invalidProject(testCase.message))
            }
            #expect(runner.commands.isEmpty)
        }

        let scaleRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: scaleRunner).create(
                project: project,
                options: ComposeCreateOptions {
                    $0.scales = ["api=two"]
                }
            )
            Issue.record("Expected invalid create scale failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--scale for service 'api' must be a non-negative integer"))
        }
        #expect(scaleRunner.commands.isEmpty)

        let pullRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: pullRunner).create(
                project: project,
                options: ComposeCreateOptions {
                    $0.pullPolicy = "daily"
                }
            )
            Issue.record("Expected unsupported create pull policy failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unsupported pull policy 'daily'"))
        }
        #expect(pullRunner.commands.isEmpty)
    }

    @Test("create allocates dynamic published ports before creating containers")
    func createAllocatesDynamicPublishedPortsBeforeCreatingContainers() async throws {
        let ports = HostPortSource([49153, 49154])
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["80-81/udp"]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) }),
            discoveryManager: RecordingContainerDiscoveryManager()
        ).create(project: project, options: ComposeCreateOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--publish", "49153:80/udp"]))
        #expect(command.containsSequence(["--publish", "49154:81/udp"]))
        #expect(ports.requests == [
            HostPortAllocationRequest(hostAddress: nil, protocolName: "udp"),
            HostPortAllocationRequest(hostAddress: nil, protocolName: "udp"),
        ])
    }

    @Test("default dynamic host port allocator allocates local tcp ports")
    func defaultDynamicHostPortAllocatorAllocatesLocalTCPPorts() throws {
        let port = try ComposeExecutionOptions.defaultHostPortAllocator(
            hostAddress: "127.0.0.1",
            protocolName: "tcp"
        )

        #expect(port > 0)
    }

    @Test("default dynamic host port allocator rejects unknown protocols")
    func defaultDynamicHostPortAllocatorRejectsUnknownProtocols() throws {
        do {
            _ = try ComposeExecutionOptions.defaultHostPortAllocator(
                hostAddress: nil,
                protocolName: "sctp"
            )
            Issue.record("Expected invalid protocol failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("dynamic host-port allocation supports tcp and udp protocols, got 'sctp'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("up validates incompatible build options before side effects")
    func upValidatesIncompatibleBuildOptionsBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.build = true
                    $0.noBuild = true
                }
            )
            Issue.record("Expected invalid up build option combination")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--build and --no-build are incompatible"))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up validates incompatible recreate options before side effects")
    func upValidatesIncompatibleRecreateOptionsBeforeSideEffects() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])
        let incompatibleOptionCases: [(options: ComposeUpOptions, message: String)] = [
            (
                ComposeUpOptions {
                    $0.forceRecreate = true
                    $0.noRecreate = true
                },
                "--force-recreate and --no-recreate are incompatible"
            ),
            (
                ComposeUpOptions {
                    $0.alwaysRecreateDeps = true
                    $0.noRecreate = true
                },
                "--always-recreate-deps and --no-recreate are incompatible"
            ),
            (
                ComposeUpOptions {
                    $0.wait = true
                    $0.noStart = true
                },
                "--wait and --no-start are incompatible"
            ),
            (
                ComposeUpOptions {
                    $0.noRecreate = true
                    $0.renewAnonymousVolumes = true
                },
                "--no-recreate and --renew-anon-volumes are incompatible"
            ),
            (
                ComposeUpOptions {
                    $0.menuWatch = true
                },
                "up --watch requires --menu in menu watch mode"
            ),
            (
                ComposeUpOptions {
                    $0.menu = true
                    $0.menuWatch = true
                    $0.noStart = true
                },
                "up --watch cannot be combined with --no-start"
            ),
            (
                ComposeUpOptions {
                    $0.menu = true
                    $0.menuWatch = true
                    $0.detach = true
                },
                "up --watch cannot be combined with --detach"
            ),
            (
                ComposeUpOptions {
                    $0.menu = true
                    $0.menuWatch = true
                    $0.wait = true
                },
                "up --watch cannot be combined with --wait"
            ),
            (
                ComposeUpOptions {
                    $0.menu = true
                    $0.menuWatch = true
                    $0.abortOnContainerExit = true
                },
                "up --watch cannot be combined with exit-control options"
            ),
        ]

        for testCase in incompatibleOptionCases {
            let runner = RecordingRunner()
            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: testCase.options)
                Issue.record("Expected invalid up option combination")
            } catch let error as ComposeError {
                #expect(error == .invalidProject(testCase.message))
            }
            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up creates scaled service replicas")
    func upCreatesScaledServiceReplicas() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands[0].contains("--detach"))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-2"]))
        #expect(!commands[1].contains("--detach"))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true, true])
    }

    @Test("up wait implies detached containers and polls through restarting until running")
    func upWaitImpliesDetachedContainersAndPollsThroughRestartingUntilRunning() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-api-1", status: "starting"),
                    ComposeContainerSummary(id: "demo-api-1", status: "restarting"),
                    ComposeContainerSummary(id: "demo-api-1", status: "running"),
                ],
            ]
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { _ in }),
            discoveryManager: discoveryManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.wait = true
                $0.waitTimeout = 5
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-1", "demo-api-1", "demo-api-1"])
    }

    @Test("up wait treats deploy job modes as ordinary running services")
    func upWaitTreatsDeployJobModesAsOrdinaryRunningServices() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-migrate-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-migrate-1", status: "starting"),
                    ComposeContainerSummary(id: "demo-migrate-1", status: "running"),
                ],
            ]
        )
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "global-job"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { _ in }),
            discoveryManager: discoveryManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.wait = true
                $0.waitTimeout = 5
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-migrate-1", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-migrate-1", "demo-migrate-1", "demo-migrate-1"])
    }

    @Test("up wait polls configured healthchecks until healthy")
    func upWaitPollsConfiguredHealthchecksUntilHealthy() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-api-1", status: "running", health: "starting"),
                    ComposeContainerSummary(id: "demo-api-1", status: "running", health: "healthy"),
                ],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.healthcheck = .object([
                        "test": .array([.string("CMD"), .string("/bin/true")]),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(sleep: { _ in }),
            discoveryManager: discoveryManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.wait = true
                $0.waitTimeout = 5
            }
        )

        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-1", "demo-api-1"])
    }

    @Test("up wait fails when a configured healthcheck becomes unhealthy")
    func upWaitFailsWhenConfiguredHealthcheckBecomesUnhealthy() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-api-1", status: "running", health: "unhealthy"),
                ],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.healthcheck = .object([
                        "test": .array([.string("CMD"), .string("/bin/false")]),
                    ])
                },
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: runner,
                options: ComposeExecutionOptions(sleep: { _ in }),
                discoveryManager: discoveryManager
            ).up(
                project: project,
                options: ComposeUpOptions {
                    $0.wait = true
                    $0.waitTimeout = 5
                }
            )
            Issue.record("Expected up wait to reject an unhealthy container")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' container 'demo-api-1' is unhealthy"))
        }
    }

    @Test("up wait dry run emits wait-ready operations")
    func upWaitDryRunEmitsWaitReadyOperations() async throws {
        let emitted = MessageRecorder()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.wait = true
                $0.waitTimeout = 3
            }
        )

        #expect(emitted.messages.contains("+ container inspect demo-api-1"))
        #expect(emitted.messages.contains { message in
            message.contains("container run --name demo-api-1 --detach")
                && message.contains("com.apple.container.compose.service=api")
                && message.hasSuffix("example/api")
        })
        #expect(emitted.messages.contains("+ compose-runtime wait-ready --timeout 3 demo-api-1"))
    }

    @Test("up passes configured init image to container create")
    func upPassesConfiguredInitImageToContainerCreate() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(initImage: "vminit:container-compose"),
            dependencies: orchestratorDependencies { _ in }
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "create"]) })
        #expect(runArguments.containsSequence(["--init-image", "vminit:container-compose"]))
        #expect(runArguments.last == "example/api")
    }

    @Test("up wait timeout reports up command")
    func upWaitTimeoutReportsUpCommand() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(
            getResponses: [
                "demo-api-1": [
                    nil,
                    ComposeContainerSummary(id: "demo-api-1", status: "starting"),
                ],
            ]
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        let now = Date(timeIntervalSince1970: 1000)
        do {
            try await ComposeOrchestrator(
                runner: runner,
                options: ComposeExecutionOptions(runtimeHooks: .init(currentDate: { now }, sleep: { _ in })),
                discoveryManager: discoveryManager
            ).up(
                project: project,
                options: ComposeUpOptions {
                    $0.wait = true
                    $0.waitTimeout = 0
                }
            )
            Issue.record("Expected up wait timeout error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("up --wait timed out waiting for demo-api-1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("create creates scaled service replicas")
    func createCreatesScaledServiceReplicas() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-2"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("up allocates published port ranges per service replica")
    func upAllocatesPublishedPortRangesPerServiceReplica() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.ports = ["8080-8081:80"]
        }])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].containsSequence(["--publish", "8080:80"]))
        #expect(!commands[0].containsSequence(["--publish", "8081:80"]))
        #expect(commands[1].containsSequence(["--publish", "8081:80"]))
        #expect(!commands[1].containsSequence(["--publish", "8080:80"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true, true])
    }

    @Test("up allocates dynamic published ports per service replica")
    func upAllocatesDynamicPublishedPortsPerServiceReplica() async throws {
        let ports = HostPortSource([49154, 49155])
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.ports = ["80"]
        }])

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) }),
            discoveryManager: discoveryManager
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].containsSequence(["--publish", "49154:80"]))
        #expect(commands[1].containsSequence(["--publish", "49155:80"]))
        #expect(ports.requests == [
            HostPortAllocationRequest(hostAddress: nil, protocolName: "tcp"),
            HostPortAllocationRequest(hostAddress: nil, protocolName: "tcp"),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true, true])
    }

    @Test("up allocates dynamic published ports with host addresses and protocols")
    func upAllocatesDynamicPublishedPortsWithHostAddressesAndProtocols() async throws {
        let ports = HostPortSource([49156, 49157])
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.ports = ["127.0.0.1::80/udp", "[::1]::81"]
        }])

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(hostPortAllocator: { try ports.next(hostAddress: $0, protocolName: $1) }),
            discoveryManager: discoveryManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--publish", "127.0.0.1:49156:80/udp"]))
        #expect(command.containsSequence(["--publish", "[::1]:49157:81"]))
        #expect(ports.requests == [
            HostPortAllocationRequest(hostAddress: "127.0.0.1", protocolName: "udp"),
            HostPortAllocationRequest(hostAddress: "[::1]", protocolName: "tcp"),
        ])
    }

    @Test("up maps anonymous volumes per service replica")
    func upMapsAnonymousVolumesPerServiceReplica() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.volumes = [
                ComposeMount(type: "volume", target: "/scratch"),
            ]
        }])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].contains { $0.hasPrefix("demo_anon-api-1-") && $0.hasSuffix(":/scratch") })
        #expect(commands[1].contains { $0.hasPrefix("demo_anon-api-2-") && $0.hasSuffix(":/scratch") })
        #expect(!commands[0].contains { $0.hasPrefix("demo_anon-api-2-") })
        #expect(!commands[1].contains { $0.hasPrefix("demo_anon-api-1-") })
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true, true])
    }

    @Test("up isolates anonymous volumes for single replica services")
    func upIsolatesAnonymousVolumesForSingleReplicaServices() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: [
            "api": composeService(name: "api", image: "example/api") {
                $0.volumes = [ComposeMount(type: "volume", target: "/scratch")]
            },
            "worker": composeService(name: "worker", image: "example/worker") {
                $0.volumes = [ComposeMount(type: "volume", target: "/scratch")]
            },
        ])

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager
        ).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        let api = try #require(commands.first { $0.containsSequence(["--name", "demo-api-1"]) })
        let worker = try #require(commands.first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let apiVolume = try #require(anonymousVolumeSource(target: "/scratch", in: api))
        let workerVolume = try #require(anonymousVolumeSource(target: "/scratch", in: worker))
        #expect(apiVolume.hasPrefix("demo_anon-api-1-"))
        #expect(workerVolume.hasPrefix("demo_anon-worker-1-"))
        #expect(apiVolume != workerVolume)
    }

    @Test("run isolates anonymous volume from the managed service")
    func runIsolatesAnonymousVolumeFromManagedService() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: [
            "job": composeService(name: "job", image: "alpine") {
                $0.volumes = [ComposeMount(type: "volume", target: "/scratch")]
            },
        ])
        let options = ComposeExecutionOptions(runtimeHooks: .init(oneOffIdentifier: { "abc123" }))
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: options,
            discoveryManager: discoveryManager
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())
        try await orchestrator.run(
            project: project,
            serviceName: "job",
            options: composeRunOptions(command: ["true"])
        )

        let commands = runner.commands.map(\.arguments)
        let managed = try #require(commands.first { $0.containsSequence(["--name", "demo-job-1"]) })
        let oneOff = try #require(commands.first { $0.containsSequence(["--name", "demo-job-run-abc123"]) })
        let managedVolume = try #require(anonymousVolumeSource(target: "/scratch", in: managed))
        let oneOffVolume = try #require(anonymousVolumeSource(target: "/scratch", in: oneOff))
        #expect(managedVolume.hasPrefix("demo_anon-job-1-"))
        #expect(oneOffVolume.hasPrefix("demo_anon-job-run-"))
        #expect(managedVolume != oneOffVolume)
    }

    @Test("up renew anonymous volumes recreates matching containers")
    func upRenewAnonymousVolumesRecreatesMatchingContainers() async throws {
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.volumes = [
                ComposeMount(type: "volume", target: "/scratch"),
            ]
        }])
        let createRunner = RecordingRunner(responses: [.success])
        let createDiscovery = RecordingContainerDiscoveryManager()

        try await ComposeOrchestrator(runner: createRunner, discoveryManager: createDiscovery)
            .up(project: project, options: ComposeUpOptions())

        let createCommand = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: createCommand))
        let anonymousVolume = try #require(createCommand.compactMap { argument -> String? in
            guard argument.hasPrefix("demo_anon-"), argument.hasSuffix(":/scratch") else {
                return nil
            }
            return String(argument.split(separator: ":", maxSplits: 1)[0])
        }.first)
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: hash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let resourceManager = RecordingContainerResourceManager(volumes: [
            ComposeVolumeSummary(name: anonymousVolume),
        ])

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions {
            $0.renewAnonymousVolumes = true
        })

        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
        #expect(await resourceManager.requests == [
            .listVolumes,
            .deleteVolume(name: anonymousVolume),
            .createVolume(ComposeVolumeCreateRequest(name: anonymousVolume)),
        ])
        #expect(runner.commands.map(\.arguments).count == 1)
        #expect(try #require(runner.commands.last?.arguments).contains { $0 == "\(anonymousVolume):/scratch" })
    }

    @Test("create allocates multi port ranges per service replica")
    func createAllocatesMultiPortRangesPerServiceReplica() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
            $0.ports = ["127.0.0.1:8080-8083:80-81/udp"]
        }])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).create(
            project: project,
            options: ComposeCreateOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].containsSequence(["--publish", "127.0.0.1:8080:80/udp"]))
        #expect(commands[0].containsSequence(["--publish", "127.0.0.1:8081:81/udp"]))
        #expect(commands[1].containsSequence(["--publish", "127.0.0.1:8082:80/udp"]))
        #expect(commands[1].containsSequence(["--publish", "127.0.0.1:8083:81/udp"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("scale creates detached service replicas")
    func scaleCreatesDetachedServiceReplicas() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).scale(
            project: project,
            options: ComposeScaleOptions {
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-2", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("scale no-deps starts only selected services")
    func scaleNoDepsStartsOnlySelectedServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).scale(
            project: project,
            options: ComposeScaleOptions {
                $0.noDeps = true
                $0.scales = ["api=2"]
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-2", "--detach"]))
        #expect(!commands.contains { $0.contains("demo-db-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true])
    }

    @Test("scale requires assignment before side effects")
    func scaleRequiresAssignmentBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).scale(project: project, options: ComposeScaleOptions())
            Issue.record("Expected missing scale assignment failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("scale requires at least one SERVICE=REPLICAS argument"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up prunes replicas above requested scale")
    func upPrunesReplicasAboveRequestedScale() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.noRecreate = true
                $0.scales = ["api=1"]
            }
        )

        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await discoveryManager.listRequests == [true, true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-2", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-2", force: false),
        ])
    }

    @Test("up rejects invalid and unsafe scale before side effects")
    func upRejectsInvalidAndUnsafeScaleBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.scales = ["api=-1"]
                }
            )
            Issue.record("Expected invalid up scale failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--scale for service 'api' must be a non-negative integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(runner.commands.isEmpty)

        let namedRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: namedRunner).up(
                project: ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                    $0.containerName = "fixed-api"
                }]),
                options: ComposeUpOptions {
                    $0.scales = ["api=2"]
                }
            )
            Issue.record("Expected container_name scale failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' uses container_name; scale greater than 1 requires Compose-managed replica names"))
        }
        #expect(namedRunner.commands.isEmpty)

        let portRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: portRunner).up(
                project: ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                    $0.ports = ["8080:80"]
                }]),
                options: ComposeUpOptions {
                    $0.scales = ["api=2"]
                }
            )
            Issue.record("Expected published-port scale failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' publishes '8080:80'; scaled published ports require at least 2 explicit host ports for 2 replicas"))
        }
        #expect(portRunner.commands.isEmpty)

        let serviceMACRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: serviceMACRunner).up(
                project: composeProject(
                    name: "demo",
                    services: [
                        "api": composeService(name: "api", image: "example/api") {
                            $0.macAddress = "02:42:ac:11:00:03"
                            $0.networks = ["backend"]
                        },
                    ]
                ) {
                    $0.networks = ["backend": ComposeNetwork(name: "backend")]
                },
                options: ComposeUpOptions {
                    $0.scales = ["api=2"]
                }
            )
            Issue.record("Expected service mac_address scale failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses mac_address; scaled MAC addresses would collide across replicas"))
        }
        #expect(serviceMACRunner.commands.isEmpty)

        let networkMACRunner = RecordingRunner()
        do {
            try await ComposeOrchestrator(runner: networkMACRunner).up(
                project: composeProject(
                    name: "demo",
                    services: [
                        "api": composeService(name: "api", image: "example/api") {
                            $0.networks = ["backend"]
                            $0.networkOptions = [
                                "backend": ComposeNetworkOptions(addressing: .init(macAddress: "02:42:ac:11:00:04")),
                            ]
                        },
                    ]
                ) {
                    $0.networks = ["backend": ComposeNetwork(name: "backend")]
                },
                options: ComposeUpOptions {
                    $0.scales = ["api=2"]
                }
            )
            Issue.record("Expected per-network mac_address scale failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses mac_address; scaled MAC addresses would collide across replicas"))
        }
        #expect(networkMACRunner.commands.isEmpty)
    }

    @Test("up no-deps starts only selected services")
    func upNoDepsStartsOnlySelectedServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noDeps = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-db-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-deps skips dependency metadata validation")
    func upNoDepsSkipsDependencyMetadataValidation() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy", restart: true)]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noDeps = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-db-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-start creates containers without starting them")
    func upNoStartCreatesContainersWithoutStartingThem() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noStart = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.starts(with: ["container", "run"]) })
        #expect(!commands.contains { $0.contains("--detach") })
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
    }

    @Test("up accepts deploy endpoint mode metadata normalized by compose-go")
    func upAcceptsDeployEndpointModeMetadataNormalizedByComposeGo() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: alpine:3.20
            deploy:
              endpoint_mode: dnsrr
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "demo",
            projectDirectory: directory.path
        ))
        let api = try #require(project.services["api"])
        #expect(api.unsupportedDeployFields == nil)

        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.noStart = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-api-1"]) })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up projects deploy memory reservations while retaining CPU reservation metadata")
    func upProjectsDeployMemoryReservationsWhileRetainingCPUReservationMetadata() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        services:
          api:
            image: alpine:3.20
            deploy:
              resources:
                reservations:
                  cpus: "0.25"
                  memory: 32M
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "demo",
            projectDirectory: directory.path
        ))
        let api = try #require(project.services["api"])
        #expect(api.unsupportedDeployFields == nil)
        #expect(api.memReservation == "33554432")

        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.noStart = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--memory-reservation", "33554432"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-start no-deps creates only selected services")
    func upNoStartNoDepsCreatesOnlySelectedServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_healthy", restart: true)]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noDeps = true
                $0.noStart = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!commands.contains { $0.contains("demo-db-1") })
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-start always-recreate-deps recreates matching dependency containers")
    func upNoStartAlwaysRecreateDepsRecreatesMatchingDependencyContainers() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )
        let baselineRunner = RecordingRunner()
        try await ComposeOrchestrator(runner: baselineRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noStart = true
            })

        let dbCreate = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiCreate = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        let dbHash = try #require(composeConfigHash(in: dbCreate))
        let apiHash = try #require(composeConfigHash(in: apiCreate))
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-db-1", status: "running", labels: [composeConfigHashLabel: dbHash]),
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: apiHash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.noStart = true
            $0.alwaysRecreateDeps = true
            $0.timeout = 12
        })

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-db-1"]))
        #expect(!commands.contains { $0.contains("demo-api-1") })
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: 12),
            .delete(id: "demo-db-1", force: false),
        ])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
    }

    @Test("up no-start quiet build passes quiet through create")
    func upNoStartQuietBuildPassesQuietThroughCreate() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.build = true
                $0.noStart = true
                $0.quietBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "build"]))
        #expect(commands[0].contains("--quiet"))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("up uses external resource names without creating project resources")
    func upUsesExternalResourceNamesWithoutCreatingProjectResources() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networks = ["shared"]
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/data")]
                },
            ]
        ) {
            $0.networks = ["shared": ComposeNetwork(name: "corp-net", options: ComposeNetwork.Options(external: true))]
            $0.volumes = ["data": ComposeVolume(name: "corp-data", external: true)]
        }

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(!commands.contains { $0.containsSequence(["network", "create"]) })
        #expect(!commands.contains { $0.containsSequence(["volume", "create"]) })

        let run = commands[0]
        #expect(run.containsSequence(["--network", "corp-net"]))
        #expect(run.containsSequence(["--volume", "corp-data:/data"]))
        #expect(!run.contains("demo_shared"))
        #expect(!run.contains("demo_data"))
    }

    @Test("orchestrator honors explicit non external resource names")
    func orchestratorHonorsExplicitNonExternalResourceNames() async throws {
        let upRunner = RecordingRunner(responses: [
            .success,
        ])
        let upResources = RecordingContainerResourceManager()
        let upDiscovery = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "team-net")]
            $0.volumes = ["cache": ComposeVolume(name: "team-cache")]
        }

        try await ComposeOrchestrator(
            runner: upRunner,
            discoveryManager: upDiscovery,
            resourceManager: upResources
        ).up(project: project, options: ComposeUpOptions())

        let upCommands = upRunner.commands.map(\.arguments)
        let upResourceRequests = await upResources.requests
        #expect(upResourceRequests.map(\.name) == ["team-net", "team-cache"])
        #expect(upCommands[0].containsSequence(["--network", "team-net"]))
        #expect(upCommands[0].containsSequence(["--volume", "team-cache:/cache"]))
        #expect(await upDiscovery.getRequests == ["demo-api-1"])

        let downRunner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let downResources = RecordingContainerResourceManager()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let downDiscovery = RecordingContainerDiscoveryManager()

        try await ComposeOrchestrator(
            runner: downRunner,
            discoveryManager: downDiscovery,
            lifecycleManager: lifecycleManager,
            resourceManager: downResources
        ).down(project: project, options: ComposeDownOptions(volumes: true))

        let lifecycleRequests = await lifecycleManager.requests
        let downResourceRequests = await downResources.requests
        #expect(downRunner.commands.isEmpty)
        #expect(lifecycleRequests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
        #expect(await downDiscovery.listRequests == [true])
        #expect(downResourceRequests == [
            .deleteNetwork(id: "team-net"),
            .listVolumes,
            .deleteVolume(name: "team-cache"),
        ])
    }

    @Test("up removes orphan containers when requested")
    func upRemovesOrphanContainersWhenRequested() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-worker-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                    composeConfigHashLabel: "worker-hash",
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, lifecycleManager: lifecycleManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.removeOrphans = true
            $0.assumeYes = true
            $0.timeout = 7
        })

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!runner.commands[0].arguments.contains("--detach"))
        #expect(runner.commands[0].arguments.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(runner.commands[0].arguments.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(runner.commands[0].arguments.last == "example/api:latest")
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await discoveryManager.listRequests == [true, true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: 7),
            .delete(id: "demo-worker-1", force: false),
        ])
    }

    @Test("up warns about orphan containers unless ignored or removed")
    func upWarnsAboutOrphanContainersUnlessIgnoredOrRemoved() async throws {
        let statuses = MessageRecorder()
        let runner = RecordingRunner(responses: [.success])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-worker-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                    composeConfigHashLabel: "worker-hash",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions {
                $0.reportOrphans = true
                $0.emitStatus = { statuses.append($0) }
            },
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).up(project: project, options: ComposeUpOptions())

        #expect(statuses.messages == [
            "warning: found orphan containers (demo-worker-1) for this project; run with --remove-orphans to remove them",
        ])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("up suppresses orphan warnings when execution options ignore them")
    func upSuppressesOrphanWarningsWhenExecutionOptionsIgnoreThem() async throws {
        let statuses = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-worker-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                    composeConfigHashLabel: "worker-hash",
                ]
            ),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(responses: [.success]),
            options: ComposeExecutionOptions {
                $0.ignoreOrphans = true
                $0.reportOrphans = true
                $0.emitStatus = { statuses.append($0) }
            },
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).up(project: project, options: ComposeUpOptions())

        #expect(statuses.messages.isEmpty)
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("up remove orphans cancellation leaves orphan containers")
    func upRemoveOrphansCancellationLeavesOrphanContainers() async throws {
        let prompts = MessageRecorder()
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-worker-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                    composeConfigHashLabel: "worker-hash",
                ]
            ),
        ])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                runtimeHooks: .init(confirm: { prompt in
                    prompts.append(prompt)
                    return false
                })
            ),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.removeOrphans = true
            $0.timeout = 7
        })

        #expect(runner.commands.count == 1)
        #expect(await discoveryManager.listRequests == [true, true])
        #expect(prompts.messages == ["Going to remove orphan containers demo-worker-1\nAre you sure? [yN] "])
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("up remove orphans preserves declared service replicas without explicit scale")
    func upRemoveOrphansPreservesDeclaredServiceReplicasWithoutExplicitScale() async throws {
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                    composeConfigHashLabel: "api-hash",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-worker-1",
                status: "stopped",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                    composeConfigHashLabel: "worker-hash",
                ]
            ),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        ).up(project: project, options: ComposeUpOptions {
            $0.noRecreate = true
            $0.removeOrphans = true
            $0.assumeYes = true
        })

        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await discoveryManager.listRequests == [true, true])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-worker-1", force: false),
        ])
    }

    @Test("up --detach starts containers without following logs")
    func upDetachStartsContainersWithoutFollowingLogs() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let attachManager = RecordingContainerAttachManager()
        let logManager = RecordingContainerLogManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.attachManager = attachManager
                $0.logManager = logManager
            }
        ).up(project: project, options: ComposeUpOptions {
            $0.detach = true
        })

        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(runner.commands[0].arguments.last == "example/api:latest")
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up detaches services that disable attach")
    func upDetachesServicesThatDisableAttach() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let attachManager = RecordingContainerAttachManager()
        let logManager = RecordingContainerLogManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.attach = false
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.attachManager = attachManager
                $0.logManager = logManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
        })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(dbRun.starts(with: ["container", "create"]))
        #expect(!dbRun.contains("--detach"))
        #expect(apiRun.contains("--detach"))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-db-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up no-attach detaches named service and attaches next eligible dependency")
    func upNoAttachDetachesNamedServiceAndAttachesNextEligibleDependency() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let attachManager = RecordingContainerAttachManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.attachManager = attachManager
            },
        )
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
                $0.noAttach = ["api"]
            })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(dbRun.starts(with: ["container", "create"]))
        #expect(!dbRun.contains("--detach"))
        #expect(apiRun.contains("--detach"))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-db-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
    }

    @Test("up attach follows selected service output from before start")
    func upAttachFollowsSelectedServiceOutputFromBeforeStart() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("ready\n".utf8)),
        ])
        let logManager = RecordingContainerLogManager()
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
            )),
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.logManager = logManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.attach = ["api"]
        })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(dbRun.contains("--detach"))
        #expect(apiRun.starts(with: ["container", "create"]))
        #expect(!apiRun.contains("--detach"))
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
        #expect(emitted.messages == ["api-1 | ready\n"])
    }

    @Test("up attach frames split, blank, and unterminated output lines exactly once")
    func upAttachFramesSplitBlankAndUnterminatedOutputLinesExactlyOnce() async throws {
        let runner = RecordingRunner(responses: [.success])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("hel".utf8)),
            ComposeLogRecord(stream: .stdout, payload: Data("lo\n\npart".utf8)),
            ComposeLogRecord(stream: .stdout, payload: Data("ial".utf8)),
            ComposeLogRecord(stream: .stderr, payload: Data("err\n".utf8)),
        ])
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")],
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(runtimeHooks: .init(
                emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) },
            )),
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
            },
        ).up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages == [
            "api-1 | hello\n",
            "api-1 | \n",
            "api-1 | err\n",
            "api-1 | partial",
        ])
    }

    @Test("up attach dependencies follows selected service and dependency logs")
    func upAttachDependenciesFollowsSelectedServiceAndDependencyLogs() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let attachManager = RecordingContainerAttachManager()
        let logManager = RecordingContainerLogManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.logManager = logManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.attach = ["api"]
            $0.attachDependencies = true
            $0.timestamps = true
        })

        #expect(await attachManager.requests.sorted { $0.id < $1.id } == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
            ContainerAttachRequest(id: "demo-db-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up menu follows attachable selected service logs through menu controller")
    func upMenuFollowsAttachableSelectedServiceLogsThroughMenuController() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("ready\n".utf8)),
        ])
        let logManager = RecordingContainerLogManager()
        let menuController = RecordingComposeUpMenuController()
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "src", action: "sync", target: "/app/src"),
                    ])
                },
                "db": composeService(name: "db", image: "postgres") {
                    $0.attach = false
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
            )),
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
        })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(dbRun.contains("--detach"))
        #expect(apiRun.starts(with: ["container", "create"]))
        #expect(!apiRun.contains("--detach"))
        #expect(await menuController.requests == [
            ComposeUpMenuConfigurationSnapshot(
                projectName: "demo",
                watchEnabled: false,
                watchAvailable: true,
                colorEnabled: false
            ),
        ])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
        #expect(emitted.messages == ["api-1 | ready\n"])
    }

    @Test("up menu watch starts the menu with watch already enabled")
    func upMenuWatchStartsTheMenuWithWatchAlreadyEnabled() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let runner = RecordingRunner(responses: [
            .success,
        ])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("ready\n".utf8)),
        ])
        let logManager = RecordingContainerLogManager()
        let menuController = RecordingComposeUpMenuController()
        let emitted = MessageRecorder()
        var project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "src", action: "sync", target: "/app/src"),
                    ])
                },
            ]
        )
        project.workingDirectory = directory.path

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
            $0.menuWatch = true
            $0.quietBuild = true
        })

        let apiRun = try #require(runner.commands.first?.arguments)
        #expect(apiRun.starts(with: ["container", "create"]))
        #expect(!apiRun.contains("--detach"))
        #expect(await menuController.requests == [
            ComposeUpMenuConfigurationSnapshot(
                projectName: "demo",
                watchEnabled: true,
                watchAvailable: true,
                colorEnabled: false
            ),
        ])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
        #expect(emitted.messages == ["api-1 | ready\n"])
    }

    @Test("up menu watch rejects missing develop triggers before runtime side effects")
    func upMenuWatchRejectsMissingDevelopTriggersBeforeRuntimeSideEffects() async throws {
        let runner = RecordingRunner()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let menuController = RecordingComposeUpMenuController()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: runner,
                dependencies: orchestratorDependencies {
                    $0.logManager = logManager
                    $0.upMenuController = menuController
                }
            )
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
                $0.menu = true
                $0.menuWatch = true
            })
            Issue.record("Expected menu watch preflight to reject missing watch triggers")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("selected services does not declare develop.watch triggers"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await menuController.requests.isEmpty)
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up menu dry run emits log follow plan without invoking menu controller")
    func upMenuDryRunEmitsLogFollowPlanWithoutInvokingMenuController() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let menuController = RecordingComposeUpMenuController()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
        })

        #expect(emitted.messages.contains("+ compose-runtime attach --no-stdin demo-api-1"))
        #expect(await menuController.requests.isEmpty)
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up menu dry run emits exit-control plan without invoking menu controller")
    func upMenuDryRunEmitsExitControlPlanWithoutInvokingMenuController() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let menuController = RecordingComposeUpMenuController()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
            $0.abortOnContainerFailure = true
        })

        #expect(exitCode == 0)
        #expect(emitted.messages.contains("+ compose-runtime attach --no-stdin demo-api-1"))
        #expect(emitted.messages.contains("+ compose-runtime wait demo-api-1"))
        #expect(emitted.messages.contains("+ container stop demo-api-1"))
        #expect(emitted.messages.contains("+ container delete demo-api-1"))
        #expect(await menuController.requests.isEmpty)
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up menu waits on selected services when no logs are attachable")
    func upMenuWaitsOnSelectedServicesWhenNoLogsAreAttachable() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let menuController = RecordingComposeUpMenuController()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.attach = false
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
        })

        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(apiRun.contains("--detach"))
        #expect(await menuController.requests == [
            ComposeUpMenuConfigurationSnapshot(
                projectName: "demo",
                watchEnabled: false,
                watchAvailable: false,
                colorEnabled: false
            ),
        ])
        #expect(await lifecycleManager.requests == [
            .wait(id: "demo-api-1"),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up menu accepts exit-control options and returns the selected status")
    func upMenuAcceptsExitControlOptionsAndReturnsTheSelectedStatus() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-api-1": 6])
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-api-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "api",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
            ]
        )
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("ready\n".utf8)),
        ])
        let logManager = RecordingContainerLogManager()
        let menuController = RecordingComposeUpMenuController()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopGracePeriodSeconds = 3
                },
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
                $0.attachManager = attachManager
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
            $0.exitCodeFrom = "api"
        })

        #expect(exitCode == 6)
        #expect(await menuController.requests == [
            ComposeUpMenuConfigurationSnapshot(
                projectName: "demo",
                watchEnabled: false,
                watchAvailable: false,
                colorEnabled: false
            ),
        ])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
        let lifecycleRequests = await lifecycleManager.requests
        #expect(lifecycleRequests.contains(.wait(id: "demo-api-1")))
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: nil, timeoutInSeconds: 3)))
        #expect(lifecycleRequests.contains(.delete(id: "demo-api-1", force: false)))
    }

    @Test("up menu watch toggle validates before reporting watch enabled")
    func upMenuWatchToggleValidatesBeforeReportingWatchEnabled() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let menuController = RecordingComposeUpMenuController(actions: [.toggleWatch])
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-menu-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        var project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "missing-src", action: "sync", target: "/app/src"),
                    ])
                },
            ]
        )
        project.workingDirectory = temporaryDirectory.path

        do {
            try await ComposeOrchestrator(
                runner: runner,
                dependencies: orchestratorDependencies {
                    $0.logManager = logManager
                    $0.upMenuController = menuController
                }
            )
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
                $0.menu = true
            })
            Issue.record("Expected menu watch preflight to reject the missing watch path")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("develop.watch path does not exist: missing-src"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await menuController.requests == [
            ComposeUpMenuConfigurationSnapshot(
                projectName: "demo",
                watchEnabled: false,
                watchAvailable: true,
                colorEnabled: false
            ),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up menu shortcut actions stop and kill selected service graph")
    func upMenuShortcutActionsStopAndKillSelectedServiceGraph() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["ready\n"])
        let menuController = RecordingComposeUpMenuController(actions: [.gracefulStop, .forceStop])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.upMenuController = menuController
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.menu = true
            $0.timeout = 4
        })

        let lifecycleRequests = await lifecycleManager.requests
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: nil, timeoutInSeconds: 4)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-db-1", signal: nil, timeoutInSeconds: 4)))
        #expect(lifecycleRequests.contains(.kill(id: "demo-api-1", signal: "KILL")))
        #expect(lifecycleRequests.contains(.kill(id: "demo-db-1", signal: "KILL")))
    }

    @Test("up attach rejects services outside selected start graph")
    func upAttachRejectsServicesOutsideSelectedStartGraph() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.services = ["api"]
                    $0.attach = ["worker"]
                }
            )
            Issue.record("Expected attach selection error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("up --attach service 'worker' is not being started"))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up exit-code-from returns selected status and retains stopped containers")
    func upExitCodeFromReturnsSelectedStatusAndRetainsStoppedContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-api-1": 7])
        let attachManager = RecordingContainerAttachManager()
        let logManager = RecordingContainerLogManager()
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-api-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "api",
                        composeOneOffLabel: "false",
                    ]
                ),
                ComposeContainerSummary(
                    id: "demo-db-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "db",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
                "demo-db-1": [nil],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
                $0.attachManager = attachManager
                $0.logManager = logManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.exitCodeFrom = "api"
        })

        let dbRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(runner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        #expect(exitCode == 7)
        #expect(dbRun.starts(with: ["container", "create"]))
        #expect(apiRun.starts(with: ["container", "create"]))
        #expect(!dbRun.contains("--detach"))
        #expect(!apiRun.contains("--detach"))
        let lifecycleRequests = await lifecycleManager.requests
        #expect(lifecycleRequests.contains(.wait(id: "demo-api-1")))
        #expect(lifecycleRequests.contains(.wait(id: "demo-db-1")))
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil)))
        #expect(!lifecycleRequests.contains(.delete(id: "demo-api-1", force: false)))
        #expect(!lifecycleRequests.contains(.delete(id: "demo-db-1", force: false)))
        #expect(await discoveryManager.listRequests == [true, true, true])
        #expect(await attachManager.requests.sorted { $0.id < $1.id } == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
            ContainerAttachRequest(id: "demo-db-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up exit-code-from aborts when another service exits first and returns selected status")
    func upExitCodeFromAbortsOnOtherServiceExitAndReturnsSelectedStatus() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(
            waitExitCodes: [
                "demo-api-1": 7,
                "demo-db-1": 0,
            ],
            waitDelaysByID: [
                "demo-api-1": .milliseconds(20),
            ]
        )
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-api-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "api",
                        composeOneOffLabel: "false",
                    ]
                ),
                ComposeContainerSummary(
                    id: "demo-db-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "db",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
                "demo-db-1": [nil],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.exitCodeFrom = "api"
        })
        let lifecycleRequests = await lifecycleManager.requests

        #expect(exitCode == 7)
        #expect(lifecycleRequests.contains(.wait(id: "demo-db-1")))
        #expect(lifecycleRequests.contains(.wait(id: "demo-api-1")))
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil)))
        #expect(!lifecycleRequests.contains(.delete(id: "demo-api-1", force: false)))
        #expect(!lifecycleRequests.contains(.delete(id: "demo-db-1", force: false)))
    }

    @Test("up exit-code-from preserves selected status when attached log follow ends")
    func upExitCodeFromPreservesSelectedStatusWhenAttachedLogFollowEnds() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(
            waitExitCodes: [
                "demo-api-1": 7,
                "demo-db-1": 0,
            ],
            waitDelaysByID: [
                "demo-api-1": .milliseconds(20),
            ]
        )
        let attachManager = RecordingContainerAttachManager(
            delay: .milliseconds(10),
            error: ComposeError.unsupported("attached log stream ended during exit-control teardown")
        )
        let logManager = RecordingContainerLogManager()
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-api-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "api",
                        composeOneOffLabel: "false",
                    ]
                ),
                ComposeContainerSummary(
                    id: "demo-db-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "db",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
                "demo-db-1": [nil],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
                $0.attachManager = attachManager
                $0.logManager = logManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.exitCodeFrom = "api"
        })

        #expect(exitCode == 7)
        #expect(await attachManager.requests.sorted { $0.id < $1.id } == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
            ContainerAttachRequest(id: "demo-db-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("up abort-on-container-failure returns status and retains stopped containers")
    func upAbortOnContainerFailureReturnsStatusAndRetainsStoppedContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(
            waitExitCodes: [
                "demo-api-1": 0,
                "demo-worker-1": 8,
            ],
            waitDelaysByID: [
                "demo-worker-1": .milliseconds(20),
            ]
        )
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-api-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "api",
                        composeOneOffLabel: "false",
                    ]
                ),
                ComposeContainerSummary(
                    id: "demo-worker-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "worker",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
                "demo-worker-1": [nil],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.abortOnContainerFailure = true
        })
        let lifecycleRequests = await lifecycleManager.requests

        #expect(exitCode == 8)
        #expect(lifecycleRequests.contains(.wait(id: "demo-api-1")))
        #expect(lifecycleRequests.contains(.wait(id: "demo-worker-1")))
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil)))
        #expect(!lifecycleRequests.contains(.delete(id: "demo-api-1", force: false)))
        #expect(!lifecycleRequests.contains(.delete(id: "demo-worker-1", force: false)))
    }

    @Test("up abort-on-container-exit returns status and retains stopped containers")
    func upAbortOnContainerExitReturnsStatusAndRetainsStoppedContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let lifecycleManager = RecordingContainerLifecycleManager(
            waitExitCodes: [
                "demo-api-1": 3,
                "demo-worker-1": 0,
            ],
            waitDelaysByID: [
                "demo-worker-1": .milliseconds(20),
            ]
        )
        let discoveryManager = RecordingContainerDiscoveryManager(
            containers: [
                ComposeContainerSummary(
                    id: "demo-api-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "api",
                        composeOneOffLabel: "false",
                    ]
                ),
                ComposeContainerSummary(
                    id: "demo-worker-1",
                    status: "running",
                    labels: [
                        composeProjectLabel: "demo",
                        composeServiceLabel: "worker",
                        composeOneOffLabel: "false",
                    ]
                ),
            ],
            getResponses: [
                "demo-api-1": [nil],
                "demo-worker-1": [nil],
            ]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
            }
        )
        .up(project: project, options: ComposeUpOptions {
            $0.abortOnContainerExit = true
        })
        let lifecycleRequests = await lifecycleManager.requests

        #expect(exitCode == 3)
        #expect(lifecycleRequests.contains(.wait(id: "demo-api-1")))
        #expect(lifecycleRequests.contains(.wait(id: "demo-worker-1")))
        #expect(lifecycleRequests.contains(.stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil)))
        #expect(lifecycleRequests.contains(.stop(id: "demo-worker-1", signal: nil, timeoutInSeconds: nil)))
        #expect(!lifecycleRequests.contains(.delete(id: "demo-api-1", force: false)))
        #expect(!lifecycleRequests.contains(.delete(id: "demo-worker-1", force: false)))
    }

    @Test("up exit-control dry run renders wait then stop plan")
    func upExitControlDryRunRendersWaitThenStopPlan() async throws {
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.stopGracePeriodSeconds = 7
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        let exitCode = try await ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        .up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
            $0.exitCodeFrom = "api"
        })

        #expect(exitCode == 0)
        #expect(emitted.messages.contains("+ compose-runtime attach --no-stdin demo-api-1"))
        #expect(emitted.messages.contains("+ compose-runtime attach --no-stdin demo-db-1"))
        #expect(emitted.messages.contains("+ compose-runtime wait demo-api-1"))
        #expect(emitted.messages.contains("+ container stop --time 7 demo-api-1"))
        #expect(emitted.messages.contains("+ container stop demo-db-1"))
        #expect(!emitted.messages.contains("+ container delete demo-api-1"))
        #expect(!emitted.messages.contains("+ container delete demo-db-1"))
    }

    @Test("up exit-control rejects detached mode before side effects")
    func upExitControlRejectsDetachedModeBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.detach = true
                    $0.exitCodeFrom = "api"
                }
            )
            Issue.record("Expected detached exit-control validation error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--exit-code-from and --detach are incompatible"))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up no-attach rejects unknown services before side effects")
    func upNoAttachRejectsUnknownServicesBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).up(
                project: project,
                options: ComposeUpOptions {
                    $0.noAttach = ["missing"]
                }
            )
            Issue.record("Expected unknown no-attach service error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unknown service 'missing'"))
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up detaches all services when each service disables attach")
    func upDetachesAllServicesWhenEachServiceDisablesAttach() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.attach = false
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        #expect(runner.commands[0].arguments.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up timestamps formats attached foreground output")
    func upTimestampsFormatsAttachedForegroundOutput() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let emitted = MessageRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(
                stream: .stdout,
                payload: Data("ready\n".utf8),
                timestamp: Date(timeIntervalSince1970: 0),
            ),
        ])
        let logManager = RecordingContainerLogManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.attachManager = attachManager
                $0.logManager = logManager
            }
        ).up(
            project: project,
            options: ComposeUpOptions {
                $0.timestamps = true
                $0.noLogPrefix = true
            }
        )

        #expect(runner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(!runner.commands[0].arguments.contains("--detach"))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
        #expect(await logManager.requests.isEmpty)
        #expect(emitted.messages == ["1970-01-01T00:00:00.000Z ready\n"])
    }

    @Test("up timestamps dry run renders detached run and followed timestamped logs")
    func upTimestampsDryRunRendersDetachedRunAndFollowedTimestampedLogs() async throws {
        let emitted = MessageRecorder()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        ).up(project: project, options: ComposeUpOptions {
            $0.timestamps = true
        })

        #expect(emitted.messages.contains { $0.contains("+ container create --name demo-api-1") })
        #expect(emitted.messages.contains("+ container start demo-api-1"))
        #expect(emitted.messages.contains("+ compose-runtime attach --no-stdin demo-api-1"))
    }

    @Test("up build does not rebuild build-only services")
    func upBuildDoesNotRebuildBuildOnlyServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.build = true
        })

        let buildCommands = runner.commands.map(\.arguments).filter { $0.starts(with: ["container", "build"]) }
        #expect(buildCommands.count == 2)
        let apiCommand = try #require(buildCommands.first { $0.containsSequence(["--tag", "example/api"]) })
        let workerCommand = try #require(buildCommands.first { $0.containsSequence(["--tag", "demo_worker:latest"]) })
        #expect(apiCommand.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
        #expect(workerCommand.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("worker").standardizedFileURL.path)
        #expect(await discoveryManager.getRequests.sorted() == ["demo-api-1", "demo-worker-1"])
    }

    @Test("up quiet-build suppresses explicit build output")
    func upQuietBuildSuppressesExplicitBuildOutput() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.build = true
                $0.quietBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "build"]))
        #expect(commands[0].contains("--quiet"))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up applies service build pull policy before starting containers")
    func upAppliesServiceBuildPullPolicyBeforeStartingContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                    $0.pullPolicy = "build"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions()
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/api"]))
        #expect(commands[0].last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-build skips service build pull policy")
    func upNoBuildSkipsServiceBuildPullPolicy() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                    $0.pullPolicy = "build"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.noBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(!commands.contains { $0.containsSequence(["container", "build"]) })
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up no-build skips auto build for build-only service")
    func upNoBuildSkipsAutoBuildForBuildOnlyService() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.noBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(!commands.contains { $0.containsSequence(["container", "build"]) })
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(commands[0].last == "demo_worker:latest")
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("up quiet-build suppresses auto build-only output")
    func upQuietBuildSuppressesAutoBuildOnlyOutput() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.quietBuild = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "build"]))
        #expect(commands[0].contains("--quiet"))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-worker-1"]))
        #expect(await discoveryManager.getRequests == ["demo-worker-1"])
    }

    @Test("up pull missing pulls only absent images")
    func upPullMissingPullsOnlyAbsentImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.pullPolicy = "missing"
        })

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-api-1"]) })
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-db-1"]) })
        let imageRequests = await imageManager.requests
        #expect(imageRequests.count == 4)
        #expect(imageRequests.contains(.pullMissing("example/api")))
        #expect(imageRequests.contains(.pullMissing("postgres")))
        #expect(imageRequests.contains(.healthCheck(reference: "example/api", platform: nil)))
        #expect(imageRequests.contains(.healthCheck(reference: "postgres", platform: nil)))
        #expect(await discoveryManager.getRequests.sorted() == ["demo-api-1", "demo-db-1"])
    }

    @Test("up build with missing pull builds buildable images and pulls only runtime images")
    func upBuildWithMissingPullBuildsBuildableImagesAndPullsOnlyRuntimeImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let orchestrator = ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api")
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.build = true
            $0.pullPolicy = "missing"
        })

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "build", "--tag", "example/api"]))
        #expect(commands[0].last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-api-1"]) })
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-db-1"]) })
        let imageRequests = await imageManager.requests
        #expect(imageRequests.count == 3)
        #expect(imageRequests.contains(.pullMissing("postgres")))
        #expect(imageRequests.contains(.healthCheck(reference: "example/api", platform: nil)))
        #expect(imageRequests.contains(.healthCheck(reference: "postgres", platform: nil)))
        #expect(await discoveryManager.getRequests.sorted() == ["demo-api-1", "demo-db-1"])
    }

    @Test("up pull if not present uses the missing-image flow")
    func upPullIfNotPresentUsesMissingImageFlow() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.pullPolicy = "if_not_present"
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await imageManager.requests == [
            .pullMissing("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up quiet-pull uses direct image pull before run")
    func upQuietPullUsesDirectImagePullBeforeRun() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).up(
            project: project,
            options: ComposeUpOptions {
                $0.pullPolicy = "always"
                $0.quietPull = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(await imageManager.requests == [
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up direct image pull emits progress before run")
    func upDirectImagePullEmitsProgressBeforeRun() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let progress = LockedStringRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.pullPolicy = "always"
        })

        #expect(progress.snapshot.joined() == """
        ⠓ Pulling image example/api
        ✓ Pulling image example/api
        ⠓ Creating api
        ✓ Creating api

        """)
        #expect(await imageManager.requests == [
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(runner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
    }

    @Test("TTY up progress clears the pending row before attached output")
    func ttyUpProgressClearsPendingRowBeforeAttachedOutput() async throws {
        let progress = LockedStringRecorder()
        let runner = RecordingRunner(responses: [.success])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("ready\n".utf8)),
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager(existingReferences: ["example/api"])
        let reporter = ComposeProgressReporter(
            style: .tty,
            emitData: { progress.append(String(decoding: $0, as: UTF8.self)) }
        )
        var executionOptions = ComposeExecutionOptions(runtimeHooks: .init {
            $0.emitAttachedData = { progress.append(String(decoding: $0, as: UTF8.self)) }
        })
        executionOptions.progress = reporter
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: executionOptions,
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(progress.snapshot == [
            "\r⠓ Creating api",
            "\r\u{001B}[K",
            "✓ Creating api\n",
            "api-1 | ready\n",
        ])
    }

    @Test("up direct image pull emits first progress row before pull starts")
    func upDirectImagePullEmitsFirstProgressRowBeforePullStarts() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let progress = LockedStringRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager(onPullImage: { reference in
            #expect(reference == "example/api")
            #expect(progress.snapshot == ["⠓ Pulling image example/api\n"])
        })
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.pullPolicy = "always"
        })

        #expect(progress.snapshot.joined().hasPrefix("⠓ Pulling image example/api\n"))
        #expect(await imageManager.requests == [
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(runner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
    }

    @Test("up quiet-pull suppresses direct image pull progress")
    func upQuietPullSuppressesDirectImagePullProgress() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let progress = LockedStringRecorder()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api")]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: progressReportingOptions(recordingTo: progress),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions {
            $0.pullPolicy = "always"
            $0.quietPull = true
        })

        #expect(progress.snapshot.joined() == "⠓ Creating api\n✓ Creating api\n")
        #expect(await imageManager.requests == [
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(runner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
    }

    @Test("up applies service pull policies when no global pull policy is set")
    func upAppliesServicePullPoliciesWhenNoGlobalPullPolicyIsSet() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "always"
                },
                "db": composeService(name: "db", image: "postgres") {
                    $0.pullPolicy = "never"
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.pullPolicy = "missing"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager, imageManager: imageManager).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 3)
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-api-1"]) })
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-db-1"]) })
        #expect(commands.contains { $0.starts(with: ["container", "create", "--name", "demo-worker-1"]) })
        let imageRequests = await imageManager.requests
        #expect(imageRequests.count == 5)
        #expect(imageRequests.contains(.pull("example/api")))
        #expect(imageRequests.contains(.pullMissing("example/worker")))
        #expect(imageRequests.contains(.healthCheck(reference: "example/api", platform: nil)))
        #expect(imageRequests.contains(.healthCheck(reference: "postgres", platform: nil)))
        #expect(imageRequests.contains(.healthCheck(reference: "example/worker", platform: nil)))
        #expect(
            await discoveryManager.getRequests.sorted()
                == ["demo-api-1", "demo-db-1", "demo-worker-1"])
    }

    @Test("up pulls service image when daily policy has no metadata")
    func upPullsServiceImageWhenDailyPolicyHasNoMetadata() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let imageManager = RecordingContainerImageManager(existingReferences: ["example/api"])
        let metadataStore = RecordingPullMetadataStore()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "daily"
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(currentDate: { now }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.imageManager = imageManager
                $0.pullMetadataStore = metadataStore
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(await imageManager.requests == [
            .exists("example/api"),
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(await metadataStore.recordedDate(for: "example/api") == now)
        #expect(runner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
    }

    @Test("up skips service image pull when weekly policy is fresh")
    func upSkipsServiceImagePullWhenWeeklyPolicyIsFresh() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let imageManager = RecordingContainerImageManager(existingReferences: ["example/api"])
        let metadataStore = RecordingPullMetadataStore(dates: [
            "example/api": now.addingTimeInterval(-60 * 60),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "weekly"
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(currentDate: { now }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.pullMetadataStore = metadataStore
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(await imageManager.requests == [
            .exists("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(runner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
    }

    @Test("up pulls service image when every duration policy is stale")
    func upPullsServiceImageWhenEveryDurationPolicyIsStale() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let imageManager = RecordingContainerImageManager(existingReferences: ["example/api"])
        let metadataStore = RecordingPullMetadataStore(dates: [
            "example/api": now.addingTimeInterval(-91 * 60),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "every_1h30m"
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(currentDate: { now }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.pullMetadataStore = metadataStore
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(await imageManager.requests == [
            .exists("example/api"),
            .pull("example/api"),
            .healthCheck(reference: "example/api", platform: nil),
        ])
        #expect(await metadataStore.recordedDate(for: "example/api") == now)
        #expect(runner.commands[0].arguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
    }

    @Test("up quiet-pull dry run disables service pull policy progress")
    func upQuietPullDryRunDisablesServicePullPolicyProgress() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.pullPolicy = "always"
                },
            ]
        )

        try await orchestrator.up(
            project: project,
            options: ComposeUpOptions {
                $0.quietPull = true
            }
        )

        let messages = emitted.messages
        #expect(messages.contains("+ container image pull --progress none alpine"))
        #expect(messages.contains { $0.hasPrefix("+ container create ") })
    }

    @Test("up rejects unsupported service pull policies before creating resources")
    func upRejectsUnsupportedServicePullPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "sometimes"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported service pull policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses pull_policy 'sometimes'; supported values are always, missing, if_not_present, never, build, daily, weekly, and every_<duration>"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("rejects dependency conditions with runtime gap reasons")
    func rejectsUnsupportedDependencyConditions() async throws {
        let cases = [
            (
                condition: "custom_condition",
                reason: "dependency condition support needs an apple/container runtime gap PR"
            ),
        ]

        for testCase in cases {
            let runner = RecordingRunner()
            let project = ComposeProject(
                name: "demo",
                services: [
                    "job": ComposeService(name: "job", image: "example/job:latest"),
                    "api": composeService(name: "api", image: "example/api:latest") {
                        $0.dependsOn = ["job": ComposeDependency(condition: testCase.condition)]
                    },
                ]
            )

            do {
                try await ComposeOrchestrator(runner: runner)
                    .up(project: project, options: ComposeUpOptions {
                        $0.services = ["api"]
                    })
                Issue.record("Expected unsupported dependency condition")
            } catch let error as ComposeError {
                #expect(error == .unsupported("service 'api' depends on 'job' with condition '\(testCase.condition)'; \(testCase.reason)"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up restarts reused dependents when restart dependencies change")
    func upRestartsReusedDependentsWhenRestartDependenciesChange() async throws {
        let baselineProject = ComposeProject(
            name: "demo",
            services: [
                "db": ComposeService(name: "db", image: "postgres:16"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started", restart: true)]
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )
        let baselineRunner = RecordingRunner()
        try await ComposeOrchestrator(runner: baselineRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: baselineProject, options: ComposeUpOptions())

        let dbRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        let oldDBHash = try #require(composeConfigHash(in: dbRun))
        let apiHash = try #require(composeConfigHash(in: apiRun))

        let changedProject = ComposeProject(
            name: "demo",
            services: [
                "db": composeService(name: "db", image: "postgres:16") {
                    $0.labels = ["com.example.version": "two"]
                },
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started", restart: true)]
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-db-1", status: "running", labels: [composeConfigHashLabel: oldDBHash]),
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: apiHash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let attachManager = RecordingContainerAttachManager()

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.lifecycleManager = lifecycleManager
                $0.attachManager = attachManager
            }
        )
        .up(project: changedProject, options: ComposeUpOptions {
            $0.services = ["api"]
        })

        #expect(runner.commands.map(\.arguments).count == 1)
        #expect(runner.commands[0].arguments.containsSequence(["--name", "demo-db-1"]))
        #expect(await discoveryManager.getRequests == ["demo-db-1", "demo-api-1"])
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-db-1", force: false),
            .stop(id: "demo-api-1", signal: "SIGUSR1", timeoutInSeconds: 9),
        ])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-db-1", stdout: true, stderr: true, mode: .beforeStart),
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .beforeStart),
        ])
    }

    @Test("up does not dependency restart services already recreated")
    func upDoesNotDependencyRestartServicesAlreadyRecreated() async throws {
        let baselineProject = ComposeProject(
            name: "demo",
            services: [
                "db": ComposeService(name: "db", image: "postgres:16"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started", restart: true)]
                },
            ]
        )
        let baselineRunner = RecordingRunner()
        try await ComposeOrchestrator(runner: baselineRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: baselineProject, options: ComposeUpOptions())

        let dbRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-db-1"]) }?.arguments)
        let apiRun = try #require(baselineRunner.commands.first { $0.arguments.containsSequence(["--name", "demo-api-1"]) }?.arguments)
        let oldDBHash = try #require(composeConfigHash(in: dbRun))
        let oldAPIHash = try #require(composeConfigHash(in: apiRun))

        let changedProject = ComposeProject(
            name: "demo",
            services: [
                "db": composeService(name: "db", image: "postgres:16") {
                    $0.labels = ["com.example.version": "two"]
                },
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started", restart: true)]
                    $0.labels = ["com.example.version": "two"]
                },
            ]
        )
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-db-1", status: "running", labels: [composeConfigHashLabel: oldDBHash]),
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: oldAPIHash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        )
        .up(project: changedProject, options: ComposeUpOptions {
            $0.services = ["api"]
        })

        #expect(runner.commands.map(\.arguments).count == 2)
        #expect(runner.commands[0].arguments.containsSequence(["--name", "demo-db-1"]))
        #expect(runner.commands[1].arguments.containsSequence(["--name", "demo-api-1"]))
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-db-1", force: false),
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("rejects missing health status on present optional dependencies")
    func rejectsMissingHealthStatusOnPresentOptionalDependencies() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(getResponses: [
            "demo-job-1": [
                nil,
                ComposeContainerSummary(id: "demo-job-1", status: "running"),
            ],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": ComposeService(name: "job", image: "example/job:latest"),
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["job": ComposeDependency(condition: "service_healthy", required: false)]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
                .up(project: project, options: ComposeUpOptions {
                    $0.services = ["api"]
                })
            Issue.record("Expected missing health status")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' dependency 'job' container 'demo-job-1' has no health status"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 1)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-job-1"]))
    }

    @Test("up maps explicit legacy links to source-scoped DNS aliases")
    func upMapsExplicitLegacyLinksToSourceScopedDNSAliases() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache", "redis:cache"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
        })

        let redisCommand = try #require(runner.commands.first?.arguments)
        let apiCommand = try #require(runner.commands.last?.arguments)
        #expect(redisCommand.containsSequence(["--network", "demo_backend"]))
        #expect(!redisCommand.contains(where: { $0.contains("dns-alias=cache:demo-redis-1") }))
        #expect(apiCommand.containsSequence(["--network", "demo_backend,dns-alias=cache:demo-redis-1"]))
        #expect(apiCommand.filter { $0.contains("dns-alias=cache:demo-redis-1") }.count == 1)
        #expect(!apiCommand.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(await discoveryManager.getRequests == ["demo-redis-1", "demo-api-1"])
    }

    @Test("up maps implicit legacy links to source-scoped DNS aliases")
    func upMapsImplicitLegacyLinksToSourceScopedDNSAliases() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
        })

        let apiCommand = try #require(runner.commands.last?.arguments)
        #expect(apiCommand.containsSequence(["--network", "demo_backend,dns-alias=redis:demo-redis-1"]))
        #expect(!apiCommand.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
    }

    @Test("up resolves legacy links through the normalized default network")
    func upResolvesLegacyLinksThroughNormalizedDefaultNetwork() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["default"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache"]
                    $0.networks = ["default"]
                },
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "demo_default")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions {
            $0.services = ["api"]
        })

        let apiCommand = try #require(runner.commands.last?.arguments)
        #expect(apiCommand.containsSequence(["--network", "demo_default,dns-alias=cache:demo-redis-1"]))
        #expect(!apiCommand.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_default"])
    }

    @Test("up maps a scaled link target once through its single shared network")
    func upMapsScaledLinkTargetOnceThroughItsSingleSharedNetwork() async throws {
        let runner = RecordingRunner(responses: [.success, .success, .success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "db": composeService(name: "db", image: "postgres:18") {
                    $0.networks = ["backend", "storage"]
                    $0.scale = 2
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["db:database"]
                    $0.networks = ["frontend", "backend"]
                },
            ]
        ) {
            $0.networks = [
                "frontend": ComposeNetwork(name: "frontend"),
                "backend": ComposeNetwork(name: "backend"),
                "storage": ComposeNetwork(name: "storage"),
            ]
        }

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
            })

        let apiCommand = try #require(runner.commands.last?.arguments)
        #expect(apiCommand.containsSequence(["--network", "demo_frontend"]))
        #expect(apiCommand.containsSequence(["--network", "demo_backend,dns-alias=database:demo-db-1"]))
        #expect(apiCommand.filter { $0.contains("dns-alias=database:demo-db-1") }.count == 1)
        #expect(!apiCommand.contains("--add-host"))
    }

    @Test("up maps external links to source-scoped DNS aliases")
    func upMapsExternalLinksToSourceScopedDNSAliases() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy_db",
                status: "running",
                networks: [
                    ComposeContainerNetworkAttachment(network: "demo_backend", ipv4Address: "192.168.64.20"),
                ]
            ),
            ComposeContainerSummary(
                id: "legacy_cache",
                status: "running",
                networks: [
                    ComposeContainerNetworkAttachment(network: "demo_backend", ipv4Address: "192.168.64.21"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.externalLinks = ["legacy_db:db", "legacy_db:db", "legacy_cache"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(command.containsSequence(["--network", "demo_backend,dns-alias=db:legacy_db,dns-alias=legacy_cache:legacy_cache"]))
        #expect(command.filter { $0.contains("dns-alias=db:legacy_db") }.count == 1)
        #expect(!command.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(!(await discoveryManager.getRequests).contains("legacy_db"))
        #expect(!(await discoveryManager.getRequests).contains("legacy_cache"))
    }

    @Test("up maps external links through every source network")
    func upMapsExternalLinksThroughEverySourceNetwork() async throws {
        let runner = RecordingRunner(responses: [.success])
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy_db",
                status: "running",
                networks: [
                    ComposeContainerNetworkAttachment(network: "demo_backend", ipv4Address: "192.168.64.20"),
                    ComposeContainerNetworkAttachment(network: "legacy_observability", ipv4Address: "192.168.65.20"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.externalLinks = ["legacy_db:db"]
                    $0.networks = ["backend", "observability"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(name: "backend"),
                "observability": ComposeNetwork(name: "observability"),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "demo_backend,dns-alias=db:legacy_db"]))
        #expect(command.containsSequence(["--network", "demo_observability,dns-alias=db:legacy_db"]))
        #expect(!command.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_observability"])
        #expect(!(await discoveryManager.getRequests).contains("legacy_db"))
    }

    @Test("up allows external links without a shared runtime network")
    func upAllowsExternalLinksWithoutSharedRuntimeNetwork() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy_db",
                status: "running",
                networks: [
                    ComposeContainerNetworkAttachment(network: "other", ipv4Address: "192.168.64.20"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.externalLinks = ["legacy_db:db"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "demo_backend,dns-alias=db:legacy_db"]))
        #expect(!command.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(!(await discoveryManager.getRequests).contains("legacy_db"))
    }

    @Test("up maps external links with multiple shared runtime networks")
    func upMapsExternalLinksWithMultipleSharedRuntimeNetworks() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy_db",
                status: "running",
                networks: [
                    ComposeContainerNetworkAttachment(network: "demo_backend", ipv4Address: "192.168.64.20"),
                    ComposeContainerNetworkAttachment(network: "demo_observability", ipv4Address: "192.168.65.20"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.externalLinks = ["legacy_db:db"]
                    $0.networks = ["backend", "observability"]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(name: "backend"),
                "observability": ComposeNetwork(name: "observability"),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "demo_backend,dns-alias=db:legacy_db"]))
        #expect(command.containsSequence(["--network", "demo_observability,dns-alias=db:legacy_db"]))
        #expect(!command.contains("--add-host"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_observability"])
        #expect(!(await discoveryManager.getRequests).contains("legacy_db"))
    }

    @Test("up rejects invalid link aliases before creating resources")
    func upRejectsInvalidLinkAliasesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:bad_alias"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid link alias error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' link alias 'bad_alias' is not a valid RFC1123 hostname"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects legacy link aliases that conflict with extra hosts before creating resources")
    func upRejectsLegacyLinkAliasesThatConflictWithExtraHostsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache"]
                    $0.extraHosts = ["Cache=192.168.64.99"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions {
                    $0.services = ["api"]
                })
            Issue.record("Expected conflicting host entry error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' links to 'redis' with alias 'cache', but extra_hosts already defines that hostname; generated link aliases cannot override host entries"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects legacy link aliases that resolve multiple services before creating resources")
    func upRejectsLegacyLinkAliasesThatResolveMultipleServicesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["backend"]
                },
                "cache": composeService(name: "cache", image: "memcached:1.6") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:database", "cache:database"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions {
                    $0.services = ["api"]
                })
            Issue.record("Expected conflicting link alias error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' maps both links to 'redis' and links to 'cache' to alias 'database'; each generated alias must reference exactly one target"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects generated aliases shared by links and external links before creating resources")
    func upRejectsGeneratedAliasesSharedByLinksAndExternalLinksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["backend"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:database"]
                    $0.externalLinks = ["legacy_db:database"]
                    $0.networks = ["backend"]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions {
                    $0.services = ["api"]
                })
            Issue.record("Expected conflicting static host alias error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' maps both links to 'redis' and external_links to 'legacy_db' to alias 'database'; each generated alias must reference exactly one target"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects links without a shared network")
    func upRejectsLinksWithoutSharedNetwork() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": ComposeService(name: "redis", image: "redis:7"),
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
            })
            Issue.record("Expected unsupported links error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' links to 'redis'; links require both services to share a Compose network"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps links through the first normalised shared network")
    func upMapsLinksThroughFirstNormalisedSharedNetwork() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.networks = ["second", "first"]
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache"]
                    $0.networks = ["second", "first"]
                },
            ]
        ) {
            $0.networks = [
                "first": ComposeNetwork(name: "first"),
                "second": ComposeNetwork(name: "second"),
            ]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["api"]
            })

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--network", "demo_first,dns-alias=cache:demo-redis-1"]))
        #expect(command.containsSequence(["--network", "demo_second"]))
        #expect(!command.contains(where: { $0 == "demo_second,dns-alias=cache:demo-redis-1" }))
    }

    @Test("link target runtime inputs affect the source config hash")
    func linkTargetRuntimeInputsAffectSourceConfigHash() throws {
        let source = composeService(name: "api", image: "example/api") {
            $0.links = ["redis:cache"]
            $0.networks = ["first", "second"]
        }
        let original = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.containerName = "custom-redis"
                    $0.networks = ["first", "second"]
                },
                "api": source,
            ]
        )
        let renamedTarget = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.containerName = "replacement-redis"
                    $0.networks = ["first", "second"]
                },
                "api": source,
            ]
        )
        let movedTarget = composeProject(
            name: "demo",
            services: [
                "redis": composeService(name: "redis", image: "redis:7") {
                    $0.containerName = "custom-redis"
                    $0.networks = ["second"]
                },
                "api": source,
            ]
        )

        let originalHash = try configHash(project: original, service: source)
        #expect(try configHash(project: renamedTarget, service: source) != originalHash)
        #expect(try configHash(project: movedTarget, service: source) != originalHash)
    }

    @Test("up maps hostnames to runtime arguments")
    func upMapsHostnamesToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.hostname = "custom-api"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--hostname", "custom-api"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up rejects invalid hostnames before creating resources")
    func upRejectsInvalidHostnamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.hostname = "bad_name"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid hostname error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' hostname 'bad_name' is not a valid RFC1123 hostname"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps domain names to runtime arguments")
    func upMapsDomainNamesToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.domainName = "example.test."
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--domainname", "example.test"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up rejects invalid domain names before creating resources")
    func upRejectsInvalidDomainNamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.domainName = "bad_name"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid domain name error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' domainname 'bad_name' is not a valid RFC1123 hostname"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps DNS options to runtime arguments")
    func upMapsDNSOptionsToRuntimeArguments() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dnsOptions = ["use-vc"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--dns-option", "use-vc"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up maps extra hosts to runtime host entries")
    func upMapsExtraHostsToRuntimeHostEntries() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.extraHosts = ["db=10.0.0.5", "myhostv6=[::1]"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--add-host", "db:10.0.0.5"]))
        #expect(command.containsSequence(["--add-host", "myhostv6:::1"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up maps host-gateway extra hosts to runtime host entries")
    func upMapsHostGatewayExtraHostsToRuntimeHostEntries() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.extraHosts = ["host.docker.internal=host-gateway"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--add-host", "host.docker.internal:host-gateway"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
    }

    @Test("up maps sysctls to runtime arguments")
    func upMapsSysctlsToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.sysctls = [
                        "net.core.somaxconn": "1024",
                        "net.ipv4.ip_forward": "1",
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--sysctl", "net.core.somaxconn=1024"]))
        #expect(command.containsSequence(["--sysctl", "net.ipv4.ip_forward=1"]))
    }

    @Test("up maps no-new-privileges security_opt to runtime arguments")
    func upMapsNoNewPrivilegesSecurityOptionToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.securityOpt = ["no-new-privileges:true"]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--security-opt", "no-new-privileges:true"]))
    }

    @Test("up maps unconfined systempaths security_opt to the generic runtime argument")
    func upMapsUnconfinedSystemPathsSecurityOptionToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.securityOpt = ["systempaths:unconfined"]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--security-opt", "systempaths=unconfined"]))
    }

    @Test("up maps standard security_opt spellings at the Compose boundary")
    func upMapsStandardSecurityOptionSpellings() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.securityOpt = [
                        "no-new-privileges",
                        "seccomp:unconfined",
                        "apparmor=unconfined",
                        "label:disable",
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--security-opt", "no-new-privileges:true"]))
        #expect(!command.contains("seccomp:unconfined"))
        #expect(!command.contains("apparmor=unconfined"))
        #expect(!command.contains("label:disable"))
    }

    @Test("up accepts host user namespace as the sandbox guest default")
    func upAcceptsHostUserNamespaceAsSandboxGuestDefault() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.usernsMode = "host"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--userns"))
    }

    @Test("up maps private user namespace mode to the guest runtime")
    func upMapsPrivateUserNamespaceModeToGuestRuntime() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.usernsMode = "private"
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--userns", "private"]))
    }

    @Test("up rejects unsupported user namespace modes before creating resources")
    func upRejectsUnsupportedUserNamespaceModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.usernsMode = "container:db"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported user namespace mode error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses userns_mode 'container:db'; only host and private are supported by the local runtime"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps shared service and explicit aliases for every replica")
    func upMapsSharedServiceAndExplicitAliasesForEveryReplica() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["api", "api.internal"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions {
                $0.scales = ["api=2"]
            })

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands.allSatisfy {
            $0.containsSequence(["--network", "demo_backend,alias=api,alias=api.internal"])
        })
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("up rejects invalid network aliases before creating resources")
    func upRejectsInvalidNetworkAliasesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["bad_alias"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid network alias error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' network alias 'bad_alias' is not a valid RFC1123 hostname"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects aliases on unattached networks before creating resources")
    func upRejectsAliasesOnUnattachedNetworksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["frontend": ["api"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(name: "backend"),
                "frontend": ComposeNetwork(name: "frontend"),
            ]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unattached network alias error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' sets network aliases on unattached network 'frontend'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up maps multiple network attachments at create time")
    func upMapsMultipleNetworksAtCreateTime() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["frontend", "backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = [
                "frontend": ComposeNetwork(name: "frontend"),
                "backend": ComposeNetwork(name: "backend"),
            ]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        let resourceNames = await resourceManager.requests.map(\.name)
        #expect(runner.commands.count == 1)
        #expect(command.containsSequence(["--network", "demo_frontend", "--network", "demo_backend"]))
        #expect(Set(resourceNames) == ["demo_frontend", "demo_backend", "demo_cache"])
    }

    @Test("up maps link-local IPs to runtime network attachments")
    func upMapsLinkLocalIPsToRuntimeNetworkAttachments() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            addressing: .init(linkLocalIPs: ["169.254.1.5", "fe80::5"])
                        ),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence([
            "--network", "demo_backend,address=169.254.1.5,address=fe80::5",
        ]))
    }

    @Test("up maps static IPv4 and IPv6 addresses to runtime network attachments")
    func upMapsStaticNetworkAddressesToRuntimeNetworkAttachments() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            addressing: .init(
                                ipv4Address: "172.28.0.10",
                                ipv6Address: "2001:db8:7::10"
                            )
                        ),
                    ]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(
                        subnets: .init(
                            ipv4Subnet: "172.28.0.0/16",
                            ipv6Subnet: "2001:db8:7::/64"
                        )
                    )
                ),
            ]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence([
            "--network", "demo_backend,ip=172.28.0.10,ip6=2001:db8:7::10",
        ]))
    }

    @Test("up maps static addresses on external networks without local IPAM")
    func upMapsStaticAddressesOnExternalNetworks() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["shared"]
                    $0.networkOptions = [
                        "shared": ComposeNetworkOptions(addressing: .init(ipv4Address: "192.0.2.10")),
                    ]
                },
            ]
        ) {
            $0.networks = [
                "shared": ComposeNetwork(name: "shared", options: .init(external: true)),
            ]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--network", "shared,ip=192.0.2.10"]))
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up selects default route and service MAC networks by their independent priorities")
    func upMapsNetworkGatewayAndConnectionPriorities() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.macAddress = "02:42:ac:11:00:03"
                    $0.networks = ["frontend", "backend"]
                    $0.networkOptions = [
                        "frontend": ComposeNetworkOptions(gatewayPriority: 10, priority: 100),
                        "backend": ComposeNetworkOptions(gatewayPriority: 100, priority: 10),
                    ]
                },
            ]
        ) {
            $0.networks = [
                "frontend": ComposeNetwork(name: "frontend"),
                "backend": ComposeNetwork(name: "backend"),
            ]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence([
            "--network", "demo_backend",
            "--network", "demo_frontend,mac=02:42:ac:11:00:03",
        ]))
    }

    @Test("up maps distinct per-network MAC addresses across multiple attachments")
    func upMapsPerNetworkMACAddressesAcrossMultipleAttachments() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["frontend", "backend"]
                    $0.networkOptions = [
                        "frontend": ComposeNetworkOptions(addressing: .init(macAddress: "02:42:ac:11:00:03")),
                        "backend": ComposeNetworkOptions(addressing: .init(macAddress: "02:42:ac:11:00:04")),
                    ]
                },
            ]
        ) {
            $0.networks = [
                "frontend": ComposeNetwork(name: "frontend"),
                "backend": ComposeNetwork(name: "backend"),
            ]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence([
            "--network", "demo_frontend,mac=02:42:ac:11:00:03",
            "--network", "demo_backend,mac=02:42:ac:11:00:04",
        ]))
    }

    @Test("up rejects unsupported network options before creating resources")
    func upRejectsUnsupportedNetworkOptionsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            driverOpts: ["com.example.unsupported": "true"],
                            addressing: .init(ipv4Address: "10.10.0.5"),
                            priority: 42
                        ),
                    ]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported network option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses network attachment options driver_opts on network 'backend'; network attachment options need an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("network option addressing maps to normalized fields")
    func networkOptionAddressingMapsToNormalizedFields() {
        let options = ComposeNetworkOptions(
            addressing: .init(
                ipv4Address: "10.10.0.5",
                ipv6Address: "fd00::5",
                linkLocalIPs: ["169.254.1.5"],
                macAddress: "02:42:ac:11:00:05"
            ),
            priority: 42
        )

        #expect(options.ipv4Address == "10.10.0.5")
        #expect(options.ipv6Address == "fd00::5")
        #expect(options.linkLocalIPs == ["169.254.1.5"])
        #expect(options.macAddress == "02:42:ac:11:00:05")
        #expect(options.priority == 42)
    }

    @Test("up rejects unsupported network mode before creating resources")
    func upRejectsUnsupportedNetworkModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networkMode = "service:redis"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported network mode error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses network_mode 'service:redis'; network mode support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported isolation before creating resources")
    func upRejectsUnsupportedIsolationBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.isolation = "process"
                },
            ]
        )

        await #expect(throws: ComposeError.unsupported(
            "service 'api' uses isolation 'process'; supported values are default, dedicated-vm, and shared-vm"
        )) {
            try await ComposeOrchestrator(runner: runner)
                .up(project: project, options: ComposeUpOptions())
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported pid mode before creating resources")
    func upRejectsUnsupportedPIDModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pid = "service:db"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported PID mode error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses pid 'service:db'; supported values are host and private"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported CPU resource fields before creating resources")
    func upRejectsUnsupportedCPUResourceFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedCPUResourceFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects invalid cpu_shares before creating resources")
    func upRejectsInvalidCPUSharesBeforeCreatingResources() async throws {
        for cpuShares in [1, -1] {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        $0.cpuShares = cpuShares
                    },
                ]
            )

            await #expect(throws: ComposeError.invalidProject(
                "service 'api' uses cpu_shares '\(cpuShares)'; cpu_shares must be 0 or at least 2"
            )) {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            }
            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects invalid memory reservations before creating resources")
    func upRejectsInvalidMemoryReservationsBeforeCreatingResources() async throws {
        let cases: [(reservation: String, memoryLimit: String?, expectedMessage: String)] = [
            ("-1", nil, "service 'api' uses invalid mem_reservation '-1'; expected a non-negative byte value"),
            ("536870912", "536870912", "service 'api' uses mem_reservation '536870912'; mem_reservation must be lower than mem_limit '536870912'"),
        ]

        for testCase in cases {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        $0.memReservation = testCase.reservation
                        $0.memLimit = testCase.memoryLimit
                    },
                ]
            )

            await #expect(throws: ComposeError.invalidProject(testCase.expectedMessage)) {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            }
            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects invalid memory swap limits before creating resources")
    func upRejectsInvalidMemorySwapLimitsBeforeCreatingResources() async throws {
        let cases: [(swapLimit: String, memoryLimit: String?, expectedMessage: String)] = [
            ("-1", nil, "service 'api' uses memswap_limit; memswap_limit requires a positive mem_limit"),
            ("268435456", "536870912", "service 'api' uses memswap_limit '268435456'; memswap_limit must be at least mem_limit '536870912'"),
            ("-2", "536870912", "service 'api' uses invalid memswap_limit '-2'; expected -1, 0, or a positive byte value"),
        ]

        for testCase in cases {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        $0.memSwapLimit = testCase.swapLimit
                        $0.memLimit = testCase.memoryLimit
                    },
                ]
            )

            await #expect(throws: ComposeError.invalidProject(testCase.expectedMessage)) {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            }
            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported memory and process resource fields before creating resources")
    func upRejectsUnsupportedMemoryAndProcessResourceFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedMemoryAndProcessResourceFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up maps block IO config to runtime arguments")
    func upMapsBlockIOConfigToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.blkioConfig = ComposeBlkioConfig(
                        weight: 300,
                        weightDevice: [ComposeBlkioWeightDevice(path: "8:0", weight: 700)],
                        deviceReadBps: [ComposeBlkioThrottleDevice(path: "8:0", rate: "1048576")]
                    )
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--blkio", "weight=300"]))
        #expect(command.containsSequence(["--blkio", "device=8:0,weight=700"]))
        #expect(command.containsSequence(["--blkio", "device=8:0,read-bps=1048576"]))
    }

    @Test("up maps pids_limit to runtime arguments")
    func upMapsPidsLimitToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pidsLimit = 128
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--pids-limit", "128"]))
    }

    @Test("up maps cpu_shares to runtime arguments")
    func upMapsCPUSharesToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cpuShares = 512
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--cpu-shares", "512"]))
    }

    @Test("up maps cgroup_parent to runtime arguments")
    func upMapsCgroupParentToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cgroupParent = "workloads/build"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--cgroup-parent", "workloads/build"]))
    }

    @Test("up maps mem_reservation to runtime arguments")
    func upMapsMemoryReservationToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.memReservation = "268435456"
                    $0.memLimit = "536870912"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--memory", "536870912"]))
        #expect(command.containsSequence(["--memory-reservation", "268435456"]))
    }

    @Test("up maps explicit memswap_limit to runtime arguments")
    func upMapsMemorySwapLimitToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.memLimit = "536870912"
                    $0.memSwapLimit = "1073741824"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--memory", "536870912"]))
        #expect(command.containsSequence(["--memory-swap", "1073741824"]))
    }

    @Test("up maps Docker default memory swap limit")
    func upMapsDefaultMemorySwapLimitToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.memLimit = "536870912"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--memory-swap", "1073741824"]))
    }

    @Test("up omits default cpu_shares from runtime arguments")
    func upOmitsDefaultCPUSharesFromRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.cpuShares = 0
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--cpu-shares"))
    }

    @Test("up omits zero mem_reservation from runtime arguments")
    func upOmitsZeroMemoryReservationFromRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.memReservation = "0"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--memory-reservation"))
    }

    @Test("up omits unlimited pids_limit from runtime arguments")
    func upOmitsUnlimitedPidsLimitFromRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pidsLimit = -1
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(!command.contains("--pids-limit"))
    }

    @Test("up maps device cgroup rules to runtime arguments")
    func upMapsDeviceCgroupRulesToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deviceCgroupRules = [
                        "c 1:3 mr",
                        "a *:* rwm",
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--device-cgroup-rule", "c 1:3 mr"]))
        #expect(command.containsSequence(["--device-cgroup-rule", "a *:* rwm"]))
    }

    @Test("up maps devices to runtime arguments")
    func upMapsDevicesToRuntimeArguments() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.devices = [
                        .object([
                            "source": .string("/dev/null"),
                            "target": .string("/dev/xnull"),
                            "permissions": .string("rw"),
                        ]),
                        .string("/dev/random:/dev/xrandom"),
                        .string("/dev/zero"),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--device", "/dev/null:/dev/xnull:rw"]))
        #expect(command.containsSequence(["--device", "/dev/random:/dev/xrandom"]))
        #expect(command.containsSequence(["--device", "/dev/zero"]))
    }

    @Test("up maps service gpus all to the runtime")
    func upMapsServiceGPUsAllToRuntime() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.gpus = [
                        .object([
                            "count": .number(-1),
                            "capabilities": .array([.string("gpu")]),
                        ]),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--gpus", "all"]))
    }

    @Test("up maps deploy GPU reservations to the runtime")
    func upMapsDeployGPUReservationsToRuntime() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployGPURequests = [
                        .object([
                            "device_ids": .array([.string("0")]),
                            "capabilities": .array([.string("gpu")]),
                        ]),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--gpus", "device=0"]))
    }

    @Test("up rejects unsupported GPU drivers before creating resources")
    func upRejectsUnsupportedGPUDriversBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.gpus = [
                        .object([
                            "driver": .string("nvidia"),
                            "count": .number(1),
                            "capabilities": .array([.string("gpu")]),
                        ]),
                    ]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported GPU driver error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' requests GPU driver 'nvidia'; the Apple backend supports only virtio-gpu"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects non-GPU deploy device reservations before creating resources")
    func upRejectsNonGPUDeployDeviceReservationsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["resources.reservations.devices"]
                    $0.deployGPURequests = [
                        .object([
                            "count": .number(1),
                            "capabilities": .array([.string("tpu")]),
                        ]),
                    ]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported deploy device reservation error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses a non-GPU deploy device reservation; the Apple backend supports only the generic GPU capability"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects invalid devices before creating resources")
    func upRejectsInvalidDevicesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.devices = [.string("dev/null:/dev/xnull")]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid devices error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' has invalid devices; entries must use HOST[:CONTAINER[:PERMISSIONS]] with absolute paths and r/w/m permissions"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects non-string device object fields")
    func upRejectsNonStringDeviceObjectFields() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.devices = [
                        .object([
                            "source": .string("/dev/null"),
                            "target": .number(1),
                        ]),
                    ]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid devices error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' has invalid devices; entries must use HOST[:CONTAINER[:PERMISSIONS]] with absolute paths and r/w/m permissions"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects relative device targets")
    func upRejectsRelativeDeviceTargets() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.devices = [
                        .string("/dev/null:rw"),
                        .object([
                            "source": .string("/dev/zero"),
                            "target": .string("zero"),
                        ]),
                    ]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid devices error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' has invalid devices; entries must use HOST[:CONTAINER[:PERMISSIONS]] with absolute paths and r/w/m permissions"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up treats develop watch metadata as harmless")
    func upTreatsDevelopWatchMetadataAsHarmless() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "src", action: "sync", target: "/app/src"),
                    ])
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.containsSequence(["create", "--name", "demo-api-1"]))
    }

    @Test("up rejects unmapped build fields before creating resources")
    func upRejectsUnmappedBuildFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(
                        context: "api",
                        options: ComposeBuild.Options(unsupportedFields: ["secrets"])
                    )
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported build field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses unsupported build fields secrets; advanced build fields need Docker Compose compatible apple/container build primitives"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported deploy modes as apple/container runtime gaps")
    func upRejectsUnsupportedDeployModesAsAppleContainerRuntimeGaps() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["mode"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported deploy field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.mode; deploy modes outside local replicated/global behavior need apple/container scheduler or job lifecycle primitives"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up treats deploy job mode replicas as ordinary local services")
    func upTreatsDeployJobModeReplicasAsOrdinaryLocalServices() async throws {
        let runner = RecordingRunner(responses: [.success, .success])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: [
            "demo-migrate-1": 0,
            "demo-migrate-2": 0,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "create", "--name", "demo-migrate-1"]))
        #expect(!commands[0].contains("--detach"))
        #expect(commands[1].starts(with: ["container", "create", "--name", "demo-migrate-2"]))
        #expect(!commands[1].contains("--detach"))
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("up does not gate dependent services on deploy job completion")
    func upDoesNotGateDependentServicesOnDeployJobCompletion() async throws {
        let runner = RecordingRunner(responses: [.success, .success, .success])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: [
            "demo-migrate-1": 0,
            "demo-migrate-2": 7,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.scale = 2
                },
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["migrate": ComposeDependency(condition: "service_started")]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 3)
        #expect(commands.prefix(2).allSatisfy { $0.containsSequence(["example/migrate"]) })
        #expect(commands.last?.contains("example/api") == true)
        #expect(await lifecycleManager.requests.isEmpty)
    }

    @Test("up rejects unsupported deploy update order as apple/container orchestration gap")
    func upRejectsUnsupportedDeployUpdateOrderAsAppleContainerOrchestrationGap() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["update_config.order"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported deploy update order error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.update_config.order; unsupported update orders need Docker Compose compatible apple/container update orchestration primitives"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported generic deploy resource limits as apple/container runtime gaps")
    func upRejectsUnsupportedDeployResourceLimitsAsAppleContainerRuntimeGaps() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["resources.limits.generic_resources"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported deploy resource limit error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.resources.limits.generic_resources; apple/container exposes local deploy CPU, memory, and pids limits but not this deploy resource limit yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up accepts start-first deploy updates and recreates when the order changes")
    func upAcceptsStartFirstDeployUpdatesAndRecreatesWhenOrderChanges() async throws {
        let initialProject = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deploy = .object([
                        "update_config": .object([
                            "order": .string("stop-first"),
                        ]),
                    ])
                },
            ]
        )
        let createRunner = RecordingRunner(responses: [.success])

        try await ComposeOrchestrator(runner: createRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: initialProject, options: ComposeUpOptions())

        let oldRun = try #require(createRunner.commands.last?.arguments)
        let oldHash = try #require(composeConfigHash(in: oldRun))
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(id: "demo-api-1", status: "running", labels: [composeConfigHashLabel: oldHash]),
        ])
        let lifecycleManager = RecordingContainerLifecycleManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deploy = .object([
                        "update_config": .object([
                            "order": .string("start-first"),
                        ]),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        let newRun = try #require(runner.commands.first?.arguments)
        #expect(newRun.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(composeConfigHash(in: newRun) != oldHash)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("up rejects unsupported deploy resource reservations as apple/container runtime gaps")
    func upRejectsUnsupportedDeployResourceReservationsAsAppleContainerRuntimeGaps() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["resources.reservations.pids"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported deploy resource reservation error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.resources.reservations.pids; resource reservations need an apple/container scheduler/resource reservation gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported model fields before creating resources")
    func upRejectsUnsupportedModelFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedModelFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "api")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up runs provider services and injects setenv and rawsetenv into dependents")
    func upRunsProviderServicesAndInjectsProviderEnvironmentIntoDependents() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[{"name":"name","required":true},{"name":"size"}]},"down":{"parameters":[{"name":"name","required":true}]}}
            """, stderr: ""),
            CommandResult(status: 0, stdout: """
            {"type":"info","message":"provisioned database"}
            {"type":"setenv","message":"URL=https://magic.cloud/database"}
            {"type":"rawsetenv","message":"CLOUD_REGION=us-east-1"}
            """, stderr: ""),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(
                        type: provider.path,
                        options: [
                            "ignored": ["not-forwarded"],
                            "name": ["db"],
                            "size": ["small"],
                        ]
                    )
                },
                "api": composeService(name: "api", image: "alpine") {
                    $0.dependsOn = ["database": ComposeDependency()]
                    $0.environment = ["CLOUD_REGION": "user-defined-region"]
                },
                "worker-identical": composeService(name: "worker-identical", image: "alpine") {
                    $0.dependsOn = ["database": ComposeDependency()]
                    $0.environment = ["CLOUD_REGION": "us-east-1"]
                },
                "worker-missing": composeService(name: "worker-missing", image: "alpine") {
                    $0.dependsOn = ["database": ComposeDependency()]
                },
            ]
        ) {
            $0.environment = ["PROVIDER_PROJECT_TOKEN": "from-project"]
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies { _ in }
        ).up(project: project, options: ComposeUpOptions())

        #expect(emitted.messages == [
            "compose: provider database: provisioned database",
            "warning: provider \"database\" overrides environment variable \"CLOUD_REGION\" in service \"api\"",
        ])
        #expect(runner.commands.prefix(2).map(\.executable) == [provider.path, provider.path])
        #expect(runner.commands.count == 5)
        #expect(runner.commands.dropFirst(2).allSatisfy {
            $0.executable == ComposeExecutionOptions.defaultEnvironmentLauncher
        })
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
        #expect(runner.commands[0].environment == ["PROVIDER_PROJECT_TOKEN": "from-project"])
        #expect(runner.commands[1].arguments == [
            "compose",
            "--project-name=demo",
            "up",
            "--name=db",
            "--size=small",
            "database",
        ])
        #expect(runner.commands[1].environment == ["PROVIDER_PROJECT_TOKEN": "from-project"])
        #expect(!runner.commands[1].arguments.contains("--ignored=not-forwarded"))
        let runArguments = try #require(runner.commands.first {
            $0.arguments.contains("demo-api-1")
        }).arguments
        #expect(runArguments.starts(with: ["container", "create", "--name", "demo-api-1"]))
        #expect(runArguments.contains("--env"))
        #expect(runArguments.contains("DATABASE_URL=https://magic.cloud/database"))
        #expect(runArguments.contains("CLOUD_REGION=us-east-1"))
        #expect(!runArguments.contains("CLOUD_REGION=user-defined-region"))
        for name in ["demo-worker-identical-1", "demo-worker-missing-1"] {
            let arguments = try #require(runner.commands.first {
                $0.arguments.contains(name)
            }).arguments
            #expect(arguments.contains("DATABASE_URL=https://magic.cloud/database"))
            #expect(arguments.contains("CLOUD_REGION=us-east-1"))
        }
    }

    @Test("up rejects malformed provider rawsetenv", arguments: ["MISSING_VALUE", "=value"])
    func upRejectsMalformedProviderRawSetenv(message: String) async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: "", stderr: ""),
            CommandResult(status: 0, stdout: """
            {"type":"rawsetenv","message":"\(message)"}
            """, stderr: ""),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(type: provider.path)
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected malformed rawsetenv failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "invalid rawsetenv response from provider service 'database': \(message)"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

}
