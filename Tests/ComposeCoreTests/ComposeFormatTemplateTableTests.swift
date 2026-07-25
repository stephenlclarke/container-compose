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

@Suite("Docker output template tables")
struct ComposeFormatTemplateTableTests {
    @Test
    func `analysis preserves fields and root context`() {
        #expect(dockerTemplateFields(in: "{{.Name}}\t{{.Name}}") == ["Name", "Name"])
        #expect(
            dockerTemplateFields(in: "{{if .Health}}{{.Health}}{{else}}{{.Status}}{{end}}")
                == ["Health", "Health", "Status"],
        )
        #expect(
            dockerTemplateFields(in: "{{with .Publishers}}{{.Name}}{{else}}{{$.Status}}{{end}}")
                == ["Publishers", "Status"],
        )
        #expect(dockerTemplateFields(in: "{{with .}}{{.Command}}{{end}}") == ["Command"])
        #expect(
            dockerTemplateFields(in: "{{range .Publishers}}{{with $}}{{.Command}}{{end}}{{end}}")
                == ["Publishers", "Command"],
        )
        #expect(
            dockerTemplateFields(in: "{{with (.)}}{{.Command}}{{end}}")
                == ["Command"],
        )
        #expect(
            dockerTemplateFields(in: "{{($).Command}}\t{{((.)).Name}}")
                == ["Command", "Name"],
        )
        #expect(
            dockerTemplateFields(in: "{{with or $ .Name}}{{.Command}}{{end}}")
                == ["Name", "Command"],
        )
        #expect(
            dockerTemplateFields(in: "{{with .Name | or $}}{{.Command}}{{end}}")
                == ["Name", "Command"],
        )
        #expect(
            dockerTemplateFields(in: "{{with $ | and .Name}}{{.Command}}{{end}}")
                == ["Name", "Command"],
        )
        #expect(
            dockerTemplateFields(in: "{{with and .Name $}}{{.Command}}{{end}}")
                == ["Name", "Command"],
        )
        #expect(
            dockerTemplateFields(in: "{{with and $ .Name}}{{.Command}}{{end}}")
                == ["Name"],
        )
        #expect(throws: (any Error).self) {
            try validateDockerTemplateFields(
                dockerTemplateFields(in: "{{with .}}{{.Command}}{{end}}"),
                command: "ps",
                supported: ["Name"],
            )
        }
        #expect(dockerTemplateFields(in: "{{if .Name}}") == [])
    }

    @Test
    func `headers preserve fields and execute control flow`() throws {
        let duplicate = try renderDockerTemplateTable(
            template: "{{.Name}}\t{{.Name}}",
            headers: ["Name": "NAME"],
            rows: ["demo-api\tdemo-api"],
        )
        let duplicateLines = duplicate.split(separator: "\n").map(String.init)

        #expect(duplicateLines.count == 2)
        #expect(duplicateLines[0].split(whereSeparator: \.isWhitespace).map(String.init) == ["NAME", "NAME"])
        #expect(
            duplicateLines[1].split(whereSeparator: \.isWhitespace).map(String.init)
                == ["demo-api", "demo-api"],
        )
        #expect(
            try renderDockerTemplateTable(
                template: "{{if .Health}}{{.Health}}{{else}}{{.Status}}{{end}}",
                headers: ["Status": "STATUS"],
                rows: ["Up"],
            ) == "STATUS\nUp",
        )
        #expect(
            try renderDockerTemplateTable(
                template: "{{.Label \"oracle.example/key\"}}",
                headers: ["Labels": "LABELS"],
                rows: ["value"],
            ) == "example/key\nvalue",
        )
        #expect(renderDockerTemplateTable(fields: ["Name"], rows: ["demo-api"]) == "NAME\ndemo-api")
        #expect(
            try renderDockerTemplateTable(template: "", headers: [:], rows: ["demo-api"])
                == "demo-api",
        )
        #expect(
            try renderDockerTemplateTable(template: "{{.Name}}", headers: ["Name": "NAME"], rows: [])
                == "",
        )
    }

    @Test
    func `omitted headers render Docker no value sentinel`() throws {
        for field in [
            "ExitCode",
            "Health",
            "LocalVolumes",
            "Mounts",
            "Names",
            "Networks",
            "Publishers",
        ] {
            #expect(
                try renderDockerTemplateTable(
                    template: "{{.\(field)}}",
                    headers: [:],
                    rows: ["value"],
                ) == "<no value>\nvalue",
            )
        }
    }
}
