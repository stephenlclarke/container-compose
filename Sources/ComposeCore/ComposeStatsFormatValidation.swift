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

private let composeStatsFormatFields: Set<String> = [
    "BlockIO",
    "CPUPerc",
    "Container",
    "ID",
    "MemPerc",
    "MemUsage",
    "Name",
    "NetIO",
    "PIDs",
]

/// Validates the `compose stats --format` value before calling a runtime provider.
func validateComposeStatsFormat(_ value: String) throws {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized.lowercased() {
    case "table", "json":
        return
    default:
        let tablePrefix = "table "
        let template: String = if normalized.lowercased().hasPrefix(tablePrefix) {
            String(normalized.dropFirst(tablePrefix.count))
        } else {
            normalized
        }
        try validateDockerTemplateActions(in: template)
        try validateDockerTemplateFields(
            dockerTemplateFields(in: template),
            command: "stats",
            supported: composeStatsFormatFields,
        )
    }
}
