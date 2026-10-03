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

struct ComposeResolvedMountTests {
    private var service: ComposeService {
        .init(name: "app", image: "fixture:latest")
    }

    private var project: ComposeProject {
        composeProject(name: "demo", services: ["app": service]) {
            $0.volumes = ["data": .init(name: "data")]
        }
    }

    @Test func preservesPolicyAndResolvesSourcesOnce() throws {
        let orchestrator = ComposeOrchestrator(options: .init(dryRun: true))
        let context = MountRenderContext(
            project: project, service: service, containerName: "demo-app-1", oneOff: false, containerIndex: 1
        )
        for mount in examples {
            let plan = try orchestrator.resolvedMount(mount, context: context)
            #expect(plan.definition == mount)
            let data = try JSONEncoder().encode(plan)
            #expect(try JSONDecoder().decode(ComposeResolvedMount.self, from: data) == plan)
            var direct: [String] = []
            var compatibility: [String] = []
            try orchestrator.appendResolvedMount(plan, args: &direct)
            try orchestrator.appendMount(mount, context: context, args: &compatibility)
            #expect(direct == compatibility)
            if mount.type == "volume", mount.source == "data" {
                #expect(plan.source == "demo_data")
                #expect(direct.joined().contains("source=demo_data"))
                #expect(!direct.joined().contains("demo_demo_data"))
            } else {
                #expect(plan.source == mount.source)
            }
        }
    }

    @Test func anonymousMountIdentityIsStableAndReplicaScoped() throws {
        let orchestrator = ComposeOrchestrator(options: .init(dryRun: true))
        let mount = ComposeMount(type: "volume", target: "/data")
        var context = MountRenderContext(
            project: project, service: service, containerName: "demo-app-1", oneOff: false, containerIndex: 1
        )
        let first = try orchestrator.resolvedMount(mount, context: context)
        #expect(try orchestrator.resolvedMount(mount, context: context) == first)
        #expect(first.source?.hasPrefix("demo_anon-app-1-") == true)
        context.containerIndex = 2
        #expect(try orchestrator.resolvedMount(mount, context: context).source != first.source)
        context.oneOff = true
        #expect(try orchestrator.resolvedMount(mount, context: context).source != first.source)
        #expect(throws: ComposeError.self) {
            try orchestrator.resolvedMount(.init(type: "bind", source: "/work"), context: context)
        }
    }

    @Test func launchPlanRetainsResolvedMountsAndTmpfs() async throws {
        var service = service
        service.volumes = [.init(type: "volume", source: "data", target: "/data")]
        service.tmpfs = ["/run"]
        let orchestrator = ComposeOrchestrator(options: .init(dryRun: true))
        var project = project
        project.services["app"] = service
        let preliminary = try await orchestrator.serviceCreatePlan(
            project: project, serviceName: "app", options: .init(resolveHealthCheck: false)
        )
        #expect(preliminary.resolvedMounts == nil)
        let launch = try await orchestrator.serviceLaunchPlan(project: project, service: service)
        let mounts = try #require(launch.configuration.resolvedMounts)
        #expect(mounts.count == 1)
        #expect(mounts.first?.source == "demo_data")
        #expect(launch.configuration.tmpfs == ["/run"])
        #expect(launch.arguments.contains("demo_data:/data"))
        #expect(zip(launch.arguments, launch.arguments.dropFirst()).contains { $0 == "--tmpfs" && $1 == "/run" })
    }

    private var examples: [ComposeMount] {
        [
            .init(type: "volume", source: "data", target: "/data", options: .init(
                readOnly: true, volume: .init(noCopy: true, subpath: "nested", labels: ["owner": "test"])
            )),
            .init(type: "external-volume", source: "shared", target: "/shared", options: .init(
                volume: .init(subpath: "dir")
            )),
            .init(type: "bind", source: "/work", target: "/workspace", options: .init(
                readOnly: true, volume: .init(fileOwnership: .init(uid: 1000, gid: 1001))
            )),
            .init(type: "bind", source: "/work", target: "/workspace", options: .init(
                bind: .init(propagation: "rprivate")
            )),
            .init(type: "tmpfs", target: "/run", options: .init(
                readOnly: true, tmpfs: .init(size: "16m", mode: "1777")
            )),
            .init(type: "image", source: "fixture:latest", target: "/image", options: .init(imageSubpath: "assets"))
        ]
    }
}
