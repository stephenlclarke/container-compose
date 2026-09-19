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
import ComposeRuntimeSPI
import Testing

struct ComposeHealthPolicyPreflightTests {
    @Test(arguments: ["up", "create", "run"])
    func `unsupported health gateway fails before project resources`(operation: String) async throws {
        let runner = RecordingRunner()
        let resources = RecordingContainerResourceManager()
        let launch = RejectingHealthLaunchManager()
        let project = composeProject(name: "demo", services: [
            "app": composeService(name: "app", image: "alpine") {
                $0.healthcheck = .object(["test": .array([.string("CMD"), .string("true")])])
                $0.networks = ["backend"]
            },
        ]) { $0.networks = ["backend": ComposeNetwork(name: "backend")] }
        let dependencies = orchestratorDependencies {
            $0.launchManager = launch
            $0.resourceManager = resources
        }
        let orchestrator = ComposeOrchestrator(runner: runner, dependencies: dependencies)
        do {
            switch operation {
            case "up": try await orchestrator.up(project: project, options: ComposeUpOptions())
            case "create": try await orchestrator.create(project: project, options: ComposeCreateOptions())
            default: try await orchestrator.run(project: project, serviceName: "app", options: ComposeRunOptions())
            }
            Issue.record("Expected gateway health-policy rejection")
        } catch let error as ComposeError {
            #expect(error == .unsupported("test gateway lacks health policy"))
        }
        #expect(await launch.validations == [["--health-cmd", "true"]])
        #expect(await launch.launches == 0)
        #expect(await resources.requests.isEmpty)
        #expect(runner.commands.isEmpty)
    }

    @Test
    func `dry run does not negotiate a live health gateway`() async throws {
        let launch = RejectingHealthLaunchManager()
        let dependencies = orchestratorDependencies { $0.launchManager = launch }
        let orchestrator = ComposeOrchestrator(
            options: ComposeExecutionOptions(dryRun: true), dependencies: dependencies
        )
        let service = composeService(name: "app", image: "alpine") {
            $0.healthcheck = .object(["test": .string("true")])
        }
        let project = ComposeProject(name: "demo", services: ["app": service])
        try await orchestrator.validateRuntimeHealthChecks(
            project: project, services: [service], cache: ComposeImageHealthCheckCache()
        )
        #expect(await launch.validations.isEmpty)
    }
}

private actor RejectingHealthLaunchManager: ComposeRuntimeContainerLaunching {
    var validations: [[String]] = []
    var launches = 0
    func validateHealthCheckArguments(_ arguments: [String]) async throws {
        validations.append(arguments)
        throw ComposeError.unsupported("test gateway lacks health policy")
    }

    func launchContainer(_: ComposeRuntimeContainerLaunchRequest) async throws -> Int32 {
        launches += 1
        return 0
    }
}
