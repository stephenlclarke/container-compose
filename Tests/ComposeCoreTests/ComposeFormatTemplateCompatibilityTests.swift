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

    @Test
    func `string collection helpers use UTF8 byte offsets`() throws {
        let values = ["Text": DockerTemplateData.string("é")]

        #expect(
            try renderDockerTemplate(
                "{{len .Text}}|{{index .Text 0}}|{{index .Text 1}}",
                values: values,
            ) == "2|195|169",
        )
        #expect(
            try renderDockerTemplate(
                "{{printf \"%q\" (slice .Text 0 1)}}|{{printf \"%q\" (slice .Text 1 2)}}",
                values: values,
            ) == #""\xc3"|"\xa9""#,
        )
        #expect(throws: (any Error).self) {
            try renderDockerTemplate("{{index .Text 2}}", values: values)
        }
        #expect(throws: (any Error).self) {
            try renderDockerTemplate("{{slice .Text 0 3}}", values: values)
        }
    }

    @Test
    func `split and truncate match Go UTF8 string helpers`() throws {
        let values: [String: DockerTemplateData] = [:]

        #expect(
            try renderDockerTemplate(
                #"{{join (split "abc" "") "-"}}|{{printf "%q" (split "" "")}}"#,
                values: values,
            ) == "a-b-c|[]",
        )
        #expect(
            try renderDockerTemplate(
                #"{{join (split "é" "") "-"}}|{{join (split "👨‍👩‍👧‍👦" "") "-"}}"#,
                values: values,
            ) == "e-́|👨-‍-👩-‍-👧-‍-👦",
        )
        #expect(
            try renderDockerTemplate(
                #"{{printf "%q" (truncate "é" 1)}}"#,
                values: values,
            ) == #""\xc3""#,
        )
        #expect(
            try renderDockerTemplate(
                #"{{printf "%q" (split (truncate "é" 1) "")}}"#,
                values: values,
            ) == #"["\xc3"]"#,
        )
        #expect(
            try renderDockerTemplate(
                #"{{printf "%q" (join (split (truncate "é" 1) "") "-")}}"#,
                values: values,
            ) == #""\xc3""#,
        )
        #expect(throws: (any Error).self) {
            try renderDockerTemplate(
                #"{{truncate "abc" -1}}"#,
                values: values,
            )
        }
    }

    @Test
    func `string keyed maps preserve key types`() throws {
        let values: [String: DockerTemplateData] = [
            "Object": .object(["1": .string("one")]),
        ]

        #expect(
            try renderDockerTemplate(
                "{{index .Object \"1\"}}|{{index .Object (slice \"1\" 0 1)}}",
                values: values,
            ) == "one|one",
        )
        #expect(
            try renderDockerTemplate(
                "{{index .Object (slice \"é\" 0 1)}}",
                values: values,
            ) == "<no value>",
        )
    }

    @Test
    func `print spaces only adjacent non string values`() throws {
        let values: [String: DockerTemplateData] = [
            "False": .boolean(false),
            "Integer": .integer(7),
            "Text": .string("x"),
        ]

        #expect(
            try renderDockerTemplate(
                "{{print .Integer 0}}|{{print true .False}}|{{print .Integer .Text 2}}",
                values: values,
            ) == "7 0|true false|7x2",
        )
        #expect(
            try renderDockerTemplate(
                "{{print \"a\" \"b\"}}|{{print \"a\" 1}}|{{print 1 \"a\"}}",
                values: values,
            ) == "ab|a1|1a",
        )
    }

    @Test
    func `printf quote follows structured operand types`() throws {
        let values: [String: DockerTemplateData] = [
            "Labels": .lookupObject(["x": .string("y")], display: "x=y"),
            "Object": .object(["a": .integer(7)]),
            "Publishers": .array([
                .record([
                    "Protocol": .string("tcp"),
                    "PublishedPort": .integer(65),
                    "TargetPort": .integer(7),
                    "URL": .string("url"),
                ]),
            ]),
        ]

        #expect(
            try renderDockerTemplate(
                "{{printf \"%q\" 7}}|{{printf \"%q\" true}}|{{printf \"%q\" \"é\"}}",
                values: values,
            ) == #"'\a'|%!q(bool=true)|"é""#,
        )
        #expect(
            try renderDockerTemplate(
                "{{printf \"%q\" .Labels}}|{{printf \"%q\" .Object}}|{{printf \"%q\" .Publishers}}",
                values: values,
            ) == #""x=y"|map["a":'\a']|[{"url" '\a' 'A' "tcp"}]"#,
        )
    }

    @Test
    func `publisher records display in Go struct order`() throws {
        let values: [String: DockerTemplateData] = [
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
                "{{.Publishers}}|{{printf \"%v\" .Publishers}}",
                values: values,
            ) == "[{127.0.0.1 8080 32768 tcp}]|[{127.0.0.1 8080 32768 tcp}]",
        )
    }

    @Test
    func `printf width counts Unicode scalars as Go runes`() throws {
        let combining = "e\u{0301}"
        let family = "👨‍👩‍👧‍👦"
        let values: [String: DockerTemplateData] = [
            "Combining": .string(combining),
            "Family": .string(family),
        ]

        #expect(
            try renderDockerTemplate(
                "{{printf \"[%2s]|[%3s]|[%-3s]|[%7s]|[%8s]\" .Combining .Combining .Combining .Family .Family}}",
                values: values,
            ) == "[\(combining)]|[ \(combining)]|[\(combining) ]|[\(family)]|[ \(family)]",
        )
    }

    @Test
    func `printf quote uses Go escapes for runes and raw bytes`() throws {
        let replacementCharacter = "\u{FFFD}"
        let values: [String: DockerTemplateData] = [
            "Bytes": .byteString([0xC3, 0x07, 0x22, 0x5C]),
            "Nothing": .null,
            "SoftHyphen": .string("\u{00AD}"),
        ]

        #expect(
            try renderDockerTemplate(
                """
                {{printf "%q" 0}}|{{printf "%q" 8}}|{{printf "%q" 9}}|\
                {{printf "%q" 10}}|{{printf "%q" 11}}|{{printf "%q" 12}}|\
                {{printf "%q" 13}}|{{printf "%q" 39}}|{{printf "%q" 92}}|\
                {{printf "%q" -1}}|{{printf "%q" 173}}|{{printf "%q" 255}}
                """,
                values: values,
            ) == #"'\x00'|'\b'|'\t'|'\n'|'\v'|'\f'|'\r'|'\''|'\\'|'\#(replacementCharacter)'|'\u00ad'|'ÿ'"#,
        )
        #expect(
            try renderDockerTemplate(
                "{{printf \"%q\" .Bytes}}|{{printf \"%q\" .Nothing}}|{{printf \"%q\" .SoftHyphen}}",
                values: values,
            ) == #""\xc3\a\"\\"|%!q(<nil>)|"\u00ad""#,
        )
    }
}
