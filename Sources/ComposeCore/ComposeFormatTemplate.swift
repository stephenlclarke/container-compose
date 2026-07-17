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
    guard let actionMatches = try? dockerTemplateActionMatches(in: template) else {
        return []
    }
    return actionMatches.flatMap { match -> [String] in
        guard let segments = dockerTemplatePipelineSegments(match.action) else {
            return []
        }
        return segments.flatMap { segment -> [String] in
            guard let tokens = dockerTemplateTokens(segment), !tokens.isEmpty else {
                return []
            }
            let valueTokens = dockerTemplateFunctions.contains(tokens[0])
                ? tokens.dropFirst()
                : tokens[...]
            return valueTokens.flatMap(dockerTemplateFieldsForValueToken)
        }
    }
}

/// Renders Docker's portable row-oriented output-template functions.
///
/// Compose keeps formatting at its boundary: the runtime supplies data, while
/// this adapter handles Docker's display vocabulary without a runtime fork.
public func renderDockerTemplate(_ template: String, values: [String: String]) throws -> String {
    try validateDockerTemplateActions(in: template)
    let actionMatches = try dockerTemplateActionMatches(in: template)
    var rendered = template
    for match in actionMatches.reversed() {
        let value = try renderDockerTemplateAction(match.action, values: values)
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

/// Rejects unsupported control or function actions before runtime discovery.
public func validateDockerTemplateActions(in template: String) throws {
    for match in try dockerTemplateActionMatches(in: template) where !dockerTemplateActionIsSupported(match.action) {
        throw unsupportedDockerTemplateAction(match.action)
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

private struct DockerTemplateActionMatch {
    var action: String
    var range: Range<String.Index>
}

private let dockerTemplateFunctions: Set<String> = [
    "index",
    "join",
    "json",
    "len",
    "lower",
    "pad",
    "print",
    "printf",
    "println",
    "slice",
    "split",
    "table",
    "title",
    "truncate",
    "upper",
]

private enum DockerTemplateValue {
    case integer(Int)
    case object([String: String])
    case string(String)
    case strings([String])

    var display: String {
        switch self {
        case let .integer(value):
            return String(value)
        case let .object(values):
            let entries = values.keys.sorted().map { key in
                "\(key):\(values[key] ?? "")"
            }
            return "map[\(entries.joined(separator: " "))]"
        case let .string(value):
            return value
        case let .strings(values):
            return "[\(values.joined(separator: " "))]"
        }
    }

    func json() throws -> String {
        let object: Any = switch self {
        case let .integer(value): value
        case let .object(values): values
        case let .string(value): value
        case let .strings(values): values
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed, .sortedKeys]
        )
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

private func dockerTemplateActionIsSupported(_ action: String) -> Bool {
    guard let segments = dockerTemplatePipelineSegments(action), !segments.isEmpty else {
        return false
    }
    var hasPipelineValue = false
    for (index, segment) in segments.enumerated() {
        guard let tokens = dockerTemplateTokens(segment) else {
            return false
        }
        guard !tokens.isEmpty else { return false }
        if index == 0, tokens.count == 1, isDockerTemplateValue(tokens[0]) {
            hasPipelineValue = true
            continue
        }
        guard let function = tokens.first, dockerTemplateFunctions.contains(function) else {
            return false
        }
        guard tokens.dropFirst().allSatisfy(isDockerTemplateValue) else { return false }
        guard dockerTemplateFunctionArgumentsAreSupported(
            function,
            arguments: tokens.dropFirst(),
            hasPipelineValue: hasPipelineValue
        ) else {
            return false
        }
        hasPipelineValue = true
    }
    return hasPipelineValue
}

private func isDockerTemplateValue(_ token: String) -> Bool {
    token == "."
        || dockerTemplateFieldName(token) != nil
        || dockerTemplateStringLiteral(token) != nil
        || dockerTemplateParenthesizedAction(token).map(dockerTemplateActionIsSupported) == true
        || Int(token) != nil
}

private func dockerTemplateFieldName(_ token: String) -> String? {
    guard token.hasPrefix("."), token.count > 1 else {
        return nil
    }
    let field = String(token.dropFirst())
    guard let first = field.first, first.isLetter else {
        return nil
    }
    guard field.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
        return nil
    }
    return field
}

private func dockerTemplateStringLiteral(_ token: String) -> String? {
    guard token.count >= 2 else {
        return nil
    }
    if token.first == "`", token.last == "`" {
        return String(token.dropFirst().dropLast())
    }
    guard token.first == "\"", token.last == "\"" else {
        return nil
    }
    guard
        let data = token.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else {
        return nil
    }
    return value as? String
}

private func dockerTemplateParenthesizedAction(_ token: String) -> String? {
    guard token.count >= 3, token.first == "(", token.last == ")" else {
        return nil
    }
    return String(token.dropFirst().dropLast())
}

private func dockerTemplateFieldsForValueToken(_ token: String) -> [String] {
    if let field = dockerTemplateFieldName(token) {
        return [field]
    }
    guard let action = dockerTemplateParenthesizedAction(token) else {
        return []
    }
    return dockerTemplateFields(in: "{{\(action)}}")
}

private struct DockerTemplateLexicalState {
    private var quote: Character?
    private var escaped = false
    private var parentheses = 0

    var isTopLevel: Bool {
        quote == nil && parentheses == 0
    }

    var isBalanced: Bool {
        isTopLevel && !escaped
    }

    mutating func consume(_ character: Character) -> Bool {
        if let quote {
            return consumeQuoted(character, quote: quote)
        }
        return consumeUnquoted(character)
    }

    private mutating func consumeQuoted(_ character: Character, quote: Character) -> Bool {
        if escaped {
            escaped = false
            return true
        }
        if quote == "\"", character == "\\" {
            escaped = true
            return true
        }
        if character == quote {
            self.quote = nil
        }
        return true
    }

    private mutating func consumeUnquoted(_ character: Character) -> Bool {
        switch character {
        case "\"", "`":
            quote = character
        case "(":
            parentheses += 1
        case ")":
            guard parentheses > 0 else { return false }
            parentheses -= 1
        default:
            break
        }
        return true
    }
}

private func dockerTemplateTokens(_ value: String) -> [String]? {
    var tokens: [String] = []
    var token = ""
    var lexicalState = DockerTemplateLexicalState()
    for character in value.trimmingCharacters(in: .whitespacesAndNewlines) {
        guard lexicalState.consume(character) else { return nil }
        if character.isWhitespace, lexicalState.isTopLevel {
            if !token.isEmpty {
                tokens.append(token)
                token = ""
            }
        } else {
            token.append(character)
        }
    }
    guard lexicalState.isBalanced else {
        return nil
    }
    if !token.isEmpty {
        tokens.append(token)
    }
    return tokens
}

private func dockerTemplatePipelineSegments(_ action: String) -> [String]? {
    var segments: [String] = []
    var segment = ""
    var lexicalState = DockerTemplateLexicalState()
    for character in action {
        guard lexicalState.consume(character) else { return nil }
        if character == "|", lexicalState.isTopLevel {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            segments.append(trimmed)
            segment = ""
        } else {
            segment.append(character)
        }
    }
    let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard lexicalState.isBalanced, !trimmed.isEmpty else {
        return nil
    }
    segments.append(trimmed)
    return segments
}

private func renderDockerTemplateAction(_ action: String, values: [String: String]) throws -> String {
    try dockerTemplateEvaluatedAction(action, values: values).display
}

private func dockerTemplateEvaluatedAction(
    _ action: String,
    values: [String: String]
) throws -> DockerTemplateValue {
    guard let segments = dockerTemplatePipelineSegments(action) else {
        throw unsupportedDockerTemplateAction(action)
    }
    var pipelineValue: DockerTemplateValue?
    for (index, segment) in segments.enumerated() {
        guard let tokens = dockerTemplateTokens(segment) else {
            throw unsupportedDockerTemplateAction(action)
        }
        guard let head = tokens.first else { throw unsupportedDockerTemplateAction(action) }
        if index == 0, tokens.count == 1, isDockerTemplateValue(head) {
            pipelineValue = try dockerTemplateValue(head, values: values)
        } else {
            guard dockerTemplateFunctions.contains(head) else { throw unsupportedDockerTemplateAction(action) }
            let arguments = try tokens.dropFirst().map { try dockerTemplateValue($0, values: values) }
            pipelineValue = try applyDockerTemplateFunction(head, arguments: arguments, pipelineValue: pipelineValue)
        }
    }
    guard let pipelineValue else { throw unsupportedDockerTemplateAction(action) }
    return pipelineValue
}

private func dockerTemplateValue(_ token: String, values: [String: String]) throws -> DockerTemplateValue {
    if token == "." {
        return .object(values)
    }
    if let field = dockerTemplateFieldName(token) {
        guard let value = values[field] else {
            throw unsupportedDockerTemplateField(field, command: "format", supported: Set(values.keys))
        }
        return .string(value)
    }
    if let value = dockerTemplateStringLiteral(token) {
        return .string(value)
    }
    if let action = dockerTemplateParenthesizedAction(token) {
        return try dockerTemplateEvaluatedAction(action, values: values)
    }
    if let value = Int(token) {
        return .integer(value)
    }
    throw unsupportedDockerTemplateAction(token)
}

private func applyDockerTemplateFunction(
    _ function: String,
    arguments: [DockerTemplateValue],
    pipelineValue: DockerTemplateValue?
) throws -> DockerTemplateValue {
    switch function {
    case "json", "len", "lower", "table", "title", "upper":
        return try dockerTemplateSimpleFunction(function, arguments: arguments, pipelineValue: pipelineValue)
    case "print", "printf", "println":
        return try dockerTemplateOutputFunction(function, arguments: arguments, pipelineValue: pipelineValue)
    case "index", "join", "pad", "slice", "split", "truncate":
        return try dockerTemplateCollectionFunction(function, arguments: arguments, pipelineValue: pipelineValue)
    default:
        throw unsupportedDockerTemplateAction(function)
    }
}

private func dockerTemplateSimpleFunction(
    _ function: String,
    arguments: [DockerTemplateValue],
    pipelineValue: DockerTemplateValue?
) throws -> DockerTemplateValue {
    switch function {
    case "json":
        return try .string(dockerTemplateSingleInput(function, arguments, pipelineValue).json())
    case "lower":
        return try .string(dockerTemplateStringInput(function, arguments, pipelineValue).lowercased())
    case "upper":
        return try .string(dockerTemplateStringInput(function, arguments, pipelineValue).uppercased())
    case "title":
        return try .string(dockerTemplateStringInput(function, arguments, pipelineValue).capitalized)
    case "table":
        return try dockerTemplateSingleInput(function, arguments, pipelineValue)
    case "len":
        return try .integer(dockerTemplateLength(dockerTemplateSingleInput(function, arguments, pipelineValue)))
    default:
        throw unsupportedDockerTemplateAction(function)
    }
}

private func dockerTemplateOutputFunction(
    _ function: String,
    arguments: [DockerTemplateValue],
    pipelineValue: DockerTemplateValue?
) throws -> DockerTemplateValue {
    let inputs = arguments + (pipelineValue.map { [$0] } ?? [])
    switch function {
    case "print":
        return .string(inputs.map(\.display).joined())
    case "println":
        return .string(inputs.map(\.display).joined(separator: " ") + "\n")
    case "printf":
        guard let format = inputs.first else { throw unsupportedDockerTemplateAction(function) }
        return try .string(dockerTemplatePrintf(format.display, values: Array(inputs.dropFirst())))
    default:
        throw unsupportedDockerTemplateAction(function)
    }
}

private func dockerTemplateCollectionFunction(
    _ function: String,
    arguments: [DockerTemplateValue],
    pipelineValue: DockerTemplateValue?
) throws -> DockerTemplateValue {
    guard pipelineValue == nil else { throw unsupportedDockerTemplateAction(function) }
    switch function {
    case "pad":
        return try .string(dockerTemplatePaddedValue(dockerTemplatePadInput(arguments)))
    case "truncate":
        let input = try dockerTemplateTruncateInput(arguments)
        return .string(String(input.value.prefix(max(0, input.length))))
    case "split":
        let input = try dockerTemplateSplitInput(arguments)
        return .strings(input.value.components(separatedBy: input.separator))
    case "join":
        let input = try dockerTemplateJoinInput(arguments)
        return .string(input.values.joined(separator: input.separator))
    case "index":
        return try dockerTemplateIndex(arguments)
    case "slice":
        return try dockerTemplateSlice(arguments)
    default:
        throw unsupportedDockerTemplateAction(function)
    }
}

private func dockerTemplateFunctionArgumentsAreSupported(
    _ function: String,
    arguments: ArraySlice<String>,
    hasPipelineValue: Bool
) -> Bool {
    let argumentCount = arguments.count
    switch function {
    case "json", "len", "lower", "table", "title", "upper":
        return argumentCount == (hasPipelineValue ? 0 : 1)
    case "pad":
        return !hasPipelineValue && argumentCount == 3
    case "truncate", "split", "join", "index":
        return !hasPipelineValue && argumentCount == 2
    case "slice":
        return !hasPipelineValue && (2 ... 3).contains(argumentCount)
    case "printf":
        guard argumentCount >= 1 else { return false }
        guard let format = dockerTemplateStringLiteral(arguments[arguments.startIndex]) else { return true }
        return dockerTemplatePrintfFormatIsSupported(format)
    case "print", "println":
        return true
    default:
        return false
    }
}

private func unsupportedDockerTemplateAction(_ action: String) -> ComposeError {
    ComposeError.unsupported(
        "format template action '{{\(action)}}'; supported actions are field references plus Docker's json, join, table, lower, split, title, upper, pad, truncate, and println functions, and Go's print, printf, len, index, and slice functions"
    )
}

private func dockerTemplateSingleInput(
    _ function: String,
    _ arguments: [DockerTemplateValue],
    _ pipelineValue: DockerTemplateValue?
) throws -> DockerTemplateValue {
    if let pipelineValue {
        guard arguments.isEmpty else { throw unsupportedDockerTemplateAction(function) }
        return pipelineValue
    }
    guard arguments.count == 1, let value = arguments.first else {
        throw unsupportedDockerTemplateAction(function)
    }
    return value
}

private func dockerTemplateStringInput(
    _ function: String,
    _ arguments: [DockerTemplateValue],
    _ pipelineValue: DockerTemplateValue?
) throws -> String {
    let value = try dockerTemplateSingleInput(function, arguments, pipelineValue)
    guard case let .string(string) = value else {
        throw unsupportedDockerTemplateAction(function)
    }
    return string
}

private func dockerTemplateInteger(_ value: DockerTemplateValue, function: String) throws -> Int {
    switch value {
    case let .integer(integer):
        return integer
    case let .string(string):
        guard let integer = Int(string) else { throw unsupportedDockerTemplateAction(function) }
        return integer
    default:
        throw unsupportedDockerTemplateAction(function)
    }
}

private struct DockerTemplatePadding {
    var value: String
    var left: Int
    var right: Int
}

private func dockerTemplatePadInput(_ arguments: [DockerTemplateValue]) throws -> DockerTemplatePadding {
    guard arguments.count == 3, case let .string(string) = arguments[0] else {
        throw unsupportedDockerTemplateAction("pad")
    }
    let left = try dockerTemplateInteger(arguments[1], function: "pad")
    let right = try dockerTemplateInteger(arguments[2], function: "pad")
    return DockerTemplatePadding(value: string, left: left, right: right)
}

private func dockerTemplatePaddedValue(_ padding: DockerTemplatePadding) -> String {
    String(repeating: " ", count: max(0, padding.left)) + padding.value
        + String(repeating: " ", count: max(0, padding.right))
}

private func dockerTemplateTruncateInput(_ arguments: [DockerTemplateValue]) throws -> (value: String, length: Int) {
    guard arguments.count == 2, case let .string(string) = arguments[0] else {
        throw unsupportedDockerTemplateAction("truncate")
    }
    return try (string, dockerTemplateInteger(arguments[1], function: "truncate"))
}

private func dockerTemplateSplitInput(_ arguments: [DockerTemplateValue]) throws -> (value: String, separator: String) {
    guard arguments.count == 2,
          case let .string(string) = arguments[0],
          case let .string(separator) = arguments[1]
    else {
        throw unsupportedDockerTemplateAction("split")
    }
    return (string, separator)
}

private func dockerTemplateJoinInput(_ arguments: [DockerTemplateValue]) throws -> (values: [String], separator: String) {
    guard arguments.count == 2 else { throw unsupportedDockerTemplateAction("join") }
    let strings: [String] = switch arguments[0] {
    case let .strings(value): value
    case let .string(value): [value]
    default: throw unsupportedDockerTemplateAction("join")
    }
    guard case let .string(separator) = arguments[1] else {
        throw unsupportedDockerTemplateAction("join")
    }
    return (strings, separator)
}

private func dockerTemplateLength(_ value: DockerTemplateValue) -> Int {
    switch value {
    case .integer:
        1
    case let .object(values):
        values.count
    case let .string(value):
        value.count
    case let .strings(values):
        values.count
    }
}

private func dockerTemplateIndex(_ arguments: [DockerTemplateValue]) throws -> DockerTemplateValue {
    guard arguments.count == 2 else { throw unsupportedDockerTemplateAction("index") }
    let offset = try dockerTemplateInteger(arguments[1], function: "index")
    guard offset >= 0 else { throw unsupportedDockerTemplateAction("index") }
    switch arguments[0] {
    case let .string(string):
        guard offset < string.count else { throw unsupportedDockerTemplateAction("index") }
        let stringIndex = string.index(string.startIndex, offsetBy: offset)
        return .string(String(string[stringIndex]))
    case let .strings(values):
        guard offset < values.count else { throw unsupportedDockerTemplateAction("index") }
        return .string(values[offset])
    default:
        throw unsupportedDockerTemplateAction("index")
    }
}

private func dockerTemplateSlice(_ arguments: [DockerTemplateValue]) throws -> DockerTemplateValue {
    guard (2 ... 3).contains(arguments.count) else { throw unsupportedDockerTemplateAction("slice") }
    let bounds = arguments.dropFirst()
    let lower = try dockerTemplateInteger(bounds[bounds.startIndex], function: "slice")
    switch arguments[0] {
    case let .string(string):
        let upper = try dockerTemplateSliceUpperBound(bounds, length: string.count)
        guard lower >= 0, lower <= upper, upper <= string.count else {
            throw unsupportedDockerTemplateAction("slice")
        }
        let start = string.index(string.startIndex, offsetBy: lower)
        let end = string.index(string.startIndex, offsetBy: upper)
        return .string(String(string[start ..< end]))
    case let .strings(values):
        let upper = try dockerTemplateSliceUpperBound(bounds, length: values.count)
        guard lower >= 0, lower <= upper, upper <= values.count else {
            throw unsupportedDockerTemplateAction("slice")
        }
        return .strings(Array(values[lower ..< upper]))
    default:
        throw unsupportedDockerTemplateAction("slice")
    }
}

private func dockerTemplateSliceUpperBound(_ bounds: ArraySlice<DockerTemplateValue>, length: Int) throws -> Int {
    guard bounds.count == 2 else { return length }
    return try dockerTemplateInteger(bounds[bounds.index(after: bounds.startIndex)], function: "slice")
}

private func dockerTemplatePrintf(_ format: String, values: [DockerTemplateValue]) throws -> String {
    guard dockerTemplatePrintfFormatIsSupported(format) else {
        throw unsupportedDockerTemplateAction("printf \(format)")
    }
    var rendered = ""
    var cursor = format.startIndex
    var valueIndex = 0
    while cursor < format.endIndex {
        guard format[cursor] == "%" else {
            rendered.append(format[cursor])
            cursor = format.index(after: cursor)
            continue
        }
        let specifierStart = format.index(after: cursor)
        guard specifierStart < format.endIndex else { throw unsupportedDockerTemplateAction("printf \(format)") }
        if format[specifierStart] == "%" {
            rendered.append("%")
            cursor = format.index(after: specifierStart)
            continue
        }
        guard "svq".contains(format[specifierStart]), valueIndex < values.count else {
            throw unsupportedDockerTemplateAction("printf \(format)")
        }
        switch format[specifierStart] {
        case "q":
            rendered += try values[valueIndex].json()
        case "s", "v":
            rendered += values[valueIndex].display
        default:
            throw unsupportedDockerTemplateAction("printf \(format)")
        }
        valueIndex += 1
        cursor = format.index(after: specifierStart)
    }
    guard valueIndex == values.count else { throw unsupportedDockerTemplateAction("printf \(format)") }
    return rendered
}

private func dockerTemplatePrintfFormatIsSupported(_ format: String) -> Bool {
    var cursor = format.startIndex
    while cursor < format.endIndex {
        guard format[cursor] == "%" else {
            cursor = format.index(after: cursor)
            continue
        }
        let specifier = format.index(after: cursor)
        guard specifier < format.endIndex, "%svq".contains(format[specifier]) else {
            return false
        }
        cursor = format.index(after: specifier)
    }
    return true
}

private func dockerTemplateActionMatches(in template: String) throws -> [DockerTemplateActionMatch] {
    var matches: [DockerTemplateActionMatch] = []
    var cursor = template.startIndex
    while let openRange = template.range(of: "{{", range: cursor ..< template.endIndex) {
        let contentStart = openRange.upperBound
        var index = contentStart
        var lexicalState = DockerTemplateLexicalState()
        var closeRange: Range<String.Index>?
        while index < template.endIndex {
            let character = template[index]
            if character == "}", lexicalState.isTopLevel {
                let next = template.index(after: index)
                if next < template.endIndex, template[next] == "}" {
                    closeRange = index ..< template.index(after: next)
                    break
                }
            }
            guard lexicalState.consume(character) else { break }
            index = template.index(after: index)
        }
        guard let closeRange, lexicalState.isBalanced else {
            throw unsupportedDockerTemplateAction("unclosed template action")
        }
        matches.append(
            DockerTemplateActionMatch(
                action: String(template[contentStart ..< closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                range: openRange.lowerBound ..< closeRange.upperBound
            )
        )
        cursor = closeRange.upperBound
    }
    return matches
}
