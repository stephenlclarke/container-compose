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

@Suite("Docker output template call compatibility")
struct ComposeFormatCallCompatibilityTests {
    @Test
    func `root label calls survive changed dot contexts`() throws {
        let values: [String: DockerTemplateData] = [
            "Labels": .lookupObject(
                ["oracle.example/key": .string("value")],
                display: "oracle.example/key=value",
            ),
            "Publishers": .array([
                .record(["TargetPort": .integer(8080)]),
            ]),
        ]
        let template = "{{range .Publishers}}{{$.Label \"oracle.example/key\"}}{{end}}"
        let pipelineTemplate =
            "{{\"oracle.example/key\" | .Label | upper}}|"
                + "{{range .Publishers}}{{\"oracle.example/key\" | $.Label}}{{end}}"

        #expect(try renderDockerTemplate(template, values: values) == "value")
        #expect(dockerTemplateFields(in: template) == ["Publishers", "Labels"])
        #expect(try renderDockerTemplate(pipelineTemplate, values: values) == "VALUE|value")
        #expect(dockerTemplateFields(in: pipelineTemplate) == ["Labels", "Publishers", "Labels"])
        #expect(
            try renderDockerTemplateTable(
                template: "{{$.Label \"oracle.example/key\"}}",
                headers: ["Labels": "LABELS"],
                rows: ["value"],
            ) == "example/key\nvalue",
        )
        #expect(
            try renderDockerTemplateTable(
                template: "{{\"oracle.example/key\" | .Label}}",
                headers: ["Labels": "LABELS"],
                rows: ["value"],
            ) == "example/key\nvalue",
        )
        #expect(
            try renderDockerTemplateTable(
                template: "{{\"oracle.example/key\" | print | printf \"%s\" | .Label}}",
                headers: ["Labels": "LABELS"],
                rows: ["value"],
            ) == "example/key\nvalue",
        )
    }

    @Test
    func `label calls require typed string keys`() throws {
        let values: [String: DockerTemplateData] = [
            "Bytes": .byteString(Array("oracle.example/key".utf8)),
            "Labels": .lookupObject(
                ["oracle.example/key": .string("value")],
                display: "oracle.example/key=value",
            ),
            "Publishers": .array([
                .record(["TargetPort": .integer(8080)]),
            ]),
        ]

        #expect(try renderDockerTemplate("{{.Label .Bytes}}", values: values) == "value")
        #expect(throws: (any Error).self) {
            try renderDockerTemplate("{{.Label 1}}", values: values)
        }
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                "{{\"oracle.example/key\" | .Label \"other\"}}",
                values: values,
            )
        }
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                "{{range .Publishers}}{{$.Label .TargetPort}}{{end}}",
                values: values,
            )
        }
    }

    @Test
    func `compact range assignments preserve declared variables`() throws {
        let values: [String: DockerTemplateData] = [
            "Publishers": .array([
                .record(["TargetPort": .integer(8080)]),
            ]),
        ]

        #expect(
            try renderDockerTemplate(
                "{{range $publisher:=.Publishers}}{{$publisher.TargetPort}}{{end}}",
                values: values,
            ) == "8080",
        )
        #expect(
            try renderDockerTemplate(
                "{{range $index,$publisher:=.Publishers}}{{$index}}={{$publisher.TargetPort}}{{end}}",
                values: values,
            ) == "0=8080",
        )
        #expect(
            try renderDockerTemplate(
                "{{range (split \"a:=b\" \":=\")}}{{.}};{{end}}",
                values: values,
            ) == "a;b;",
        )
    }

    @Test
    func `parenthesized expression selectors retain structured types`() throws {
        let values: [String: DockerTemplateData] = [
            "Publishers": .array([
                .record(["TargetPort": .integer(8080)]),
            ]),
        ]
        let template = "{{(index .Publishers 0).TargetPort}}"

        #expect(try renderDockerTemplate(template, values: values) == "8080")
        #expect(dockerTemplateFields(in: template) == ["Publishers"])
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                "{{(index .Publishers 0).Missing}}",
                values: values,
            )
        }
        for malformed in ["{{()}}", "{{(1)x}}", "{{(1).}}"] {
            #expect(throws: (any Error).self) {
                try renderDockerTemplate(malformed, values: values)
            }
        }
    }

    @Test
    func `printf requires a typed string format`() throws {
        let values: [String: DockerTemplateData] = [
            "Bytes": .byteString(Array("%s".utf8)),
            "Integer": .integer(8080),
            "InvalidBytes": .byteString([0xFF]),
            "Lookup": .lookupObject(["key": .string("value")], display: "%s"),
        ]

        #expect(try renderDockerTemplate("{{printf .Bytes \"ok\"}}", values: values) == "ok")
        for template in [
            "{{printf .Integer}}",
            "{{printf .InvalidBytes \"ok\"}}",
            "{{printf .Lookup \"ok\"}}",
        ] {
            #expect(throws: (any Error).self) {
                try renderDockerTemplate(template, values: values)
            }
        }
    }
}
