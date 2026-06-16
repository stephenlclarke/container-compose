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

import ComposeCore
import Foundation
import Testing

private func composeService(
    name: String,
    image: String? = nil,
    configure: (inout ComposeService) -> Void = { _ in }
) -> ComposeService {
    var service = ComposeService(name: name, image: image)
    configure(&service)
    return service
}

private func composeProject(
    name: String,
    services: [String: ComposeService],
    configure: (inout ComposeProject) -> Void = { _ in }
) -> ComposeProject {
    var project = ComposeProject(name: name, services: services)
    configure(&project)
    return project
}

private func projectWithRuntimeResources(networkName: String, volumeName: String) -> ComposeProject {
    composeProject(
        name: "demo",
        services: [
            "api": composeService(name: "api", image: "alpine") {
                $0.networks = ["shared"]
                $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
            },
        ]
    ) {
        $0.networks = ["shared": ComposeNetwork(name: networkName, external: true)]
        $0.volumes = ["cache": ComposeVolume(name: volumeName, external: true)]
    }
}

@Suite("Compose orchestrator")
struct ComposeOrchestratorTests {
    @Test("orders selected services after dependencies")
    func ordersSelectedServicesAfterDependencies() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["db": "service_started"]
                },
                "db": ComposeService(name: "db", image: "postgres:16"),
                "web": composeService(name: "web", image: "nginx:latest") {
                    $0.dependsOn = ["api": "service_started"]
                },
            ]
        )

        let ordered = try ComposeOrchestrator().orderedServices(project: project, selected: ["web"])

        #expect(ordered.map(\.name) == ["db", "api", "web"])
    }

    @Test("detects dependency cycles")
    func detectsDependencyCycles() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = ["worker": "service_started"]
                },
                "worker": composeService(name: "worker", image: "example/worker:latest") {
                    $0.dependsOn = ["api": "service_started"]
                },
            ]
        )

        do {
            _ = try ComposeOrchestrator().orderedServices(project: project, selected: [])
            Issue.record("Expected dependency cycle error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("dependency cycle involving 'api'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("up creates resources and runs services with compose labels")
    func upCreatesResourcesAndRunsServicesWithComposeLabels() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .failure,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
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
        #expect(runner.commands[0].arguments.containsSequence(["network", "create"]))
        #expect(runner.commands[0].arguments.contains("demo_default"))
        #expect(runner.commands[0].arguments.containsSequence(["--label", "com.apple.container.compose.project.working-directory=/tmp/demo"]))
        #expect(runner.commands[0].arguments.containsLabel(withPrefix: "com.apple.container.compose.project.config-files-hash="))
        #expect(runner.commands[1].arguments.containsSequence(["volume", "create"]))
        #expect(runner.commands[1].arguments.contains("demo_cache"))
        #expect(runner.commands[1].arguments.containsSequence(["--label", "com.apple.container.compose.project.working-directory=/tmp/demo"]))
        #expect(runner.commands[1].arguments.containsLabel(withPrefix: "com.apple.container.compose.project.config-files-hash="))
        #expect(runner.commands[2].arguments == ["container", "inspect", "demo-api-1"])

        let run = runner.commands[3].arguments
        #expect(run.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!run.contains("--detach"))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.project.working-directory=/tmp/demo"]))
        #expect(run.containsLabel(withPrefix: "com.apple.container.compose.project.config-files-hash="))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(run.containsSequence(["--label", "com.apple.container.compose.oneoff=false"]))
        #expect(run.containsSequence(["--label", "com.example.role=api"]))
        #expect(run.containsSequence(["--env", "LOG_LEVEL=debug"]))
        #expect(run.containsSequence(["--publish", "8080:80"]))
        #expect(run.containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(run.containsSequence(["--network", "demo_default"]))
        #expect(run.containsSequence(["--platform", "linux/amd64"]))
        #expect(Array(run.suffix(2)) == ["example/api:latest", "serve"])
    }

    @Test("up uses external resource names without creating project resources")
    func upUsesExternalResourceNamesWithoutCreatingProjectResources() async throws {
        let runner = RecordingRunner(responses: [
            .failure,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.networks = ["shared"]
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/data")]
                },
            ]
        ) {
            $0.networks = ["shared": ComposeNetwork(name: "corp-net", external: true)]
            $0.volumes = ["data": ComposeVolume(name: "corp-data", external: true)]
        }

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0] == ["container", "inspect", "demo-api-1"])
        #expect(!commands.contains { $0.containsSequence(["network", "create"]) })
        #expect(!commands.contains { $0.containsSequence(["volume", "create"]) })

        let run = commands[1]
        #expect(run.containsSequence(["--network", "corp-net"]))
        #expect(run.containsSequence(["--volume", "corp-data:/data"]))
        #expect(!run.contains("demo_shared"))
        #expect(!run.contains("demo_data"))
    }

    @Test("orchestrator honors explicit non external resource names")
    func orchestratorHonorsExplicitNonExternalResourceNames() async throws {
        let upRunner = RecordingRunner(responses: [
            .success,
            .success,
            .failure,
            .success,
        ])
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

        try await ComposeOrchestrator(runner: upRunner).up(project: project, options: ComposeUpOptions())

        let upCommands = upRunner.commands.map(\.arguments)
        #expect(upCommands[0].containsSequence(["network", "create"]))
        #expect(upCommands[0].last == "team-net")
        #expect(upCommands[1].containsSequence(["volume", "create"]))
        #expect(upCommands[1].last == "team-cache")
        #expect(upCommands[3].containsSequence(["--network", "team-net"]))
        #expect(upCommands[3].containsSequence(["--volume", "team-cache:/cache"]))

        let downRunner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
        ])

        try await ComposeOrchestrator(runner: downRunner).down(project: project, options: ComposeDownOptions(volumes: true))

        #expect(downRunner.commands.map(\.arguments) == [
            ["container", "stop", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
            ["container", "network", "delete", "team-net"],
            ["container", "volume", "delete", "team-cache"],
        ])
    }

    @Test("up removes orphan containers when requested")
    func upRemovesOrphanContainersWhenRequested() async throws {
        let runner = RecordingRunner(responses: [
            .failure,
            .success,
            containerListResult(),
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions(removeOrphans: true))

        #expect(runner.commands.count == 5)
        #expect(runner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(runner.commands[1].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(!runner.commands[1].arguments.contains("--detach"))
        #expect(runner.commands[1].arguments.containsSequence(["--label", "com.apple.container.compose.project=demo"]))
        #expect(runner.commands[1].arguments.containsSequence(["--label", "com.apple.container.compose.service=api"]))
        #expect(runner.commands[1].arguments.last == "example/api:latest")
        #expect(runner.commands[2].arguments == ["container", "list", "--format", "json", "--all"])
        #expect(runner.commands[3].arguments == ["container", "stop", "demo-worker-1"])
        #expect(runner.commands[4].arguments == ["container", "delete", "demo-worker-1"])
    }

    @Test("up emits detach flag only when requested")
    func upEmitsDetachFlagOnlyWhenRequested() async throws {
        let runner = RecordingRunner(responses: [
            .failure,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
            ]
        )

        try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions(detach: true))

        #expect(runner.commands[1].arguments.starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(runner.commands[1].arguments.last == "example/api:latest")
    }

    @Test("up build does not rebuild build-only services")
    func upBuildDoesNotRebuildBuildOnlyServices() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .failure,
            .success,
            .failure,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
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

        try await orchestrator.up(project: project, options: ComposeUpOptions(build: true))

        let buildCommands = runner.commands.map(\.arguments).filter { $0.starts(with: ["container", "build"]) }
        #expect(buildCommands.count == 2)
        #expect(buildCommands[0].containsSequence(["--tag", "example/api"]))
        #expect(buildCommands[0].last == "api")
        #expect(buildCommands[1].containsSequence(["--tag", "demo_worker:latest"]))
        #expect(buildCommands[1].last == "worker")
    }

    @Test("up pull missing pulls only absent images")
    func upPullMissingPullsOnlyAbsentImages() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .failure,
            .success,
            .failure,
            .success,
            .failure,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions(pullPolicy: "missing"))

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "inspect", "example/api"])
        #expect(commands[1] == ["container", "image", "inspect", "postgres"])
        #expect(commands[2] == ["container", "image", "pull", "postgres"])
        #expect(commands[3] == ["container", "inspect", "demo-api-1"])
        #expect(commands[5] == ["container", "inspect", "demo-db-1"])
    }

    @Test("up applies service pull policies when no global pull policy is set")
    func upAppliesServicePullPoliciesWhenNoGlobalPullPolicyIsSet() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .failure,
            .success,
            .failure,
            .success,
            .failure,
            .success,
            .failure,
            .success,
        ])
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

        try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "pull", "example/api"])
        #expect(commands[1] == ["container", "image", "inspect", "example/worker"])
        #expect(commands[2] == ["container", "image", "pull", "example/worker"])
        #expect(commands[3] == ["container", "inspect", "demo-api-1"])
        #expect(commands[5] == ["container", "inspect", "demo-db-1"])
        #expect(commands[7] == ["container", "inspect", "demo-worker-1"])
    }

    @Test("up rejects unsupported service pull policies before creating resources")
    func upRejectsUnsupportedServicePullPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.pullPolicy = "build"
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
            #expect(error == .unsupported("service 'api' uses pull_policy 'build'; supported values are always, missing, if_not_present, and never"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("rejects dependency conditions with runtime gap reasons")
    func rejectsUnsupportedDependencyConditions() async throws {
        let cases = [
            (
                condition: "service_healthy",
                reason: "health status support needs an apple/container runtime gap PR"
            ),
            (
                condition: "service_completed_successfully",
                reason: "exit code and completion time need an apple/container runtime gap PR"
            ),
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
                        $0.dependsOn = ["job": testCase.condition]
                    },
                ]
            )

            do {
                try await ComposeOrchestrator(runner: runner)
                    .up(project: project, options: ComposeUpOptions(services: ["api"]))
                Issue.record("Expected unsupported dependency condition")
            } catch let error as ComposeError {
                #expect(error == .unsupported("service 'api' depends on 'job' with condition '\(testCase.condition)'; \(testCase.reason)"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported links before creating resources")
    func upRejectsUnsupportedLinksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.links = ["redis:cache"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported links error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses links; legacy link support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported hostnames before creating resources")
    func upRejectsUnsupportedHostnamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.hostname = "custom-api"
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
            Issue.record("Expected unsupported hostname error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses hostname; custom hostname support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported domain names before creating resources")
    func upRejectsUnsupportedDomainNamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.domainName = "example.test"
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
            Issue.record("Expected unsupported domain name error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses domainname; custom domain name support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported DNS options before creating resources")
    func upRejectsUnsupportedDNSOptionsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dnsOptions = ["use-vc"]
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
            Issue.record("Expected unsupported DNS option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses dns_opt; DNS option support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported sysctls before creating resources")
    func upRejectsUnsupportedSysctlsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.sysctls = ["net.core.somaxconn": "1024"]
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
            Issue.record("Expected unsupported sysctls error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses sysctls; sysctl support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported network aliases before creating resources")
    func upRejectsUnsupportedNetworkAliasesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["api.internal"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported network alias error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses network aliases; network alias support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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
                        "backend": ComposeNetworkOptions(addressing: .init(ipv4Address: "10.10.0.5"), priority: 42),
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
            #expect(error == .unsupported("service 'api' uses network attachment options ipv4_address, priority on network 'backend'; network attachment options need an apple/container runtime gap PR"))
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

    @Test("up rejects unsupported namespace and cgroup fields before creating resources")
    func upRejectsUnsupportedNamespaceAndCgroupFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedRuntimeStringFieldCases() {
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

    @Test("up rejects unsupported block IO config before creating resources")
    func upRejectsUnsupportedBlockIOConfigBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.blkioConfig = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported block IO config error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses blkio_config; block I/O controls are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported develop config before creating resources")
    func upRejectsUnsupportedDevelopConfigBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported develop config error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses develop; develop/watch workflows are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported build fields before creating resources")
    func upRejectsUnsupportedBuildFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.build = ComposeBuild(context: "api", unsupportedFields: ["additional_contexts", "ssh"])
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
            #expect(error == .unsupported("service 'api' uses unsupported build fields additional_contexts, ssh; advanced build fields are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported deploy fields before creating resources")
    func upRejectsUnsupportedDeployFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.unsupportedDeployFields = ["mode", "resources.limits", "placement"]
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
            #expect(error == .unsupported("service 'api' uses unsupported deploy fields mode, resources.limits, placement; Compose Deploy Specification beyond replica count is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported provider model and hook fields before creating resources")
    func upRejectsUnsupportedProviderModelAndHookFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedProviderModelAndHookFieldCases() {
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

    @Test("up rejects unsupported user and security option fields before creating resources")
    func upRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedUserAndSecurityOptionFieldCases() {
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

    @Test("up rejects unsupported device access fields before creating resources")
    func upRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedDeviceAccessFieldCases() {
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

    @Test("up rejects unsupported service scale before creating resources")
    func upRejectsUnsupportedServiceScaleBeforeCreatingResources() async throws {
        for scale in [0, 2] {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        $0.scale = scale
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported scale error")
            } catch let error as ComposeError {
                #expect(error == .unsupported("service 'api' uses scale \(scale); service replica scaling is not implemented by container-compose yet"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("up rejects unsupported metadata and logging fields before creating resources")
    func upRejectsUnsupportedMetadataAndLoggingFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedServiceMetadataAndLoggingFieldCases() {
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

    @Test("up rejects unsupported volume shortcut fields before creating resources")
    func upRejectsUnsupportedVolumeShortcutFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedServiceVolumeShortcutFieldCases() {
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

    @Test("up rejects unsupported API socket mounting before creating resources")
    func upRejectsUnsupportedAPISocketBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.useAPISocket = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported API socket error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses use_api_socket; API socket mounting is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported MAC address before creating resources")
    func upRejectsUnsupportedMACAddressBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.macAddress = "02:42:ac:11:00:03"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported MAC address error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses mac_address '02:42:ac:11:00:03'; MAC address support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported healthchecks before creating resources")
    func upRejectsUnsupportedHealthchecksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.healthcheck = .object(["disable": .bool(true)])
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
            Issue.record("Expected unsupported healthcheck error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses healthcheck; health status support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported configs before creating resources")
    func upRejectsUnsupportedConfigsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.configs = ["app_config": .object(["external": .bool(true)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported configs error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses configs; config mount support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported secrets before creating resources")
    func upRejectsUnsupportedSecretsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("/run/secrets/app_secret")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.secrets = ["app_secret": .object(["external": .bool(true)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported secrets error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses secrets; secret mount support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported restart policies before creating resources")
    func upRejectsUnsupportedRestartPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.restart = "unless-stopped"
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
            Issue.record("Expected unsupported restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses restart policy 'unless-stopped'; restart policy support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("lists selected service images")
    func listsSelectedServiceImages() throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api:latest"),
                "builder": composeService(name: "builder") {
                    $0.build = ComposeBuild(context: ".")
                },
                "web": ComposeService(name: "web", image: "nginx:latest"),
            ]
        )

        let images = try ComposeOrchestrator().images(project: project, services: ["web", "builder", "api"])

        #expect(images == ["example/api:latest", "nginx:latest"])
    }

    @Test("ps filters containers by project label")
    func psFiltersContainersByProjectLabel() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: false)

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json"]])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-api-1", "demo-worker-1"])
    }

    @Test("ps keeps project scoping when all containers are requested")
    func psKeepsProjectScopingWhenAllContainersAreRequested() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [containerListResult()])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.ps(project: ComposeProject(name: "demo", services: [:]), all: true)

        #expect(runner.commands.map(\.arguments) == [["container", "list", "--format", "json", "--all"]])
        #expect(try listedContainerIDs(from: try #require(emitted.messages.first)) == ["demo-api-1", "demo-worker-1"])
    }

    @Test("normalizes a compose file through compose-go")
    func normalizesComposeFileThroughComposeGo() async throws {
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
            image: nginx:latest
            pull_policy: always
            platform: linux/amd64
            mac_address: 02:42:ac:11:00:03
            runtime: container-runtime-linux
            cgroup: host
            cgroup_parent: m-executor-abcd
            cpu_count: 2
            cpu_period: 100000
            cpu_quota: 50000
            cpu_rt_period: 950000
            cpu_rt_runtime: 900000
            cpuset: "0-1"
            cpu_shares: 512
            domainname: example.test
            ipc: host
            isolation: default
            pid: host
            userns_mode: host
            uts: host
            command: ["nginx", "-g", "daemon off;"]
            networks:
              default:
                aliases:
                  - api.internal
                ipv4_address: 10.10.0.5
            ports:
              - "8080:80"
            environment:
              LOG_LEVEL: debug
            dns_opt:
              - use-vc
            expose:
              - "9000"
            mem_reservation: 128m
            memswap_limit: 256m
            mem_swappiness: 60
            oom_kill_disable: true
            oom_score_adj: -500
            pids_limit: 128
            shm_size: 64m
            ulimits:
              nofile:
                soft: 1024
                hard: 2048
              nproc: 512
            sysctls:
              net.core.somaxconn: "1024"
            stop_signal: SIGUSR1
            stop_grace_period: 90s
            links:
              - redis:cache
            external_links:
              - legacy_db:db
          redis:
            image: redis:7
        volumes:
          data: {}
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        #expect(project.name == "sample")
        #expect(project.services["api"]?.image == "nginx:latest")
        #expect(project.services["api"]?.pullPolicy == "always")
        #expect(project.services["api"]?.platform == "linux/amd64")
        #expect(project.services["api"]?.macAddress == "02:42:ac:11:00:03")
        #expect(project.services["api"]?.runtime == "container-runtime-linux")
        #expect(project.services["api"]?.cgroup == "host")
        #expect(project.services["api"]?.cgroupParent == "m-executor-abcd")
        #expect(project.services["api"]?.cpuCount == 2)
        #expect(project.services["api"]?.cpuPeriod == 100000)
        #expect(project.services["api"]?.cpuQuota == 50000)
        #expect(project.services["api"]?.cpuRealtimePeriod == 950000)
        #expect(project.services["api"]?.cpuRealtimeRuntime == 900000)
        #expect(project.services["api"]?.cpuset == "0-1")
        #expect(project.services["api"]?.cpuShares == 512)
        #expect(project.services["api"]?.ipc == "host")
        #expect(project.services["api"]?.isolation == "default")
        #expect(project.services["api"]?.pid == "host")
        #expect(project.services["api"]?.usernsMode == "host")
        #expect(project.services["api"]?.uts == "host")
        #expect(project.services["api"]?.domainName == "example.test")
        #expect(project.services["api"]?.command == ["nginx", "-g", "daemon off;"])
        #expect(project.services["api"]?.networkAliases == ["default": ["api.internal"]])
        #expect(project.services["api"]?.networkOptions == ["default": ComposeNetworkOptions(addressing: .init(ipv4Address: "10.10.0.5"))])
        #expect(project.services["api"]?.environment?["LOG_LEVEL"] == "debug")
        #expect(project.services["api"]?.dnsOptions == ["use-vc"])
        #expect(project.services["api"]?.expose == ["9000"])
        #expect(project.services["api"]?.memReservation == "134217728")
        #expect(project.services["api"]?.memSwapLimit == "268435456")
        #expect(project.services["api"]?.memSwappiness == "60")
        #expect(project.services["api"]?.oomKillDisable == true)
        #expect(project.services["api"]?.oomScoreAdj == -500)
        #expect(project.services["api"]?.pidsLimit == 128)
        #expect(project.services["api"]?.shmSize == "67108864")
        #expect(project.services["api"]?.ulimits == ["nofile=1024:2048", "nproc=512"])
        #expect(project.services["api"]?.sysctls == ["net.core.somaxconn": "1024"])
        #expect(project.services["api"]?.stopSignal == "SIGUSR1")
        #expect(project.services["api"]?.stopGracePeriodSeconds == 90)
        #expect(project.services["api"]?.links == ["redis:cache"])
        #expect(project.services["api"]?.externalLinks == ["legacy_db:db"])
        #expect(project.services["api"]?.ports == ["8080:80"])
        #expect(project.volumes["data"] != nil)
    }

    @Test("normalizes network mode through compose-go")
    func normalizesNetworkModeThroughComposeGo() async throws {
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
            image: nginx:latest
            network_mode: service:redis
          redis:
            image: redis:7
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        #expect(project.services["api"]?.networkMode == "service:redis")
    }

    @Test("normalizer infers project directory from the first compose file")
    func normalizerInfersProjectDirectoryFromFirstComposeFile() async throws {
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
          web:
            image: nginx:latest
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(files: [composeFile.path]))

        #expect(project.workingDirectory == directory.path)
        #expect(project.name == directory.lastPathComponent.lowercased())
        #expect(project.services["web"]?.image == "nginx:latest")
    }

    @Test("normalizer preserves healthchecks configs secrets and extensions")
    func normalizerPreservesHealthchecksConfigsSecretsAndExtensions() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        try """
        x-project:
          enabled: true
        models:
          llm:
            model: example/local-llm
        services:
          api:
            image: alpine
            restart: unless-stopped
            healthcheck:
              disable: true
            configs:
              - source: app_config
                target: /etc/app.conf
            secrets:
              - source: app_secret
            x-service:
              owner: platform
        configs:
          app_config:
            external: true
        secrets:
          app_secret:
            external: true
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(files: [composeFile.path]))
        let api = try #require(project.services["api"])

        #expect(project.configs?["app_config"] == .object(["external": .bool(true), "name": .string("app_config")]))
        #expect(project.secrets?["app_secret"] == .object(["external": .bool(true), "name": .string("app_secret")]))
        #expect(project.models?["llm"] == .object(["model": .string("example/local-llm")]))
        #expect(project.extensions?["x-project"] == .object(["enabled": .bool(true)]))
        #expect(api.restart == "unless-stopped")
        #expect(api.healthcheck == .object(["disable": .bool(true)]))
        #expect(api.configs == [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])])
        #expect(api.secrets == [.object(["source": .string("app_secret"), "target": .string("/run/secrets/app_secret")])])
        #expect(api.extensions?["x-service"] == .object(["owner": .string("platform")]))
    }

    @Test("describes compose errors")
    func describesComposeErrors() {
        #expect(ComposeError.commandFailed(command: "container ps", status: 7, stderr: "").description == "container ps failed with exit code 7")
        #expect(ComposeError.commandFailed(command: "container ps", status: 7, stderr: " denied\n").description == "container ps failed with exit code 7: denied")
        #expect(ComposeError.invalidProject("missing service").description == "invalid compose project: missing service")
        #expect(ComposeError.unsupported("profiles").description == "unsupported compose feature: profiles")
        #expect(ComposeError.missingNormalizer("missing helper").description == "compose normalizer unavailable: missing helper")
    }

    @Test("prints sorted config JSON")
    func printsSortedConfigJSON() throws {
        let project = ComposeProject(name: "demo", services: ["web": ComposeService(name: "web", image: "nginx")])

        let json = try ComposeOrchestrator().config(project: project)

        #expect(json.contains(#""name" : "demo""#))
        #expect(json.contains(#""web" : {"#))
    }

    @Test("config preserves normalized compose extension fields")
    func configPreservesNormalizedComposeExtensionFields() throws {
        let project = composeProject(
            name: "demo",
            services: [
                "web": composeService(name: "web", image: "nginx") {
                    $0.healthcheck = .object(["disable": .bool(true)])
                    $0.configs = [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])]
                    $0.secrets = [.object(["source": .string("app_secret")])]
                    $0.extensions = ["x-service": .object(["owner": .string("platform")])]
                },
            ]
        ) {
            $0.configs = ["app_config": .object(["external": .bool(true)])]
            $0.secrets = ["app_secret": .object(["external": .bool(true)])]
            $0.models = ["llm": .object(["model": .string("example/local-llm")])]
            $0.extensions = ["x-project": .object(["enabled": .bool(true), "retries": .number(3)])]
        }

        let json = try ComposeOrchestrator().config(project: project)
        let decoded = try JSONDecoder().decode(ComposeProject.self, from: Data(json.utf8))

        #expect(decoded.configs?["app_config"] == .object(["external": .bool(true)]))
        #expect(decoded.secrets?["app_secret"] == .object(["external": .bool(true)]))
        #expect(decoded.models?["llm"] == .object(["model": .string("example/local-llm")]))
        #expect(decoded.extensions?["x-project"] == .object(["enabled": .bool(true), "retries": .number(3)]))
        #expect(decoded.services["web"]?.healthcheck == .object(["disable": .bool(true)]))
        #expect(decoded.services["web"]?.configs == [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])])
        #expect(decoded.services["web"]?.secrets == [.object(["source": .string("app_secret")])])
        #expect(decoded.services["web"]?.extensions?["x-service"] == .object(["owner": .string("platform")]))
    }

    @Test("service init key maps to initEnabled")
    func serviceInitKeyMapsToInitEnabled() throws {
        let decoded = try JSONDecoder().decode(ComposeService.self, from: Data(#"{"name":"web","init":true}"#.utf8))

        #expect(decoded.initEnabled == true)

        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(encoded.contains(#""init":true"#))
        #expect(!encoded.contains("initEnabled"))
    }

    @Test("normalizer decodes JSON and forwards compose options")
    func normalizerDecodesJSONAndForwardsOptions() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"{"name":"demo","workingDirectory":"/tmp/demo","composeFiles":["compose.yml"],"services":{"web":{"name":"web","image":"nginx","cpuPercent":12.5}},"networks":{},"volumes":{}}"#,
                stderr: ""
            ),
        ])

        let project = try await ComposeNormalizer(runner: runner).normalize(options: ComposeOptions(
            files: ["compose.yml"],
            projectName: "demo",
            profiles: ["dev"],
            envFiles: [".env"],
            projectDirectory: "/tmp/demo"
        ))

        #expect(project.name == "demo")
        #expect(project.services["web"]?.image == "nginx")
        #expect(project.services["web"]?.cpuPercent == 12.5)
        let command = try #require(runner.commands.first)
        #expect(command.arguments.containsSequence(["--file", "compose.yml"]))
        #expect(command.arguments.containsSequence(["--profile", "dev"]))
        #expect(command.arguments.containsSequence(["--env-file", ".env"]))
        #expect(command.arguments.containsSequence(["--project-name", "demo"]))
        #expect(command.arguments.containsSequence(["--project-directory", "/tmp/demo"]))
    }

    @Test("normalizer uses configured fallback launcher")
    func normalizerUsesConfiguredFallbackLauncher() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"{"name":"demo","workingDirectory":"/tmp/demo","composeFiles":["compose.yml"],"services":{"web":{"name":"web","image":"nginx"}},"networks":{},"volumes":{}}"#,
                stderr: ""
            ),
        ])

        _ = try await ComposeNormalizer(runner: runner, fallbackLauncher: "custom-env")
            .normalize(options: ComposeOptions(files: ["compose.yml"], projectDirectory: "/tmp/demo"))

        let command = try #require(runner.commands.first)
        #expect(command.executable == "custom-env")
        #expect(command.arguments.starts(with: ["go", "run", "."]))
        #expect(command.arguments.containsSequence(["--project-directory", "/tmp/demo"]))
    }

    @Test("normalizer forwards inferred project directory")
    func normalizerForwardsInferredProjectDirectory() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"{"name":"demo","workingDirectory":"/tmp/demo","composeFiles":["/tmp/demo/compose.yml"],"services":{"web":{"name":"web","image":"nginx"}},"networks":{},"volumes":{}}"#,
                stderr: ""
            ),
        ])

        _ = try await ComposeNormalizer(runner: runner).normalize(options: ComposeOptions(files: ["/tmp/demo/compose.yml"]))

        let command = try #require(runner.commands.first)
        #expect(command.arguments.containsSequence(["--file", "/tmp/demo/compose.yml"]))
        #expect(command.arguments.containsSequence(["--project-directory", "/tmp/demo"]))
    }

    @Test("normalizer defaults project directory to current working directory")
    func normalizerDefaultsProjectDirectoryToCurrentWorkingDirectory() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"{"name":"demo","workingDirectory":"/tmp/demo","composeFiles":["compose.yml"],"services":{"web":{"name":"web","image":"nginx"}},"networks":{},"volumes":{}}"#,
                stderr: ""
            ),
        ])

        _ = try await ComposeNormalizer(runner: runner).normalize(options: ComposeOptions())

        let command = try #require(runner.commands.first)
        #expect(command.arguments.containsSequence(["--project-directory", FileManager.default.currentDirectoryPath]))
    }

    @Test("normalizer surfaces command and decode failures")
    func normalizerSurfacesCommandAndDecodeFailures() async throws {
        do {
            _ = try await ComposeNormalizer(runner: RecordingRunner(responses: [
                CommandResult(status: 23, stdout: "", stderr: "bad compose"),
            ])).normalize(options: ComposeOptions(files: ["compose.yml"]))
            Issue.record("Expected command failure")
        } catch let error as ComposeError {
            #expect(error == .commandFailed(
                command: "/usr/bin/env go run . --file compose.yml --project-directory \(FileManager.default.currentDirectoryPath)",
                status: 23,
                stderr: "bad compose"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try await ComposeNormalizer(runner: RecordingRunner(responses: [
                CommandResult(status: 0, stdout: "not json", stderr: ""),
            ])).normalize(options: ComposeOptions(files: ["compose.yml"]))
            Issue.record("Expected decode failure")
        } catch let error as ComposeError {
            if case .invalidProject(let message) = error {
                #expect(message.contains("failed to decode normalized compose JSON"))
            } else {
                Issue.record("Unexpected compose error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("build pull and push emit image commands")
    func buildPullAndPushEmitImageCommands() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        dockerfile: "Containerfile",
                        args: ["VERSION": "1"],
                        target: "runtime",
                        noCache: true
                    )
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await orchestrator.build(project: project, services: [], noCache: true)
        try await orchestrator.pull(project: project, services: ["api", "worker"])
        try await orchestrator.push(project: project, services: ["api", "worker"])

        #expect(runner.commands[0].arguments.containsSequence(["container", "build", "--tag", "example/api:latest"]))
        #expect(runner.commands[0].arguments.containsSequence(["--file", "Containerfile"]))
        #expect(runner.commands[0].arguments.containsSequence(["--target", "runtime"]))
        #expect(runner.commands[0].arguments.contains("--no-cache"))
        #expect(runner.commands[0].arguments.containsSequence(["--build-arg", "VERSION=1"]))
        #expect(runner.commands[0].arguments.last == "api")
        #expect(runner.commands[1].arguments.containsSequence(["--tag", "demo_worker:latest"]))
        #expect(runner.commands[2].arguments == ["container", "image", "pull", "example/api:latest"])
        #expect(runner.commands[3].arguments == ["container", "image", "push", "example/api:latest"])
    }

    @Test("build applies Compose file no cache setting")
    func buildAppliesComposeFileNoCacheSetting() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api", noCache: true)
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(project: project, services: ["api"], noCache: false)

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.contains("--no-cache"))
    }

    @Test("build rejects unsupported build fields before emitting commands")
    func buildRejectsUnsupportedBuildFieldsBeforeEmittingCommands() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api", unsupportedFields: ["dockerfile_inline", "secrets"])
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).build(project: project, services: [], noCache: false)
            Issue.record("Expected unsupported build field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses unsupported build fields dockerfile_inline, secrets; advanced build fields are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("orchestrator uses configured environment launcher")
    func orchestratorUsesConfiguredEnvironmentLauncher() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(environmentLauncher: "custom-env")
        )
        let project = ComposeProject(
            name: "demo",
            services: ["api": ComposeService(name: "api", image: "example/api:latest")]
        )

        try await orchestrator.pull(project: project, services: ["api"])

        let command = try #require(runner.commands.first)
        #expect(command.executable == "custom-env")
        #expect(command.arguments == ["container", "image", "pull", "example/api:latest"])
    }

    @Test("down removes project resources in dependency order")
    func downRemovesProjectResourcesInDependencyOrder() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
            .success,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.dependsOn = ["db": "service_started"]
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
                "db": ComposeService(name: "db", image: "postgres"),
            ]
        ) {
            $0.networks = ["default": ComposeNetwork(name: "default")]
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await orchestrator.down(project: project, options: ComposeDownOptions(volumes: true))

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
            ["container", "stop", "demo-db-1"],
            ["container", "delete", "demo-db-1"],
            ["container", "network", "delete", "demo_default"],
            ["container", "volume", "delete", "demo_data"],
        ])
    }

    @Test("down leaves orphan containers unless requested")
    func downLeavesOrphanContainersUnlessRequested() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions())

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stop", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
        ])
    }

    @Test("down removes remaining project scoped containers")
    func downRemovesRemainingProjectScopedContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            containerListResult(),
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.down(project: project, options: ComposeDownOptions(removeOrphans: true))

        #expect(runner.commands.map(\.arguments) == [
            ["container", "stop", "demo-api-1"],
            ["container", "delete", "demo-api-1"],
            ["container", "list", "--format", "json", "--all"],
            ["container", "stop", "demo-worker-1"],
            ["container", "delete", "demo-worker-1"],
        ])
    }

    @Test("lifecycle commands target selected service containers")
    func lifecycleCommandsTargetSelectedServiceContainers() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.tty = true
                    $0.stdinOpen = true
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
                "web": ComposeService(name: "web", image: "nginx"),
            ]
        )

        try await orchestrator.logs(project: project, services: ["api"], follow: true, tail: "10")
        try await orchestrator.exec(project: project, serviceName: "api", command: ["echo", "ok"])
        try await orchestrator.start(project: project, services: ["api"])
        try await orchestrator.stop(project: project, services: ["api"])
        try await orchestrator.restart(project: project, services: ["api"])
        try await orchestrator.rm(project: project, services: ["api"], stopFirst: true)
        try await orchestrator.kill(project: project, services: ["api"], signal: "SIGTERM")
        try await orchestrator.copy(project: project, arguments: ["api:/tmp/file", "."])

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "logs", "--follow", "-n", "10", "demo-api-1"])
        #expect(commands[1] == ["container", "exec", "--interactive", "--tty", "demo-api-1", "echo", "ok"])
        #expect(runner.commands[1].io == .inherited)
        #expect(commands[2] == ["container", "start", "demo-api-1"])
        #expect(commands[3] == ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"])
        #expect(commands[4] == ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"])
        #expect(commands[5] == ["container", "start", "demo-api-1"])
        #expect(commands[6] == ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"])
        #expect(commands[7] == ["container", "delete", "demo-api-1"])
        #expect(commands[8] == ["container", "kill", "--signal", "SIGTERM", "demo-api-1"])
        #expect(commands[9] == ["container", "cp", "demo-api-1:/tmp/file", "."])
    }

    @Test("exec disables TTY while keeping stdin inherited")
    func execDisablesTTYWhileKeepingStdinInherited() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await orchestrator.exec(
            project: project,
            serviceName: "api",
            command: ["echo", "ok"],
            interactive: true,
            tty: false
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command == ["container", "exec", "--interactive", "demo-api-1", "echo", "ok"])
        #expect(runner.commands.first?.io == .inherited)
    }

    @Test("logs accepts Compose all tail value")
    func logsAcceptsComposeAllTailValue() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(runner: runner).logs(project: project, services: ["api"], follow: false, tail: "all")

        #expect(runner.commands.map(\.arguments) == [
            ["container", "logs", "demo-api-1"],
        ])
    }

    @Test("logs rejects invalid tail values before runtime commands")
    func logsRejectsInvalidTailValuesBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).logs(project: project, services: ["api"], follow: false, tail: "latest")
            Issue.record("Expected invalid tail error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("logs --tail must be 'all' or a non-negative integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("cp maps service references in both copy directions")
    func cpMapsServiceReferencesInBothCopyDirections() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
                "db": composeService(name: "db", image: "postgres") {
                    $0.containerName = "custom-db"
                },
            ]
        )

        try await orchestrator.copy(project: project, arguments: ["api:/tmp/report.txt", "./report.txt"])
        try await orchestrator.copy(project: project, arguments: ["./seed.sql", "db:/docker-entrypoint-initdb.d/seed.sql"])
        try await orchestrator.copy(project: project, arguments: ["./local:file.txt", "./out:file.txt"])

        #expect(runner.commands.map(\.arguments) == [
            ["container", "cp", "demo-api-1:/tmp/report.txt", "./report.txt"],
            ["container", "cp", "./seed.sql", "custom-db:/docker-entrypoint-initdb.d/seed.sql"],
            ["container", "cp", "./local:file.txt", "./out:file.txt"],
        ])
    }

    @Test("run supports one-off containers and option flags")
    func runSupportsOneOffContainersAndOptionFlags() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = ComposeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.entrypoint = ["/bin/sh", "-c"]
                    $0.environment = ["A": "B", "EMPTY": nil]
                    $0.envFiles = [".env"]
                    $0.ports = ["8080:80"]
                    $0.volumes = [
                        ComposeMount(type: "bind", source: "/host", target: "/container", readOnly: true),
                        ComposeMount(type: "tmpfs", target: "/tmp"),
                        ComposeMount(type: "volume", target: "/anon"),
                    ]
                    $0.workingDir = "/work"
                    $0.user = "1000"
                    $0.tty = true
                    $0.stdinOpen = true
                    $0.readOnly = true
                    $0.initEnabled = true
                    $0.platform = "linux/arm64"
                    $0.runtime = "container-runtime-linux"
                    $0.tmpfs = ["/cache"]
                    $0.dns = ["1.1.1.1"]
                    $0.dnsSearch = ["local"]
                    $0.capAdd = ["NET_ADMIN"]
                    $0.capDrop = ["MKNOD"]
                    $0.memLimit = "1024"
                    $0.cpus = "2"
                    $0.shmSize = "67108864"
                    $0.ulimits = ["nofile=1024:2048", "nproc=512"]
                },
            ]
        )

        try await orchestrator.run(project: project, serviceName: "job", command: ["echo", "ok"], remove: true)

        let command = try #require(runner.commands.first?.arguments)
        #expect(runner.commands.first?.io == .inherited)
        #expect(command.starts(with: ["container", "run", "--name"]))
        #expect(command.contains("--rm"))
        #expect(command.containsSequence(["--env", "A=B"]))
        #expect(command.containsSequence(["--env", "EMPTY"]))
        #expect(command.containsSequence(["--env-file", ".env"]))
        #expect(!command.containsSequence(["--publish", "8080:80"]))
        #expect(command.containsSequence(["--volume", "/host:/container:ro"]))
        #expect(command.containsSequence(["--tmpfs", "/tmp"]))
        #expect(command.containsSequence(["--workdir", "/work"]))
        #expect(command.containsSequence(["--user", "1000"]))
        #expect(command.contains("--tty"))
        #expect(command.contains("--interactive"))
        #expect(command.containsSequence(["--platform", "linux/arm64"]))
        #expect(command.containsSequence(["--runtime", "container-runtime-linux"]))
        #expect(command.containsSequence(["--cap-add", "NET_ADMIN"]))
        #expect(command.containsSequence(["--cap-drop", "MKNOD"]))
        #expect(command.containsSequence(["--dns", "1.1.1.1"]))
        #expect(command.containsSequence(["--dns-search", "local"]))
        #expect(command.containsSequence(["--memory", "1024"]))
        #expect(command.containsSequence(["--cpus", "2"]))
        #expect(command.containsSequence(["--shm-size", "67108864"]))
        #expect(command.containsSequence(["--ulimit", "nofile=1024:2048"]))
        #expect(command.containsSequence(["--ulimit", "nproc=512"]))
        #expect(command.containsSequence(["--entrypoint", "/bin/sh -c"]))
        #expect(command.contains("--read-only"))
        #expect(command.contains("--init"))
        #expect(Array(command.suffix(3)) == ["alpine", "echo", "ok"])
    }

    @Test("run publishes service ports only when requested")
    func runPublishesServicePortsOnlyWhenRequested() async throws {
        let defaultRunner = RecordingRunner()
        let servicePortsRunner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.ports = ["8080:80"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: defaultRunner).run(
            project: project,
            serviceName: "api",
            options: ComposeRunOptions(command: ["true"])
        )
        try await ComposeOrchestrator(runner: servicePortsRunner).run(
            project: project,
            serviceName: "api",
            options: ComposeRunOptions(command: ["true"], servicePorts: true)
        )

        let defaultCommand = try #require(defaultRunner.commands.first?.arguments)
        let servicePortsCommand = try #require(servicePortsRunner.commands.first?.arguments)
        #expect(!defaultCommand.containsSequence(["--publish", "8080:80"]))
        #expect(servicePortsCommand.containsSequence(["--publish", "8080:80"]))
    }

    @Test("run publishes manual ports without service ports")
    func runPublishesManualPortsWithoutServicePorts() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "alpine") {
                    $0.ports = ["8080:80"]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).run(
            project: project,
            serviceName: "api",
            options: ComposeRunOptions(
                command: ["true"],
                publish: ["127.0.0.1:9090:90"]
            )
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--publish", "127.0.0.1:9090:90"]))
        #expect(!command.containsSequence(["--publish", "8080:80"]))
    }

    @Test("run creates project resources before one-off containers")
    func runCreatesProjectResourcesBeforeOneOffContainers() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
        ])
        let orchestrator = ComposeOrchestrator(runner: runner)
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await orchestrator.run(project: project, serviceName: "job", command: ["true"], remove: true)

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0].containsSequence(["container", "network", "create"]))
        #expect(commands[0].last == "demo_backend")
        #expect(commands[1].containsSequence(["container", "volume", "create"]))
        #expect(commands[1].last == "demo_cache")
        #expect(commands[2].starts(with: ["container", "run", "--name"]))
        #expect(commands[2].containsSequence(["--network", "demo_backend"]))
        #expect(commands[2].containsSequence(["--volume", "demo_cache:/cache"]))
        #expect(Array(commands[2].suffix(2)) == ["alpine", "true"])
    }

    @Test("run applies service pull policy before creating resources")
    func runAppliesServicePullPolicyBeforeCreatingResources() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
            .success,
            .success,
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pullPolicy = "always"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)

        let commands = runner.commands.map(\.arguments)
        #expect(commands[0] == ["container", "image", "pull", "alpine"])
        #expect(commands[1].containsSequence(["container", "network", "create"]))
        #expect(commands[2].containsSequence(["container", "volume", "create"]))
        #expect(commands[3].starts(with: ["container", "run", "--name"]))
    }

    @Test("run rejects unsupported service pull policies before creating resources")
    func runRejectsUnsupportedServicePullPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.pullPolicy = "daily"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported service pull policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses pull_policy 'daily'; supported values are always, missing, if_not_present, and never"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported external links before creating resources")
    func runRejectsUnsupportedExternalLinksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.externalLinks = ["legacy_db:db"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported external links error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses external_links; legacy link support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported hostnames before creating resources")
    func runRejectsUnsupportedHostnamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.hostname = "custom-job"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported hostname error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses hostname; custom hostname support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported domain names before creating resources")
    func runRejectsUnsupportedDomainNamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.domainName = "example.test"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported domain name error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses domainname; custom domain name support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported DNS options before creating resources")
    func runRejectsUnsupportedDNSOptionsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.dnsOptions = ["use-vc"]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported DNS option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses dns_opt; DNS option support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported sysctls before creating resources")
    func runRejectsUnsupportedSysctlsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.sysctls = ["net.core.somaxconn": "1024"]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported sysctls error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses sysctls; sysctl support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported network aliases before creating resources")
    func runRejectsUnsupportedNetworkAliasesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.networkAliases = ["backend": ["job.internal"]]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported network alias error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses network aliases; network alias support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported network options before creating resources")
    func runRejectsUnsupportedNetworkOptionsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(interfaceName: "eth0"),
                    ]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported network option error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses network attachment options interface_name on network 'backend'; network attachment options need an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported network mode before creating resources")
    func runRejectsUnsupportedNetworkModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.networkMode = "host"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported network mode error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses network_mode 'host'; network mode support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported namespace and cgroup fields before creating resources")
    func runRejectsUnsupportedNamespaceAndCgroupFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedRuntimeStringFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported CPU resource fields before creating resources")
    func runRejectsUnsupportedCPUResourceFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedCPUResourceFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported memory and process resource fields before creating resources")
    func runRejectsUnsupportedMemoryAndProcessResourceFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedMemoryAndProcessResourceFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported block IO config before creating resources")
    func runRejectsUnsupportedBlockIOConfigBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.blkioConfig = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported block IO config error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses blkio_config; block I/O controls are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported develop config before creating resources")
    func runRejectsUnsupportedDevelopConfigBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.develop = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported develop config error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses develop; develop/watch workflows are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported build fields before creating resources")
    func runRejectsUnsupportedBuildFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.build = ComposeBuild(context: "job", unsupportedFields: ["cache_from", "platforms"])
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported build field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses unsupported build fields cache_from, platforms; advanced build fields are not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported deploy fields before creating resources")
    func runRejectsUnsupportedDeployFieldsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.unsupportedDeployFields = ["labels", "restart_policy", "endpoint_mode"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported deploy field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses unsupported deploy fields labels, restart_policy, endpoint_mode; Compose Deploy Specification beyond replica count is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported provider model and hook fields before creating resources")
    func runRejectsUnsupportedProviderModelAndHookFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedProviderModelAndHookFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported user and security option fields before creating resources")
    func runRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedUserAndSecurityOptionFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported device access fields before creating resources")
    func runRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedDeviceAccessFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported service scale before creating resources")
    func runRejectsUnsupportedServiceScaleBeforeCreatingResources() async throws {
        for scale in [0, 3] {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        $0.scale = scale
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported scale error")
            } catch let error as ComposeError {
                #expect(error == .unsupported("service 'job' uses scale \(scale); service replica scaling is not implemented by container-compose yet"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported metadata and logging fields before creating resources")
    func runRejectsUnsupportedMetadataAndLoggingFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedServiceMetadataAndLoggingFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported volume shortcut fields before creating resources")
    func runRejectsUnsupportedVolumeShortcutFieldsBeforeCreatingResources() async throws {
        for testCase in unsupportedServiceVolumeShortcutFieldCases() {
            let runner = RecordingRunner()
            let project = composeProject(
                name: "demo",
                services: [
                    "job": composeService(name: "job", image: "alpine") {
                        testCase.configure(&$0)
                        $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                    },
                ]
            ) {
                $0.volumes = ["cache": ComposeVolume(name: "cache")]
            }

            do {
                try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
                Issue.record("Expected unsupported \(testCase.composeName) error")
            } catch let error as ComposeError {
                #expect(error == .unsupported(testCase.expectedMessage(serviceName: "job")))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("run rejects unsupported API socket mounting before creating resources")
    func runRejectsUnsupportedAPISocketBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.useAPISocket = true
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported API socket error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses use_api_socket; API socket mounting is not implemented by container-compose yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported MAC address before creating resources")
    func runRejectsUnsupportedMACAddressBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.macAddress = "02:42:ac:11:00:04"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported MAC address error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses mac_address '02:42:ac:11:00:04'; MAC address support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported healthchecks before creating resources")
    func runRejectsUnsupportedHealthchecksBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.healthcheck = .object(["disable": .bool(true)])
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported healthcheck error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses healthcheck; health status support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported configs before creating resources")
    func runRejectsUnsupportedConfigsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.configs = [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.configs = ["app_config": .object(["external": .bool(true)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported configs error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses configs; config mount support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported secrets before creating resources")
    func runRejectsUnsupportedSecretsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("/run/secrets/app_secret")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.secrets = ["app_secret": .object(["external": .bool(true)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported secrets error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses secrets; secret mount support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run rejects unsupported restart policies before creating resources")
    func runRejectsUnsupportedRestartPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "job": composeService(name: "job", image: "alpine") {
                    $0.restart = "on-failure"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).run(project: project, serviceName: "job", command: ["true"], remove: true)
            Issue.record("Expected unsupported restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'job' uses restart policy 'on-failure'; restart policy support needs an apple/container runtime gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("run assigns unique names to one-off containers")
    func runAssignsUniqueNamesToOneOffContainers() async throws {
        let identifiers = OneOffIdentifierSource(["first", "second"])
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(oneOffIdentifier: { identifiers.next() })
        )
        let project = ComposeProject(
            name: "demo",
            services: ["job": ComposeService(name: "job", image: "alpine")]
        )

        try await orchestrator.run(project: project, serviceName: "job", command: ["true"], remove: true)
        try await orchestrator.run(project: project, serviceName: "job", command: ["true"], remove: true)

        let names = runner.commands.compactMap { $0.arguments.value(after: "--name") }
        #expect(names == ["demo-job-run-first", "demo-job-run-second"])
    }

    @Test("up reuses existing containers when no recreate is requested")
    func upReusesExistingContainersWhenNoRecreateIsRequested() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [.success])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        try await orchestrator.up(project: project, options: ComposeUpOptions(noRecreate: true))

        #expect(runner.commands.map(\.arguments) == [["container", "inspect", "demo-api-1"]])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
    }

    @Test("up reuses existing containers when config hash matches")
    func upReusesExistingContainersWhenConfigHashMatches() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])
        let createRunner = RecordingRunner(responses: [.failure, .success])

        try await ComposeOrchestrator(runner: createRunner).up(project: project, options: ComposeUpOptions())

        let run = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: run))
        let emitted = MessageRecorder()
        let runner = RecordingRunner(responses: [inspectResult(configHash: hash)])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.map(\.arguments) == [["container", "inspect", "demo-api-1"]])
        #expect(emitted.messages == ["compose: reusing existing container demo-api-1"])
    }

    @Test("up recreates existing containers when resource runtime names change")
    func upRecreatesExistingContainersWhenResourceRuntimeNamesChange() async throws {
        let oldProject = projectWithRuntimeResources(networkName: "old-net", volumeName: "old-cache")
        let createRunner = RecordingRunner(responses: [.failure, .success])

        try await ComposeOrchestrator(runner: createRunner).up(project: oldProject, options: ComposeUpOptions())

        let oldRun = try #require(createRunner.commands.last?.arguments)
        let oldHash = try #require(composeConfigHash(in: oldRun))
        let newProject = projectWithRuntimeResources(networkName: "new-net", volumeName: "new-cache")
        let runner = RecordingRunner(responses: [
            inspectResult(configHash: oldHash),
            .success,
            .success,
            .success,
        ])

        try await ComposeOrchestrator(runner: runner).up(project: newProject, options: ComposeUpOptions())

        #expect(runner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(runner.commands[1].arguments == ["container", "stop", "demo-api-1"])
        #expect(runner.commands[2].arguments == ["container", "delete", "demo-api-1"])
        let newRun = runner.commands[3].arguments
        #expect(newRun.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(newRun.containsSequence(["--network", "new-net"]))
        #expect(newRun.containsSequence(["--volume", "new-cache:/cache"]))
        #expect(composeConfigHash(in: newRun) != oldHash)
    }

    @Test("up recreates existing containers when config hash changes")
    func upRecreatesExistingContainersWhenConfigHashChanges() async throws {
        let runner = RecordingRunner(responses: [
            inspectResult(configHash: "stale"),
            .success,
            .success,
            .success,
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.stopSignal = "SIGUSR1"
                    $0.stopGracePeriodSeconds = 9
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())

        #expect(runner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(runner.commands[1].arguments == ["container", "stop", "--signal", "SIGUSR1", "--time", "9", "demo-api-1"])
        #expect(runner.commands[2].arguments == ["container", "delete", "demo-api-1"])
        #expect(runner.commands[3].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(composeConfigHash(in: runner.commands[3].arguments) != "stale")
    }

    @Test("up force recreates existing containers even when config hash matches")
    func upForceRecreatesExistingContainersWhenConfigHashMatches() async throws {
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])
        let createRunner = RecordingRunner(responses: [.failure, .success])

        try await ComposeOrchestrator(runner: createRunner).up(project: project, options: ComposeUpOptions())

        let run = try #require(createRunner.commands.last?.arguments)
        let hash = try #require(composeConfigHash(in: run))
        let runner = RecordingRunner(responses: [
            inspectResult(configHash: hash),
            .success,
            .success,
            .success,
        ])

        try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions(forceRecreate: true))

        #expect(runner.commands[0].arguments == ["container", "inspect", "demo-api-1"])
        #expect(runner.commands[1].arguments == ["container", "stop", "demo-api-1"])
        #expect(runner.commands[2].arguments == ["container", "delete", "demo-api-1"])
        #expect(runner.commands[3].arguments.starts(with: ["container", "run", "--name", "demo-api-1"]))
    }

    @Test("dry run emits quoted commands")
    func dryRunEmitsQuotedCommands() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, containerBinary: "container bin", emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api:latest")])

        try await orchestrator.pull(project: project, services: ["api"])

        #expect(emitted.messages == ["+ 'container bin' image pull example/api:latest"])
    }

    @Test("dry run up does not treat synthetic inspect success as existing container")
    func dryRunUpDoesNotTreatSyntheticInspectSuccessAsExistingContainer() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "alpine")])

        try await orchestrator.up(project: project, options: ComposeUpOptions(noRecreate: true))

        let messages = emitted.messages
        #expect(messages.contains("+ container inspect demo-api-1"))
        #expect(messages.contains { $0.hasPrefix("+ container run ") && !$0.contains("--detach") })
        #expect(!messages.contains("compose: reusing existing container demo-api-1"))
        #expect(!messages.contains { $0.contains("container stop demo-api-1") })
        #expect(!messages.contains { $0.contains("container delete demo-api-1") })
    }

    @Test("dry run pull missing emits inspect and pull plan")
    func dryRunPullMissingEmitsInspectAndPullPlan() async throws {
        let emitted = MessageRecorder()
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        )
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "alpine")])

        try await orchestrator.up(project: project, options: ComposeUpOptions(pullPolicy: "missing"))

        let messages = emitted.messages
        #expect(messages.contains("+ container image inspect alpine"))
        #expect(messages.contains("+ container image pull alpine"))
    }

    @Test("invalid and unsupported projects fail clearly")
    func invalidAndUnsupportedProjectsFailClearly() async throws {
        do {
            try await ComposeOrchestrator().up(project: ComposeProject(name: "", services: [:]), options: ComposeUpOptions())
            Issue.record("Expected empty project name failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("project name is empty"))
        }

        do {
            try await ComposeOrchestrator().exec(project: ComposeProject(name: "demo", services: [:]), serviceName: "missing", command: ["true"], interactive: false, tty: false)
            Issue.record("Expected unknown service failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unknown service 'missing'"))
        }

        do {
            try await ComposeOrchestrator().exec(
                project: ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")]),
                serviceName: "api",
                command: [],
                interactive: false,
                tty: false
            )
            Issue.record("Expected empty exec command failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("exec requires a command"))
        }

        let invalidPullPolicyRunner = RecordingRunner()
        let invalidPullPolicyProject = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }
        do {
            try await ComposeOrchestrator(runner: invalidPullPolicyRunner).up(
                project: invalidPullPolicyProject,
                options: ComposeUpOptions(pullPolicy: "sometimes")
            )
            Issue.record("Expected unsupported pull policy failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unsupported pull policy 'sometimes'"))
        }
        #expect(invalidPullPolicyRunner.commands.isEmpty)

        do {
            try await ComposeOrchestrator().copy(project: ComposeProject(name: "demo", services: [:]), arguments: [])
            Issue.record("Expected cp argument failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("cp requires source and destination"))
        }

        do {
            try await ComposeOrchestrator().copy(
                project: ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")]),
                arguments: ["missing:/tmp/file", "."]
            )
            Issue.record("Expected cp unknown service failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unknown service 'missing'"))
        }

        let unsupportedProjects = [
            ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                $0.networks = ["a", "b"]
            }]),
            ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                $0.extraHosts = ["db:127.0.0.1"]
            }]),
            ComposeProject(name: "demo", services: ["api": composeService(name: "api", image: "example/api") {
                $0.privileged = true
            }]),
        ]

        for project in unsupportedProjects {
            do {
                try await ComposeOrchestrator().up(project: project, options: ComposeUpOptions())
                Issue.record("Expected unsupported runtime feature")
            } catch let error as ComposeError {
                if case .unsupported = error {
                    continue
                } else {
                    Issue.record("Unexpected compose error: \(error)")
                }
            }
        }
    }

    @Test("command failures are surfaced")
    func commandFailuresAreSurfaced() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(status: 4, stdout: "", stderr: ""),
        ])
        let project = ComposeProject(name: "demo", services: ["api": ComposeService(name: "api", image: "example/api")])

        do {
            try await ComposeOrchestrator(runner: runner).pull(project: project, services: ["api"])
            Issue.record("Expected command failure")
        } catch let error as ComposeError {
            #expect(error == .commandFailed(command: "container image pull example/api", status: 4, stderr: ""))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("process runner captures stdout stderr status input env and cwd")
    func processRunnerCapturesProcessDetails() async throws {
        let directory = FileManager.default.temporaryDirectory
        let script = "printf \"%s:%s\" \"$PROCESS_RUNNER_VALUE\" \"$(pwd)\"; cat; printf err >&2"
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", script],
            workingDirectory: directory,
            environment: ["PROCESS_RUNNER_VALUE": "ok"],
            input: Data(" input".utf8)
        )

        #expect(result.succeeded)
        #expect(
            result.stdout == "ok:\(directory.path) input"
                || result.stdout == "ok:/private\(directory.path) input"
        )
        #expect(result.stderr == "err")
    }

    @Test("recording runner captures command environment")
    func recordingRunnerCapturesCommandEnvironment() async throws {
        let runner = RecordingRunner()

        _ = try await runner.run("/usr/bin/env", ["true"], environment: ["SAMPLE": "value"])

        let command = try #require(runner.commands.first)
        #expect(command.environment == ["SAMPLE": "value"])
    }

    @Test("recording runner captures command input")
    func recordingRunnerCapturesCommandInput() async throws {
        let runner = RecordingRunner()
        let input = Data("payload".utf8)

        _ = try await runner.run("/usr/bin/env", ["true"], input: input)

        let command = try #require(runner.commands.first)
        #expect(command.input == input)
    }

    @Test("process runner reports status when inheriting terminal IO")
    func processRunnerReportsStatusWhenInheritingTerminalIO() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", "exit 7"],
            workingDirectory: nil,
            environment: nil,
            io: .inherited
        )

        #expect(result.status == 7)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test("process runner drains large stdout and stderr while process runs")
    func processRunnerDrainsLargeOutputWhileProcessRuns() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            [
                "-c",
                """
                python3 - <<'PY'
                import sys
                sys.stdout.write("o" * 262144)
                sys.stdout.flush()
                sys.stderr.write("e" * 262144)
                sys.stderr.flush()
                PY
                """,
            ]
        )

        #expect(result.succeeded)
        #expect(result.stdout.count == 262_144)
        #expect(result.stderr.count == 262_144)
    }

    @Test("process runner reports nonzero status")
    func processRunnerReportsNonzeroStatus() async throws {
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "printf nope >&2; exit 9"])

        #expect(!result.succeeded)
        #expect(result.status == 9)
        #expect(result.stderr == "nope")
    }
}

private extension CommandResult {
    static let success = CommandResult(status: 0, stdout: "", stderr: "")
    static let failure = CommandResult(status: 1, stdout: "", stderr: "")
}

private let composeConfigHashLabel = "com.apple.container.compose.config-hash"
private let composeProjectLabel = "com.apple.container.compose.project"

private struct UnsupportedRuntimeStringFieldCase: Sendable {
    let composeName: String
    let value: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; \(reason)"
    }
}

private func unsupportedRuntimeStringFieldCases() -> [UnsupportedRuntimeStringFieldCase] {
    [
        UnsupportedRuntimeStringFieldCase(
            composeName: "cgroup",
            value: "host",
            reason: "cgroup namespace support needs an apple/container runtime gap PR",
            configure: { $0.cgroup = "host" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "cgroup_parent",
            value: "m-executor-abcd",
            reason: "cgroup parent support needs an apple/container runtime gap PR",
            configure: { $0.cgroupParent = "m-executor-abcd" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "ipc",
            value: "host",
            reason: "IPC namespace support needs an apple/container runtime gap PR",
            configure: { $0.ipc = "host" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "isolation",
            value: "default",
            reason: "isolation support needs an apple/container runtime gap PR",
            configure: { $0.isolation = "default" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "pid",
            value: "host",
            reason: "PID namespace support needs an apple/container runtime gap PR",
            configure: { $0.pid = "host" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "userns_mode",
            value: "host",
            reason: "user namespace support needs an apple/container runtime gap PR",
            configure: { $0.usernsMode = "host" }
        ),
        UnsupportedRuntimeStringFieldCase(
            composeName: "uts",
            value: "host",
            reason: "UTS namespace support needs an apple/container runtime gap PR",
            configure: { $0.uts = "host" }
        ),
    ]
}

private struct UnsupportedCPUResourceFieldCase: Sendable {
    let composeName: String
    let value: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; advanced CPU resource support needs an apple/container runtime gap PR"
    }
}

private func unsupportedCPUResourceFieldCases() -> [UnsupportedCPUResourceFieldCase] {
    [
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_count",
            value: "2",
            configure: { $0.cpuCount = 2 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_percent",
            value: "12.5",
            configure: { $0.cpuPercent = 12.5 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_period",
            value: "100000",
            configure: { $0.cpuPeriod = 100_000 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_quota",
            value: "50000",
            configure: { $0.cpuQuota = 50_000 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_rt_period",
            value: "950000",
            configure: { $0.cpuRealtimePeriod = 950_000 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_rt_runtime",
            value: "900000",
            configure: { $0.cpuRealtimeRuntime = 900_000 }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpuset",
            value: "0-1",
            configure: { $0.cpuset = "0-1" }
        ),
        UnsupportedCPUResourceFieldCase(
            composeName: "cpu_shares",
            value: "512",
            configure: { $0.cpuShares = 512 }
        ),
    ]
}

private struct UnsupportedMemoryAndProcessResourceFieldCase: Sendable {
    let composeName: String
    let value: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; memory, OOM, and process resource support needs an apple/container runtime gap PR"
    }
}

private func unsupportedMemoryAndProcessResourceFieldCases() -> [UnsupportedMemoryAndProcessResourceFieldCase] {
    [
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "mem_reservation",
            value: "134217728",
            configure: { $0.memReservation = "134217728" }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "memswap_limit",
            value: "268435456",
            configure: { $0.memSwapLimit = "268435456" }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "mem_swappiness",
            value: "60",
            configure: { $0.memSwappiness = "60" }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "oom_kill_disable",
            value: "true",
            configure: { $0.oomKillDisable = true }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "oom_score_adj",
            value: "-500",
            configure: { $0.oomScoreAdj = -500 }
        ),
        UnsupportedMemoryAndProcessResourceFieldCase(
            composeName: "pids_limit",
            value: "128",
            configure: { $0.pidsLimit = 128 }
        ),
    ]
}

private struct UnsupportedUserAndSecurityOptionFieldCase: Sendable {
    let composeName: String
    let value: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName) '\(value)'; \(reason)"
    }
}

private func unsupportedUserAndSecurityOptionFieldCases() -> [UnsupportedUserAndSecurityOptionFieldCase] {
    [
        UnsupportedUserAndSecurityOptionFieldCase(
            composeName: "group_add",
            value: "video",
            reason: "supplemental group support needs an apple/container runtime gap PR",
            configure: { $0.groupAdd = ["video", "staff"] }
        ),
        UnsupportedUserAndSecurityOptionFieldCase(
            composeName: "security_opt",
            value: "label:disable",
            reason: "security option support needs an apple/container runtime gap PR",
            configure: { $0.securityOpt = ["label:disable"] }
        ),
    ]
}

private struct UnsupportedDeviceAccessFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

private func unsupportedDeviceAccessFieldCases() -> [UnsupportedDeviceAccessFieldCase] {
    [
        UnsupportedDeviceAccessFieldCase(
            composeName: "credential_spec",
            reason: "credential spec support needs an apple/container runtime gap PR",
            configure: { $0.credentialSpec = .object(["file": .string("credential-spec.json")]) }
        ),
        UnsupportedDeviceAccessFieldCase(
            composeName: "device_cgroup_rules",
            reason: "device cgroup rule support needs an apple/container runtime gap PR",
            configure: { $0.deviceCgroupRules = ["c 1:3 mr"] }
        ),
        UnsupportedDeviceAccessFieldCase(
            composeName: "devices",
            reason: "host device access support needs an apple/container runtime gap PR",
            configure: {
                $0.devices = [
                    .object([
                        "source": .string("/dev/fuse"),
                        "target": .string("/dev/fuse"),
                        "permissions": .string("rwm"),
                    ]),
                ]
            }
        ),
        UnsupportedDeviceAccessFieldCase(
            composeName: "gpus",
            reason: "GPU device access support needs an apple/container runtime gap PR",
            configure: {
                $0.gpus = [
                    .object([
                        "driver": .string("nvidia"),
                        "capabilities": .array([.string("gpu")]),
                    ]),
                ]
            }
        ),
        UnsupportedDeviceAccessFieldCase(
            composeName: "privileged",
            reason: "privileged mode support needs an apple/container runtime gap PR",
            configure: { $0.privileged = true }
        ),
    ]
}

private struct UnsupportedProviderModelAndHookFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

private func unsupportedProviderModelAndHookFieldCases() -> [UnsupportedProviderModelAndHookFieldCase] {
    [
        UnsupportedProviderModelAndHookFieldCase(
            composeName: "provider",
            reason: "service providers are not implemented by container-compose yet",
            configure: { $0.provider = true }
        ),
        UnsupportedProviderModelAndHookFieldCase(
            composeName: "models",
            reason: "service model bindings are not implemented by container-compose yet",
            configure: { $0.models = true }
        ),
        UnsupportedProviderModelAndHookFieldCase(
            composeName: "post_start",
            reason: "lifecycle hooks are not implemented by container-compose yet",
            configure: { $0.postStart = true }
        ),
        UnsupportedProviderModelAndHookFieldCase(
            composeName: "pre_stop",
            reason: "lifecycle hooks are not implemented by container-compose yet",
            configure: { $0.preStop = true }
        ),
    ]
}

private struct UnsupportedServiceMetadataAndLoggingFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

private func unsupportedServiceMetadataAndLoggingFieldCases() -> [UnsupportedServiceMetadataAndLoggingFieldCase] {
    [
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "annotations",
            reason: "service annotations are not implemented by container-compose yet",
            configure: { $0.annotations = ["com.example.note": "runtime"] }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "attach",
            reason: "service attach behavior is not implemented by container-compose yet",
            configure: { $0.attach = false }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "label_file",
            reason: "label file support is not implemented by container-compose yet",
            configure: { $0.labelFiles = ["./service.labels"] }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "logging",
            reason: "service logging configuration is not implemented by container-compose yet",
            configure: { $0.logging = .object(["driver": .string("json-file")]) }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "log_driver",
            reason: "service logging configuration is not implemented by container-compose yet",
            configure: { $0.logDriver = "json-file" }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "log_opt",
            reason: "service logging configuration is not implemented by container-compose yet",
            configure: { $0.logOptions = ["max-size": "10m"] }
        ),
        UnsupportedServiceMetadataAndLoggingFieldCase(
            composeName: "storage_opt",
            reason: "service storage options are not implemented by container-compose yet",
            configure: { $0.storageOptions = ["size": "1G"] }
        ),
    ]
}

private struct UnsupportedServiceVolumeShortcutFieldCase: Sendable {
    let composeName: String
    let reason: String
    let configure: @Sendable (inout ComposeService) -> Void

    func expectedMessage(serviceName: String) -> String {
        "service '\(serviceName)' uses \(composeName); \(reason)"
    }
}

private func unsupportedServiceVolumeShortcutFieldCases() -> [UnsupportedServiceVolumeShortcutFieldCase] {
    [
        UnsupportedServiceVolumeShortcutFieldCase(
            composeName: "volumes_from",
            reason: "volume inheritance is not implemented by container-compose yet",
            configure: { $0.volumesFrom = ["db:ro"] }
        ),
        UnsupportedServiceVolumeShortcutFieldCase(
            composeName: "volume_driver",
            reason: "service-level volume driver support is not implemented by container-compose yet",
            configure: { $0.volumeDriver = "local" }
        ),
    ]
}

private func inspectResult(configHash: String) -> CommandResult {
    CommandResult(
        status: 0,
        stdout: """
        [
          {
            "id": "demo-api-1",
            "configuration": {
              "labels": {
                "\(composeConfigHashLabel)": "\(configHash)"
              }
            }
          }
        ]
        """,
        stderr: ""
    )
}

private func composeConfigHash(in arguments: [String]) -> String? {
    for index in arguments.indices where arguments[index] == "--label" {
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            continue
        }
        let label = arguments[valueIndex]
        let prefix = "\(composeConfigHashLabel)="
        if label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
    }
    return nil
}

private func containerListResult() -> CommandResult {
    CommandResult(
        status: 0,
        stdout: """
        [
          {
            "id": "demo-api-1",
            "configuration": {
              "labels": {
                "\(composeProjectLabel)": "demo"
              }
            }
          },
          {
            "id": "other-api-1",
            "configuration": {
              "labels": {
                "\(composeProjectLabel)": "other"
              }
            }
          },
          {
            "id": "demo-worker-1",
            "Config": {
              "Labels": {
                "\(composeProjectLabel)": "demo"
              }
            }
          }
        ]
        """,
        stderr: ""
    )
}

private func emptyContainerListResult() -> CommandResult {
    CommandResult(status: 0, stdout: "[]", stderr: "")
}

private struct ListedContainer: Decodable {
    var id: String
}

private func listedContainerIDs(from output: String) throws -> [String] {
    try JSONDecoder().decode([ListedContainer].self, from: Data(output.utf8)).map(\.id)
}

private final class MessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(message)
    }
}

private final class OneOffIdentifierSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? "fallback" : values.removeFirst()
    }
}

private extension Array where Element: Equatable {
    func containsSequence(_ sequence: [Element]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else {
            return false
        }
        return indices.contains { index in
            let end = self.index(index, offsetBy: sequence.count, limitedBy: endIndex)
            guard let end else {
                return false
            }
            return Array(self[index..<end]) == sequence
        }
    }
}

private extension Array where Element == String {
    func value(after option: String) -> String? {
        guard let index = firstIndex(of: option) else {
            return nil
        }
        let valueIndex = self.index(after: index)
        guard valueIndex < endIndex else {
            return nil
        }
        return self[valueIndex]
    }

    func containsLabel(withPrefix prefix: String) -> Bool {
        indices.contains { index in
            self[index] == "--label"
                && self.index(after: index) < endIndex
                && self[self.index(after: index)].hasPrefix(prefix)
        }
    }
}
