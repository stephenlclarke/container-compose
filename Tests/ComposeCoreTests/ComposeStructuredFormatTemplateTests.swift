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

@Suite("Docker structured output template failures")
struct ComposeStructuredFormatTemplateTests {
    @Test
    func `invalid collection logical and printf operations fail explicitly`() {
        let values: [String: DockerTemplateData] = [
            "Array": .array([.string("alpha")]),
            "Name": .string("demo-api"),
            "Object": .object([:]),
        ]

        for template in [
            "{{index .Array 2}}",
            "{{index .Object}}",
            "{{slice .Array 1 0}}",
            "{{slice .Object 0}}",
            "{{and}}",
            "{{or}}",
            "{{ne .Name .Name .Name}}",
            "{{3-}}",
            "{{printf \"%\"}}",
            "{{printf \"%s\" .Name .Name}}",
            "{{printf \"%f\" .Name}}",
        ] {
            #expect(throws: (any Error).self) {
                try renderDockerTemplate(template, values: values)
            }
        }
    }

    @Test
    func `invalid scalar ranges lengths and mixed comparisons are rejected`() {
        let values: [String: DockerTemplateData] = [
            "False": .boolean(false),
            "Integer": .integer(1),
            "Nothing": .null,
            "Text": .string("1"),
        ]

        for template in [
            "{{range .Text}}{{.}}{{end}}",
            "{{len .Integer}}",
            "{{len .False}}",
            "{{len .Nothing}}",
            "{{eq .Integer .Text}}",
            "{{ne .Integer \"1\"}}",
        ] {
            #expect(throws: (any Error).self) {
                try renderDockerTemplate(template, values: values)
            }
        }
    }

    @Test
    func `quoted field-like literals do not become field references`() {
        #expect(dockerTemplateFields(in: "{{printf \".NotAField\" .Name}}") == ["Name"])
    }
}
