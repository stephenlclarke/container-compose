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

@Suite("Compose normalizer")
struct ComposeNormalizerTests {
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
            depends_on:
              redis:
                condition: service_started
                restart: true
                required: false
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
        #expect(project.services["api"]?.dependsOn == ["redis": ComposeDependency(condition: "service_started", restart: true, required: false)])
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

    @Test("normalizer decodes JSON and forwards compose options")
    func normalizerDecodesJSONAndForwardsOptions() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"""
                {
                  "name": "demo",
                  "workingDirectory": "/tmp/demo",
                  "composeFiles": ["compose.yml"],
                  "services": {
                    "web": {
                      "name": "web",
                      "image": "nginx",
                      "cpuPercent": 12.5,
                      "dependsOn": {
                        "db": "service_started",
                        "job": {
                          "condition": "service_completed_successfully",
                          "restart": true,
                          "required": false
                        }
                      }
                    }
                  },
                  "networks": {},
                  "volumes": {}
                }
                """#,
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
        #expect(project.services["web"]?.dependsOn == [
            "db": ComposeDependency(condition: "service_started"),
            "job": ComposeDependency(condition: "service_completed_successfully", restart: true, required: false),
        ])
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
