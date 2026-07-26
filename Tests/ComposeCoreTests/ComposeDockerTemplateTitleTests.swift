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

@Suite("Docker output template title")
struct ComposeDockerTemplateTitleTests {
    @Test
    func `title preserves existing case and Go word boundaries`() throws {
        let values: [String: String] = [:]

        #expect(
            try renderDockerTemplate(
                "{{title \"FOO BAR\"}}|{{title \"foo_bar\"}}|{{title \"foo-bar baz\"}}",
                values: values,
            ) == "FOO BAR|Foo_bar|Foo-Bar Baz",
        )
    }

    @Test
    func `title uses simple Unicode title mappings`() throws {
        let values: [String: String] = [:]

        #expect(
            try renderDockerTemplate(
                "{{title \"ǳemo\"}}|{{title \"ßeta\"}}|{{title \"ﬃle\"}}",
                values: values,
            ) == "ǲemo|ßeta|ﬃle",
        )
    }
}
