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

struct ComposeProcessOverridesTests {
    @Test(arguments: [nil, [], ["/custom", "--flag"]] as [[String]?],
          [nil, [], ["arg with spaces", "--network", ""]] as [[String]?])
    func preservesInheritanceAndExplicitClearing(entrypoint: [String]?, command: [String]?) async throws {
        let service = composeService(name: "app", image: "fixture:latest") {
            $0.entrypoint = entrypoint
            $0.command = command
        }
        let project = composeProject(name: "test", services: ["app": service])
        let orchestrator = ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true))
        let plan = try await orchestrator.serviceCreatePlan(
            project: project, serviceName: "app", options: .init(resolveHealthCheck: false)
        )
        #expect(plan.processOverrides.entrypoint == entrypoint)
        #expect(plan.processOverrides.command == command)
        let data = try JSONEncoder().encode(plan.processOverrides)
        #expect(try JSONDecoder().decode(ComposeProcessOverrides.self, from: data) == plan.processOverrides)
        let arguments = try await orchestrator.runArguments(project: project, service: service)
        #expect(arguments.contains("--clear-entrypoint") == (entrypoint == []))
        #expect(arguments.contains("--entrypoint") == (entrypoint?.isEmpty == false))
        let imageIndex = try #require(arguments.firstIndex(of: "fixture:latest"))
        #expect(Array(arguments.dropFirst(imageIndex + 1)) == Array((entrypoint ?? []).dropFirst()) + (command ?? []))
        if let first = entrypoint?.first {
            let index = try #require(arguments.firstIndex(of: "--entrypoint"))
            #expect(arguments[index + 1] == first)
        }
    }

    @Test func preservesProcessSettingsAndNullEnvironment() async throws {
        let environment: [String: String?] = ["EMPTY": "", "INHERIT": nil, "VALUE": "a=b with spaces"]
        let service = composeService(name: "app", image: "fixture:latest") {
            $0.environment = environment
            $0.workingDir = "/work space"
            $0.user = "1000:1001"
            $0.tty = true
            $0.stdinOpen = true
        }
        let project = composeProject(name: "test", services: ["app": service])
        let orchestrator = ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: true))
        let plan = try await orchestrator.serviceCreatePlan(
            project: project, serviceName: "app", options: .init(resolveHealthCheck: false)
        )
        let expected = ComposeProcessOverrides(
            environment: environment, workingDirectory: "/work space", user: "1000:1001",
            terminal: true, openStandardInput: true
        )
        #expect(plan.processOverrides == expected)
        let data = try JSONEncoder().encode(expected)
        #expect(try JSONDecoder().decode(ComposeProcessOverrides.self, from: data) == expected)
        let arguments = try await orchestrator.runArguments(project: project, service: service)
        for (flag, value) in [("--env", "EMPTY="), ("--env", "INHERIT"), ("--env", "VALUE=a=b with spaces"),
                              ("--workdir", "/work space"), ("--user", "1000:1001")]
        {
            #expect(zip(arguments, arguments.dropFirst()).contains { $0 == flag && $1 == value })
        }
        #expect(arguments.contains("--tty"))
        #expect(arguments.contains("--interactive"))
    }
}
