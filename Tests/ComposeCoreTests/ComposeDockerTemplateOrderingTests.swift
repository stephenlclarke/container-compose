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

@Suite("Docker output template ordering")
struct ComposeDockerTemplateOrderingTests {
    @Test
    func `ordering functions compare integers and UTF8 strings`() throws {
        #expect(
            try renderDockerTemplate(
                """
                {{lt 1 2}}|{{le 1 1}}|{{gt 2 1}}|{{ge 1 1}}|\
                {{lt "a" "b"}}|{{le "a" "a"}}|{{gt "b" "a"}}|{{ge "a" "a"}}|\
                {{lt "é" "z"}}|{{gt "é" "z"}}
                """,
                values: [String: DockerTemplateData](),
            ) == "true|true|true|true|true|true|true|true|false|true",
        )
    }

    @Test
    func `ordering functions preserve Go string operands and pipeline order`() throws {
        let values: [String: DockerTemplateData] = [
            "BytesA": .byteString(Array("a".utf8)),
            "BytesB": .byteString(Array("b".utf8)),
            "Labels": .lookupObject(["a": .string("value")], display: "a"),
            "TextA": .string("a"),
            "TextB": .string("b"),
        ]

        #expect(
            try renderDockerTemplate(
                """
                {{lt .BytesA .BytesB}}|{{le .BytesA .TextA}}|\
                {{gt .TextB .BytesA}}|{{ge .TextA .BytesA}}|\
                {{lt .Labels "b"}}|{{1 | lt 2}}|{{1 | le 1}}|\
                {{2 | gt 1}}|{{1 | ge 1}}
                """,
                values: values,
            ) == "true|true|true|true|true|false|true|false|true",
        )
    }

    @Test
    func `ordering functions reject incompatible types and arity`() {
        let values: [String: DockerTemplateData] = [
            "Array": .array([]),
            "False": .boolean(false),
            "Integer": .integer(1),
            "Nothing": .null,
            "Record": .record(["Value": .integer(1)]),
            "Text": .string("1"),
        ]

        for template in [
            "{{lt .Integer .Text}}",
            "{{lt .False false}}",
            "{{lt .Nothing .Nothing}}",
            "{{lt .Array .Array}}",
            "{{lt .Record .Record}}",
            "{{lt 1}}",
            "{{lt 1 2 3}}",
            "{{le 1}}",
            "{{gt 1 2 3}}",
            "{{ge}}",
        ] {
            #expect(throws: (any Error).self) {
                try renderDockerTemplate(template, values: values)
            }
        }
    }
}
