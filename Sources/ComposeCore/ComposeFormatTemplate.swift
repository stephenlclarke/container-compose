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

/// Returns field references from a Docker-style template in encounter order.
public func dockerTemplateFields(in template: String) -> [String] {
    dockerTemplateFieldMatches(in: template).map(\.field)
}

/// Renders the field-reference subset of Docker's output template language.
public func renderDockerTemplate(
    _ template: String,
    valueForField: (String) throws -> String,
) throws -> String {
    try validateDockerTemplateActions(in: template)
    let fieldMatches = dockerTemplateFieldMatches(in: template)
    var rendered = template
    for match in fieldMatches.reversed() {
        let value = try valueForField(match.field)
        rendered.replaceSubrange(match.range, with: value)
    }
    return rendered
        .replacingOccurrences(of: #"\t"#, with: "\t")
        .replacingOccurrences(of: #"\n"#, with: "\n")
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

/// Rejects template actions outside the supported field-reference subset.
public func validateDockerTemplateActions(in template: String) throws {
    let actionMatches = dockerTemplateActionMatches(in: template)
    let fieldMatches = dockerTemplateFieldMatches(in: template)
    guard actionMatches.count == fieldMatches.count else {
        let fieldRanges = Set(fieldMatches.map(\.range))
        let unsupported = actionMatches.first { !fieldRanges.contains($0.range) }?.action ?? ""
        throw ComposeError.unsupported("format template action '{{\(unsupported)}}'; supported actions are field references like '{{.Name}}'")
    }
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

private struct DockerTemplateFieldMatch {
    var field: String
    var range: Range<String.Index>
}

private struct DockerTemplateActionMatch {
    var action: String
    var range: Range<String.Index>
}

private func dockerTemplateFieldMatches(in template: String) -> [DockerTemplateFieldMatch] {
    let pattern = #"\{\{\s*\.([A-Za-z][A-Za-z0-9_]*)\s*\}\}"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let range = NSRange(template.startIndex ..< template.endIndex, in: template)
    return regex.matches(in: template, range: range).compactMap { match in
        guard
            let fullRange = Range(match.range(at: 0), in: template),
            let fieldRange = Range(match.range(at: 1), in: template)
        else {
            return nil
        }
        return DockerTemplateFieldMatch(field: String(template[fieldRange]), range: fullRange)
    }
}

private func dockerTemplateActionMatches(in template: String) -> [DockerTemplateActionMatch] {
    let pattern = #"\{\{([^}]*)\}\}"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let range = NSRange(template.startIndex ..< template.endIndex, in: template)
    return regex.matches(in: template, range: range).compactMap { match in
        guard
            let fullRange = Range(match.range(at: 0), in: template),
            let actionRange = Range(match.range(at: 1), in: template)
        else {
            return nil
        }
        return DockerTemplateActionMatch(
            action: String(template[actionRange]).trimmingCharacters(in: .whitespacesAndNewlines),
            range: fullRange,
        )
    }
}
