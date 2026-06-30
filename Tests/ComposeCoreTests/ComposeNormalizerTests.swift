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
                driver_opts:
                  com.docker.network.driver.mtu: "1450"
                ipv4_address: 10.10.0.5
            ports:
              - "8080:80"
            environment:
              LOG_LEVEL: debug
            extra_hosts:
              - "somehost=162.242.195.82"
              - "myhostv6=[::1]"
              - "colonhost:10.0.0.5"
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
            volumes:
              - type: volume
                source: data
                target: /data
                volume:
                  labels:
                    com.example.mount: named
              - type: volume
                target: /scratch
                volume:
                  labels:
                    com.example.mount: anonymous
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
          isolated:
            image: alpine:3.20
            network_mode: none
        volumes:
          data:
            driver: local
            driver_opts:
              size: 64m
              journal: ordered
            labels:
              role: state
        networks:
          default:
            internal: true
            ipam:
              config:
                - subnet: 10.10.0.0/24
                - subnet: fd00:10::/64
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
        #expect(project.services["api"]?.networkOptions == [
            "default": ComposeNetworkOptions(
                driverOpts: ["com.docker.network.driver.mtu": "1450"],
                addressing: .init(ipv4Address: "10.10.0.5")
            ),
        ])
        #expect(project.services["api"]?.environment?["LOG_LEVEL"] == "debug")
        #expect(project.services["api"]?.extraHosts?.sorted() == [
            "colonhost:10.0.0.5",
            "myhostv6:::1",
            "somehost:162.242.195.82",
        ])
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
        #expect(project.services["api"]?.volumes == [
            ComposeMount(
                type: "volume",
                source: "data",
                target: "/data",
                volumeLabels: ["com.example.mount": "named"]
            ),
            ComposeMount(
                type: "volume",
                target: "/scratch",
                volumeLabels: ["com.example.mount": "anonymous"]
            ),
        ])
        #expect(project.services["api"]?.stopSignal == "SIGUSR1")
        #expect(project.services["api"]?.stopGracePeriodSeconds == 90)
        #expect(project.services["api"]?.links == ["redis:cache"])
        #expect(project.services["api"]?.externalLinks == ["legacy_db:db"])
        #expect(project.services["api"]?.dependsOn == ["redis": ComposeDependency(condition: "service_started", restart: true, required: false)])
        #expect(project.services["api"]?.ports == ["8080:80"])
        #expect(project.services["isolated"]?.networkMode == "none")
        #expect(project.networks["default"] == ComposeNetwork(
            name: "sample_default",
            isInternal: true,
            subnets: ComposeNetwork.Subnets(
                ipv4Subnet: "10.10.0.0/24",
                ipv6Subnet: "fd00:10::/64"
            )
        ))
        #expect(project.volumes["data"] == ComposeVolume(
            name: "sample_data",
            driver: "local",
            driverOpts: [
                "journal": "ordered",
                "size": "64m",
            ],
            labels: ["role": "state"]
        ))
    }

    @Test("normalizer preserves entrypoint command and environment forms")
    func normalizerPreservesEntrypointCommandAndEnvironmentForms() async throws {
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
          map:
            image: alpine
            entrypoint: ["/bin/sh", "-c"]
            command: ["echo map"]
            environment:
              MAP_EMPTY:
              MAP_VALUE: one
          list:
            image: alpine
            environment:
              - LIST_EMPTY=
              - CONTAINER_COMPOSE_TEST_UNSET_LIST_INHERIT
              - LIST_VALUE=two=with=equals
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(files: [composeFile.path]))

        #expect(project.services["map"]?.entrypoint == ["/bin/sh", "-c"])
        #expect(project.services["map"]?.command == ["echo map"])
        #expect(project.services["map"]?.environment == [
            "MAP_EMPTY": nil,
            "MAP_VALUE": "one",
        ])
        #expect(project.services["list"]?.environment == [
            "CONTAINER_COMPOSE_TEST_UNSET_LIST_INHERIT": nil,
            "LIST_EMPTY": "",
            "LIST_VALUE": "two=with=equals",
        ])
    }

    @Test("normalizes logging fixture without losing shell variables")
    func normalizesLoggingFixtureWithoutLosingShellVariables() async throws {
        let composeFile = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("examples/logging/compose.yml")

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(files: [composeFile.path]))

        #expect(project.name == "compose-log-fixture")
        #expect(project.services.count == 9)
        #expect(project.services["replicas"]?.scale == 2)
        #expect(project.services["disabled-capture"]?.logging == .object(["driver": .string("none")]))
        #expect(project.services["rotating-json"]?.logging == .object([
            "driver": .string("json-file"),
            "options": .object([
                "max-file": .string("3"),
                "max-size": .string("2k"),
            ]),
        ]))
        #expect(project.services["rotating-local"]?.logging == .object([
            "driver": .string("local"),
            "options": .object([
                "max-file": .string("3"),
                "max-size": .string("2k"),
            ]),
        ]))

        let followCommand = try #require(project.services["follow"]?.command?.last)
        #expect(followCommand.contains(#""$i" -le "${LOG_LINES}""#))
        #expect(followCommand.contains(#"sleep "${LOG_DELAY}""#))

        let tailCommand = try #require(project.services["tail"]?.command?.last)
        #expect(tailCommand.contains(#""$i" -le 12"#))

        let replicaCommand = try #require(project.services["replicas"]?.command?.last)
        #expect(replicaCommand.contains(#""${HOSTNAME:-unknown}""#))

        let fidelityCommand = try #require(project.services["fidelity"]?.command?.last)
        #expect(fidelityCommand.contains(#"printf 'non-utf8:\377\376\n'"#))
    }

    @Test("normalizes dynamic host-bound ports through compose-go")
    func normalizesDynamicHostBoundPortsThroughComposeGo() async throws {
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
            ports:
              - target: 80
                host_ip: 127.0.0.1
              - target: 53
                host_ip: "::1"
                protocol: udp
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        #expect(project.services["api"]?.ports == ["127.0.0.1::80", "[::1]::53/udp"])
    }

    @Test("normalizes supported build secrets through compose-go")
    func normalizesSupportedBuildSecretsThroughComposeGo() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("container-compose-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let composeFile = directory.appendingPathComponent("compose.yml")
        let tokenFile = directory.appendingPathComponent("token.txt")
        let tokenVariable = "BUILD_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(tokenVariable, "secret", 1)
        defer {
            unsetenv(tokenVariable)
        }
        try Data("token\n".utf8).write(to: tokenFile)
        try """
        services:
          api:
            build:
              context: .
              secrets:
                - source: file_token
                  uid: "1000"
                  gid: "1000"
                  mode: 0440
                - source: env_token
                  target: npm_token
          worker:
            build:
              context: .
              secrets:
                - external_token
        secrets:
          file_token:
            file: ./token.txt
          env_token:
            environment: \(tokenVariable)
          external_token:
            external: true
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        #expect(project.services["api"]?.build?.secrets == [
            ComposeBuildSecret(id: "file_token", file: tokenFile.path),
            ComposeBuildSecret(id: "npm_token", environment: tokenVariable),
        ])
        #expect(project.services["api"]?.build?.unsupportedFields == nil)
        #expect(project.services["worker"]?.build?.unsupportedFields == ["secrets"])
    }

    @Test("normalizes volume nocopy as supported no-op")
    func normalizesVolumeNoCopyAsSupportedNoOp() async throws {
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
            volumes:
              - type: volume
                source: cache
                target: /cache
                volume:
                  nocopy: true
        volumes:
          cache: {}
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        let api = try #require(project.services["api"])
        let mount = try #require(api.volumes?.first)
        #expect(mount.type == "volume")
        #expect(mount.source == "cache")
        #expect(mount.target == "/cache")
        #expect(mount.unsupportedFields == nil)
    }

    @Test("normalizes bind create host path policy")
    func normalizesBindCreateHostPathPolicy() async throws {
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
          defaulted:
            image: alpine:3.20
            volumes:
              - ./defaulted:/defaulted
          required:
            image: alpine:3.20
            volumes:
              - type: bind
                source: ./required
                target: /required
                bind:
                  create_host_path: false
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        let defaulted = try #require(project.services["defaulted"]?.volumes?.first)
        let required = try #require(project.services["required"]?.volumes?.first)
        #expect(defaulted.type == "bind")
        #expect(defaulted.bindCreateHostPath == true)
        #expect(required.type == "bind")
        #expect(required.bindCreateHostPath == false)
    }

    @Test("grouped model initializers preserve flat normalized fields")
    func groupedModelInitializersPreserveFlatNormalizedFields() throws {
        let build = ComposeBuild(
            contexts: ComposeBuild.Contexts(
                context: "api",
                dockerfile: "Containerfile",
                dockerfileInline: "FROM alpine:3.20\nRUN echo inline\n",
                additionalContexts: ["shared": "/workspace/shared"]),
            args: ["VERSION": "1"],
            cache: ComposeBuild.Cache(
                from: ["type=registry,ref=example/api:cache"],
                to: ["type=local,dest=.cache"]
            ),
            metadata: ComposeBuild.Metadata(
                labels: ["org.opencontainers.image.title": "api"],
                secrets: [ComposeBuildSecret(id: "token", environment: "TOKEN")],
                ssh: ["default", "git=/tmp/git.sock"]
            ),
            options: ComposeBuild.Options(
                image: ComposeBuild.Options.Image(
                    target: "runtime",
                    noCache: true,
                    pull: true,
                    platforms: ["linux/arm64"],
                    tags: ["example/api:latest"]),
                frontend: ComposeBuild.Options.Frontend(
                    entitlements: ["network.host"],
                    extraHosts: ["build.local=127.0.0.1"],
                    isolation: "hyperv",
                    network: "host",
                    privileged: true,
                    shmSize: "67108864",
                    ulimits: ["nofile=1024:2048"]),
                attestations: ComposeBuild.Options.Attestations(
                    provenance: "mode=max",
                    sbom: "true"
                ),
                unsupportedFields: ["ssh"]
            )
        )
        let network = ComposeNetwork(
            name: "backend",
            isInternal: true,
            subnets: ComposeNetwork.Subnets(
                ipv4Subnet: "10.10.0.0/24",
                ipv6Subnet: "fd00:10::/64"
            )
        )

        #expect(build.cacheFrom == ["type=registry,ref=example/api:cache"])
        #expect(build.cacheTo == ["type=local,dest=.cache"])
        #expect(build.additionalContexts == ["shared": "/workspace/shared"])
        #expect(build.dockerfileInline == "FROM alpine:3.20\nRUN echo inline\n")
        #expect(build.labels == ["org.opencontainers.image.title": "api"])
        #expect(build.secrets == [ComposeBuildSecret(id: "token", environment: "TOKEN")])
        #expect(build.ssh == ["default", "git=/tmp/git.sock"])
        #expect(build.target == "runtime")
        #expect(build.noCache == true)
        #expect(build.pull == true)
        #expect(build.platforms == ["linux/arm64"])
        #expect(build.tags == ["example/api:latest"])
        #expect(build.entitlements == ["network.host"])
        #expect(build.extraHosts == ["build.local=127.0.0.1"])
        #expect(build.isolation == "hyperv")
        #expect(build.network == "host")
        #expect(build.privileged == true)
        #expect(build.shmSize == "67108864")
        #expect(build.ulimits == ["nofile=1024:2048"])
        #expect(build.provenance == "mode=max")
        #expect(build.sbom == "true")
        #expect(build.unsupportedFields == ["ssh"])
        #expect(network.ipv4Subnet == "10.10.0.0/24")
        #expect(network.ipv6Subnet == "fd00:10::/64")

        let encodedNetwork = String(data: try JSONEncoder().encode(network), encoding: .utf8) ?? ""
        #expect(encodedNetwork.contains("\"ipv4Subnet\""))
        #expect(encodedNetwork.contains("\"ipv6Subnet\""))
        #expect(!encodedNetwork.contains("\"subnets\""))
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

    @Test("normalizes supported deploy local fields through compose-go")
    func normalizesSupportedDeployLocalFieldsThroughComposeGo() async throws {
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
            deploy:
              mode: replicated
              replicas: 2
              labels:
                com.example.service: api
              update_config:
                parallelism: 2
                order: stop-first
                delay: 2s
                failure_action: pause
                monitor: 15s
                max_failure_ratio: 0.3
              rollback_config:
                parallelism: 2
                order: stop-first
                failure_action: pause
                monitor: 15s
              placement:
                constraints:
                  - node.role == worker
                preferences:
                  - spread: node.labels.zone
                max_replicas_per_node: 1
              resources:
                limits:
                  cpus: "1.5"
                  memory: 256m
          worker:
            image: alpine:latest
            deploy:
              mode: global
              labels:
                com.example.service: worker
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        let api = try #require(project.services["api"])
        #expect(api.scale == 2)
        #expect(api.deployLabels == ["com.example.service": "api"])
        #expect(api.deployUpdateDelayNanoseconds == 2_000_000_000)
        #expect(api.cpus == "1.5")
        #expect(api.memLimit?.isEmpty == false)
        #expect(api.unsupportedDeployFields == nil)

        let worker = try #require(project.services["worker"])
        #expect(worker.scale == nil)
        #expect(worker.deployLabels == ["com.example.service": "worker"])
        #expect(worker.unsupportedDeployFields == nil)
    }

    @Test("normalizes block IO config through compose-go")
    func normalizesBlockIOConfigThroughComposeGo() async throws {
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
            blkio_config:
              weight: 300
              weight_device:
                - path: "8:0"
                  weight: 700
              device_read_bps:
                - path: "8:0"
                  rate: 1048576
              device_read_iops:
                - path: "8:0"
                  rate: 1000
              device_write_bps:
                - path: "8:0"
                  rate: 2097152
              device_write_iops:
                - path: "8:0"
                  rate: 2000
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        let blkio = try #require(project.services["api"]?.blkioConfig)
        #expect(blkio.weight == 300)
        #expect(blkio.weightDevice == [ComposeBlkioWeightDevice(path: "8:0", weight: 700)])
        #expect(blkio.deviceReadBps == [ComposeBlkioThrottleDevice(path: "8:0", rate: "1048576")])
        #expect(blkio.deviceReadIOps == [ComposeBlkioThrottleDevice(path: "8:0", rate: "1000")])
        #expect(blkio.deviceWriteBps == [ComposeBlkioThrottleDevice(path: "8:0", rate: "2097152")])
        #expect(blkio.deviceWriteIOps == [ComposeBlkioThrottleDevice(path: "8:0", rate: "2000")])
    }

    @Test("normalizes unsupported deploy resource fields through compose-go")
    func normalizesUnsupportedDeployResourceFieldsThroughComposeGo() async throws {
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
            deploy:
              endpoint_mode: dnsrr
              resources:
                limits:
                  cpus: "1.5"
                  memory: 256m
                  pids: 64
                reservations:
                  cpus: "0.5"
                  memory: 128m
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        let api = try #require(project.services["api"])
        #expect(api.cpus == "1.5")
        #expect(api.memLimit?.isEmpty == false)
        #expect(api.unsupportedDeployFields == [
            "resources.limits.pids",
        ])
    }

    @Test("normalizes deploy restart policy through compose-go")
    func normalizesDeployRestartPolicyThroughComposeGo() async throws {
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
            deploy:
              restart_policy:
                condition: on-failure
                delay: 5s
                max_attempts: 3
                window: 30s
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        let api = try #require(project.services["api"])
        let policy = try #require(api.deployRestartPolicy)
        #expect(policy.condition == "on-failure")
        #expect(policy.delayNanoseconds == 5_000_000_000)
        #expect(policy.maxAttempts == 3)
        #expect(policy.windowNanoseconds == 30_000_000_000)
        #expect(api.unsupportedDeployFields == nil)
    }

    @Test("normalizes deploy job modes through compose-go")
    func normalizesDeployJobModesThroughComposeGo() async throws {
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
            deploy:
              mode: replicated-job
              replicas: 2
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        let api = try #require(project.services["api"])
        #expect(api.scale == 2)
        #expect(api.deployMode == "replicated-job")
        #expect(api.unsupportedDeployFields == nil)
    }

    @Test("normalizes start-first deploy update through compose-go")
    func normalizesStartFirstDeployUpdateThroughComposeGo() async throws {
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
            deploy:
              update_config:
                order: start-first
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(
            files: [composeFile.path],
            projectName: "sample",
            projectDirectory: directory.path
        ))

        let api = try #require(project.services["api"])
        #expect(api.unsupportedDeployFields == ["update_config.order.start-first"])
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
          embedding-model:
            model: example/local-embed
        services:
          api:
            image: alpine
            provider:
              type: example
              options:
                endpoint: local
                tag:
                  - one
                  - two
            models:
              llm:
                endpoint_var: MODEL_ENDPOINT
                model_var: MODEL_ID
              embedding-model: {}
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
        #expect(api.provider == ComposeProvider(type: "example", options: ["endpoint": ["local"], "tag": ["one", "two"]]))
        #expect(api.models?["llm"] == ComposeServiceModelBinding(endpointVariable: "MODEL_ENDPOINT", modelVariable: "MODEL_ID"))
        #expect(api.models?["embedding-model"] == ComposeServiceModelBinding())
        #expect(api.healthcheck == .object(["disable": .bool(true)]))
        #expect(api.configs == [.object(["source": .string("app_config"), "target": .string("/etc/app.conf")])])
        #expect(api.secrets == [.object(["source": .string("app_secret"), "target": .string("/run/secrets/app_secret")])])
        #expect(api.extensions?["x-service"] == .object(["owner": .string("platform")]))
    }

    @Test("normalizer preserves develop watch triggers")
    func normalizerPreservesDevelopWatchTriggers() async throws {
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
            image: alpine
            develop:
              watch:
                - path: ./src
                  action: rebuild
                  include:
                    - "*.swift"
                  ignore:
                    - .build/
                - path: ./assets
                  action: sync+exec
                  target: /app/assets
                  initial_sync: true
                  exec:
                    command: ["sh", "-c", "touch /tmp/reloaded"]
                    user: app
                    working_dir: /app
                    environment:
                      MODE: dev
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(files: [composeFile.path]))
        let api = try #require(project.services["api"])
        let watch = try #require(api.develop?.watch)

        #expect(watch.count == 2)
        #expect(watch[0].path.hasSuffix("/src"))
        #expect(watch[0].action == "rebuild")
        #expect(watch[0].ignore == [".build/"])
        #expect(watch[0].include == ["*.swift"])
        #expect(watch[1].path.hasSuffix("/assets"))
        #expect(watch[1].action == "sync+exec")
        #expect(watch[1].target == "/app/assets")
        #expect(watch[1].initialSync == true)
        #expect(watch[1].exec == ComposeDevelopWatchExec(
            command: ["sh", "-c", "touch /tmp/reloaded"],
            user: "app",
            workingDir: "/app",
            environment: ["MODE": "dev"]
        ))
    }

    @Test("normalizer preserves service lifecycle hooks")
    func normalizerPreservesServiceLifecycleHooks() async throws {
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
            image: alpine
            post_start:
              - command: ["sh", "-c", "touch /tmp/ready"]
                user: app
                working_dir: /srv
                environment:
                  READY: "1"
                  FROM_HOST:
            pre_stop:
              - command: ["sh", "-c", "echo stopping"]
                privileged: true
        """.write(to: composeFile, atomically: true, encoding: .utf8)

        let project = try await ComposeNormalizer().normalize(options: ComposeOptions(files: [composeFile.path]))
        let api = try #require(project.services["api"])

        #expect(api.postStart == [
            ComposeServiceHook(
                command: ["sh", "-c", "touch /tmp/ready"],
                user: "app",
                workingDir: "/srv",
                environment: ["FROM_HOST": nil, "READY": "1"]
            ),
        ])
        #expect(api.preStop == [
            ComposeServiceHook(
                command: ["sh", "-c", "echo stopping"],
                privileged: true
            ),
        ])
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

        let currentDirectory = FileManager.default.currentDirectoryPath
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
        #expect(command.arguments.containsSequence(["--file", "\(currentDirectory)/compose.yml"]))
        #expect(command.arguments.containsSequence(["--profile", "dev"]))
        #expect(command.arguments.containsSequence(["--env-file", "\(currentDirectory)/.env"]))
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

        let currentDirectory = FileManager.default.currentDirectoryPath
        _ = try await ComposeNormalizer(runner: runner, fallbackLauncher: "custom-env")
            .normalize(options: ComposeOptions(files: ["compose.yml"], projectDirectory: "/tmp/demo"))

        let command = try #require(runner.commands.first)
        #expect(command.executable == "custom-env")
        #expect(command.arguments.starts(with: ["go", "run", "."]))
        #expect(command.arguments.containsSequence(["--file", "\(currentDirectory)/compose.yml"]))
        #expect(command.arguments.containsSequence(["--project-directory", "/tmp/demo"]))
    }

    @Test("normalizer decodes model variables")
    func normalizerDecodesModelVariables() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"[{"name":"IMAGE_NAME","required":false,"defaultValue":"alpine"},{"name":"REQUIRED","required":true}]"#,
                stderr: ""
            ),
        ])

        let currentDirectory = FileManager.default.currentDirectoryPath
        let variables = try await ComposeNormalizer(runner: runner).variables(options: ComposeOptions(
            files: ["compose.yml"],
            projectName: "demo",
            projectDirectory: "/tmp/demo"
        ))

        #expect(variables == [
            ComposeVariable(name: "IMAGE_NAME", defaultValue: "alpine"),
            ComposeVariable(name: "REQUIRED", required: true),
        ])
        let command = try #require(runner.commands.first)
        #expect(command.arguments.contains("--variables"))
        #expect(command.arguments.containsSequence(["--file", "\(currentDirectory)/compose.yml"]))
        #expect(command.arguments.containsSequence(["--project-name", "demo"]))
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

    @Test("normalizer forwards config load switches")
    func normalizerForwardsConfigLoadSwitches() async throws {
        let runner = RecordingRunner(responses: [
            CommandResult(
                status: 0,
                stdout: #"{"name":"demo","workingDirectory":"/tmp/demo","composeFiles":["compose.yml"],"services":{"web":{"name":"web","image":"nginx"}},"networks":{},"volumes":{}}"#,
                stderr: ""
            ),
        ])

        _ = try await ComposeNormalizer(runner: runner).normalize(options: ComposeOptions(
            files: ["compose.yml"],
            projectDirectory: "/tmp/demo",
            normalization: ComposeOptions.NormalizationOptions {
                $0.noConsistency = true
                $0.noEnvResolution = true
                $0.noInterpolate = true
                $0.noNormalize = true
                $0.noPathResolution = true
            }
        ))

        let command = try #require(runner.commands.first)
        #expect(command.arguments.contains("--no-consistency"))
        #expect(command.arguments.contains("--no-env-resolution"))
        #expect(command.arguments.contains("--no-interpolate"))
        #expect(command.arguments.contains("--no-normalize"))
        #expect(command.arguments.contains("--no-path-resolution"))
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
                command: "/usr/bin/env go run . --file \(FileManager.default.currentDirectoryPath)/compose.yml --project-directory \(FileManager.default.currentDirectoryPath)",
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

    @Test("normalizer maps missing compose file to Docker compatible error")
    func normalizerMapsMissingComposeFileToDockerCompatibleError() async throws {
        let missingFileResult = CommandResult(
            status: 1,
            stdout: "",
            stderr: "compose-normalizer: no compose file found\nexit status 1\n"
        )

        do {
            _ = try await ComposeNormalizer(runner: RecordingRunner(responses: [
                missingFileResult,
            ])).normalize(options: ComposeOptions())
            Issue.record("Expected missing compose file error")
        } catch let error as ComposeError {
            #expect(error == .missingComposeFile)
            #expect(error.description == "no configuration file provided: not found")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try await ComposeNormalizer(runner: RecordingRunner(responses: [
                missingFileResult,
            ])).variables(options: ComposeOptions())
            Issue.record("Expected missing compose file error")
        } catch let error as ComposeError {
            #expect(error == .missingComposeFile)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
