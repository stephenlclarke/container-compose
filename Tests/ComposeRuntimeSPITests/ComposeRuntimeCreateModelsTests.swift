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

@testable import ComposeRuntimeSPI
import Foundation
import Testing

@Suite("Compose runtime create models")
struct ComposeRuntimeCreateModelsTests {
    @Test
    func `process decoding defaults fields added by newer runtimes`() throws {
        let data = Data(
            """
            {
              "executable": "/bin/true",
              "arguments": [],
              "environment": [],
              "workingDirectory": "/",
              "terminal": false,
              "user": {"id": {"uid": 0, "gid": 0}},
              "supplementalGroups": [],
              "rlimits": []
            }
            """.utf8,
        )

        let process = try JSONDecoder().decode(ComposeProcessConfiguration.self, from: data)

        #expect(process.supplementalGroupNames.isEmpty)
        #expect(process.oomScoreAdj == nil)
        #expect(!process.privileged)
        #expect(!process.noNewPrivileges)
    }

    @Test
    func `restart decoding reapplies mode invariants`() throws {
        let always = try JSONDecoder().decode(
            ComposeRestartPolicy.self,
            from: Data(
                """
                {
                  "mode": "always",
                  "maximumRetryCount": 4,
                  "retryDelayInNanoseconds": 5,
                  "successfulRunDurationInNanoseconds": 6
                }
                """.utf8,
            ),
        )
        let disabled = try JSONDecoder().decode(
            ComposeRestartPolicy.self,
            from: Data(
                """
                {
                  "mode": "no",
                  "maximumRetryCount": 4,
                  "retryDelayInNanoseconds": 5,
                  "successfulRunDurationInNanoseconds": 6
                }
                """.utf8,
            ),
        )
        let unlimited = try JSONDecoder().decode(
            ComposeRestartPolicy.self,
            from: Data(
                """
                {
                  "mode": "on-failure",
                  "maximumRetryCount": 0
                }
                """.utf8,
            ),
        )

        #expect(always.maximumRetryCount == nil)
        #expect(always.retryDelayInNanoseconds == 5)
        #expect(always.successfulRunDurationInNanoseconds == 6)
        #expect(disabled.maximumRetryCount == nil)
        #expect(disabled.retryDelayInNanoseconds == nil)
        #expect(disabled.successfulRunDurationInNanoseconds == nil)
        #expect(unlimited.maximumRetryCount == nil)
    }

    @Test
    func `legacy process initializer forwards every runtime option`() {
        let process = ComposeProcessConfiguration(
            executable: "/usr/bin/worker",
            arguments: ["--serve"],
            environment: ["A=1"],
            workingDirectory: "/srv",
            terminal: true,
            user: .raw(userString: "app:staff"),
            supplementalGroups: [10, 20],
            supplementalGroupNames: ["video"],
            rlimits: [.init(limit: "RLIMIT_NOFILE", soft: 1024, hard: 2048)],
            oomScoreAdj: -50,
            privileged: true,
            noNewPrivileges: true,
        )

        #expect(process.executable == "/usr/bin/worker")
        #expect(process.arguments == ["--serve"])
        #expect(process.environment == ["A=1"])
        #expect(process.workingDirectory == "/srv")
        #expect(process.terminal)
        #expect(process.user == .raw(userString: "app:staff"))
        #expect(process.supplementalGroups == [10, 20])
        #expect(process.supplementalGroupNames == ["video"])
        #expect(process.rlimits == [.init(limit: "RLIMIT_NOFILE", soft: 1024, hard: 2048)])
        #expect(process.oomScoreAdj == -50)
        #expect(process.privileged)
        #expect(process.noNewPrivileges)
    }

    @Test
    func `legacy logging default forwards to standard configuration`() {
        #expect(ComposeLogConfiguration.default == .standard)
    }
}
