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

@Suite("Docker output template range control")
struct ComposeDockerTemplateRangeControlTests {
    @Test
    func `break and continue preserve output before controlling the range`() throws {
        let values: [String: DockerTemplateData] = [
            "Items": .array([.integer(0), .integer(1), .integer(2)]),
        ]

        #expect(
            try renderDockerTemplate(
                "{{range .Items}}{{.}}{{if eq . 1}}{{break}}{{end}}x{{end}}",
                values: values,
            ) == "0x1",
        )
        #expect(
            try renderDockerTemplate(
                "{{range .Items}}A{{if eq . 1}}{{continue}}{{end}}{{.}};{{end}}",
                values: values,
            ) == "A0;AA2;",
        )
        #expect(
            try renderDockerTemplate(
                "{{range .Items}}{{with .}}{{if eq . 1}}{{continue}}{{end}}{{.}}{{end}}x{{end}}",
                values: values,
            ) == "x2x",
        )
    }

    @Test
    func `nested ranges consume only their own control actions`() throws {
        let values: [String: DockerTemplateData] = [
            "Groups": .array([
                .array([.integer(1), .integer(2)]),
                .array([.integer(3), .integer(4)]),
            ]),
        ]

        #expect(
            try renderDockerTemplate(
                "{{range .Groups}}O{{range .}}I{{break}}X{{end}}Z{{end}}",
                values: values,
            ) == "OIZOIZ",
        )
        #expect(
            try renderDockerTemplate(
                "{{range .Groups}}O{{range .}}I{{continue}}X{{end}}Z{{end}}",
                values: values,
            ) == "OIIZOIIZ",
        )
    }

    @Test
    func `control in an inner range else targets an enclosing range`() throws {
        let values: [String: DockerTemplateData] = [
            "Groups": .array([
                .array([]),
                .array([.integer(1)]),
            ]),
        ]

        #expect(
            try renderDockerTemplate(
                "{{range .Groups}}O{{range .}}{{.}}{{else}}E{{break}}X{{end}}Z{{end}}Q",
                values: values,
            ) == "OEQ",
        )
        #expect(
            try renderDockerTemplate(
                "{{range .Groups}}O{{range .}}{{.}}{{else}}E{{continue}}X{{end}}Z{{end}}Q",
                values: values,
            ) == "OEO1ZQ",
        )
    }

    @Test
    func `range control outside a range body is rejected`() {
        let values: [String: DockerTemplateData] = [
            "Empty": .array([]),
            "Items": .array([.integer(1)]),
        ]

        for template in [
            "A{{break}}B",
            "A{{continue}}B",
            "{{range .Items}}{{break 1}}{{end}}",
            "{{range .Items}}{{continue 1}}{{end}}",
            "{{range .Empty}}{{else}}{{break}}{{end}}",
            "{{range .Empty}}{{else}}{{continue}}{{end}}",
        ] {
            #expect(throws: (any Error).self) {
                try renderDockerTemplate(template, values: values)
            }
        }
    }

    @Test
    func `range control nodes do not introduce field or label references`() {
        let template = "{{range .Items}}{{if .Enabled}}{{continue}}{{else}}{{break}}{{end}}{{end}}"

        #expect(dockerTemplateFields(in: template) == ["Items"])
    }
}
