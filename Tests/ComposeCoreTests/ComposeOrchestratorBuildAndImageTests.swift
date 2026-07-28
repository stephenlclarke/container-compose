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
    @Test("build uses CLI while pull and push use direct image API")
    func buildUsesCLIWhilePullAndPushUseDirectImageAPI() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let imageManager = RecordingContainerImageManager()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            imageManager: imageManager
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        dockerfile: "Containerfile",
                        args: ["VERSION": "1"],
                        cache: ComposeBuild.Cache(
                            from: ["type=registry,ref=example/api:cache"],
                            to: ["type=local,dest=.cache"]
                        ),
                        metadata: ComposeBuild.Metadata(
                            labels: ["org.opencontainers.image.title": "api", "build.label": "true"],
                            secrets: [
                                ComposeBuildSecret(id: "file_token", file: "./token.txt"),
                                ComposeBuildSecret(id: "npm_token", environment: "NPM_TOKEN"),
                            ]
                        ),
                        options: ComposeBuild.Options(
                            image: ComposeBuild.Options.Image(
                                target: "runtime",
                                noCache: true,
                                noCacheFilter: ["base", "compile"],
                                pull: true,
                                platforms: ["linux/amd64", "linux/arm64"],
                                tags: ["example/api:latest", "example/api:dev", "example/api:test"]
                            ),
                            attestations: ComposeBuild.Options.Attestations(
                                provenance: "mode=min",
                                sbom: "false"
                            )
                        )
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

        let apiCommand = try #require(runner.commands.first { command in
            command.arguments.containsSequence(["container", "build", "--tag", "example/api:latest"])
        }?.arguments)
        let workerCommand = try #require(runner.commands.first { command in
            command.arguments.containsSequence(["container", "build", "--tag", "demo_worker:latest"])
        }?.arguments)
        #expect(apiCommand.filter { $0 == "example/api:latest" }.count == 1)
        #expect(apiCommand.containsSequence(["--tag", "example/api:dev"]))
        #expect(apiCommand.containsSequence(["--tag", "example/api:test"]))
        #expect(apiCommand.containsSequence([
            "--file",
            URL(fileURLWithPath: project.workingDirectory, isDirectory: true)
                .appendingPathComponent("api/Containerfile")
                .standardizedFileURL
                .path,
        ]))
        #expect(apiCommand.containsSequence(["--target", "runtime"]))
        #expect(apiCommand.contains("--no-cache"))
        #expect(apiCommand.containsSequence(["--no-cache-filter", "base"]))
        #expect(apiCommand.containsSequence(["--no-cache-filter", "compile"]))
        #expect(apiCommand.contains("--pull"))
        #expect(apiCommand.containsSequence(["--platform", "linux/amd64"]))
        #expect(apiCommand.containsSequence(["--platform", "linux/arm64"]))
        #expect(apiCommand.containsSequence(["--cache-in", "type=registry,ref=example/api:cache"]))
        #expect(apiCommand.containsSequence(["--cache-out", "type=local,dest=.cache"]))
        #expect(apiCommand.containsSequence(["--label", "build.label=true"]))
        #expect(apiCommand.containsSequence(["--label", "org.opencontainers.image.title=api"]))
        #expect(apiCommand.containsSequence(["--secret", "id=file_token,src=./token.txt"]))
        #expect(apiCommand.containsSequence(["--secret", "id=npm_token,env=NPM_TOKEN"]))
        #expect(apiCommand.containsSequence(["--provenance", "mode=min"]))
        #expect(!apiCommand.contains("--sbom"))
        #expect(apiCommand.containsSequence(["--build-arg", "VERSION=1"]))
        #expect(apiCommand.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
        #expect(workerCommand.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("worker").standardizedFileURL.path)
        #expect(runner.commands.count == 2)
        #expect(await imageManager.requests == [
            .pull("example/api:latest"),
            .push("example/api:latest"),
        ])
        #expect(emitted.messages == ["example/api:latest"])
    }

    @Test("build materializes external secrets only for the engine invocation")
    func buildMaterializesExternalSecretsOnlyForEngineInvocation() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let contents = Data([0x00, 0xFF, 0x0A])
        let reader = BuildSecretFixtureReader(secrets: ["shared_build_secret": contents])
        let runner = BuildSecretInspectingRunner()
        let stateRoot = directory.appendingPathComponent("state", isDirectory: true)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        metadata: ComposeBuild.Metadata(secrets: [
                            ComposeBuildSecret(id: "api_token", externalName: "shared_build_secret"),
                        ])
                    )
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.secretReader = reader
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(materializedConfigSecretDirectory: stateRoot),
            dependencies: dependencies
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.quiet = true
            }
        )

        #expect(await reader.requests == ["shared_build_secret"])
        #expect(runner.secretContents == [contents])
        #expect(runner.secretPermissions == [0o400])
        let secretURL = try #require(runner.secretURLs.first)
        #expect(!FileManager.default.fileExists(atPath: secretURL.path))
        let command = try #require(runner.commands.first)
        #expect(command.containsSequence(["--secret", "id=api_token,src=\(secretURL.path)"]))
        #expect(!command.joined(separator: " ").contains("shared_build_secret"))
    }

    @Test("build removes external secret files after an engine failure")
    func buildRemovesExternalSecretFilesAfterEngineFailure() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let contents = Data("fixture".utf8)
        let reader = BuildSecretFixtureReader(secrets: ["shared_build_secret": contents])
        let runner = BuildSecretInspectingRunner(
            result: CommandResult(status: 1, stdout: "", stderr: "")
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        metadata: ComposeBuild.Metadata(secrets: [
                            ComposeBuildSecret(id: "api_token", externalName: "shared_build_secret"),
                        ])
                    )
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.secretReader = reader
        }

        await #expect(throws: ComposeError.self) {
            try await ComposeOrchestrator(
                runner: runner,
                options: ComposeExecutionOptions(
                    materializedConfigSecretDirectory: directory.appendingPathComponent(
                        "state",
                        isDirectory: true
                    )
                ),
                dependencies: dependencies
            ).build(
                project: project,
                options: ComposeBuildOptions {
                    $0.quiet = true
                }
            )
        }

        #expect(runner.secretContents == [contents])
        let secretURL = try #require(runner.secretURLs.first)
        #expect(!FileManager.default.fileExists(atPath: secretURL.path))
    }

    @Test("build dry run neither reads nor writes external secrets")
    func buildDryRunNeitherReadsNorWritesExternalSecrets() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let reader = BuildSecretFixtureReader(secrets: [:])
        let emitted = MessageRecorder()
        let stateRoot = directory.appendingPathComponent("state", isDirectory: true)
        var executionOptions = ComposeExecutionOptions(
            dryRun: true,
            materializedConfigSecretDirectory: stateRoot
        )
        executionOptions.emit = { emitted.append($0) }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        metadata: ComposeBuild.Metadata(secrets: [
                            ComposeBuildSecret(id: "api_token", externalName: "shared_build_secret"),
                        ])
                    )
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.secretReader = reader
        }

        try await ComposeOrchestrator(
            options: executionOptions,
            dependencies: dependencies
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.quiet = true
            }
        )

        #expect(await reader.requests.isEmpty)
        let command = try #require(emitted.messages.first)
        #expect(command.contains("--secret"))
        #expect(command.contains("build-secrets/dry-run/secret-0"))
        #expect(!command.contains("shared_build_secret"))
        #expect(!FileManager.default.fileExists(atPath: stateRoot.path))
    }

    @Test("build reports an unavailable external secret before invoking the engine")
    func buildReportsUnavailableExternalSecretBeforeInvokingEngine() async throws {
        let reader = BuildSecretFixtureReader(secrets: [:])
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        metadata: ComposeBuild.Metadata(secrets: [
                            ComposeBuildSecret(id: "api_token", externalName: "missing_build_secret"),
                        ])
                    )
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.secretReader = reader
        }

        do {
            try await ComposeOrchestrator(
                runner: runner,
                dependencies: dependencies
            ).build(
                project: project,
                options: ComposeBuildOptions {
                    $0.quiet = true
                }
            )
            Issue.record("Expected missing external build secret failure")
        } catch let error as ComposeError {
            guard case .invalidProject(let message) = error else {
                Issue.record("Unexpected Compose error: \(error)")
                return
            }
            #expect(message.contains("service 'api' could not read external build secret 'api_token'"))
            #expect(message.contains("as 'missing_build_secret'"))
            #expect(message.contains("missing build secret fixture"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await reader.requests == ["missing_build_secret"])
        #expect(runner.commands.isEmpty)
    }

    @Test("build honors the configured parallel engine call limit")
    func buildHonorsConfiguredParallelEngineCallLimit() async throws {
        let runner = DelayedBuildRunner(delay: .milliseconds(50))
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
                "cache": composeService(name: "cache", image: "example/cache:latest") {
                    $0.build = ComposeBuild(context: "cache")
                },
                "worker": composeService(name: "worker", image: "example/worker:latest") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(maxParallelism: 2)
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.quiet = true
            }
        )

        #expect(await runner.commands.count == 3)
        #expect(await runner.maximumActiveOperations == 2)
    }

    @Test("build layers additional context dependencies before dependents")
    func buildLayersAdditionalContextDependenciesBeforeDependents() async throws {
        let runner = DelayedBuildRunner(delay: .milliseconds(50))
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(contexts: ComposeBuild.Contexts(
                        context: "api",
                        additionalContexts: ["base": "service:base"]
                    ))
                },
                "base": composeService(name: "base", image: "example/base:latest") {
                    $0.build = ComposeBuild(context: "base")
                },
                "worker": composeService(name: "worker", image: "example/worker:latest") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(maxParallelism: 2)
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.quiet = true
            }
        )

        let commands = await runner.commands
        let targets = commands.compactMap(\.last)
        let baseIndex = try #require(targets.firstIndex { $0.hasSuffix("/base") })
        let apiIndex = try #require(targets.firstIndex { $0.hasSuffix("/api") })
        #expect(baseIndex < apiIndex)
        #expect(await runner.maximumActiveOperations == 2)
    }

    @Test("build resolves Dockerfile relative to build context")
    func buildResolvesDockerfileRelativeToBuildContext() async throws {
        let runner = RecordingRunner()
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions()
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api") {
                    $0.build = ComposeBuild(
                        context: "/tmp/container-compose-build-context/api",
                        dockerfile: "docker/Dockerfile"
                    )
                },
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(
                        context: "worker",
                        dockerfile: "Containerfile"
                    )
                },
                "remote": composeService(name: "remote") {
                    $0.build = ComposeBuild(
                        context: "https://example.com/repo.git",
                        dockerfile: "Containerfile"
                    )
                },
                "default": composeService(name: "default") {
                    $0.build = ComposeBuild()
                },
            ]
        )

        try await orchestrator.build(project: project, services: ["api", "worker", "remote", "default"], noCache: false)

        let apiCommand = try #require(runner.commands.first { command in
            command.arguments.last == "/tmp/container-compose-build-context/api"
        }?.arguments)
        let workerCommand = try #require(runner.commands.first { command in
            command.arguments.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("worker").standardizedFileURL.path
        }?.arguments)
        let remoteCommand = try #require(runner.commands.first { command in
            command.arguments.last == "https://example.com/repo.git"
        }?.arguments)
        let defaultCommand = try #require(runner.commands.first { command in
            command.arguments.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).standardizedFileURL.path
        }?.arguments)

        #expect(apiCommand.containsSequence([
            "--file",
            "/tmp/container-compose-build-context/api/docker/Dockerfile",
        ]))
        #expect(workerCommand.containsSequence([
            "--file",
            URL(fileURLWithPath: project.workingDirectory, isDirectory: true)
                .appendingPathComponent("worker/Containerfile")
                .standardizedFileURL
                .path,
        ]))
        #expect(remoteCommand.containsSequence(["--file", "Containerfile"]))
        #expect(!defaultCommand.contains("--file"))
    }

    @Test("build materializes inline Dockerfile for container build")
    func buildMaterializesInlineDockerfileForContainerBuild() async throws {
        let runner = InlineDockerfileRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:inline") {
                    $0.build = ComposeBuild(
                        context: "api",
                        dockerfileInline: "FROM alpine:3.20\nRUN echo inline\n"
                    )
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(project: project, services: ["api"], noCache: false)

        let command = try #require(runner.commands.first)
        let fileIndex = try #require(command.firstIndex(of: "--file"))
        let dockerfilePath = command[fileIndex + 1]
        #expect(command.containsSequence(["container", "build", "--tag", "example/api:inline"]))
        #expect(dockerfilePath.contains("container-compose-demo-api-"))
        #expect(dockerfilePath.hasSuffix("/Dockerfile"))
        #expect(command.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
        #expect(runner.dockerfileContents == ["FROM alpine:3.20\nRUN echo inline\n"])
        #expect(!FileManager.default.fileExists(atPath: dockerfilePath))
    }

    @Test("build rejects conflicting Dockerfile forms before emitting commands")
    func buildRejectsConflictingDockerfileFormsBeforeEmittingCommands() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        dockerfile: "Dockerfile",
                        dockerfileInline: "FROM alpine"
                    )
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).build(project: project, services: [], noCache: false)
            Issue.record("Expected conflicting Dockerfile forms error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("service 'api' cannot define both dockerfile and dockerfile_inline"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("pull include deps selects dependency images with the missing policy")
    func pullIncludeDepsWithMissingPolicySelectsDependencyImages() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = [
                        "db": ComposeDependency(condition: "service_started"),
                    ]
                },
                "db": composeService(name: "db", image: "example/db:latest"),
            ]
        )

        try await ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).pull(
            project: project,
            options: ComposePullOptions {
                $0.services = ["api"]
                $0.includeDependencies = true
                $0.policy = "missing"
            }
        )

        let requests = await imageManager.requests
        #expect(requests.count == 2)
        #expect(requests.contains(.pullMissing("example/db:latest")))
        #expect(requests.contains(.pullMissing("example/api:latest")))
    }

    @Test("pull ignore buildable skips services with build sections")
    func pullIgnoreBuildableSkipsServicesWithBuildSections() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
                "db": composeService(name: "db", image: "example/db:latest"),
            ]
        )

        try await ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).pull(
            project: project,
            options: ComposePullOptions {
                $0.ignoreBuildable = true
            }
        )

        #expect(await imageManager.requests == [.pull("example/db:latest")])
    }

    @Test("pull ignore failures continues with later services")
    func pullIgnoreFailuresContinuesWithLaterServices() async throws {
        let imageManager = RecordingContainerImageManager(pullFailures: ["example/api:latest"])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
                "worker": composeService(name: "worker", image: "example/worker:latest"),
            ]
        )

        try await ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).pull(
            project: project,
            options: ComposePullOptions {
                $0.ignorePullFailures = true
            }
        )

        let requests = await imageManager.requests
        #expect(requests.count == 2)
        #expect(requests.contains(.pull("example/api:latest")))
        #expect(requests.contains(.pull("example/worker:latest")))
    }

    @Test("pull honors configured parallel image operation limit")
    func pullHonorsConfiguredParallelImageOperationLimit() async throws {
        let concurrency = OperationConcurrencyRecorder(delay: .milliseconds(50))
        let imageManager = RecordingContainerImageManager(onPullImage: { _ in
            await concurrency.recordOperation()
        })
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
                "db": composeService(name: "db", image: "example/db:latest"),
                "cache": composeService(name: "cache", image: "example/cache:latest"),
                "worker": composeService(name: "worker", image: "example/worker:latest"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(maxParallelism: 2),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).pull(project: project, options: ComposePullOptions())

        let requests = await imageManager.requests
        #expect(requests.count == 4)
        #expect(requests.contains(.pull("example/api:latest")))
        #expect(requests.contains(.pull("example/db:latest")))
        #expect(requests.contains(.pull("example/cache:latest")))
        #expect(requests.contains(.pull("example/worker:latest")))
        #expect(await concurrency.maximumActiveOperations == 2)
    }

    @Test("pull defaults to unlimited independent engine operations")
    func pullDefaultsToUnlimitedParallelImageOperations() async throws {
        let concurrency = OperationConcurrencyRecorder(delay: .milliseconds(50))
        let imageManager = RecordingContainerImageManager(onPullImage: { _ in
            await concurrency.recordOperation()
        })
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
                "db": composeService(name: "db", image: "example/db:latest"),
                "worker": composeService(name: "worker", image: "example/worker:latest"),
            ]
        )

        try await ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).pull(project: project, options: ComposePullOptions())

        #expect(await concurrency.maximumActiveOperations == 3)
    }

    @Test("pull rejects invalid parallelism before side effects")
    func pullRejectsInvalidParallelismBeforeSideEffects() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
            ]
        )

        do {
            try await ComposeOrchestrator(
                options: ComposeExecutionOptions(maxParallelism: 0),
                dependencies: orchestratorDependencies {
                    $0.imageManager = imageManager
                }
            ).pull(project: project, options: ComposePullOptions())
            Issue.record("Expected invalid --parallel failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("--parallel must be -1 or a positive integer"))
        }

        #expect(await imageManager.requests.isEmpty)
    }

    @Test("pull rejects unsupported policy before side effects")
    func pullRejectsUnsupportedPolicyBeforeSideEffects() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
            ]
        )

        do {
            try await ComposeOrchestrator(
                dependencies: orchestratorDependencies {
                    $0.imageManager = imageManager
                }
            ).pull(
                project: project,
                options: ComposePullOptions {
                    $0.policy = "never"
                }
            )
            Issue.record("Expected unsupported pull policy failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("unsupported pull policy 'never'"))
        }

        #expect(await imageManager.requests.isEmpty)
    }

    @Test("push include deps selects dependency images")
    func pushIncludeDepsSelectsDependencyImages() async throws {
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = [
                        "db": ComposeDependency(condition: "service_started"),
                    ]
                },
                "db": composeService(name: "db", image: "example/db:latest"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).push(
            project: project,
            options: ComposePushOptions {
                $0.services = ["api"]
                $0.includeDependencies = true
            }
        )

        let requests = await imageManager.requests
        #expect(requests.count == 2)
        #expect(requests.contains(.push("example/db:latest")))
        #expect(requests.contains(.push("example/api:latest")))
    }

    @Test("push quiet suppresses emitted pushed references")
    func pushQuietSuppressesEmittedPushedReferences() async throws {
        let emitted = MessageRecorder()
        let imageManager = RecordingContainerImageManager(pushOutputs: [
            "example/api:latest": "registry.example.com/api@sha256:abc",
        ])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
            ]
        )
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        )

        try await orchestrator.push(
            project: project,
            options: ComposePushOptions {
                $0.quiet = true
            }
        )

        #expect(await imageManager.requests == [.push("example/api:latest")])
        #expect(emitted.messages.isEmpty)
    }

    @Test("push ignore failures continues with later services")
    func pushIgnoreFailuresContinuesWithLaterServices() async throws {
        let imageManager = RecordingContainerImageManager(pushFailures: ["example/api:latest"])
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
                "worker": composeService(name: "worker", image: "example/worker:latest"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).push(
            project: project,
            options: ComposePushOptions {
                $0.ignorePushFailures = true
            }
        )

        let requests = await imageManager.requests
        #expect(requests.count == 2)
        #expect(requests.contains(.push("example/api:latest")))
        #expect(requests.contains(.push("example/worker:latest")))
    }

    @Test("push honors unlimited parallel image operations")
    func pushHonorsUnlimitedParallelImageOperations() async throws {
        let concurrency = OperationConcurrencyRecorder(delay: .milliseconds(50))
        let imageManager = RecordingContainerImageManager(onPushImage: { _ in
            await concurrency.recordOperation()
        })
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest"),
                "cache": composeService(name: "cache", image: "example/cache:latest"),
                "worker": composeService(name: "worker", image: "example/worker:latest"),
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(
                maxParallelism: -1,
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(emit: { _ in })
            ),
            dependencies: orchestratorDependencies {
                $0.imageManager = imageManager
            }
        ).push(project: project, options: ComposePushOptions())

        let requests = await imageManager.requests
        #expect(requests.count == 3)
        #expect(requests.contains(.push("example/api:latest")))
        #expect(requests.contains(.push("example/cache:latest")))
        #expect(requests.contains(.push("example/worker:latest")))
        #expect(await concurrency.maximumActiveOperations == 3)
    }

    @Test("build options add pull quiet and push service image")
    func buildOptionsAddPullQuietAndPushServiceImage() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { _ in }),
            imageManager: imageManager
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.pull = true
                $0.push = true
                $0.quiet = true
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.contains("--pull"))
        #expect(command.contains("--quiet"))
        #expect(command.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
        #expect(await imageManager.requests == [.push("example/api:latest")])
    }

    @Test("build options add CLI build args and memory")
    func buildOptionsAddCLIBuildArgsAndMemory() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "base": composeService(name: "base", image: "example/base:latest") {
                    $0.build = ComposeBuild(context: "base")
                },
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        contexts: ComposeBuild.Contexts(
                            context: "api",
                            additionalContexts: [
                                "base": "service:base",
                                "shared": "/workspace/shared",
                            ]
                        ),
                        args: ["FILE_ARG": "1"],
                        metadata: ComposeBuild.Metadata(
                            ssh: ["default", "git=/tmp/git.sock"]
                        ),
                        options: ComposeBuild.Options(
                            frontend: ComposeBuild.Options.Frontend(
                                entitlements: ["network.host"],
                                extraHosts: ["build.local=127.0.0.1"],
                                network: "host",
                                privileged: true,
                                shmSize: "67108864",
                                ulimits: ["nofile=1024:2048"]
                            )
                        )
                    )
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.buildArguments = ["CLI_ARG=2"]
                $0.memory = "256m"
                $0.ssh = ["default=/tmp/cli.sock", "deploy=/tmp/deploy.sock"]
            }
        )

        #expect(runner.commands.count == 2)
        let baseCommand = try #require(runner.commands.first?.arguments)

        let command = try #require(runner.commands.last?.arguments)
        #expect(command.containsSequence(["--memory", "256m"]))
        #expect(!command.containsSequence(["--ssh", "default"]))
        #expect(command.containsSequence(["--ssh", "git=/tmp/git.sock"]))
        #expect(command.containsSequence(["--ssh", "default=/tmp/cli.sock"]))
        #expect(command.containsSequence(["--ssh", "deploy=/tmp/deploy.sock"]))
        #expect(command.containsSequence(["--build-context", "base=docker-image://example/base:latest"]))
        #expect(command.containsSequence(["--build-context", "shared=/workspace/shared"]))
        #expect(command.containsSequence(["--allow", "network.host"]))
        #expect(command.containsSequence(["--add-host", "build.local=127.0.0.1"]))
        #expect(command.containsSequence(["--network", "host"]))
        #expect(command.contains("--privileged"))
        #expect(command.containsSequence(["--shm-size", "67108864"]))
        #expect(command.containsSequence(["--ulimit", "nofile=1024:2048"]))
        #expect(command.containsSequence(["--build-arg", "FILE_ARG=1"]))
        #expect(command.containsSequence(["--build-arg", "CLI_ARG=2"]))
        #expect(baseCommand.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("base").standardizedFileURL.path)
        #expect(command.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
    }

    @Test("build rejects unknown service additional contexts before side effects")
    func buildRejectsUnknownServiceAdditionalContextsBeforeSideEffects() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        contexts: ComposeBuild.Contexts(
                            context: "api",
                            additionalContexts: [
                                "base": "service:missing",
                            ]
                        )
                    )
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).build(
                project: project,
                options: ComposeBuildOptions {
                    $0.services = ["api"]
                }
            )
            Issue.record("Expected unknown build additional_contexts service failure")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("build additional_contexts references unknown service 'missing'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("build print renders bake targets without build side effects")
    func buildPrintRendersBakeTargetsWithoutBuildSideEffects() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let imageManager = RecordingContainerImageManager()
        var project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = [
                        "db": ComposeDependency(condition: "service_started"),
                    ]
                    $0.build = ComposeBuild(
                        contexts: ComposeBuild.Contexts(
                            context: "api",
                            dockerfile: "Containerfile",
                            additionalContexts: [
                                "db": "service:db",
                                "shared": "/workspace/project/shared",
                            ]
                        ),
                        args: ["FILE_ARG": "1"],
                        cache: ComposeBuild.Cache(
                            from: ["type=registry,ref=example/api:cache"],
                            to: ["type=local,dest=.cache"]
                        ),
                        metadata: ComposeBuild.Metadata(
                            labels: ["org.opencontainers.image.title": "api"],
                            secrets: [
                                ComposeBuildSecret(id: "file_token", file: "token.txt"),
                                ComposeBuildSecret(id: "npm_token", environment: "NPM_TOKEN"),
                                ComposeBuildSecret(id: "external_token", externalName: "shared_build_secret"),
                            ],
                            ssh: ["default", "git=/tmp/git.sock"]
                        ),
                        options: ComposeBuild.Options(
                            image: ComposeBuild.Options.Image(
                                target: "runtime",
                                noCache: true,
                                noCacheFilter: ["base", "compile"],
                                pull: true,
                                platforms: ["linux/arm64"],
                                tags: ["example/api:dev"]
                            ),
                            frontend: ComposeBuild.Options.Frontend(
                                entitlements: ["network.host"],
                                extraHosts: ["build.local=127.0.0.1"],
                                network: "host",
                                privileged: true,
                                shmSize: "67108864",
                                ulimits: ["nofile=1024:2048"]
                            ),
                            attestations: ComposeBuild.Options.Attestations(
                                provenance: "mode=min",
                                sbom: "true"
                            )
                        )
                    )
                },
                "db": composeService(name: "db") {
                    $0.build = ComposeBuild(context: "db")
                },
            ]
        )
        project.workingDirectory = "/workspace/project"
        project.environment = ["ENV_ONLY": "from-env"]

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            imageManager: imageManager
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.buildArguments = ["CLI_ARG=2", "ENV_ONLY", "MISSING_ENV"]
                $0.noCache = true
                $0.printBake = true
                $0.pull = true
                $0.push = true
                $0.provenance = "mode=max"
                $0.sbom = "true"
                $0.ssh = ["deploy=/tmp/deploy.sock"]
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await imageManager.requests.isEmpty)
        let output = try #require(emitted.messages.first)
        let bake = try bakeJSON(output)
        #expect(try bakeGroupTargets(bake) == ["db", "api"])

        let api = try bakeTarget(bake, name: "api")
        #expect(api["context"] as? String == "/workspace/project/api")
        #expect(api["dockerfile"] as? String == "/workspace/project/api/Containerfile")
        #expect(api["target"] as? String == "runtime")
        #expect(api["pull"] as? Bool == true)
        #expect(api["no-cache"] as? Bool == true)
        #expect(api["no-cache-filter"] as? [String] == ["base", "compile"])
        #expect(api["tags"] as? [String] == ["example/api:dev", "example/api:latest"])
        #expect(api["cache-from"] as? [String] == ["type=registry,ref=example/api:cache"])
        #expect(api["cache-to"] as? [String] == ["type=local,dest=.cache"])
        #expect(api["contexts"] as? [String: String] == [
            "db": "target:db",
            "shared": "/workspace/project/shared",
        ])
        #expect(api["entitlements"] as? [String] == ["network.host"])
        #expect(api["extra-hosts"] as? [String] == ["build.local=127.0.0.1"])
        #expect(api["network"] as? String == "host")
        #expect(api["privileged"] as? Bool == true)
        #expect(api["shm-size"] as? String == "67108864")
        #expect(api["ulimits"] as? [String] == ["nofile=1024:2048"])
        #expect(api["platforms"] as? [String] == ["linux/arm64"])
        #expect(api["attest"] as? [String] == ["type=provenance,mode=max", "type=sbom"])
        #expect(api["secret"] as? [String] == [
            "id=file_token,type=file,src=/workspace/project/token.txt",
            "id=npm_token,type=env,env=NPM_TOKEN",
        ])
        #expect(api["ssh"] as? [String] == ["default", "git=/tmp/git.sock", "deploy=/tmp/deploy.sock"])
        #expect(api["output"] as? [String] == ["type=registry"])
        #expect((api["labels"] as? [String: String])?["org.opencontainers.image.title"] == "api")
        let arguments = try #require(api["args"] as? [String: String])
        #expect(arguments["FILE_ARG"] == "1")
        #expect(arguments["CLI_ARG"] == "2")
        #expect(arguments["ENV_ONLY"] == "from-env")
        #expect(arguments["MISSING_ENV"] == nil)

        let db = try bakeTarget(bake, name: "db")
        #expect(db["context"] as? String == "/workspace/project/db")
        #expect(db["dockerfile"] as? String == "/workspace/project/db/Dockerfile")
        #expect(db["tags"] as? [String] == ["demo_db:latest"])
        #expect(db["output"] as? [String] == ["type=docker"])
    }

    @Test("build print check renders lint bake call without output")
    func buildPrintCheckRendersLintBakeCallWithoutOutput() async throws {
        let emitted = MessageRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.check = true
                $0.printBake = true
            }
        )

        let output = try #require(emitted.messages.first)
        let api = try bakeTarget(bakeJSON(output), name: "api")
        #expect(api["call"] as? String == "lint")
        #expect(api["output"] == nil)
    }

    @Test("build print renders inline Dockerfile")
    func buildPrintRendersInlineDockerfile() async throws {
        let emitted = MessageRecorder()
        var project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:inline") {
                    $0.build = ComposeBuild(
                        context: ".",
                        dockerfileInline: "FROM alpine:3.20\nRUN echo inline\n"
                    )
                },
            ]
        )
        project.workingDirectory = "/workspace/inline"

        try await ComposeOrchestrator(
            options: ComposeExecutionOptions(emit: { emitted.append($0) })
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.printBake = true
            }
        )

        let output = try #require(emitted.messages.first)
        let api = try bakeTarget(bakeJSON(output), name: "api")
        #expect(api["context"] as? String == "/workspace/inline")
        #expect(api["dockerfile"] == nil)
        #expect(api["dockerfile-inline"] as? String == "FROM alpine:3.20\nRUN echo inline\n")
        #expect(api["tags"] as? [String] == ["example/api:inline"])
    }

    @Test("build print rejects empty build argument names")
    func buildPrintRejectsEmptyBuildArgumentNames() async throws {
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        do {
            try await ComposeOrchestrator().build(
                project: project,
                options: ComposeBuildOptions {
                    $0.services = ["api"]
                    $0.buildArguments = ["=bad"]
                    $0.printBake = true
                }
            )
            Issue.record("Expected empty build argument name error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("build --build-arg requires KEY or KEY=VALUE"))
        }
    }

    @Test("build emits progress rows when progress is enabled")
    func buildEmitsProgressRowsWhenProgressIsEnabled() async throws {
        let runner = RecordingRunner()
        let emitted = LockedStringRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )
        let progress = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append(String(bytes: $0, encoding: .utf8) ?? "") }
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(progress: progress)
        ).build(project: project, services: ["api"], noCache: false)

        #expect(runner.commands.count == 1)
        #expect(emitted.snapshot == [
            "⠓ Building api\n",
            "✓ Building api\n",
        ])
    }

    @Test("build emits first progress row before container build starts")
    func buildEmitsFirstProgressRowBeforeContainerBuildStarts() async throws {
        let emitted = LockedStringRecorder()
        let runner = ProgressAssertingRunner { arguments in
            #expect(arguments.containsSequence(["container", "build"]))
            #expect(emitted.snapshot == ["⠓ Building api\n"])
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )
        let progress = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(progress: progress)
        ).build(project: project, services: ["api"], noCache: false)

        #expect(runner.commands.count == 1)
        #expect(emitted.snapshot == [
            "⠓ Building api\n",
            "✓ Building api\n",
        ])
    }

    @Test("TTY build progress leaves a clean row for container build output")
    func ttyBuildProgressLeavesCleanRowForContainerBuildOutput() async throws {
        let emitted = LockedStringRecorder()
        let runner = ProgressAssertingRunner { arguments in
            #expect(arguments.containsSequence(["container", "build"]))
            #expect(emitted.snapshot == ["⠓ Building api\n"])
        }
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )
        let progress = ComposeProgressReporter(
            style: .tty,
            emitData: { emitted.append(String(bytes: $0, encoding: .utf8) ?? "") }
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(progress: progress)
        ).build(project: project, services: ["api"], noCache: false)

        #expect(runner.commands.count == 1)
        #expect(emitted.snapshot == [
            "⠓ Building api\n",
            "✓ Building api\n",
        ])
    }

    @Test("quiet build suppresses progress rows")
    func quietBuildSuppressesProgressRows() async throws {
        let runner = RecordingRunner()
        let emitted = LockedStringRecorder()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )
        let progress = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append(String(bytes: $0, encoding: .utf8) ?? "") }
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(progress: progress)
        ).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.quiet = true
            }
        )

        #expect(runner.commands.count == 1)
        #expect(emitted.snapshot.isEmpty)
    }

    @Test("build with dependencies builds dependency images first")
    func buildWithDependenciesBuildsDependencyImagesFirst() async throws {
        let runner = RecordingRunner()
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.dependsOn = [
                        "db": ComposeDependency(condition: "service_started"),
                    ]
                    $0.build = ComposeBuild(context: "api")
                },
                "db": composeService(name: "db", image: "example/db:latest") {
                    $0.build = ComposeBuild(context: "db")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(
            project: project,
            options: ComposeBuildOptions {
                $0.services = ["api"]
                $0.withDependencies = true
            }
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 2)
        #expect(commands[0].containsSequence(["--tag", "example/db:latest"]))
        #expect(commands[0].last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("db").standardizedFileURL.path)
        #expect(commands[1].containsSequence(["--tag", "example/api:latest"]))
        #expect(commands[1].last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
    }

    @Test("build push skips services without explicit image references")
    func buildPushSkipsServicesWithoutExplicitImageReferences() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let project = composeProject(
            name: "demo",
            services: [
                "worker": composeService(name: "worker") {
                    $0.build = ComposeBuild(context: "worker")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).build(
            project: project,
            options: ComposeBuildOptions {
                $0.push = true
            }
        )

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.containsSequence(["--tag", "demo_worker:latest"]))
        #expect(await imageManager.requests.isEmpty)
    }

    @Test("build applies Compose file no cache setting")
    func buildAppliesComposeFileNoCacheSetting() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        options: ComposeBuild.Options(
                            image: ComposeBuild.Options.Image(noCache: true)
                        )
                    )
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(project: project, services: ["api"], noCache: false)

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.contains("--no-cache"))
    }

    @Test("build check forwards check flag and skips push")
    func buildCheckForwardsCheckFlagAndSkipsPush() async throws {
        let runner = RecordingRunner()
        let imageManager = RecordingContainerImageManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner, imageManager: imageManager).build(
            project: project,
            options: ComposeBuildOptions {
                $0.check = true
                $0.push = true
            }
        )

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].arguments.contains("--check"))
        #expect(await imageManager.requests.isEmpty)
    }

    @Test("build forwards default builder selection")
    func buildForwardsDefaultBuilderSelection() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(
            project: project,
            options: ComposeBuildOptions {
                $0.builder = "default"
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["container", "build", "--builder", "default", "--tag", "example/api:latest"]))
    }

    @Test("build forwards named builders")
    func buildForwardsNamedBuilders() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await ComposeOrchestrator(runner: runner).build(
            project: project,
            options: ComposeBuildOptions {
                $0.builder = "remote"
            }
        )

        let command = try #require(runner.commands.first?.arguments)
        #expect(command.containsSequence(["container", "build", "--builder", "remote", "--tag", "example/api:latest"]))
    }

    @Test("build rejects unsupported build fields before emitting commands")
    func buildRejectsUnsupportedBuildFieldsBeforeEmittingCommands() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        options: ComposeBuild.Options(unsupportedFields: ["secrets"])
                    )
                },
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).build(project: project, services: [], noCache: false)
            Issue.record("Expected unsupported build field error")
        } catch let error as ComposeError {
            #expect(error == .unsupported("service 'api' uses unsupported build fields secrets; advanced build fields need Docker Compose compatible apple/container build primitives"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("build rejects malformed build secrets before emitting commands")
    func buildRejectsMalformedBuildSecretsBeforeEmittingCommands() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        metadata: ComposeBuild.Metadata(
                            secrets: [ComposeBuildSecret(id: "both", file: "./token.txt", environment: "TOKEN")]
                        )
                    )
                },
            ]
        )
        let runner = RecordingRunner()

        do {
            try await ComposeOrchestrator(runner: runner).build(project: project, services: [], noCache: false)
            Issue.record("Expected invalid build secret error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("build secret 'both' cannot define both file and environment"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("build rejects external secrets combined with another source")
    func buildRejectsExternalSecretsCombinedWithAnotherSource() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(
                        context: "api",
                        metadata: ComposeBuild.Metadata(
                            secrets: [
                                ComposeBuildSecret(
                                    id: "both",
                                    file: "./token.txt",
                                    externalName: "shared_build_secret"
                                ),
                            ]
                        )
                    )
                },
            ]
        )
        let runner = RecordingRunner()

        await #expect(
            throws: ComposeError.invalidProject(
                "build secret 'both' cannot combine an external resource with file or environment"
            )
        ) {
            try await ComposeOrchestrator(runner: runner).build(
                project: project,
                services: [],
                noCache: false
            )
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
            services: [
                "api": composeService(name: "api", image: "example/api:latest") {
                    $0.build = ComposeBuild(context: "api")
                },
            ]
        )

        try await orchestrator.build(project: project, services: ["api"], noCache: false)

        let command = try #require(runner.commands.first)
        #expect(command.executable == "custom-env")
        #expect(command.arguments.containsSequence(["container", "build", "--tag", "example/api:latest"]))
        #expect(command.arguments.last == URL(fileURLWithPath: project.workingDirectory, isDirectory: true).appendingPathComponent("api").standardizedFileURL.path)
    }

}
