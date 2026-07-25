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

@Suite("Docker output template compatibility")
struct ComposeFormatTemplateCompatibilityTests {
    @Test
    func `publisher records reject invalid fields while maps retain misses`() throws {
        let values: [String: DockerTemplateData] = [
            "Object": .object(["present": .string("value")]),
            "Publishers": .array([
                .record([
                    "Protocol": .string("tcp"),
                    "PublishedPort": .integer(32768),
                    "TargetPort": .integer(8080),
                ]),
            ]),
        ]

        #expect(try renderDockerTemplate("{{.Object.Missing}}", values: values) == "<no value>")
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                "{{range .Publishers}}{{.TargetPort.Bad}}{{end}}",
                values: values,
            )
        }
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                "{{range .Publishers}}{{.Unknown}}{{end}}",
                values: values,
            )
        }
    }

    @Test
    func `empty range else retains declaration variables`() throws {
        let values = ["Empty": DockerTemplateData.array([])]

        #expect(
            try renderDockerTemplate(
                "{{range $value := .Empty}}{{else}}{{len $value}}{{end}}",
                values: values,
            ) == "0",
        )
        #expect(
            try renderDockerTemplate(
                "{{range $index, $value := .Empty}}{{else}}{{printf \"%v|%v\" $index $value}}{{end}}",
                values: values,
            ) == "[]|[]",
        )
    }

    @Test
    func `compact control actions accept parenthesized pipelines`() throws {
        let values = ["Name": DockerTemplateData.string("demo-api")]

        #expect(
            try renderDockerTemplate(
                "{{if(.Name)}}{{with(.Name)}}{{.}}{{end}}{{else if(.Name)}}bad{{end}}",
                values: values,
            ) == "demo-api",
        )
        #expect(
            try renderDockerTemplate(
                "{{range(split .Name \"-\")}}{{.}};{{end}}",
                values: values,
            ) == "demo;api;",
        )
    }
}
