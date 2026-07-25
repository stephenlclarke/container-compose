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

@Suite("Docker output template operand compatibility")
struct ComposeFormatOperandCompatibilityTests {
    @Test
    func `indexed collections require integer offsets`() {
        let values: [String: DockerTemplateData] = [
            "Array": .array([.string("zero")]),
            "Text": .string("zero"),
        ]

        for template in [
            "{{index .Array \"0\"}}",
            "{{index .Text \"0\"}}",
            "{{slice .Array \"0\" 1}}",
            "{{slice .Text 0 \"1\"}}",
        ] {
            #expect(throws: (any Error).self) {
                try renderDockerTemplate(template, values: values)
            }
        }
    }

    @Test
    func `join uses Docker display values for structured arrays`() throws {
        let values = ["Publishers": publisherValues]

        #expect(
            try renderDockerTemplate(
                "{{join .Publishers \",\"}}",
                values: values,
            ) == "{127.0.0.1 8080 32768 tcp}",
        )
    }

    @Test
    func `printf verbs preserve structured operand types`() throws {
        let values: [String: DockerTemplateData] = [
            "Bytes": .byteString(Array("raw".utf8)),
            "Integer": .integer(8080),
            "Lookup": .lookupObject(["key": .string("value")], display: "key=value"),
            "Publishers": publisherValues,
            "Text": .string("tcp"),
            "True": .boolean(true),
        ]

        #expect(
            try renderDockerTemplate(
                "{{printf \"%s|%d|%s|%d\" .Integer .Text .True .True}}",
                values: values,
            ) == "%!s(int=8080)|%!d(string=tcp)|%!s(bool=true)|%!d(bool=true)",
        )
        #expect(
            try renderDockerTemplate(
                "{{printf \"%5s|%-5s|%5d|%-5d\" .Integer .Integer .Text .Text}}",
                values: values,
            ) == "%!s(int= 8080)|%!s(int=8080 )|%!d(string=  tcp)|%!d(string=tcp  )",
        )
        #expect(
            try renderDockerTemplate(
                "{{printf \"%s|%s\" .Bytes .Lookup}}",
                values: values,
            ) == "raw|key=value",
        )
        #expect(
            try renderDockerTemplate(
                "{{printf \"%s|%d\" .Publishers .Publishers}}",
                values: values,
            ) == """
            [{127.0.0.1 %!s(int=8080) %!s(int=32768) tcp}]|\
            [{%!d(string=127.0.0.1) 8080 32768 %!d(string=tcp)}]
            """,
        )
    }

    private var publisherValues: DockerTemplateData {
        .array([
            .record([
                "Protocol": .string("tcp"),
                "PublishedPort": .integer(32768),
                "TargetPort": .integer(8080),
                "URL": .string("127.0.0.1"),
            ]),
        ])
    }
}
