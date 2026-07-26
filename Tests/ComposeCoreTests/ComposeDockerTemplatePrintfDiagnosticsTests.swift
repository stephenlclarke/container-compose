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

@Suite("Docker output template printf diagnostics")
struct DockerTemplatePrintfDiagnosticsTests {
    @Test
    func `printf renders Go diagnostics for missing arguments`() throws {
        let values = ["Name": DockerTemplateData.string("demo-api")]

        #expect(
            try renderDockerTemplate(
                #"{{printf "%s%s" .Name}}"#,
                values: values,
            ) == "demo-api%!s(MISSING)",
        )
        #expect(
            try renderDockerTemplate(
                #"{{printf "%d|%q|%v"}}"#,
                values: values,
            ) == "%!d(MISSING)|%!q(MISSING)|%!v(MISSING)",
        )
    }
}
