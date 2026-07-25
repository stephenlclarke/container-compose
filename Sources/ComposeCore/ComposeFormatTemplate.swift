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

/// Renders a Docker-style output template without replacing invalid UTF-8 bytes.
public func renderDockerTemplateData(_ template: String, values: [String: String]) throws -> Data {
    try renderDockerTemplateData(
        template,
        values: values.mapValues(DockerTemplateData.string),
    )
}

/// Renders a Docker-style output template against structured row data.
public func renderDockerTemplate(_ template: String, values: [String: DockerTemplateData]) throws -> String {
    try renderStructuredDockerTemplate(template, values: values)
}

/// Renders a structured Docker-style template as its exact output bytes.
public func renderDockerTemplateData(
    _ template: String,
    values: [String: DockerTemplateData],
) throws -> Data {
    try Data(renderStructuredDockerTemplateBytes(template, values: values))
}

/// Renders table template rows with Docker-style headers from referenced fields.
public func renderDockerTemplateTable(fields: [String], rows: [String]) -> String {
    renderDockerTemplateTable(
        header: fields.map { $0.uppercased() }.joined(separator: "\t"),
        rows: rows,
    )
}

/// Renders table rows after evaluating the template against Docker-style header values.
public func renderDockerTemplateTable(
    template: String,
    headers: [String: String],
    rows: [String],
) throws -> String {
    var headerValues = headers.mapValues(DockerTemplateData.string)
    if let labelsHeader = headers["Labels"] {
        var labelValues: [String: DockerTemplateData] = [:]
        for key in structuredDockerTemplateLabelKeys(in: template) {
            labelValues[key.lookupKey] = .string(dockerTemplateLabelHeader(key.headerKey))
        }
        headerValues["Labels"] = .lookupObject(labelValues, display: labelsHeader)
    }
    let header = try renderDockerTemplate(template, values: headerValues)
    return renderDockerTemplateTable(header: header, rows: rows)
}

/// Renders exact-byte template rows with Docker-style table headers.
public func renderDockerTemplateTableData(
    template: String,
    headers: [String: String],
    rows: [Data],
) throws -> Data {
    var headerValues = headers.mapValues(DockerTemplateData.string)
    if let labelsHeader = headers["Labels"] {
        var labelValues: [String: DockerTemplateData] = [:]
        for key in structuredDockerTemplateLabelKeys(in: template) {
            labelValues[key.lookupKey] = .string(dockerTemplateLabelHeader(key.headerKey))
        }
        headerValues["Labels"] = .lookupObject(labelValues, display: labelsHeader)
    }
    let header = try renderDockerTemplateData(template, values: headerValues)
    return Data(renderDockerTemplateTableBytes(header: Array(header), rows: rows.map(Array.init)))
}

private func renderDockerTemplateTable(header: String, rows: [String]) -> String {
    guard !rows.isEmpty else {
        return ""
    }
    guard !header.isEmpty else {
        return rows.joined(separator: "\n")
    }
    let headers = header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    let tableRows = [headers] + rows.map { row in
        let columns = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return columns.count == headers.count ? columns : [row]
    }
    return renderTable(tableRows)
}

private func renderDockerTemplateTableBytes(
    header: [UInt8],
    rows: [[UInt8]],
) -> [UInt8] {
    guard !rows.isEmpty else {
        return []
    }
    guard !header.isEmpty else {
        return joinedDockerTemplateBytes(rows, separator: [UInt8(ascii: "\n")])
    }
    if let header = String(bytes: header, encoding: .utf8) {
        let decodedRows = rows.compactMap { String(bytes: $0, encoding: .utf8) }
        if decodedRows.count == rows.count {
            return Array(renderDockerTemplateTable(header: header, rows: decodedRows).utf8)
        }
    }

    let headers = splitDockerTemplateBytes(header, separator: UInt8(ascii: "\t"))
    let tableRows = [headers] + rows.map { row in
        let columns = splitDockerTemplateBytes(row, separator: UInt8(ascii: "\t"))
        return columns.count == headers.count ? columns : [row]
    }
    let widths = tableRows.reduce(Array(repeating: 0, count: headers.count)) { current, row in
        zip(current, row).map { max($0, structuredTemplateUTF8Sequences($1).count) }
    }
    let renderedRows = tableRows.map { row in
        row.enumerated().reduce(into: [UInt8]()) { output, entry in
            let (index, value) = entry
            output.append(contentsOf: value)
            guard index < row.count - 1 else { return }
            let width = structuredTemplateUTF8Sequences(value).count
            output.append(
                contentsOf: Array(
                    repeating: UInt8(ascii: " "),
                    count: widths[index] - width + 2,
                ),
            )
        }
    }
    return joinedDockerTemplateBytes(
        renderedRows,
        separator: [UInt8(ascii: "\n")],
    )
}

private func splitDockerTemplateBytes(
    _ value: [UInt8],
    separator: UInt8,
) -> [[UInt8]] {
    var parts: [[UInt8]] = []
    var start = 0
    for index in value.indices where value[index] == separator {
        parts.append(Array(value[start ..< index]))
        start = index + 1
    }
    parts.append(Array(value[start...]))
    return parts
}

/// Joins exact-byte template rows with one newline between rows.
public func joinedDockerTemplateData(_ values: [Data]) -> Data {
    Data(
        joinedDockerTemplateBytes(
            values.map(Array.init),
            separator: [UInt8(ascii: "\n")],
        ),
    )
}

func emitDockerTemplateOutput(
    _ output: Data,
    emit: @Sendable (String) -> Void,
    emitData: @Sendable (Data) -> Void,
) {
    if let text = String(data: output, encoding: .utf8) {
        emit(text)
    } else {
        emitData(output)
    }
}

func emitDockerTemplateOutput(
    _ output: Data,
    options: ComposeExecutionOptions,
) {
    emitDockerTemplateOutput(
        output,
        emit: options.emit,
        emitData: options.emitData,
    )
}

private func joinedDockerTemplateBytes(
    _ values: [[UInt8]],
    separator: [UInt8],
) -> [UInt8] {
    var output: [UInt8] = []
    for (index, value) in values.enumerated() {
        if index > 0 {
            output.append(contentsOf: separator)
        }
        output.append(contentsOf: value)
    }
    return output
}

private func dockerTemplateLabelHeader(_ key: String) -> String {
    let name = key.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? key
    return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
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
