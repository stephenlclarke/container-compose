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
import ComposeCore
@testable import ComposePlugin
import Testing

@Suite("Compose run exit codes")
struct ComposeRunExitCodeTests {
    @Test
    func `command failures preserve the one-off process exit status`() throws {
        let error = ComposeRunExitError(status: 7)

        do {
            try throwRunCommandError(error)
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue == 7)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `non-command failures retain their original error`() throws {
        let expected = ComposeError.invalidProject("missing service")

        do {
            try throwRunCommandError(expected)
        } catch let error as ComposeError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
