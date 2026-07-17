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

import ArgumentParser
@testable import ComposePlugin
import Testing

@Suite("Compose environment defaults")
struct ComposeEnvironmentTests {
    @Test("truthy Compose environment values are opt-in")
    func truthyValuesAreOptIn() {
        let environment = ComposeEnvironment(values: [
            "ENABLED": " yes ",
            "DISABLED": "false",
            "MALFORMED": "sometimes",
            "EMPTY": "   ",
        ])

        #expect(environment.value(named: "ENABLED") == "yes")
        #expect(environment.value(named: "EMPTY") == nil)
        #expect(environment.isEnabled("ENABLED"))
        #expect(!environment.isEnabled("DISABLED"))
        #expect(!environment.isEnabled("MALFORMED"))
        #expect(!environment.isEnabled("MISSING"))
    }

    @Test("root options use Compose environment defaults and preserve CLI precedence")
    func rootOptionsUseEnvironmentDefaults() throws {
        let environment = ComposeEnvironment(values: [
            "COMPOSE_ANSI": "always",
            "COMPOSE_COMPATIBILITY": "true",
            "COMPOSE_IGNORE_ORPHANS": "true",
            "COMPOSE_PROGRESS": "json",
            "COMPOSE_REMOVE_ORPHANS": "true",
            "COMPOSE_STATUS_STDOUT": "yes",
        ])
        var options = try GlobalOptions.parse([])

        #expect(options.effectiveANSI(environment: environment) == "always")
        #expect(options.effectiveProgress(environment: environment) == "json")
        #expect(options.progressStyle(environment: environment) == .json)
        #expect(options.shouldColorLogs(noColor: false, environment: environment))
        #expect(options.shouldColorProgress(environment: environment))
        #expect(options.statusOutputUsesStdout(environment: environment))
        #expect(options.effectiveRemoveOrphans(false, environment: environment))

        options.ansi = "never"
        options.progress = "quiet"
        #expect(options.effectiveANSI(environment: environment) == "never")
        #expect(options.effectiveProgress(environment: environment) == "quiet")
        #expect(options.progressStyle(environment: environment) == .quiet)
        #expect(!options.shouldColorProgress(environment: environment))
    }

    @Test("invalid progress values fail before Compose commands run")
    func invalidProgressValuesFailValidation() throws {
        var options = try GlobalOptions.parse([])
        options.progress = "invalid"

        #expect(throws: (any Error).self) {
            try options.validate()
        }
    }
}
