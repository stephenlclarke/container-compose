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

struct ComposePublishedPortBindingTests {
    @Test func expandsRangesAndPreservesIPv6AndProtocol() throws {
        let orchestrator = ComposeOrchestrator(options: .init(dryRun: true))
        let bindings = try orchestrator.publishedPortBindings(
            ports: ["[::1]:9000-9003:80-81/udp", "127.0.0.1:9100-9101:90"],
            serviceName: "app", replicaIndex: 2, replicaCount: 2
        )
        #expect(bindings == [
            .init(hostAddress: "[::1]", hostPort: 9002, containerPort: 80, protocolName: "udp"),
            .init(hostAddress: "[::1]", hostPort: 9003, containerPort: 81, protocolName: "udp"),
            .init(hostAddress: "127.0.0.1", hostPort: 9101, containerPort: 90, protocolName: "tcp")
        ])
        #expect(bindings.map(orchestrator.publishedPortArgument) == [
            "[::1]:9002:80/udp", "[::1]:9003:81/udp", "127.0.0.1:9101:90"
        ])
        let encoded = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode([ComposePublishedPortBinding].self, from: encoded) == bindings)
    }

    @Test func launchAllocatesOnlyOnceAndRetainsExactBindings() async throws {
        let ports = HostPortSource([49157, 49158, 49159])
        var options = ComposeExecutionOptions(hostPortAllocator: {
            try ports.next(hostAddress: $0, protocolName: $1)
        })
        options.dryRun = true
        let orchestrator = ComposeOrchestrator(options: options)
        let service = composeService(name: "app", image: "fixture:latest") {
            $0.ports = ["80-81/udp", "[::1]::90"]
        }
        let project = composeProject(name: "demo", services: ["app": service])
        let preliminary = try await orchestrator.serviceCreatePlan(
            project: project, serviceName: "app", options: .init(resolveHealthCheck: false)
        )
        #expect(preliminary.publishedPorts == nil)
        #expect(ports.requests.isEmpty)
        let launch = try await orchestrator.serviceLaunchPlan(project: project, service: service)
        let bindings = try #require(launch.configuration.publishedPorts)
        #expect(bindings.map(\.hostPort) == [49157, 49158, 49159])
        #expect(bindings.map(\.containerPort) == [80, 81, 90])
        #expect(bindings.map(\.hostAddress) == [nil, nil, "[::1]"])
        for binding in bindings {
            #expect(launch.arguments.containsSequence(["--publish", orchestrator.publishedPortArgument(binding)]))
        }
        #expect(ports.requests == [
            .init(hostAddress: nil, protocolName: "udp"),
            .init(hostAddress: nil, protocolName: "udp"),
            .init(hostAddress: "[::1]", protocolName: "tcp")
        ])
    }

    @Test func explicitEmptyOverrideDoesNotAllocateServicePorts() async throws {
        let ports = HostPortSource([])
        var options = ComposeExecutionOptions(hostPortAllocator: {
            try ports.next(hostAddress: $0, protocolName: $1)
        })
        options.dryRun = true
        let orchestrator = ComposeOrchestrator(options: options)
        let service = composeService(name: "app", image: "fixture:latest") { $0.ports = ["80"] }
        var run = RunArgumentOptions()
        run.publishedPorts = []
        let launch = try await orchestrator.serviceLaunchPlan(
            project: composeProject(name: "demo", services: ["app": service]), service: service, options: run
        )
        #expect(launch.configuration.publishedPorts == [])
        #expect(!launch.arguments.contains("--publish"))
        #expect(ports.requests.isEmpty)
    }

    @Test func rejectsInvalidRangesAndReplicaIndicesBeforeAllocation() throws {
        let ports = HostPortSource([])
        let orchestrator = ComposeOrchestrator(options: .init(hostPortAllocator: {
            try ports.next(hostAddress: $0, protocolName: $1)
        }))
        for port in ["8000:80-81", "invalid"] {
            #expect(throws: ComposeError.self) {
                try orchestrator.publishedPortBindings(port: port, serviceName: "app")
            }
        }
        for (index, count) in [(0, 2), (3, 2), (1, 0), (1, Int.max)] {
            #expect(throws: ComposeError.self) {
                try orchestrator.publishedPortBindings(
                    port: "8000-8003:80-81", serviceName: "app", replicaIndex: index, replicaCount: count
                )
            }
        }
        #expect(throws: ComposeError.self) {
            try orchestrator.validateScaledPublishedPorts(
                ["8000-8003:80-81"], serviceName: "app", replicaCount: Int.max
            )
        }
        #expect(ports.requests.isEmpty)
    }
}
