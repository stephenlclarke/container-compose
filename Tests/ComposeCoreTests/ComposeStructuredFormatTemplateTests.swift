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
            "Lookup": .lookupObject(["1": .string("one")], display: "1=one"),
            "Name": .string("demo-api"),
            "Object": .object(["1": .string("one")]),
        ]

        #expect((try? renderDockerTemplate("{{index .Lookup 1}}", values: values)) == "61")
        for template in [
            "{{index .Array 2}}",
            "{{index .Object}}",
            "{{index .Object 1}}",
            "{{index .Object true}}",
            "{{index .Lookup false}}",
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
    func `range rejects root only when logical fallback selects it`() throws {
        let template = "{{range or .Publishers $}}{{.}}{{end}}"
        let publisher = DockerTemplateData.record([
            "Protocol": .string("tcp"),
            "PublishedPort": .integer(32768),
            "TargetPort": .integer(8080),
            "URL": .string("127.0.0.1"),
        ])

        #expect(
            try renderDockerTemplate(
                template,
                values: ["Publishers": .array([publisher])],
            ) == "{127.0.0.1 8080 32768 tcp}",
        )
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                template,
                values: ["Publishers": .array([])],
            )
        }
    }

    @Test
    func `range defers a possible root until a logical and selects it`() throws {
        let template = "{{range and .Publishers $}}{{.}}{{else}}empty{{end}}"
        let publisher = DockerTemplateData.record([
            "Protocol": .string("tcp"),
            "PublishedPort": .integer(32768),
            "TargetPort": .integer(8080),
            "URL": .string("127.0.0.1"),
        ])

        #expect(
            try renderDockerTemplate(
                template,
                values: ["Publishers": .array([])],
            ) == "empty",
        )
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                template,
                values: ["Publishers": .array([publisher])],
            )
        }
    }

    @Test
    func `with rejects root indexing only when a logical fallback selects it`() {
        let template = #"{{with or .Health $}}{{index . "Name"}}{{end}}"#

        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                template,
                values: [
                    "Health": .string(""),
                    "Name": .string("demo-api"),
                ],
            )
        }
    }

    @Test
    func `quoted field-like literals do not become field references`() {
        #expect(dockerTemplateFields(in: "{{printf \".NotAField\" .Name}}") == ["Name"])
    }

    @Test
    func `CRLF is accepted as Go action whitespace`() throws {
        let values = ["Name": DockerTemplateData.string("demo-api")]

        #expect(try renderDockerTemplate("{{\r\n.Name}}", values: values) == "demo-api")
        #expect(
            try renderDockerTemplate(
                "{{if\r\n.Name}}{{.Name}}{{end}}",
                values: values,
            ) == "demo-api",
        )
        #expect(
            try renderDockerTemplate(
                "A {{-\r\n.Name\r\n-}} B",
                values: values,
            ) == "Ademo-apiB",
        )
    }

    @Test
    func `non-Go whitespace is rejected inside actions`() throws {
        let nonBreakingSpace = "\u{00A0}"
        let values = ["Name": DockerTemplateData.string("demo-api")]

        for template in [
            "{{\(nonBreakingSpace).Name}}",
            "{{if\(nonBreakingSpace).Name}}{{.Name}}{{end}}",
            "{{.Name\(nonBreakingSpace)}}",
        ] {
            #expect(throws: (any Error).self) {
                try renderDockerTemplate(template, values: values)
            }
        }
        #expect(
            try renderDockerTemplate(
                "{{printf \"%s\" \"A\(nonBreakingSpace)B\"}}",
                values: values,
            ) == "A\(nonBreakingSpace)B",
        )
    }
}
