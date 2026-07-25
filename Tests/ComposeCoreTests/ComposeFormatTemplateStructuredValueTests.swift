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

@Suite("Docker output template structured values")
struct ComposeTemplateStructuredValueTests {
    @Test
    func `structured values display and range deterministically`() throws {
        let values: [String: DockerTemplateData] = [
            "False": .boolean(false),
            "Integer": .integer(7),
            "Labels": .lookupObject(["x": .string("y")], display: "x=y"),
            "Nothing": .null,
            "Object": .object(["b": .integer(2), "a": .integer(1)]),
        ]

        #expect(
            try renderDockerTemplate(
                "{{.False}}|{{.Integer}}|{{.Nothing}}|{{.Labels}}",
                values: values,
            ) == "false|7|<no value>|x=y",
        )
        #expect(
            try renderDockerTemplate(
                "{{range $key, $value := .Object}}{{$key}}={{$value}};{{end}}",
                values: values,
            ) == "a=1;b=2;",
        )
    }

    @Test
    func `structured values drive nested control actions`() throws {
        let values: [String: DockerTemplateData] = [
            "False": .boolean(false),
            "Integer": .integer(7),
            "Nothing": .null,
            "Text": .string("abc"),
            "True": .boolean(true),
        ]

        #expect(
            try renderDockerTemplate(
                "{{if and .True (not .False)}}yes{{else if .Text}}text{{else}}no{{end}}",
                values: values,
            ) == "yes",
        )
        #expect(
            try renderDockerTemplate(
                "{{with .Nothing}}value{{else}}{{if or .False .Text}}fallback{{end}}{{end}}",
                values: values,
            ) == "fallback",
        )
        #expect(
            try renderDockerTemplate(
                "{{with .Nothing}}value{{else with(.Text)}}{{.}}{{end}}",
                values: values,
            ) == "abc",
        )
        #expect(
            try renderDockerTemplate(
                "{{with .Nothing}}first{{else with .False}}second{{else with .Integer}}{{.}}{{else}}none{{end}}",
                values: values,
            ) == "7",
        )
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                "{{with .Nothing}}value{{else if .Text}}invalid{{end}}",
                values: values,
            )
        }
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                "{{if .False}}value{{else with .Text}}invalid{{end}}",
                values: values,
            )
        }
    }
}
