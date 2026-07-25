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

import Foundation

/// Returns root row fields from a Docker-style template in encounter order.
public func dockerTemplateFields(in template: String) -> [String] {
    structuredDockerTemplateFields(in: template)
}

/// Renders a Docker-style output template against flat row data.
public func renderDockerTemplate(_ template: String, values: [String: String]) throws -> String {
    try renderStructuredDockerTemplate(template, values: values.mapValues(DockerTemplateData.string))
}

/// Renders a Docker-style output template against structured row data.
public func renderDockerTemplate(_ template: String, values: [String: DockerTemplateData]) throws -> String {
    try renderStructuredDockerTemplate(template, values: values)
}

/// Renders table template rows with Docker-style headers from referenced fields.
public func renderDockerTemplateTable(fields: [String], rows: [String]) -> String {
    guard !rows.isEmpty else {
        return ""
    }
    guard !fields.isEmpty else {
        return rows.joined(separator: "\n")
    }
    let tableRows = [fields.map { $0.uppercased() }] + rows.map { row in
        let columns = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return columns.count == fields.count ? columns : [row]
    }
    return renderTable(tableRows)
}

/// Validates template syntax and supported Docker/Go actions before discovery.
public func validateDockerTemplateActions(in template: String) throws {
    try validateStructuredDockerTemplate(template)
}

/// Rejects fields that the current command cannot project.
public func validateDockerTemplateFields(_ fields: [String], command: String, supported: Set<String>) throws {
    for field in fields where !supported.contains(field) {
        throw unsupportedDockerTemplateField(field, command: command, supported: supported)
    }
}

/// Formats the shared unsupported field error for early validation and defensive render checks.
public func unsupportedDockerTemplateField(_ field: String, command: String, supported: Set<String>) -> ComposeError {
    let supportedFields = supported.sorted().joined(separator: ", ")
    return ComposeError.unsupported("\(command) --format field '.\(field)'; supported fields are \(supportedFields)")
}
