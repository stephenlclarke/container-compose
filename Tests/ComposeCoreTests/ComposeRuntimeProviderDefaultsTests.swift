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
import Testing

@Suite("Compose runtime provider defaults")
struct ComposeRuntimeProviderDefaultsTests {
    @Test
    func `library defaults report a missing runtime provider`() async {
        do {
            _ = try await ComposeRuntimeProviderDefaults.images().imageExists("example/api:latest")
            Issue.record("Expected unconfigured runtime failure")
        } catch let error as ComposeError {
            #expect(error == .unsupported("image lookup requires an installed Compose runtime provider"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
