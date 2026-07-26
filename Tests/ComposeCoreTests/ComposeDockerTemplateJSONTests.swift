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

@Suite("Docker output template JSON")
struct ComposeDockerTemplateJSONTests {
    @Test
    func `JSON repairs only invalid UTF8 bytes`() throws {
        let values: [String: DockerTemplateData] = [:]

        #expect(
            try renderDockerTemplate(
                #"{{json (truncate "aéz" 2)}}"#,
                values: values,
            ) == #""a\ufffd""#,
        )
        #expect(
            try renderDockerTemplate(
                #"{{json "a�"}}"#,
                values: values,
            ) == #""a�""#,
        )
    }

    @Test
    func `JSON preserves publisher record field order`() throws {
        let values: [String: DockerTemplateData] = [
            "Publishers": .array([
                .record([
                    "Protocol": .string("tcp"),
                    "PublishedPort": .integer(32768),
                    "TargetPort": .integer(8080),
                    "URL": .string("127.0.0.1"),
                ]),
            ]),
        ]

        #expect(
            try renderDockerTemplate(
                "{{json .Publishers}}",
                values: values,
            ) == #"[{"URL":"127.0.0.1","TargetPort":8080,"PublishedPort":32768,"Protocol":"tcp"}]"#,
        )
    }
}
