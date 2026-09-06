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

@Suite("Compose API socket")
struct ComposeAPISocketTests {
    @Test
    func `disabled projects remain byte-for-byte unchanged and do not resolve credentials`() async throws {
        let resolver = StaticAPISocketCredentialResolver(
            data: Data(), failure: TestFailure.unexpectedCall,
        )
        let orchestrator = ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.apiSocketCredentialResolver = resolver
            },
        )
        let source = composeProject(
            name: "demo",
            services: ["worker": composeService(name: "worker", image: "example/worker")],
        )

        let transformed = try await orchestrator.projectByApplyingAPISocket(source)

        #expect(transformed == source)
        #expect(await resolver.callCount() == 0)
    }

    @Test
    func `transform adds the generated credential config only to enabled services`() async throws {
        let credentials = Data(#"{"auths":{"registry.example":{"auth":"dXNlcjpwYXNz"}}}"#.utf8)
        let resolver = StaticAPISocketCredentialResolver(data: credentials)
        let orchestrator = ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.apiSocketCredentialResolver = resolver
            },
        )
        let source = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.useAPISocket = true
                },
                "worker": composeService(name: "worker", image: "example/worker"),
            ],
        )

        let transformed = try await orchestrator.projectByApplyingAPISocket(source)
        let credentialContents = try #require(
            String(bytes: credentials, encoding: .utf8),
        )

        #expect(source.configs == nil)
        #expect(source.services["api"]?.environment == nil)
        #expect(source.services["api"]?.configs == nil)
        #expect(
            transformed.configs?[ComposeOrchestrator.apiSocketConfigName]
                == .object(["content": .string(credentialContents)]),
        )
        #expect(
            transformed.services["api"]?.environment?["DOCKER_CONFIG"]
                == ComposeOrchestrator.apiSocketConfigDirectory,
        )
        #expect(
            transformed.services["api"]?.configs
                == [
                    .object([
                        "source": .string(ComposeOrchestrator.apiSocketConfigName),
                        "target": .string(ComposeOrchestrator.apiSocketConfigTarget),
                    ]),
                ],
        )
        #expect(transformed.services["worker"]?.environment == nil)
        #expect(transformed.services["worker"]?.configs == nil)
        #expect(await resolver.callCount() == 1)
    }

    @Test
    func `transform preserves an explicitly supplied Docker config environment key`() async throws {
        let resolver = StaticAPISocketCredentialResolver(data: Data(#"{"auths":{}}"#.utf8))
        let orchestrator = ComposeOrchestrator(
            dependencies: orchestratorDependencies {
                $0.apiSocketCredentialResolver = resolver
            },
        )
        let source = composeProject(
            name: "demo",
            services: [
                "empty": composeService(name: "empty", image: "example/empty") {
                    $0.useAPISocket = true
                    $0.environment = ["DOCKER_CONFIG": ""]
                },
                "inherited": composeService(name: "inherited", image: "example/inherited") {
                    $0.useAPISocket = true
                    $0.environment = ["DOCKER_CONFIG": nil]
                },
            ],
        )

        let transformed = try await orchestrator.projectByApplyingAPISocket(source)

        #expect(transformed.services["empty"]?.environment?["DOCKER_CONFIG"] == "")
        let inheritedEnvironment = try #require(transformed.services["inherited"]?.environment)
        switch inheritedEnvironment["DOCKER_CONFIG"] {
        case .some(.none):
            break
        default:
            Issue.record("Expected an explicit nil DOCKER_CONFIG value")
        }
    }

    @Test
    func `dry run does not invoke a Docker credential resolver`() async throws {
        let resolver = StaticAPISocketCredentialResolver(
            data: Data(), failure: TestFailure.unexpectedCall,
        )
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true),
            dependencies: orchestratorDependencies {
                $0.apiSocketCredentialResolver = resolver
            },
        )
        let source = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.useAPISocket = true
                },
            ],
        )

        let transformed = try await orchestrator.projectByApplyingAPISocket(source)

        #expect(transformed.configs?[ComposeOrchestrator.apiSocketConfigName] != nil)
        #expect(await resolver.callCount() == 0)
    }

    @Test
    func `credential failure happens before project resource mutation`() async throws {
        let runner = RecordingRunner()
        let resourceManager = RecordingContainerResourceManager()
        let resolver = StaticAPISocketCredentialResolver(
            data: Data(), failure: TestFailure.credentialFailure,
        )
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            dependencies: orchestratorDependencies {
                $0.apiSocketCredentialResolver = resolver
                $0.resourceManager = resourceManager
            },
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.useAPISocket = true
                    $0.networks = ["backend"]
                    $0.volumes = [
                        ComposeMount(type: "volume", source: "cache", target: "/cache"),
                    ]
                },
            ],
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "demo_backend")]
            $0.volumes = ["cache": ComposeVolume(name: "demo_cache")]
        }

        await #expect(throws: ComposeError.self) {
            try await orchestrator.up(project: project, options: ComposeUpOptions())
        }
        #expect(await resourceManager.requests.isEmpty)
    }
}

@Suite("Compose API socket credentials")
struct ComposeAPISocketCredentialTests {
    @Test
    func `resolver emits only file credentials when no helper is configured`() async throws {
        let runner = RecordingRunner()
        let authConfig =
            #"{"auths":{"registry.example":{"auth":"dXNlcjpwYXNz","email":"user@example.com"}},"#
                + #""currentContext":"desktop-linux"}"#
        let resolver = DockerAPISocketCredentialResolver(
            runner: runner,
            environment: [
                "DOCKER_AUTH_CONFIG": authConfig,
            ],
        )

        let data = try await resolver.resolvedCredentialConfig()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["auths"])
        let auths = try #require(object["auths"] as? [String: Any])
        let registry = try #require(auths["registry.example"] as? [String: Any])
        #expect(registry["auth"] as? String == "dXNlcjpwYXNz")
        #expect(registry["email"] == nil)
        #expect(runner.commands.isEmpty)
    }

    @Test
    func `file username and password become canonical auth`() async throws {
        let resolver = DockerAPISocketCredentialResolver(
            runner: RecordingRunner(),
            environment: [
                "DOCKER_AUTH_CONFIG":
                    #"{"auths":{"registry.example":{"username":"alice","password":"secret"}}}"#,
            ],
        )

        let data = try await resolver.resolvedCredentialConfig()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let auths = try #require(object["auths"] as? [String: Any])
        let registry = try #require(auths["registry.example"] as? [String: Any])

        #expect(registry["auth"] as? String == Data("alice:secret".utf8).base64EncodedString())
        #expect(registry["username"] == nil)
        #expect(registry["password"] == nil)
    }

    @Test
    func `malformed file auth fails before helper execution`() async throws {
        let runner = RecordingRunner()
        let resolver = DockerAPISocketCredentialResolver(
            runner: runner,
            environment: [
                "DOCKER_AUTH_CONFIG": #"{"auths":{"registry.example":{"auth":"not-base64"}}}"#,
            ],
        )

        await #expect(throws: ComposeError.self) {
            try await resolver.resolvedCredentialConfig()
        }
        #expect(runner.commands.isEmpty)
    }

    @Test
    func `default credential helper replaces file credentials without a shell`() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: #"{"registry.example":"alice"}"#, stderr: ""),
            CommandResult(status: 0, stdout: #"{"Username":"alice","Secret":"secret"}"#, stderr: ""),
        ])
        let resolver = DockerAPISocketCredentialResolver(
            runner: runner,
            environment: [
                "DOCKER_AUTH_CONFIG":
                    #"{"auths":{"file.example":{"auth":"ZmlsZTpvbmx5"}},"credsStore":"test"}"#,
                "HOME": "/private/empty-home",
                "PATH": "/usr/bin:/bin",
            ],
        )

        let data = try await resolver.resolvedCredentialConfig()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let auths = try #require(object["auths"] as? [String: Any])
        let registry = try #require(auths["registry.example"] as? [String: Any])

        #expect(auths["file.example"] == nil)
        #expect(registry["auth"] as? String == Data("alice:secret".utf8).base64EncodedString())
        #expect(runner.commands.map(\.executable) == ["/usr/bin/env", "/usr/bin/env"])
        #expect(
            runner.commands.map(\.arguments) == [
                ["-i", "HOME=/private/empty-home", "PATH=/usr/bin:/bin", "docker-credential-test", "list"],
                ["-i", "HOME=/private/empty-home", "PATH=/usr/bin:/bin", "docker-credential-test", "get"],
            ],
        )
        #expect(runner.commands[0].input == Data("unused".utf8))
        #expect(runner.commands[1].input == Data("registry.example".utf8))
    }

    @Test
    func `registry helper failure retains the file credential`() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(status: 1, stdout: "", stderr: "credentials not found"),
        ])
        let authConfig =
            #"{"auths":{"registry.example":{"auth":"ZmlsZTpvbmx5"}},"#
                + #""credHelpers":{"registry.example":"test"}}"#
        let resolver = DockerAPISocketCredentialResolver(
            runner: runner,
            environment: [
                "DOCKER_AUTH_CONFIG": authConfig,
                "HOME": "/private/empty-home",
                "PATH": "/usr/bin:/bin",
            ],
        )

        let data = try await resolver.resolvedCredentialConfig()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let auths = try #require(object["auths"] as? [String: Any])
        let registry = try #require(auths["registry.example"] as? [String: Any])

        #expect(registry["auth"] as? String == "ZmlsZTpvbmx5")
        #expect(runner.commands.count == 1)
    }

    @Test
    func `registry helper not-found result replaces file auth with an empty credential`() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 1,
                stdout: "credentials not found in native keychain\n",
                stderr: "",
            ),
        ])
        let authConfig =
            #"{"auths":{"registry.example":{"auth":"ZmlsZTpvbmx5"}},"#
                + #""credHelpers":{"registry.example":"test"}}"#
        let resolver = DockerAPISocketCredentialResolver(
            runner: runner,
            environment: [
                "DOCKER_AUTH_CONFIG": authConfig,
                "HOME": "/private/empty-home",
                "PATH": "/usr/bin:/bin",
            ],
        )

        let data = try await resolver.resolvedCredentialConfig()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let auths = try #require(object["auths"] as? [String: Any])
        let registry = try #require(auths["registry.example"] as? [String: Any])

        #expect(registry.isEmpty)
    }

    @Test
    func `token helper credential becomes an identity token`() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(status: 0, stdout: #"{"registry.example":"<token>"}"#, stderr: ""),
            CommandResult(status: 0, stdout: #"{"Username":"<token>","Secret":"opaque-token"}"#, stderr: ""),
        ])
        let resolver = DockerAPISocketCredentialResolver(
            runner: runner,
            environment: [
                "DOCKER_AUTH_CONFIG": #"{"credsStore":"test"}"#,
                "HOME": "/private/empty-home",
                "PATH": "/usr/bin:/bin",
            ],
        )

        let data = try await resolver.resolvedCredentialConfig()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let auths = try #require(object["auths"] as? [String: Any])
        let registry = try #require(auths["registry.example"] as? [String: Any])

        #expect(registry["identitytoken"] as? String == "opaque-token")
        #expect(registry["auth"] == nil)
    }

    @Test
    func `credential helper output is bounded`() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: String(repeating: "x", count: 1_048_577),
                stderr: "",
            ),
        ])
        let resolver = DockerAPISocketCredentialResolver(
            runner: runner,
            environment: [
                "DOCKER_AUTH_CONFIG": #"{"credsStore":"test"}"#,
                "HOME": "/private/empty-home",
                "PATH": "/usr/bin:/bin",
            ],
        )

        await #expect(throws: ComposeError.self) {
            try await resolver.resolvedCredentialConfig()
        }
    }

    @Test
    func `up carries credentials and the typed socket grant into container create`() async throws {
        let materializedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: materializedRoot) }
        let credentials = Data(#"{"auths":{"registry.example":{"auth":"dXNlcjpwYXNz"}}}"#.utf8)
        let resolver = StaticAPISocketCredentialResolver(data: credentials)
        let runner = RecordingRunner(responses: [.success])
        let orchestrator = ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions {
                $0.materializedConfigSecretDirectory = materializedRoot
            },
            dependencies: orchestratorDependencies {
                $0.apiSocketCredentialResolver = resolver
            },
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.useAPISocket = true
                },
            ],
        )

        try await orchestrator.up(project: project, options: ComposeUpOptions())

        let create = try #require(runner.commands.first?.arguments)
        #expect(create.contains("--engine-api-socket"))
        #expect(create.containsSequence(["--env", "DOCKER_CONFIG=/run/secrets/docker"]))
        let source = try #require(
            orchestratorReadOnlyVolumeSource(
                target: ComposeOrchestrator.apiSocketConfigTarget,
                in: create,
            ),
        )
        #expect(try Data(contentsOf: URL(fileURLWithPath: source)) == credentials)
        #expect(await resolver.callCount() == 1)
    }

    @Test
    func `run arguments request the typed engine API socket grant`() async throws {
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true),
            dependencies: orchestratorDependencies { _ in },
        )
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.useAPISocket = true
                },
            ],
        )
        let service = try #require(project.services["api"])

        let arguments = try await orchestrator.runArguments(project: project, service: service)

        #expect(arguments.contains("--engine-api-socket"))
        #expect(
            !arguments.contains(where: { $0.contains("/var/run/docker.sock:/var/run/docker.sock") }),
        )
    }
}

private actor StaticAPISocketCredentialResolver: ComposeAPISocketCredentialResolving {
    private let data: Data
    private let failure: (any Error)?
    private var calls = 0

    init(data: Data, failure: (any Error)? = nil) {
        self.data = data
        self.failure = failure
    }

    func resolvedCredentialConfig() async throws -> Data {
        calls += 1
        if let failure {
            throw failure
        }
        return data
    }

    func callCount() -> Int {
        calls
    }
}

private enum TestFailure: Error, Equatable {
    case credentialFailure
    case unexpectedCall
}
