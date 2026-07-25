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

        #expect(try renderDockerTemplate(template, values: values) == "value")
        #expect(dockerTemplateFields(in: template) == ["Publishers", "Labels"])
        #expect(
            try renderDockerTemplateTable(
                template: "{{$.Label \"oracle.example/key\"}}",
                headers: ["Labels": "LABELS"],
                rows: ["value"],
            ) == "example/key\nvalue",
        )
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
