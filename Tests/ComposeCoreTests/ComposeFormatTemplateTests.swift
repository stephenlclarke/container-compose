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
    @Test("functions and pipelines render row values")
    func functionsAndPipelinesRenderRowValues() throws {
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
                == "registry.example/demo-api/latest"
        )
        #expect(try renderDockerTemplate("{{index .Name 5}}", values: values) == "a")
        #expect(try renderDockerTemplate("{{slice .Name 5}}", values: values) == "api")
        #expect(try renderDockerTemplate("{{len .Name}}", values: values) == "8")
        #expect(try renderDockerTemplate("{{println .Name}}", values: values) == "demo-api\n")
        #expect(try renderDockerTemplate("{{table .Name}}", values: values) == "demo-api")
    }

    @Test("JSON action renders the complete row or one field")
    func jsonActionRendersRows() throws {
        let values = ["ID": "abcdef", "Name": "demo-api"]

        #expect(try renderDockerTemplate("{{json .}}", values: values) == #"{"ID":"abcdef","Name":"demo-api"}"#)
        #expect(try renderDockerTemplate("{{json .Name}}", values: values) == #""demo-api""#)
    }

    @Test("control and nonportable actions remain explicit gaps")
    func controlAndNonportableActionsRemainUnsupported() {
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{if .Name}}{{.Name}}{{end}}")
        }
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{.Name | truncate 3}}")
        }
        #expect(throws: (any Error).self) {
            try validateDockerTemplateActions(in: "{{printf \"%5s\" .Name}}")
        }
    }

    @Test("quoted field-like literals do not become field references")
    func quotedFieldLikeLiteralsDoNotBecomeFieldReferences() {
        #expect(dockerTemplateFields(in: "{{printf \".NotAField\" .Name}}") == ["Name"])
    }
}
