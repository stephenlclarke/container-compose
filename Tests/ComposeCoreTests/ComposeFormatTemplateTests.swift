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

@Suite("Docker output template actions")
struct ComposeFormatTemplateTests {
    @Test
    func `functions and pipelines render row values`() throws {
        let values = ["ID": "abcdef", "Image": "registry.example/demo-api:latest", "Name": "demo-api"]

        #expect(try renderDockerTemplate("{{.Name | upper}}", values: values) == "DEMO-API")
        #expect(try renderDockerTemplate("{{lower .Name}}", values: values) == "demo-api")
        #expect(try renderDockerTemplate("{{title \"demo api\"}}", values: values) == "Demo Api")
        #expect(try renderDockerTemplate("{{truncate .ID 3}}", values: values) == "abc")
        #expect(try renderDockerTemplate("{{pad .Name 1 2}}", values: values) == " demo-api  ")
        #expect(try renderDockerTemplate("{{print .ID .Name}}", values: values) == "abcdefdemo-api")
        #expect(try renderDockerTemplate("{{printf \"%s-%q\" .ID .Name}}", values: values) == "abcdef-\"demo-api\"")
        #expect(try renderDockerTemplate("{{printf \"{{%s}}\" .Name}}", values: values) == "{{demo-api}}")
        #expect(
            try renderDockerTemplate("{{join (split .Image \":\") \"/\"}}", values: values)
                == "registry.example/demo-api/latest",
        )
        #expect(try renderDockerTemplate("{{index .Name 5}}", values: values) == "97")
        #expect(try renderDockerTemplate("{{slice .Name 5}}", values: values) == "api")
        #expect(try renderDockerTemplate("{{len .Name}}", values: values) == "8")
        #expect(try renderDockerTemplate("{{println .Name}}", values: values) == "demo-api\n")
    }

    @Test
    func `JSON action renders the complete row or one field`() throws {
        let values = ["ID": "abcdef", "Name": "demo-api"]

        #expect(try renderDockerTemplate("{{json .}}", values: values) == #"{"ID":"abcdef","Name":"demo-api"}"#)
        #expect(try renderDockerTemplate("{{json .Name}}", values: values) == #""demo-api""#)
    }

    @Test
    func `control actions nested paths and range variables render structured values`() throws {
        let values: [String: DockerTemplateData] = [
            "Labels": .lookupObject(
                ["oracle.example/key": .string("value")],
                display: "oracle.example/key=value",
            ),
            "Name": .string("demo-api"),
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
                "{{if .Name}}yes:{{.Name}}{{else}}no{{end}}",
                values: values,
            ) == "yes:demo-api",
        )
        #expect(
            try renderDockerTemplate(
                """
                {{with index .Publishers 0}}{{$.Name}}|{{.URL}}|{{.TargetPort}}|\
                {{.PublishedPort}}|{{.Protocol}}{{end}}
                """,
                values: values,
            ) == "demo-api|127.0.0.1|8080|32768|tcp",
        )
        #expect(
            try renderDockerTemplate(
                """
                {{range $index, $publisher := .Publishers}}{{$index}}={{$publisher.TargetPort}}/\
                {{$publisher.PublishedPort}}/{{end}}
                """,
                values: values,
            ) == "0=8080/32768/",
        )
        #expect(try renderDockerTemplate("{{.Label \"oracle.example/key\"}}", values: values) == "value")
        #expect(try renderDockerTemplate("{{.Label \"oracle.example/missing\"}}", values: values) == "")
        #expect(
            try renderDockerTemplate(
                "{{if .Label \"oracle.example/missing\"}}present{{else}}missing{{end}}",
                values: values,
            ) == "missing",
        )
    }

    @Test
    func `control actions handle false branches empty ranges and comparisons`() throws {
        let values: [String: DockerTemplateData] = [
            "Empty": .array([]),
            "Name": .string("demo-api"),
            "Publishers": .array([.string("first"), .string("second")]),
        ]

        #expect(
            try renderDockerTemplate(
                "{{if eq .Name \"demo-api\"}}yes{{else}}no{{end}}",
                values: values,
            ) == "yes",
        )
        #expect(
            try renderDockerTemplate(
                "{{range .Empty}}value{{else}}empty{{end}}",
                values: values,
            ) == "empty",
        )
        #expect(
            try renderDockerTemplate(
                "{{range .Publishers}}{{if ne . \"first\"}}{{.}}{{end}}{{end}}",
                values: values,
            ) == "second",
        )
        #expect(
            try renderDockerTemplate(
                "{{if eq .Name \"missing\" \"demo-api\"}}yes{{else}}no{{end}}",
                values: values,
            ) == "yes",
        )
        #expect(
            try renderDockerTemplate(
                "{{if and .Empty (index .Empty 0)}}bad{{else}}guarded{{end}}",
                values: values,
            ) == "guarded",
        )
        #expect(
            try renderDockerTemplate(
                "{{if or .Name (index .Empty 0)}}guarded{{else}}bad{{end}}",
                values: values,
            ) == "guarded",
        )
    }

    @Test
    func `integer ranges and struct root operations match Go templates`() throws {
        let values = ["Name": DockerTemplateData.string("demo-api")]

        #expect(try renderDockerTemplate("{{range 3}}{{.}}{{end}}", values: values) == "012")
        #expect(
            try renderDockerTemplate(
                "{{range 0}}{{.}}{{else}}empty{{end}}|{{range -2}}{{.}}{{else}}empty{{end}}",
                values: values,
            ) == "empty|empty",
        )
        #expect(
            try renderDockerTemplate(
                "{{range $value := 3}}{{$value}};{{end}}",
                values: values,
            ) == "0;1;2;",
        )
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                "{{range $index, $value := 3}}{{$index}}={{$value}}{{end}}",
                values: values,
            )
        }
        #expect(throws: (any Error).self) {
            try renderDockerTemplate("{{len $}}", values: values)
        }
        #expect(throws: (any Error).self) {
            try renderDockerTemplate("{{range $}}{{.}}{{end}}", values: values)
        }
    }

    @Test
    func `collection JSON index slice and printf helpers preserve types`() throws {
        let values: [String: DockerTemplateData] = [
            "Array": .array([.string("alpha"), .string("beta"), .string("gamma")]),
            "False": .boolean(false),
            "Integer": .integer(7),
            "Labels": .lookupObject(["x": .string("y")], display: "x=y"),
            "Nothing": .null,
            "Object": .object(["a": .integer(1)]),
            "Text": .string("abc"),
        ]

        #expect(
            try renderDockerTemplate(
                "{{json .Array}}|{{json .False}}|{{json .Integer}}|{{json .Nothing}}",
                values: values,
            ) == #"["alpha","beta","gamma"]|false|7|null"#,
        )
        #expect(
            try renderDockerTemplate(
                "{{index .Object \"a\"}}|{{index .Labels 0}}|{{index .Text 1}}",
                values: values,
            ) == "1|120|98",
        )
        #expect(
            try renderDockerTemplate(
                "{{slice .Array 1 3}}|{{slice .Text 1 3}}|{{slice .Labels 0 1}}"
                    + "|{{len .Object}}|{{len .Array}}",
                values: values,
            ) == "[beta gamma]|bc|x|1|3",
        )
        #expect(
            try renderDockerTemplate(
                "{{printf \"%%/%-5s/%3d\" .Text .Integer}}",
                values: values,
            ) == "%/abc  /  7",
        )
    }

    @Test
    func `whitespace trim and string ranges match Go templates`() throws {
        let values = ["Name": DockerTemplateData.string("demo-api")]

        #expect(
            try renderDockerTemplate("A {{- if .Name -}} B {{- end -}} C", values: values)
                == "ABC",
        )
        #expect(try renderDockerTemplate("A {{-3}} B", values: values) == "A -3 B")
        #expect(try renderDockerTemplate("A {{- 3}} B", values: values) == "A3 B")
        #expect(try renderDockerTemplate("A {{3 -}} B", values: values) == "A 3B")
        #expect(try renderDockerTemplate("A\u{00A0}{{- .Name}}", values: values) == "A\u{00A0}demo-api")
        #expect(
            try renderDockerTemplate("{{.Name -}} \u{00A0}B", values: values)
                == "demo-api\u{00A0}B",
        )
        #expect(try renderDockerTemplate("{{/* emitted as }} ( */}}OK", values: values) == "OK")
        #expect(try renderDockerTemplate("A {{- /* }} ( */ -}} B", values: values) == "AB")
        #expect(
            try renderDockerTemplate(
                "{{range $index, $value := split .Name \"-\"}}{{$index}}={{$value}};{{end}}",
                values: values,
            ) == "0=demo;1=api;",
        )
        #expect(try renderDockerTemplate("{{printf \"%5s/%d\" .Name 7}}", values: values) == "demo-api/7")
    }

    @Test
    func `field extraction validates only root row fields`() {
        let template =
            """
            {{range $index, $publisher := .Publishers}}{{$index}}={{$publisher.TargetPort}}/\
            {{.PublishedPort}}/{{$.Name}}{{end}}
            """

        #expect(dockerTemplateFields(in: template) == ["Publishers", "Name"])
        #expect(dockerTemplateFields(in: "{{.Label \"oracle.example/key\"}}") == ["Labels"])
    }

    @Test
    func `malformed or unknown actions remain explicit`() {
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{if .Name}}{{.Name}}")
        }
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{unknown .Name}}")
        }
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{table .Name}}")
        }
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{range $index, := .Name}}{{end}}")
        }
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{else}}")
        }
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{}}")
        }
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{printf \"%s\" .Name")
        }
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(
                in: "{{range $index, $publisher := .Publishers}}{{$missing.TargetPort}}{{end}}",
            )
        }
    }
}
