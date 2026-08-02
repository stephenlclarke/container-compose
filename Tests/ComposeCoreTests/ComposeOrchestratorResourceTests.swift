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
    @Test("down runs provider service down lifecycle")
    func downRunsProviderServiceDownLifecycle() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[]},"down":{"parameters":[{"name":"name","required":true}]}}
            """, stderr: ""),
            CommandResult(status: 0, stdout: "", stderr: ""),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(type: provider.path, options: ["name": ["db"]])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).down(project: project, options: ComposeDownOptions())

        #expect(runner.commands.map(\.executable) == [provider.path, provider.path])
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
        #expect(runner.commands[1].arguments == [
            "compose",
            "--project-name=demo",
            "down",
            "--name=db",
            "database",
        ])
    }

    @Test("stop runs advertised provider stop lifecycle")
    func stopRunsAdvertisedProviderStopLifecycle() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[]},"down":{"parameters":[]},"stop":{"parameters":[{"name":"name","required":true}]}}
            """, stderr: ""),
            CommandResult(status: 0, stdout: "", stderr: ""),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "database": composeService(name: "database") {
                    $0.provider = ComposeProvider(type: provider.path, options: ["name": ["db"]])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).stop(project: project, services: [])

        #expect(runner.commands.map(\.executable) == [provider.path, provider.path])
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
        #expect(runner.commands[1].arguments == [
            "compose",
            "--project-name=demo",
            "stop",
            "--name=db",
            "database",
        ])
    }

    @Test("stop skips provider service without advertised stop lifecycle")
    func stopSkipsProviderServiceWithoutAdvertisedStopLifecycle() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[]},"down":{"parameters":[]}}
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

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).stop(project: project, services: [])

        #expect(runner.commands.map(\.executable) == [provider.path])
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
    }

    @Test("stop all uses reverse dependency order")
    func stopAllUsesReverseDependencyOrder() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
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
            runner: RecordingRunner(),
            lifecycleManager: lifecycleManager
        ).stop(project: project, services: [])

        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .stop(id: "demo-db-1", signal: nil, timeoutInSeconds: nil),
        ])
    }

    @Test("stop selected service does not include dependencies")
    func stopSelectedServiceDoesNotIncludeDependencies() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
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
            runner: RecordingRunner(),
            lifecycleManager: lifecycleManager
        ).stop(project: project, services: ["api"])

        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
        ])
    }

    @Test("up rejects provider missing required metadata option")
    func upRejectsProviderMissingRequiredMetadataOption() async throws {
        let provider = try temporaryExecutable(name: "example-provider")
        defer {
            try? FileManager.default.removeItem(at: provider.deletingLastPathComponent())
        }
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: """
            {"description":"example","up":{"parameters":[{"name":"name","required":true}]}}
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
            Issue.record("Expected required provider option failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("required parameter 'name' is missing from provider '\(provider.path)' definition"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.map(\.executable) == [provider.path])
        #expect(runner.commands[0].arguments == ["compose", "metadata"])
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

    @Test("up honors service scale before creating resources")
    func upHonorsServiceScaleBeforeCreatingResources() async throws {
        let runner = RecordingRunner(responses: [
            .success,
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].starts(with: ["container", "run", "--name", "demo-api-1", "--detach"]))
        #expect(commands[1].starts(with: ["container", "run", "--name", "demo-api-2", "--detach"]))
        #expect(await discoveryManager.getRequests == ["demo-api-1", "demo-api-2"])
        #expect(await discoveryManager.listRequests == [true, true])
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

    @Test("up sends negotiated logging as a typed in-process request")
    func upSendsNegotiatedLoggingAsTypedRequest() async throws {
        let runner = RecordingRunner()
        let launchManager = RecordingContainerLaunchManager()
        let options = ComposeExecutionOptions {
            $0.runtimeCapabilities = .init(identifiers: [
                "io.github.stephenlclarke.container.logging-drivers.v1",
            ])
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.logging = ComposeLogConfiguration(
                        driver: "splunk",
                        options: [
                            "splunk-token": "protected-value",
                            "splunk-url": "https://127.0.0.1:8088",
                        ],
                    )
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.launchManager = launchManager
        }

        try await ComposeOrchestrator(runner: runner, options: options, dependencies: dependencies)
            .up(project: project, options: ComposeUpOptions())

        #expect(runner.commands.isEmpty)
        let request = try #require(await launchManager.requests.first)
        #expect(request.command == .run)
        #expect(request.logging == ComposeLogConfiguration(
            driver: "splunk",
            options: [
                "splunk-token": "protected-value",
                "splunk-url": "https://127.0.0.1:8088",
            ],
        ))
        #expect(!request.arguments.contains("--log-driver"))
        #expect(!request.arguments.contains("--log-opt"))
        #expect(!request.arguments.contains(where: { $0.contains("protected-value") }))
    }

    @Test("create uses the negotiated typed logging path")
    func createUsesNegotiatedTypedLoggingPath() async throws {
        let runner = RecordingRunner()
        let launchManager = RecordingContainerLaunchManager()
        let options = ComposeExecutionOptions {
            $0.runtimeCapabilities = .init(identifiers: [
                "io.github.stephenlclarke.container.logging-drivers.v1",
            ])
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.logging = ComposeLogConfiguration(
                        driver: "syslog",
                        options: ["syslog-address": "tcp://127.0.0.1:5514"],
                    )
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.launchManager = launchManager
        }

        try await ComposeOrchestrator(runner: runner, options: options, dependencies: dependencies)
            .create(project: project, options: ComposeCreateOptions())

        #expect(runner.commands.isEmpty)
        let request = try #require(await launchManager.requests.first)
        #expect(request.command == .create)
        #expect(request.logging.driver == "syslog")
        #expect(request.logging.options == ["syslog-address": "tcp://127.0.0.1:5514"])
        #expect(!request.arguments.contains("--log-driver"))
        #expect(!request.arguments.contains("--log-opt"))
    }

    @Test("up accepts local logging drivers without options")
    func upAcceptsLocalLoggingDriversWithoutOptions() async throws {
        for testCase in supportedLocalServiceLoggingFieldCases() {
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
                .up(project: project, options: ComposeUpOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "run", "--name", "demo-api-1"]))
            #expect(!command.contains("--log-driver"))
            #expect(!command.contains("--log-opt"))
        }
    }

    @Test("up maps local logging options to runtime policy")
    func upMapsLocalLoggingOptionsToRuntimePolicy() async throws {
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
                .up(project: project, options: ComposeUpOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "run", "--name", "demo-api-1"]))
            #expect(!command.contains("--log-driver"))
            for option in testCase.expectedOptions {
                #expect(command.containsSequence(["--log-opt", option]))
            }
        }
    }

    @Test("up maps disabled logging driver to runtime policy")
    func upMapsDisabledLoggingDriverToRuntimePolicy() async throws {
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
                .up(project: project, options: ComposeUpOptions())

            let command = try #require(runner.commands.first?.arguments)
            #expect(command.starts(with: ["container", "run", "--name", "demo-api-1"]))
            #expect(command.containsSequence(["--log-driver", "none"]))
            #expect(!command.contains("--log-opt"))
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

    @Test("up accepts local service volume driver")
    func upAcceptsLocalServiceVolumeDriver() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumeDriver = "local"
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager(),
            resourceManager: resourceManager
        )
        .up(project: project, options: ComposeUpOptions())

        let volumeRequest = try #require(await resourceManager.requests.compactMap { request -> ComposeVolumeCreateRequest? in
            guard case let .createVolume(volume) = request else {
                return nil
            }
            return volume
        }.first)
        #expect(volumeRequest.name == "demo_cache")
        #expect(volumeRequest.resolvedDriver == "local")
        #expect(volumeRequest.driverOpts == [:])
        #expect(volumeRequest.labels[composeProjectLabel] == "demo")
        let run = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(run.containsSequence(["--volume", "demo_cache:/cache"]))
    }

    @Test("up accepts volume nocopy normalized marker")
    func upAcceptsVolumeNoCopyNormalizedMarker() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            source: "cache",
                            target: "/cache",
                            unsupportedFields: ["volume.nocopy"]
                        ),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions())

        let run = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(run.containsSequence(["--volume", "demo_cache:/cache"]))
    }

    @Test("up creates missing bind sources when create host path is enabled")
    func upCreatesMissingBindSourcesWhenCreateHostPathIsEnabled() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("created")

        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(
                        type: "bind",
                        source: source.path,
                        target: "/data",
                        options: .init(bind: .init(createHostPath: true))
                    )]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions())

        var isDirectory = ObjCBool(false)
        #expect(fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let run = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(run.containsSequence(["--volume", "\(source.path):/data"]))
    }

    @Test("up rejects missing bind sources when create host path is disabled")
    func upRejectsMissingBindSourcesWhenCreateHostPathIsDisabled() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("required")
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(
                        type: "bind",
                        source: source.path,
                        target: "/data",
                        options: .init(bind: .init(createHostPath: false))
                    )]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: runner,
                discoveryManager: RecordingContainerDiscoveryManager(),
                resourceManager: resourceManager
            ).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected missing bind source error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' bind mount source '\(source.path)' does not exist and bind.create_host_path is false"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!fileManager.fileExists(atPath: source.path))
        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up maps bind propagation to volume options")
    func upMapsBindPropagationToVolumeOptions() async throws {
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
                "node-exporter": composeService(name: "node-exporter", image: "example/node-exporter") {
                    $0.volumes = [
                        ComposeMount(
                            type: "bind",
                            source: directory.path,
                            target: "/host",
                            options: .init(readOnly: true, bind: .init(propagation: "rslave"))
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions())

        let run = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(run.containsSequence(["--volume", "\(directory.path):/host:ro,rslave"]))
    }

    @Test("up maps volume subpath to the typed container mount")
    func upMapsVolumeSubpathToTypedContainerMount() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            source: "cache",
                            target: "/cache",
                            options: .init(volume: .init(subpath: "logs/app"))
                        ),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
            .up(project: project, options: ComposeUpOptions())

        let run = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(run.containsSequence(["--mount", "type=volume,source=demo_cache,destination=/cache,volume-subpath=logs/app"]))
    }

    @Test("up maps image mounts to the typed read-only container mount")
    func upMapsImageMountToTypedContainerMount() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(
                            type: "image",
                            source: "alpine:3.20",
                            target: "/assets",
                            options: .init(imageSubpath: "etc")
                        ),
                    ]
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions())

        let run = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(run.containsSequence([
            "--mount",
            "type=image,source=alpine:3.20,destination=/assets,readonly,image-subpath=etc",
        ]))
    }

    @Test("up rejects image subpaths on non-image mounts")
    func upRejectsImageSubpathOnNonImageMount() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            source: "cache",
                            target: "/cache",
                            options: .init(imageSubpath: "etc")
                        ),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid image subpath error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("image subpath is only supported for image mounts"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects a legacy unsupported volume subpath marker")
    func upRejectsLegacyUnsupportedVolumeSubpathMarker() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            source: "cache",
                            target: "/cache",
                            unsupportedFields: ["volume.subpath"]
                        ),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported legacy volume subpath marker")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses unsupported volume fields volume.subpath; advanced service volume options need an apple/container mount primitive gap PR"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up inherits declared volumes from same-project services")
    func upInheritsDeclaredVolumesFromSameProjectServices() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "base": composeService(name: "base", image: "example/base") {
                    $0.volumes = [
                        ComposeMount(type: "volume", source: "data", target: "/data"),
                        ComposeMount(type: "bind", source: "./seed", target: "/seed"),
                    ]
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["base:ro"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = [
                "cache": ComposeVolume(name: "cache"),
                "data": ComposeVolume(name: "data"),
            ]
        }

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["worker"]
            })

        let commands = runner.commands.map(\.arguments)
        let baseRun = try #require(commands.first { $0.containsSequence(["--name", "demo-base-1"]) })
        let workerRun = try #require(commands.first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let baseIndex = try #require(commands.firstIndex(of: baseRun))
        let workerIndex = try #require(commands.firstIndex(of: workerRun))
        #expect(baseIndex < workerIndex)
        #expect(baseRun.containsSequence(["--volume", "demo_data:/data"]))
        #expect(baseRun.containsSequence(["--volume", "./seed:/seed"]))
        #expect(workerRun.containsSequence(["--volume", "demo_data:/data:ro"]))
        #expect(workerRun.containsSequence(["--volume", "./seed:/seed:ro"]))
        #expect(workerRun.containsSequence(["--volume", "demo_cache:/cache"]))
    }

    @Test("up applies volumes_from read-write overrides")
    func upAppliesVolumesFromReadWriteOverrides() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "base": composeService(name: "base", image: "example/base") {
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/data", readOnly: true)]
                },
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["base:rw"]
                },
            ]
        ) {
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await ComposeOrchestrator(runner: runner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: project, options: ComposeUpOptions {
                $0.services = ["worker"]
            })

        let workerRun = try #require(runner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        #expect(workerRun.containsSequence(["--volume", "demo_data:/data"]))
        #expect(!workerRun.containsSequence(["--volume", "demo_data:/data:ro"]))
    }

    @Test("up config hash includes inherited volumes")
    func upConfigHashIncludesInheritedVolumes() async throws {
        let baselineRunner = RecordingRunner()
        let baseline = composeProjectWithInheritedVolume(target: "/data")
        try await ComposeOrchestrator(runner: baselineRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: baseline, options: ComposeUpOptions {
                $0.services = ["worker"]
                $0.noStart = true
            })
        let baselineWorkerCreate = try #require(baselineRunner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let baselineHash = try #require(composeConfigHash(in: baselineWorkerCreate))

        let changedRunner = RecordingRunner()
        let changed = composeProjectWithInheritedVolume(target: "/state")
        try await ComposeOrchestrator(runner: changedRunner, discoveryManager: RecordingContainerDiscoveryManager())
            .up(project: changed, options: ComposeUpOptions {
                $0.services = ["worker"]
                $0.noStart = true
            })
        let changedWorkerCreate = try #require(changedRunner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let changedHash = try #require(composeConfigHash(in: changedWorkerCreate))

        #expect(baselineHash != changedHash)
    }

    @Test("up config hash includes external inherited volumes")
    func upConfigHashIncludesExternalInheritedVolumes() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["container:legacy"]
                },
            ]
        )

        let baselineRunner = RecordingRunner()
        try await ComposeOrchestrator(
            runner: baselineRunner,
            discoveryManager: RecordingContainerDiscoveryManager(containers: [
                ComposeContainerSummary(
                    id: "legacy",
                    status: "running",
                    mounts: [ComposeMount(type: "external-volume", source: "legacy_data", target: "/data")]
                ),
            ])
        ).up(project: project, options: ComposeUpOptions {
            $0.noStart = true
        })
        let baselineCreate = try #require(baselineRunner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let baselineHash = try #require(composeConfigHash(in: baselineCreate))

        let changedRunner = RecordingRunner()
        try await ComposeOrchestrator(
            runner: changedRunner,
            discoveryManager: RecordingContainerDiscoveryManager(containers: [
                ComposeContainerSummary(
                    id: "legacy",
                    status: "running",
                    mounts: [ComposeMount(type: "external-volume", source: "legacy_state", target: "/state")]
                ),
            ])
        ).up(project: project, options: ComposeUpOptions {
            $0.noStart = true
        })
        let changedCreate = try #require(changedRunner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        let changedHash = try #require(composeConfigHash(in: changedCreate))

        #expect(baselineHash != changedHash)
    }

    @Test("up inherits external container volumes from direct inspect")
    func upInheritsExternalContainerVolumesFromDirectInspect() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy",
                status: "running",
                mounts: [
                    ComposeMount(
                        type: "external-volume",
                        source: "legacy_data",
                        target: "/data",
                        options: .init(volume: .init(subpath: "logs/app"))
                    ),
                    ComposeMount(type: "bind", source: "/host/seed", target: "/seed", readOnly: true),
                    ComposeMount(type: "tmpfs", target: "/scratch"),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["container:legacy:ro"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager)
            .up(project: project, options: ComposeUpOptions())

        #expect(await discoveryManager.getRequests.contains("legacy"))
        let workerRun = try #require(runner.commands.map(\.arguments).first { $0.containsSequence(["--name", "demo-worker-1"]) })
        #expect(workerRun.containsSequence(["--mount", "type=volume,source=legacy_data,destination=/data,volume-subpath=logs/app,readonly"]))
        #expect(workerRun.containsSequence(["--volume", "/host/seed:/seed:ro"]))
        #expect(workerRun.containsSequence(["--mount", "type=tmpfs,destination=/scratch,readonly"]))
        #expect(workerRun.containsSequence(["--volume", "demo_cache:/cache"]))
    }

    @Test("up rejects missing external container volumes_from before creating resources")
    func upRejectsMissingExternalContainerVolumesFromBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["container:legacy:ro"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected missing external volumes_from error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'worker' volumes_from 'container:legacy:ro' references missing external container 'legacy'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects unsupported external container volume mounts before creating resources")
    func upRejectsUnsupportedExternalContainerVolumeMountsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "legacy",
                status: "running",
                mounts: [
                    ComposeMount(
                        type: "block",
                        source: "/tmp/disk.img",
                        target: "/disk",
                        unsupportedFields: ["apple.container.block"]
                    ),
                ]
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker", image: "example/worker") {
                    $0.volumesFrom = ["container:legacy:ro"]
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner, discoveryManager: discoveryManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported external volume mount error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'worker' uses volumes_from 'container:legacy:ro'; external container 'legacy' has unsupported mount fields apple.container.block"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
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
            #expect(error == .unsupported("service 'api' uses use_api_socket; Docker-compatible API socket and credential handoff need an apple/container runtime boundary"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps service MAC address to single network attachment")
    func upMapsServiceMACAddressToSingleNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.macAddress = "02:42:ac:11:00:03"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        )
        .up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend,mac=02:42:ac:11:00:03"]))
    }

    @Test("up maps per-network MAC address to single network attachment")
    func upMapsPerNetworkMACAddressToSingleNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
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
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        )
        .up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend,mac=02:42:ac:11:00:04"]))
    }

    @Test("up maps supported network MTU option to single network attachment")
    func upMapsSupportedNetworkMTUOptionToSingleNetworkAttachment() async throws {
        let runner = RecordingRunner(responses: [
            .success,
        ])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            driverOpts: ["com.docker.network.driver.mtu": "1450"],
                            addressing: .init(macAddress: "02:42:ac:11:00:04")
                        ),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        )
        .up(project: project, options: ComposeUpOptions())

        let commands = runner.commands.map(\.arguments)
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend"])
        #expect(commands.count == 1)
        #expect(commands[0].containsSequence(["--network", "demo_backend,mac=02:42:ac:11:00:04,mtu=1450"]))
    }

    @Test("up rejects invalid network MTU before creating resources")
    func upRejectsInvalidNetworkMTUBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(driverOpts: ["com.docker.network.driver.mtu": "fast"]),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid network MTU error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("network MTU driver option 'com.docker.network.driver.mtu' must be a positive integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects interface names that could inject runtime attachment options")
    func upRejectsDelimitedInterfaceNamesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(interfaceName: "eth0,alias=unexpected"),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid interface_name error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' interface_name 'eth0,alias=unexpected' cannot contain ','"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects delimited link-local IPs before creating resources")
    func upRejectsDelimitedLinkLocalIPsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            addressing: .init(linkLocalIPs: ["169.254.1.5,address=unexpected"])
                        ),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid link_local_ips error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "service 'api' link_local_ips value '169.254.1.5,address=unexpected' cannot contain ','"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects unspecified link-local IPs before creating resources")
    func upRejectsUnspecifiedLinkLocalIPsBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            addressing: .init(linkLocalIPs: ["::"])
                        ),
                    ]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid link_local_ips error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "service 'api' link_local_ips value '::' must not be unspecified"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects static IPv4 addresses outside IPAM before creating resources")
    func upRejectsStaticIPv4OutsideIPAMBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(addressing: .init(ipv4Address: "172.29.0.10")),
                    ]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(subnets: .init(ipv4Subnet: "172.28.0.0/16"))
                ),
            ]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid ipv4_address error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "service 'api' ipv4_address '172.29.0.10' is not an allocatable host address in network 'backend'"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects delimited static IPv4 addresses before creating resources")
    func upRejectsDelimitedStaticIPv4BeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.networks = ["backend"]
                    $0.networkOptions = [
                        "backend": ComposeNetworkOptions(
                            addressing: .init(ipv4Address: "172.28.0.10,address=unexpected")
                        ),
                    ]
                },
            ]
        ) {
            $0.networks = [
                "backend": ComposeNetwork(
                    name: "backend",
                    options: .init(subnets: .init(ipv4Subnet: "172.28.0.0/16"))
                ),
            ]
        }

        do {
            try await ComposeOrchestrator(runner: runner, resourceManager: resourceManager)
                .up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid ipv4_address error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject(
                "service 'api' ipv4_address '172.28.0.10,address=unexpected' cannot contain ','"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up rejects MAC address without a network before creating resources")
    func upRejectsMACAddressWithoutNetworkBeforeCreatingResources() async throws {
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
            #expect(error == .unsupported("service 'api' uses mac_address; MAC address support requires a Compose network"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps disabled healthchecks to container flags")
    func upMapsDisabledHealthchecksToContainerFlags() async throws {
        let runner = RecordingRunner()
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
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

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(command.starts(with: ["container", "run", "--name", "demo-api-1"]))
        #expect(command.contains("--no-healthcheck"))
    }

    @Test("up maps inherited image healthchecks to container flags")
    func upMapsInheritedImageHealthchecksToContainerFlags() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(healthChecks: [
            "example/api": ComposeImageHealthCheck(
                test: ["CMD-SHELL", "curl -fsS http://localhost/health || exit 1"],
                intervalInNanoseconds: 30_000_000_000,
                timeoutInNanoseconds: 3_000_000_000,
                startPeriodInNanoseconds: 10_000_000_000,
                startIntervalInNanoseconds: 1_500_000_000,
                retries: 4
            ),
        ])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
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

        try await ComposeOrchestrator(
            runner: runner,
            imageManager: imageManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(await imageManager.requests == [.healthCheck(reference: "example/api", platform: nil)])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
        #expect(command.containsSequence(["--health-cmd", "curl -fsS http://localhost/health || exit 1"]))
        #expect(command.containsSequence(["--health-interval", "30s"]))
        #expect(command.containsSequence(["--health-timeout", "3s"]))
        #expect(command.containsSequence(["--health-start-period", "10s"]))
        #expect(command.containsSequence(["--health-start-interval", "1.5s"]))
        #expect(command.containsSequence(["--health-retries", "4"]))
    }

    @Test("up initializes implicit image volumes before creating a container")
    func upInitializesImplicitImageVolumesBeforeCreatingContainer() async throws {
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
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains { $0.hasPrefix("demo_anon-api-1-") && $0.hasSuffix(":/image-data") })
        #expect(
            await imageManager.requests == [
                .healthCheck(reference: "example/api", platform: nil),
                .volumeTargets(reference: "example/api", platform: nil),
            ]
        )
        let request = try #require((await initializer.requests).first)
        #expect(request.image == "example/api")
        #expect(request.imageSubpath == "/image-data")
        #expect(request.volumeName.hasPrefix("demo_anon-api-1-"))
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", request.volumeName])
    }

    @Test("up accepts no-copy volumes that mask image volume targets")
    func upAcceptsNoCopyVolumesThatMaskImageVolumeTargets() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(imageVolumeTargets: [
            "example/api": ["/image-data"],
        ])
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(
                            type: "volume",
                            source: "cache",
                            target: "/image-data",
                            unsupportedFields: ["volume.nocopy"],
                        ),
                    ]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            imageManager: imageManager,
            resourceManager: resourceManager,
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(
            await imageManager.requests == [
                .healthCheck(reference: "example/api", platform: nil),
                .volumeTargets(reference: "example/api", platform: nil),
            ]
        )
        #expect(await resourceManager.requests.map(\.name) == ["demo_cache"])
        #expect(command.containsSequence(["--volume", "demo_cache:/image-data"]))
    }

    @Test("up preserves Docker no-copy behavior for an image volume subpath")
    func upSkipsImageInitializationWhenVolumeUsesSubpath() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(imageVolumeTargets: [
            "example/api": ["/image-data"],
        ])
        let initializer = RecordingContainerImageVolumeInitializer()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(
                        type: "volume",
                        source: "cache",
                        target: "/image-data",
                        options: .init(volume: .init(subpath: "nested")),
                    )]
                },
            ]
        ) {
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.imageVolumeInitializer = initializer
            },
        ).up(project: project, options: ComposeUpOptions())

        #expect(await initializer.requests.isEmpty)
        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence([
            "--mount",
            "type=volume,source=demo_cache,destination=/image-data,volume-subpath=nested",
        ]))
    }

    @Test("up initializes a named image volume from its mount destination")
    func upInitializesNamedImageVolumeFromItsMountDestination() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(imageVolumeTargets: [
            "example/api": ["/data/cache"],
        ])
        let initializer = RecordingContainerImageVolumeInitializer()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/data")]
                },
            ]
        ) {
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.imageVolumeInitializer = initializer
            },
        ).up(project: project, options: ComposeUpOptions())

        #expect(await initializer.requests == [ComposeImageVolumeInitializationRequest(
            image: "example/api",
            imageSubpath: "/data",
            volumeName: "demo_data",
        )])
    }

    @Test("up initializes a named local volume from a generic image path")
    func upInitializesNamedGenericImageVolumeFromItsMountDestination() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let initializer = RecordingContainerImageVolumeInitializer()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(type: "volume", source: "data", target: "/generic-data")]
                },
            ]
        ) {
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.imageVolumeInitializer = initializer
                $0.resourceManager = resourceManager
            },
        ).up(project: project, options: ComposeUpOptions())

        #expect(await initializer.requests == [ComposeImageVolumeInitializationRequest(
            image: "example/api",
            imageSubpath: "/generic-data",
            volumeName: "demo_data",
        )])
        #expect(await resourceManager.requests.map(\.name) == ["demo_data"])
        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--volume", "demo_data:/generic-data"]))
    }

    @Test("up creates and initializes an anonymous local volume from a generic image path")
    func upInitializesAnonymousGenericImageVolumeFromItsMountDestination() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let initializer = RecordingContainerImageVolumeInitializer()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(type: "volume", target: "/generic-data")]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.imageVolumeInitializer = initializer
                $0.resourceManager = resourceManager
            },
        ).up(project: project, options: ComposeUpOptions())

        let request = try #require((await initializer.requests).first)
        #expect(request.image == "example/api")
        #expect(request.imageSubpath == "/generic-data")
        #expect(request.volumeName.hasPrefix("demo_anon-api-1-"))
        #expect(await resourceManager.requests.map(\.name) == [request.volumeName])
        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--volume", "\(request.volumeName):/generic-data"]))
    }

    @Test("up preserves Docker no-copy behavior for a generic volume path")
    func upSkipsGenericImageInitializationWhenVolumeUsesNoCopy() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let initializer = RecordingContainerImageVolumeInitializer()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(
                        type: "volume",
                        source: "data",
                        target: "/generic-data",
                        unsupportedFields: ["volume.nocopy"],
                    )]
                },
            ]
        ) {
            $0.volumes = ["data": ComposeVolume(name: "data")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.imageVolumeInitializer = initializer
                $0.resourceManager = resourceManager
            },
        ).up(project: project, options: ComposeUpOptions())

        #expect(await initializer.requests.isEmpty)
        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--volume", "demo_data:/generic-data"]))
    }

    @Test("up initializes a volume inherited from an external container")
    func upInitializesExternalContainerVolumeFromItsMountDestination() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(imageVolumeTargets: [
            "example/api": ["/data"],
        ])
        let initializer = RecordingContainerImageVolumeInitializer()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [ComposeMount(
                        type: "external-volume",
                        source: "legacy_data",
                        target: "/data",
                    )]
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
                $0.imageVolumeInitializer = initializer
            },
        ).up(project: project, options: ComposeUpOptions())

        #expect(await initializer.requests == [ComposeImageVolumeInitializationRequest(
            image: "example/api",
            imageSubpath: "/data",
            volumeName: "legacy_data",
        )])
        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--volume", "legacy_data:/data"]))
    }

    @Test("up accepts bind tmpfs and image masks for image volume targets")
    func upAcceptsNonCopyUpMasksForImageVolumeTargets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(imageVolumeTargets: [
            "example/api": ["/bind/cache", "/tmpfs/cache", "/image/cache"],
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.volumes = [
                        ComposeMount(type: "bind", source: directory.path, target: "/bind"),
                        ComposeMount(type: "tmpfs", target: "/tmpfs"),
                        ComposeMount(type: "image", source: "alpine:3.22", target: "/image"),
                    ]
                },
            ],
        )

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(
            await imageManager.requests == [
                .healthCheck(reference: "example/api", platform: nil),
                .volumeTargets(reference: "example/api", platform: nil),
            ]
        )
        #expect(command.containsSequence(["--volume", "\(directory.path):/bind"]))
        #expect(command.containsSequence(["--tmpfs", "/tmpfs"]))
        #expect(
            command.containsSequence([
                "--mount", "type=image,source=alpine:3.22,destination=/image,readonly",
            ])
        )
    }

    @Test("up merges timing-only healthcheck overrides with image metadata")
    func upMergesTimingOnlyHealthcheckOverridesWithImageMetadata() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager(healthChecks: [
            "example/api": ComposeImageHealthCheck(
                test: ["CMD", "/usr/local/bin/health"],
                intervalInNanoseconds: 30_000_000_000,
                timeoutInNanoseconds: 3_000_000_000,
                retries: 4
            ),
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.healthcheck = .object([
                        "interval": .string("5s"),
                        "retries": .number(2),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager)
            .up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(await imageManager.requests == [.healthCheck(reference: "example/api", platform: nil)])
        #expect(command.containsSequence(["--health-cmd", "/usr/local/bin/health"]))
        #expect(command.containsSequence(["--health-interval", "5s"]))
        #expect(command.containsSequence(["--health-timeout", "3s"]))
        #expect(command.containsSequence(["--health-retries", "2"]))
        #expect(!command.containsSequence(["--health-interval", "30s"]))
        #expect(!command.containsSequence(["--health-retries", "4"]))
    }

    @Test("up rejects timing-only healthchecks without image metadata before creating resources")
    func upRejectsTimingOnlyHealthchecksWithoutImageMetadataBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.healthcheck = .object(["interval": .string("5s")])
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        do {
            try await ComposeOrchestrator(
                runner: runner,
                imageManager: imageManager,
                resourceManager: resourceManager
            ).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected unsupported inherited healthcheck error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' tunes an image healthcheck, but image 'example/api' does not expose Dockerfile HEALTHCHECK metadata"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
        #expect(await imageManager.requests == [.healthCheck(reference: "example/api", platform: nil)])
        #expect(await resourceManager.requests.isEmpty)
    }

    @Test("up maps file-backed configs and secrets to read-only bind mounts")
    func upMapsFileBackedConfigsAndSecretsToReadOnlyBindMounts() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let config = directory.appendingPathComponent("app.conf")
        let otherConfig = directory.appendingPathComponent("other.conf")
        let secret = directory.appendingPathComponent("token.txt")
        let otherSecret = directory.appendingPathComponent("other-token.txt")
        try Data("config\n".utf8).write(to: config)
        try Data("other-config\n".utf8).write(to: otherConfig)
        try Data("secret\n".utf8).write(to: secret)
        try Data("other-secret\n".utf8).write(to: otherSecret)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [
                        .object(["source": .string("app_config"), "uid": .string("103"), "gid": .string("104")]),
                        .object(["source": .string("other_config"), "target": .string("/etc/other.conf")]),
                    ]
                    $0.secrets = [
                        .object(["source": .string("app_secret")]),
                        .object(["source": .string("other_secret"), "target": .string("custom-token")]),
                    ]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.configs = [
                "app_config": .object(["file": .string("app.conf")]),
                "other_config": .object(["file": .string(otherConfig.path)]),
            ]
            $0.secrets = [
                "app_secret": .object(["file": .string(secret.path)]),
                "other_secret": .object(["file": .string(otherSecret.path)]),
            ]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["--volume", "\(config.path):/app_config:ro"]))
        #expect(command.containsSequence(["--volume", "\(otherConfig.path):/etc/other.conf:ro"]))
        #expect(command.containsSequence(["--volume", "\(secret.path):/run/secrets/app_secret:ro"]))
        #expect(command.containsSequence(["--volume", "\(otherSecret.path):/run/secrets/custom-token:ro"]))
        #expect(!command.contains("--mount"))
    }

    @Test("up does not create missing file-backed config sources")
    func upDoesNotCreateMissingFileBackedConfigSources() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let config = directory.appendingPathComponent("missing.conf")
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.configs = ["app_config": .object(["file": .string("missing.conf")])]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: RecordingContainerDiscoveryManager()
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        #expect(!FileManager.default.fileExists(atPath: config.path))
        #expect(command.containsSequence(["--volume", "\(config.path):/etc/app.conf:ro"]))
    }

    @Test("up materializes inline configs and environment backed secrets")
    func upMaterializesInlineConfigsAndEnvironmentBackedSecrets() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let configEnvironment = "COMPOSE_CONFIG_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let secretEnvironment = "COMPOSE_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(configEnvironment, "from environment\n", 1)
        setenv(secretEnvironment, "super-secret", 1)
        defer {
            unsetenv(configEnvironment)
            unsetenv(secretEnvironment)
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [
                        .object(["source": .string("inline_config"), "target": .string("/etc/inline.conf"), "mode": .string("0555")]),
                        .object(["source": .string("env_config"), "target": .string("env.conf"), "mode": .string("0666")]),
                    ]
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("runtime-token"), "mode": .string("0440")])]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.composeFiles = [directory.appendingPathComponent("compose.yaml").path]
            $0.configs = [
                "inline_config": .object(["content": .string("inline config\n")]),
                "env_config": .object(["environment": .string(configEnvironment)]),
            ]
            $0.secrets = ["app_secret": .object(["environment": .string(secretEnvironment)])]
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(materializedConfigSecretDirectory: directory.appendingPathComponent("state", isDirectory: true)),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = RecordingContainerDiscoveryManager()
            }
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        let inlineConfig = try #require(orchestratorReadOnlyVolumeSource(target: "/etc/inline.conf", in: command))
        let environmentConfig = try #require(orchestratorReadOnlyVolumeSource(target: "/env.conf", in: command))
        let secret = try #require(orchestratorReadOnlyVolumeSource(target: "/run/secrets/runtime-token", in: command))
        #expect(try String(contentsOfFile: inlineConfig, encoding: .utf8) == "inline config\n")
        #expect(try String(contentsOfFile: environmentConfig, encoding: .utf8) == "from environment\n")
        #expect(try String(contentsOfFile: secret, encoding: .utf8) == "super-secret")
        #expect(try orchestratorPosixPermissions(at: inlineConfig) == 0o555)
        #expect(try orchestratorPosixPermissions(at: environmentConfig) == 0o444)
        #expect(try orchestratorPosixPermissions(at: secret) == 0o440)
    }

    @Test("down removes materialized config and secret files")
    func downRemovesMaterializedConfigAndSecretFiles() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let stateRoot = directory.appendingPathComponent("state", isDirectory: true)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("inline_config"), "target": .string("/etc/inline.conf")])]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.configs = ["inline_config": .object(["content": .string("inline config\n")])]
        }
        let lifecycleManager = RecordingContainerLifecycleManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(materializedConfigSecretDirectory: stateRoot),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = RecordingContainerDiscoveryManager()
                $0.lifecycleManager = lifecycleManager
            }
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        let inlineConfig = try #require(orchestratorReadOnlyVolumeSource(target: "/etc/inline.conf", in: command))
        #expect(FileManager.default.fileExists(atPath: inlineConfig))

        try await orchestrator.down(project: project, options: ComposeDownOptions())

        #expect(!FileManager.default.fileExists(atPath: inlineConfig))
        let remainingEntries = (try? FileManager.default.contentsOfDirectory(atPath: stateRoot.path)) ?? []
        #expect(remainingEntries.isEmpty)
        #expect(await lifecycleManager.requests == [
            .stop(id: "demo-api-1", signal: nil, timeoutInSeconds: nil),
            .delete(id: "demo-api-1", force: false),
        ])
    }

    @Test("up dry run does not materialize inline configs")
    func upDryRunDoesNotMaterializeInlineConfigs() async throws {
        let emitted = LockedStringRecorder()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let stateRoot = directory.appendingPathComponent("state", isDirectory: true)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("inline_config"), "target": .string("/etc/inline.conf")])]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.configs = ["inline_config": .object(["content": .string("inline config\n")])]
        }

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(
                dryRun: true,
                materializedConfigSecretDirectory: stateRoot,
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(emit: emitted.append)
            )
        ).up(project: project, options: ComposeUpOptions())

        #expect(!FileManager.default.fileExists(atPath: stateRoot.path))
        #expect(emitted.snapshot.contains { $0.contains("--volume") && $0.contains(":/etc/inline.conf:ro") })
    }

    @Test("up maps generated config ownership to an owned file snapshot")
    func upMapsGeneratedConfigOwnershipToOwnedFileSnapshot() async throws {
        let runner = RecordingRunner()
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("inline_config"), "target": .string("/etc/inline.conf"), "uid": .string("103"), "gid": .string("104")])]
                },
            ]
        ) {
            $0.workingDirectory = directory.path
            $0.configs = ["inline_config": .object(["content": .string("inline config\n")])]
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(materializedConfigSecretDirectory: directory.appendingPathComponent("state", isDirectory: true)),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = RecordingContainerDiscoveryManager()
            }
        ).up(project: project, options: ComposeUpOptions())

        let command = try #require(runner.commands.first?.arguments)
        let mount = try #require(command.value(after: "--mount"))
        let fields: [String: String] = Dictionary(uniqueKeysWithValues: mount.split(separator: ",").compactMap { field in
            let components = field.split(separator: "=", maxSplits: 1)
            guard components.count == 2 else {
                return nil
            }
            return (String(components[0]), String(components[1]))
        })
        let source = try #require(fields["source"])
        #expect(fields["type"] == "bind")
        #expect(fields["destination"] == "/etc/inline.conf")
        #expect(mount.contains("readonly"))
        #expect(fields["uid"] == "103")
        #expect(fields["gid"] == "104")
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "inline config\n")
    }

    @Test("up rejects invalid generated config ownership before creating resources")
    func upRejectsInvalidGeneratedConfigOwnershipBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.configs = [.object(["source": .string("inline_config"), "uid": .string("-1")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.configs = ["inline_config": .object(["content": .string("inline config\n")])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid generated config ownership to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' config 'inline_config' uid '-1' must be an unsigned 32-bit integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects invalid generated secret mode before creating resources")
    func upRejectsInvalidGeneratedSecretModeBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let secretEnvironment = "BAD_MODE_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(secretEnvironment, "secret", 1)
        defer {
            unsetenv(secretEnvironment)
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.secrets = [.object(["source": .string("app_secret"), "target": .string("runtime-token"), "mode": .string("0999")])]
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
            $0.secrets = ["app_secret": .object(["environment": .string(secretEnvironment)])]
        }

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected invalid generated secret mode to fail")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' secret 'app_secret' mode '0999' must be an octal file mode between 0000 and 0777"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps service restart policies to container create flags")
    func upMapsServiceRestartPoliciesToContainerCreateFlags() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
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

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.contains("--restart"))
        #expect(runArguments.contains("unless-stopped"))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("up maps deploy restart policy to container create flags")
    func upMapsDeployRestartPolicyToContainerCreateFlags() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "on-failure",
                        maxAttempts: 3
                    )
                    $0.restart = "unless-stopped"
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.contains("--restart"))
        #expect(runArguments.contains("on-failure:3"))
        #expect(!runArguments.contains("unless-stopped"))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("up maps deploy restart max attempts zero to unlimited on failure")
    func upMapsDeployRestartMaxAttemptsZeroToUnlimitedOnFailure() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "on-failure",
                        maxAttempts: 0
                    )
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.containsSequence(["--restart", "on-failure"]))
        #expect(!runArguments.contains("on-failure:0"))
    }

    @Test("up rejects deploy job restart policy")
    func upRejectsDeployJobRestartPolicy() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "any",
                        maxAttempts: 3
                    )
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected deploy job restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'migrate' uses deploy.restart_policy with deploy.mode 'replicated-job'; job restart policies need a restart-aware apple/container wait primitive"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects service restart policies for deploy jobs")
    func upRejectsServiceRestartPoliciesForDeployJobs() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.restart = "always"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected deploy job restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'migrate' uses restart policy 'always' with deploy.mode 'replicated-job'; job restart policies need a restart-aware apple/container wait primitive"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up rejects on-failure service restart policies for deploy jobs")
    func upRejectsOnFailureServiceRestartPoliciesForDeployJobs() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.restart = "on-failure:3"
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).up(project: project, options: ComposeUpOptions())
            Issue.record("Expected deploy job restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'migrate' uses restart policy 'on-failure:3' with deploy.mode 'replicated-job'; job restart policies need a restart-aware apple/container wait primitive"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up allows service restart none for deploy jobs")
    func upAllowsServiceRestartNoneForDeployJobs() async throws {
        let runner = RecordingRunner(responses: [.success])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-migrate-1": 0])
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.restart = "no"
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.containsSequence(["--restart", "no"]))
        #expect(await lifecycleManager.requests == [.wait(id: "demo-migrate-1")])
    }

    @Test("up allows deploy restart policy none for deploy jobs")
    func upAllowsDeployRestartPolicyNoneForDeployJobs() async throws {
        let runner = RecordingRunner(responses: [.success])
        let lifecycleManager = RecordingContainerLifecycleManager(waitExitCodes: ["demo-migrate-1": 0])
        let project = composeProject(
            name: "demo",
            services: [
                "migrate": composeService(name: "migrate", image: "example/migrate") {
                    $0.deployMode = "replicated-job"
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(condition: "none")
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            lifecycleManager: lifecycleManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.containsSequence(["--restart", "no"]))
        #expect(await lifecycleManager.requests == [.wait(id: "demo-migrate-1")])
    }

    @Test("up rejects invalid restart policies before creating resources")
    func upRejectsInvalidRestartPoliciesBeforeCreatingResources() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.restart = "sometimes"
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
            Issue.record("Expected invalid restart policy error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses restart policy 'sometimes'; supported values are no, always, on-failure[:max-retries], and unless-stopped"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("up maps deploy restart timing to container create flags")
    func upMapsDeployRestartTimingToContainerCreateFlags() async throws {
        let runner = RecordingRunner(responses: [.success])
        let discoveryManager = RecordingContainerDiscoveryManager()
        let resourceManager = RecordingContainerResourceManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "on-failure",
                        delayNanoseconds: 1_500_000_000,
                        maxAttempts: 3,
                        windowNanoseconds: 50_000_000
                    )
                    $0.networks = ["backend"]
                    $0.volumes = [ComposeMount(type: "volume", source: "cache", target: "/cache")]
                },
            ]
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
            $0.volumes = ["cache": ComposeVolume(name: "cache")]
        }

        try await ComposeOrchestrator(
            runner: runner,
            discoveryManager: discoveryManager,
            resourceManager: resourceManager
        ).up(project: project, options: ComposeUpOptions())

        let runArguments = try #require(runner.commands.map(\.arguments).first { $0.starts(with: ["container", "run"]) })
        #expect(runArguments.contains("--restart"))
        #expect(runArguments.contains("on-failure:3"))
        #expect(runArguments.contains("--restart-delay"))
        #expect(runArguments.contains("1.5s"))
        #expect(runArguments.contains("--restart-window"))
        #expect(runArguments.contains("0.05s"))
        #expect(await discoveryManager.getRequests == ["demo-api-1"])
        #expect(await resourceManager.requests.map(\.name) == ["demo_backend", "demo_cache"])
    }

    @Test("up rejects deploy restart max attempts without on-failure")
    func upRejectsDeployRestartMaxAttemptsWithoutOnFailure() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.deployRestartPolicy = ComposeDeployRestartPolicy(
                        condition: "any",
                        maxAttempts: 3
                    )
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
            Issue.record("Expected deploy restart max attempts error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses deploy.restart_policy.max_attempts with condition 'any'; apple/container retry limits are only available for on-failure restart policies"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

}
