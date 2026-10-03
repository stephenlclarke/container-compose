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

struct ComposeNetworkCreatePlanTests {
    @Test(arguments: ["none", "host", "bridge"])
    func preservesSpecialNetworkModes(mode: String) async throws {
        var service = ComposeService(name: "app", image: "fixture:latest")
        service.networkMode = mode
        let project = composeProject(name: "test", services: ["app": service])
        let orchestrator = ComposeOrchestrator(options: .init(dryRun: true))
        let plan = try await orchestrator.serviceCreatePlan(
            project: project, serviceName: "app", options: .init(resolveHealthCheck: false)
        )
        let expected = mode == "bridge" ? "default" : mode
        #expect(plan.networkAttachments == [.init(network: expected)])
        let arguments = try await orchestrator.runArguments(project: project, service: service)
        #expect(zip(arguments, arguments.dropFirst()).contains { $0 == "--network" && $1 == expected })
    }

    @Test func preservesOrderedAttachmentsAndIndependentMACPriority() async throws {
        var service = ComposeService(name: "app", image: "fixture:latest")
        service.networks = ["frontend", "backend"]
        service.macAddress = "02:42:ac:11:00:03"
        service.networkOptions = [
            "frontend": .init(gatewayPriority: 10, priority: 100),
            "backend": .init(gatewayPriority: 100, priority: 10)
        ]
        let project = composeProject(name: "demo", services: ["app": service]) {
            $0.networks = ["frontend": .init(name: "frontend"), "backend": .init(name: "backend")]
        }
        let orchestrator = ComposeOrchestrator(options: .init(dryRun: true))
        let plan = try await orchestrator.serviceCreatePlan(
            project: project, serviceName: "app", options: .init(resolveHealthCheck: false)
        )
        #expect(plan.networkAttachments.map(\.network) == ["demo_backend", "demo_frontend"])
        #expect(plan.networkAttachments[0].macAddress == nil)
        #expect(plan.networkAttachments[1].macAddress == service.macAddress)
        #expect(plan.networkAttachments.map(\.nativeArgument) ==
            ["demo_backend", "demo_frontend,mac=02:42:ac:11:00:03"])
    }

    @Test func preservesAllSupportedAttachmentOptions() throws {
        var execution = ComposeExecutionOptions(dryRun: true)
        execution.runtimeCapabilities = .init(
            identifiers: [ComposeRuntimeCapabilities.networkScopedAliasesV1Identifier]
        )
        let orchestrator = ComposeOrchestrator(options: execution)
        var service = ComposeService(name: "app", image: "fixture:latest")
        service.networks = ["backend"]
        service.networkAliases = ["backend": ["app.internal"]]
        service.externalLinks = ["external:legacy"]
        service.networkOptions = ["backend": .init(
            driverOpts: ["mtu": "1400"], interfaceName: "eth9",
            addressing: .init(ipv4Address: "192.0.2.10", ipv6Address: "2001:db8::10",
                              linkLocalIPs: ["169.254.8.8"], macAddress: "02:42:ac:11:00:03")
        )]
        var network = ComposeNetwork(name: "shared")
        network.external = true
        let project = composeProject(name: "demo", services: ["app": service]) {
            $0.networks = ["backend": network]
        }
        let attachment = try orchestrator.networkAttachmentPlan(project: project, service: service, network: "backend")
        #expect(attachment.network == "shared")
        #expect(attachment.aliases.contains("app.internal"))
        #expect(attachment.scopedAliasMappings == ["legacy:external"])
        #expect(attachment.mtu == "1400")
        #expect(attachment.macAddress == "02:42:ac:11:00:03")
        #expect(attachment.interfaceName == "eth9")
        #expect(attachment.ipv4Address == "192.0.2.10")
        #expect(attachment.ipv6Address == "2001:db8::10")
        #expect(attachment.linkLocalAddresses == ["169.254.8.8"])
        let encoded = try JSONEncoder().encode(attachment)
        #expect(try JSONDecoder().decode(ComposeNetworkCreateAttachment.self, from: encoded) == attachment)
        #expect(attachment.nativeArgument.hasSuffix(
            ",dns-alias=legacy:external,mac=02:42:ac:11:00:03,mtu=1400,interface=eth9," +
                "ip=192.0.2.10,ip6=2001:db8::10,address=169.254.8.8"
        ))
        #expect(try networkStaticAddressOptions(project: project, service: service, network: "backend") ==
            ["ip=192.0.2.10", "ip6=2001:db8::10"])
    }
}
