// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
@testable import ComposeEngineRuntime
import ComposeRuntimeSPI
import Foundation
import Testing

struct EngineServiceCreateRequestTests {
    private func plan() -> ContainerServiceCreatePlan {
        var plan = ContainerServiceCreatePlan(identity: .init(name: "app", imageReference: "fixture:latest"))
        plan.resolvedMounts = []
        plan.publishedPorts = []
        return plan
    }

    private func encode(_ plan: ContainerServiceCreatePlan) throws -> [String: Any] {
        let image = try JSONDecoder().decode(EngineImageConfig.self, from: Data(#"{"Cmd":["/bin/true"]}"#.utf8))
        let request = try EngineServiceCreateRequest(plan: plan, image: image)
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    }

    @Test func projectsPreparedServiceWithoutCommandLineParsing() throws {
        var plan = plan()
        plan.labels = ["owner": "test"]
        plan.annotations = ["annotation": "value"]
        plan.processOverrides.environment = ["EMPTY": "", "REMOVE": nil]
        plan.processOverrides.command = ["/custom", "--network", "with spaces"]
        plan.processOverrides.entrypoint = []
        plan.publishedPorts = [
            .init(hostAddress: nil, hostPort: 8080, containerPort: 80, protocolName: "tcp"),
            .init(hostAddress: "[::1]", hostPort: 8081, containerPort: 80, protocolName: "tcp"),
        ]
        plan.exposedPorts = ["9000/udp"]
        plan.launchOptions.resources.memoryLimit = "268435456"
        plan.launchOptions.resources.sharedMemorySize = "32m"
        plan.launchOptions.resources.cpus = "0.25"
        plan.launchOptions.resources.ulimits = ["nofile=1024:2048"]
        plan.launchOptions.security.readOnlyRootFilesystem = true
        plan.launchOptions.security.capabilitiesDropped = ["ALL"]
        plan.launchOptions.dnsServers = ["1.1.1.1"]
        plan.launchOptions.stopSignal = "SIGUSR1"
        plan.launchOptions.stopTimeoutSeconds = 12
        plan.sysctls = ["net.ipv4.ip_forward": "1"]
        var network = ComposeNetworkCreateAttachment(network: "project_net")
        network.aliases = ["database"]
        network.ipv4Address = "10.1.2.3"
        plan.networkAttachments = [network]
        plan.resolvedMounts = [.init(definition: .init(type: "volume", target: "/data", options: .init(
            readOnly: true, volume: .init(noCopy: true, subpath: "child")
        )), source: "project_data")]
        let object = try encode(plan)
        #expect(object["Entrypoint"] as? [String] == [""])
        #expect(object["Cmd"] as? [String] == plan.processOverrides.command)
        #expect(object["Env"] as? [String] == ["EMPTY=", "REMOVE"])
        #expect(object["StopSignal"] as? String == "SIGUSR1")
        #expect(object["StopTimeout"] as? Int == 12)
        let host = try #require(object["HostConfig"] as? [String: Any])
        #expect(host["Memory"] as? Int == 268_435_456)
        #expect(host["ShmSize"] as? Int == 33_554_432)
        #expect(host["NanoCpus"] as? Int == 250_000_000)
        #expect(host["ReadonlyRootfs"] as? Bool == true)
        #expect(host["CapDrop"] as? [String] == ["ALL"])
        let ports = try #require((host["PortBindings"] as? [String: Any])?["80/tcp"] as? [[String: Any]])
        #expect(ports.count == 2 && ports[0]["HostIp"] == nil && ports[1]["HostIp"] as? String == "::1")
        let mounts = try #require(host["Mounts"] as? [[String: Any]])
        #expect(mounts[0]["Source"] as? String == "project_data")
        #expect((mounts[0]["VolumeOptions"] as? [String: Any])?["Subpath"] as? String == "child")
        let networking = try #require(object["NetworkingConfig"] as? [String: Any])
        let endpoints = try #require(networking["EndpointsConfig"] as? [String: Any])
        #expect((endpoints["project_net"] as? [String: Any])?["Aliases"] as? [String] == ["database"])
        #expect((object["ExposedPorts"] as? [String: Any])?.count == 2)
    }

    @Test(arguments: ["none", "host", "default"])
    func specialNetworksUseHostMode(_ mode: String) throws {
        var plan = plan()
        plan.networkAttachments = [.init(network: mode)]
        let object = try encode(plan)
        #expect((object["HostConfig"] as? [String: Any])?["NetworkMode"] as? String == mode)
        let networking = try #require(object["NetworkingConfig"] as? [String: Any])
        let endpoints = try #require(networking["EndpointsConfig"] as? [String: Any])
        #expect(endpoints.isEmpty)
        plan.networkAttachments[0].aliases = ["invalid"]
        #expect(throws: ComposeError.self) { try encode(plan) }
    }

    @Test func healthAndMountPoliciesArePreserved() throws {
        var plan = plan()
        plan.healthCheck = .init(process: .init(executable: "/bin/sh", arguments: ["-c", "true"], environment: []),
                                 intervalInNanoseconds: 1_000_000_000, startIntervalInNanoseconds: 5_000_000_000)
        plan.resolvedMounts = [
            .init(definition: .init(type: "bind", target: "/work", options: .init(
                bind: .init(createHostPath: false, propagation: "rprivate")
            )), source: "/host/work"),
            .init(definition: .init(type: "tmpfs", target: "/run", options: .init(
                tmpfs: .init(size: "16m", mode: "1777")
            )), source: nil),
            .init(definition: .init(type: "image", target: "/assets", options: .init(imageSubpath: "assets")),
                  source: "fixture:assets"),
        ]
        let object = try encode(plan)
        let health = try #require(object["Healthcheck"] as? [String: Any])
        #expect(health["Test"] as? [String] == ["CMD", "/bin/sh", "-c", "true"])
        #expect(health["StartInterval"] as? Int == 5_000_000_000)
        let mounts = try #require((object["HostConfig"] as? [String: Any])?["Mounts"] as? [[String: Any]])
        #expect((mounts[1]["TmpfsOptions"] as? [String: Any])?["SizeBytes"] as? Int == 16_777_216)
        #expect((mounts[1]["TmpfsOptions"] as? [String: Any])?["Mode"] as? Int == 0o1777)
        #expect((mounts[2]["ImageOptions"] as? [String: Any])?["Subpath"] as? String == "assets")
    }

    @Test(arguments: ["", "-1", "1.5", "2oops", "9223372036854775808", "9223372036854775807g"])
    func invalidByteQuantitiesFail(_ value: String) {
        #expect(throws: ComposeError.self) { try EngineServiceCreateRequest.byteQuantity(value) }
    }

    @Test(arguments: ["bad", "1x", "1.2.3", "-1", "0.0000000001", "9223372037"])
    func invalidCPUQuantitiesFail(_ value: String) {
        var plan = plan()
        plan.launchOptions.resources.cpus = value
        #expect(throws: ComposeError.self) { try encode(plan) }
    }

    @Test func incompleteOrNativeOnlyPolicyCannotDisappear() {
        var plan = plan()
        plan.resolvedMounts = nil
        #expect(throws: ComposeError.self) { try encode(plan) }
        plan = self.plan()
        plan.environmentFiles = ["file.env"]
        #expect(throws: ComposeError.self) { try encode(plan) }
        plan = self.plan()
        plan.launchOptions.useEngineAPISocket = true
        #expect(throws: ComposeError.self) { try encode(plan) }
        plan = self.plan()
        plan.launchOptions.resources.deviceMappings = ["/dev/null:/dev/null"]
        #expect(throws: ComposeError.self) { try encode(plan) }
    }

    @Test func expandsExposedRangesWithoutLosingProtocol() throws {
        #expect(try EngineServiceCreateRequest.exposedPortNames(["80", "9000-9002/udp"]) == [
            "80/tcp", "9000/udp", "9001/udp", "9002/udp",
        ])
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func imageMountsRemainReadOnly(_ readOnly: Bool?) throws {
        let definition = ComposeMount(type: "image", target: "/image", options: .init(readOnly: readOnly))
        let mount = ComposeResolvedMount(definition: definition, source: "fixture:latest")
        let actual = try EngineServiceCreateRequest.mountConfiguration(mount)
        guard case let .object(fields) = actual else { Issue.record("Expected mount object"); return }
        #expect(fields["ReadOnly"] == .boolean(true))
    }

    @Test(arguments: ["[::1", "::1]", "[127.0.0.1]"])
    func rejectsMalformedHostBrackets(_ address: String) {
        #expect(throws: ComposeError.self) {
            try EngineServiceCreateRequest.portBindings([
                .init(hostAddress: address, hostPort: 8080, containerPort: 80, protocolName: "tcp"),
            ])
        }
    }

    @Test(arguments: ["", "0", "65536", "2-1", "1-2-3", "80/invalid", "80/tcp/udp", "80/"])
    func rejectsMalformedExposure(_ value: String) {
        #expect(throws: ComposeError.self) { try EngineServiceCreateRequest.exposedPortNames([value]) }
    }
}
