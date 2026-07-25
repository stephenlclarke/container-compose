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
import Foundation
import Testing

@Suite("Docker output template raw strings")
struct ComposeFormatTemplateRawOutputTests {
    @Test
    func `structured values render through exact output bytes`() throws {
        let values: [String: DockerTemplateData] = [
            "Array": .array([.byteString(Array("raw".utf8)), .boolean(true)]),
            "Boolean": .boolean(true),
            "Integer": .integer(7),
            "Lookup": .lookupObject(["x": .string("y")], display: "x=y"),
            "Null": .null,
            "Object": .object(["a": .integer(1)]),
            "Record": .record(["TargetPort": .integer(8080), "URL": .byteString(Array("raw".utf8))]),
            "String": .string("ok"),
        ]

        #expect(
            try renderDockerTemplateData(
                "{{.Array}}|{{.Boolean}}|{{.Integer}}|{{.Lookup}}"
                    + "|{{.Null}}|{{.Object}}|{{.Record}}|{{.String}}",
                values: values,
            ) == Data("[raw true]|true|7|x=y|<no value>|map[a:1]|{raw 8080}|ok".utf8),
        )
    }

    @Test
    func `label display behaves as a Go string for helpers`() throws {
        let values = [
            "Labels": DockerTemplateData.lookupObject(
                ["x": .string("y")],
                display: "x=y",
            ),
        ]

        #expect(
            try renderDockerTemplate(
                "{{upper .Labels}}|{{split .Labels \"=\"}}|{{truncate .Labels 1}}"
                    + "|{{index .Labels 0}}|{{slice .Labels 0 1}}",
                values: values,
            ) == "X=Y|[x y]|x|120|x",
        )
    }

    @Test
    func `direct and formatted partial UTF8 remains exact bytes`() throws {
        let values: [String: DockerTemplateData] = [:]

        #expect(
            try renderDockerTemplateData(
                #"{{truncate "é" 1}}|{{printf "%s" (truncate "é" 1)}}|"#
                    + #"{{print (truncate "é" 1)}}|{{pad (truncate "é" 1) 1 1}}"#,
                values: values,
            ) == Data([
                0xC3, 0x7C,
                0xC3, 0x7C,
                0xC3, 0x7C,
                0x20, 0xC3, 0x20,
            ]),
        )
    }

    @Test
    func `raw table output preserves bytes and row structure`() throws {
        #expect(
            try renderDockerTemplateTableData(
                template: "{{.Name}}",
                headers: ["Name": "NAME"],
                rows: [],
            ).isEmpty,
        )
        #expect(
            try renderDockerTemplateTableData(
                template: "",
                headers: [:],
                rows: [Data([0xC3]), Data("x".utf8)],
            ) == Data([0xC3, 0x0A, 0x78]),
        )

        let table = try renderDockerTemplateTableData(
            template: #"{{.Label "oracle.example/key"}}\t{{.Name}}"#,
            headers: ["Labels": "LABELS", "Name": "NAME"],
            rows: [Data([0xC3, 0x09, 0x78])],
        )
        #expect(
            table == Data("example/key  NAME\n".utf8)
                + Data([0xC3])
                + Data("            x".utf8),
        )
    }
}
