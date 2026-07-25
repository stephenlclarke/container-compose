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

private enum StructuredTemplateLexeme {
    case action(String)
    case text(String)
}

private indirect enum StructuredTemplateNode {
    case action(String)
    case conditional(
        expression: String,
        success: [StructuredTemplateNode],
        failure: [StructuredTemplateNode],
    )
    case range(
        specification: StructuredTemplateRange,
        success: [StructuredTemplateNode],
        failure: [StructuredTemplateNode],
    )
    case text(String)
    case with(
        expression: String,
        success: [StructuredTemplateNode],
        failure: [StructuredTemplateNode],
    )
}

private struct StructuredTemplateRange {
    var expression: String
    var keyVariable: String?
    var valueVariable: String?
}

private struct StructuredTemplateAction {
    var value: String
    var cursor: String.Index
    var trimFollowingText: Bool
}

private struct StructuredTemplateContext {
    var root: DockerTemplateData
    var dot: DockerTemplateData
    var variables: [String: DockerTemplateData] = [:]
}

private struct StructuredTemplateParser {
    var lexemes: [StructuredTemplateLexeme]
    var index = 0

    mutating func parse() throws -> [StructuredTemplateNode] {
        let result = try parseNodes(acceptStops: false)
        guard result.stop == nil else {
            throw structuredUnsupportedAction(result.stop ?? "")
        }
        return result.nodes
    }

    private mutating func parseNodes(
        acceptStops: Bool,
    ) throws -> (nodes: [StructuredTemplateNode], stop: String?) {
        var nodes: [StructuredTemplateNode] = []
        while index < lexemes.count {
            let lexeme = lexemes[index]
            index += 1
            switch lexeme {
            case let .text(value):
                nodes.append(.text(value))
            case let .action(action):
                if action == "else" || action == "end" || action.hasPrefix("else ") {
                    guard acceptStops else { throw structuredUnsupportedAction(action) }
                    return (nodes, action)
                }
                if action.hasPrefix("if ") {
                    try nodes.append(parseConditional(String(action.dropFirst(3))))
                } else if action.hasPrefix("with ") {
                    try nodes.append(parseWith(String(action.dropFirst(5))))
                } else if action.hasPrefix("range ") {
                    try nodes.append(parseRange(String(action.dropFirst(6))))
                } else if action.hasPrefix("/*"), action.hasSuffix("*/") {
                    continue
                } else {
                    try validateStructuredExpression(action)
                    nodes.append(.action(action))
                }
            }
        }
        return (nodes, nil)
    }

    private mutating func parseConditional(_ expression: String) throws -> StructuredTemplateNode {
        try validateStructuredExpression(expression)
        let success = try parseNodes(acceptStops: true)
        let failure = try parseFailure(stop: success.stop)
        return .conditional(expression: expression, success: success.nodes, failure: failure)
    }

    private mutating func parseWith(_ expression: String) throws -> StructuredTemplateNode {
        try validateStructuredExpression(expression)
        let success = try parseNodes(acceptStops: true)
        let failure = try parseFailure(stop: success.stop)
        return .with(expression: expression, success: success.nodes, failure: failure)
    }

    private mutating func parseRange(_ value: String) throws -> StructuredTemplateNode {
        let specification = try structuredTemplateRange(value)
        try validateStructuredExpression(specification.expression)
        let success = try parseNodes(acceptStops: true)
        let failure = try parseFailure(stop: success.stop)
        return .range(specification: specification, success: success.nodes, failure: failure)
    }

    private mutating func parseFailure(stop: String?) throws -> [StructuredTemplateNode] {
        guard let stop else {
            throw structuredUnsupportedAction("unclosed control action")
        }
        if stop == "end" {
            return []
        }
        if stop.hasPrefix("else if ") {
            let nested = try parseConditional(String(stop.dropFirst(8)))
            return [nested]
        }
        guard stop == "else" else {
            throw structuredUnsupportedAction(stop)
        }
        let failure = try parseNodes(acceptStops: true)
        guard failure.stop == "end" else {
            throw structuredUnsupportedAction(failure.stop ?? "unclosed control action")
        }
        return failure.nodes
    }
}

private struct StructuredTemplateScanState {
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

func renderStructuredDockerTemplate(
    _ template: String,
    values: [String: DockerTemplateData],
) throws -> String {
    let nodes = try structuredDockerTemplateNodes(template)
    let root = DockerTemplateData.object(values)
    let rendered = try renderStructuredTemplateNodes(
        nodes,
        context: StructuredTemplateContext(root: root, dot: root),
    )
    return rendered
        .replacingOccurrences(of: #"\t"#, with: "\t")
        .replacingOccurrences(of: #"\n"#, with: "\n")
}

func validateStructuredDockerTemplate(_ template: String) throws {
    _ = try structuredDockerTemplateNodes(template)
}

func structuredDockerTemplateFields(in template: String) -> [String] {
    guard let nodes = try? structuredDockerTemplateNodes(template) else {
        return []
    }
    var fields: [String] = []
    collectStructuredTemplateFields(nodes, dotIsRoot: true, into: &fields)
    var seen: Set<String> = []
    return fields.filter { seen.insert($0).inserted }
}

private func structuredDockerTemplateNodes(_ template: String) throws -> [StructuredTemplateNode] {
    var parser = try StructuredTemplateParser(lexemes: structuredTemplateLexemes(template))
    return try parser.parse()
}

private func structuredTemplateLexemes(_ template: String) throws -> [StructuredTemplateLexeme] {
    var lexemes: [StructuredTemplateLexeme] = []
    var cursor = template.startIndex
    var trimLeadingText = false

    while let open = template.range(of: "{{", range: cursor ..< template.endIndex) {
        var text = String(template[cursor ..< open.lowerBound])
        if trimLeadingText {
            text = text.trimmingPrefixWhitespace()
        }

        var contentStart = open.upperBound
        if structuredTemplateHasLeftTrimMarker(template, at: contentStart) {
            text = text.trimmingSuffixWhitespace()
            contentStart = template.index(after: contentStart)
        }
        if !text.isEmpty {
            lexemes.append(.text(text))
        }

        let action = try structuredTemplateAction(in: template, from: contentStart)
        lexemes.append(.action(action.value))
        cursor = action.cursor
        trimLeadingText = action.trimFollowingText
    }

    var tail = String(template[cursor...])
    if trimLeadingText {
        tail = tail.trimmingPrefixWhitespace()
    }
    if !tail.isEmpty {
        lexemes.append(.text(tail))
    }
    return lexemes
}

private func structuredTemplateAction(
    in template: String,
    from contentStart: String.Index,
) throws -> StructuredTemplateAction {
    var scan = StructuredTemplateScanState()
    var index = contentStart
    var closeStart: String.Index?
    while index < template.endIndex {
        if template[index] == "}", scan.isTopLevel {
            let next = template.index(after: index)
            if next < template.endIndex, template[next] == "}" {
                closeStart = index
                break
            }
        }
        guard scan.consume(template[index]) else {
            throw structuredUnsupportedAction("unbalanced template action")
        }
        index = template.index(after: index)
    }
    guard let closeStart, scan.isBalanced else {
        throw structuredUnsupportedAction("unclosed template action")
    }

    var contentEnd = closeStart
    var trimFollowingText = false
    if structuredTemplateHasRightTrimMarker(
        template,
        contentStart: contentStart,
        contentEnd: contentEnd,
    ) {
        trimFollowingText = true
        contentEnd = template.index(before: contentEnd)
    }
    let action = String(template[contentStart ..< contentEnd])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !action.isEmpty else {
        throw structuredUnsupportedAction("")
    }
    return StructuredTemplateAction(
        value: action,
        cursor: template.index(closeStart, offsetBy: 2),
        trimFollowingText: trimFollowingText,
    )
}

private func structuredTemplateRange(_ value: String) throws -> StructuredTemplateRange {
    guard let tokens = structuredTemplateTokens(value), !tokens.isEmpty else {
        throw structuredUnsupportedAction("range \(value)")
    }
    guard let assignmentIndex = tokens.firstIndex(of: ":=") else {
        return StructuredTemplateRange(expression: value, keyVariable: nil, valueVariable: nil)
    }
    let declarationText = tokens[..<assignmentIndex].joined(separator: " ")
    guard !declarationText.trimmingCharacters(in: .whitespaces).hasSuffix(","),
          !declarationText.contains(",,")
    else {
        throw structuredUnsupportedAction("range \(value)")
    }
    let declarations = declarationText
        .split(separator: ",", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard (1 ... 2).contains(declarations.count),
          declarations.allSatisfy(isStructuredTemplateVariable)
    else {
        throw structuredUnsupportedAction("range \(value)")
    }
    let expressionTokens = tokens[tokens.index(after: assignmentIndex)...]
    guard !expressionTokens.isEmpty else {
        throw structuredUnsupportedAction("range \(value)")
    }
    return StructuredTemplateRange(
        expression: expressionTokens.joined(separator: " "),
        keyVariable: declarations.count == 2 ? declarations[0] : nil,
        valueVariable: declarations.last,
    )
}

private func renderStructuredTemplateNodes(
    _ nodes: [StructuredTemplateNode],
    context: StructuredTemplateContext,
) throws -> String {
    var rendered = ""
    for node in nodes {
        switch node {
        case let .text(value):
            rendered += value
        case let .action(action):
            rendered += try evaluateStructuredTemplateExpression(action, context: context).display
        case let .conditional(expression, success, failure):
            let value = try evaluateStructuredTemplateExpression(expression, context: context)
            rendered += try renderStructuredTemplateNodes(value.isTruthy ? success : failure, context: context)
        case let .with(expression, success, failure):
            let value = try evaluateStructuredTemplateExpression(expression, context: context)
            var nested = context
            nested.dot = value
            rendered += try renderStructuredTemplateNodes(
                value.isTruthy ? success : failure,
                context: value.isTruthy ? nested : context,
            )
        case let .range(specification, success, failure):
            let value = try evaluateStructuredTemplateExpression(specification.expression, context: context)
            let entries = structuredTemplateRangeEntries(value)
            if entries.isEmpty {
                rendered += try renderStructuredTemplateNodes(failure, context: context)
            } else {
                for entry in entries {
                    var nested = context
                    nested.dot = entry.value
                    if let keyVariable = specification.keyVariable {
                        nested.variables[keyVariable] = entry.key
                    }
                    if let valueVariable = specification.valueVariable {
                        nested.variables[valueVariable] = entry.value
                    }
                    rendered += try renderStructuredTemplateNodes(success, context: nested)
                }
            }
        }
    }
    return rendered
}

private func structuredTemplateRangeEntries(
    _ value: DockerTemplateData,
) -> [(key: DockerTemplateData, value: DockerTemplateData)] {
    switch value {
    case let .array(values):
        values.enumerated().map { (.integer($0.offset), $0.element) }
    case let .object(values):
        values.keys.sorted().map { (.string($0), values[$0] ?? .null) }
    case let .string(value):
        value.enumerated().map { (.integer($0.offset), .string(String($0.element))) }
    default:
        []
    }
}

private let structuredTemplateFunctions: Set<String> = [
    "and",
    "eq",
    "index",
    "join",
    "json",
    "len",
    "lower",
    "ne",
    "not",
    "or",
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

private func validateStructuredExpression(_ expression: String) throws {
    guard let segments = structuredTemplatePipelineSegments(expression), !segments.isEmpty else {
        throw structuredUnsupportedAction(expression)
    }
    var hasPipelineValue = false
    for (index, segment) in segments.enumerated() {
        guard let tokens = structuredTemplateTokens(segment), !tokens.isEmpty else {
            throw structuredUnsupportedAction(expression)
        }
        if index == 0, tokens.count == 1, isStructuredTemplateValue(tokens[0]) {
            hasPipelineValue = true
            continue
        }
        if index == 0, tokens.first == ".Label", tokens.count == 2,
           isStructuredTemplateValue(tokens[1])
        {
            hasPipelineValue = true
            continue
        }
        guard let function = tokens.first,
              structuredTemplateFunctions.contains(function),
              tokens.dropFirst().allSatisfy(isStructuredTemplateValue),
              structuredTemplateArgumentsAreSupported(
                  function,
                  count: tokens.count - 1,
                  hasPipelineValue: hasPipelineValue,
              )
        else {
            throw structuredUnsupportedAction(expression)
        }
        hasPipelineValue = true
    }
    guard hasPipelineValue else {
        throw structuredUnsupportedAction(expression)
    }
}

private func isStructuredTemplateValue(_ token: String) -> Bool {
    token == "."
        || token == "$"
        || structuredTemplatePath(token) != nil
        || structuredTemplateStringLiteral(token) != nil
        || structuredTemplateParenthesizedExpression(token).map {
            (try? validateStructuredExpression($0)) != nil
        } == true
        || Int(token) != nil
        || token == "true"
        || token == "false"
}

private func structuredTemplatePath(_ token: String) -> (base: String, fields: [String])? {
    guard token.hasPrefix(".") || token.hasPrefix("$") else {
        return nil
    }
    let components = token.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    if token.hasPrefix(".") {
        guard !components.isEmpty, components.allSatisfy(isStructuredTemplateIdentifier) else {
            return nil
        }
        return (".", components)
    }
    if token.hasPrefix("$.") {
        let fields = Array(components.dropFirst())
        guard components.first == "$", !fields.isEmpty,
              fields.allSatisfy(isStructuredTemplateIdentifier)
        else {
            return nil
        }
        return ("$", fields)
    }
    guard let variable = components.first,
          isStructuredTemplateVariable(variable),
          components.dropFirst().allSatisfy(isStructuredTemplateIdentifier)
    else {
        return nil
    }
    return (variable, Array(components.dropFirst()))
}

private func isStructuredTemplateIdentifier(_ value: String) -> Bool {
    guard let first = value.first, first.isLetter || first == "_" else {
        return false
    }
    return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

private func isStructuredTemplateVariable(_ value: String) -> Bool {
    guard value.hasPrefix("$"), value.count > 1 else { return false }
    return isStructuredTemplateIdentifier(String(value.dropFirst()))
}

private func structuredTemplateStringLiteral(_ token: String) -> String? {
    guard token.count >= 2 else { return nil }
    if token.first == "`", token.last == "`" {
        return String(token.dropFirst().dropLast())
    }
    guard token.first == "\"", token.last == "\"",
          let data = token.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else {
        return nil
    }
    return value as? String
}

private func structuredTemplateParenthesizedExpression(_ token: String) -> String? {
    guard token.count >= 3, token.first == "(", token.last == ")" else {
        return nil
    }
    return String(token.dropFirst().dropLast())
}

private func structuredTemplateTokens(_ value: String) -> [String]? {
    var tokens: [String] = []
    var token = ""
    var scan = StructuredTemplateScanState()
    for character in value.trimmingCharacters(in: .whitespacesAndNewlines) {
        guard scan.consume(character) else { return nil }
        if character.isWhitespace, scan.isTopLevel {
            if !token.isEmpty {
                tokens.append(token)
                token = ""
            }
        } else {
            token.append(character)
        }
    }
    guard scan.isBalanced else { return nil }
    if !token.isEmpty {
        tokens.append(token)
    }
    return tokens
}

private func structuredTemplatePipelineSegments(_ expression: String) -> [String]? {
    var segments: [String] = []
    var segment = ""
    var scan = StructuredTemplateScanState()
    for character in expression {
        guard scan.consume(character) else { return nil }
        if character == "|", scan.isTopLevel {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            segments.append(trimmed)
            segment = ""
        } else {
            segment.append(character)
        }
    }
    let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard scan.isBalanced, !trimmed.isEmpty else { return nil }
    segments.append(trimmed)
    return segments
}

private func evaluateStructuredTemplateExpression(
    _ expression: String,
    context: StructuredTemplateContext,
) throws -> DockerTemplateData {
    guard let segments = structuredTemplatePipelineSegments(expression) else {
        throw structuredUnsupportedAction(expression)
    }
    var pipelineValue: DockerTemplateData?
    for (index, segment) in segments.enumerated() {
        guard let tokens = structuredTemplateTokens(segment), let head = tokens.first else {
            throw structuredUnsupportedAction(expression)
        }
        if index == 0, tokens.count == 1, isStructuredTemplateValue(head) {
            pipelineValue = try structuredTemplateValue(head, context: context)
        } else if index == 0, head == ".Label", tokens.count == 2 {
            let key = try structuredTemplateValue(tokens[1], context: context).display
            pipelineValue = structuredTemplateLabel(key, context: context)
        } else {
            guard structuredTemplateFunctions.contains(head) else {
                throw structuredUnsupportedAction(expression)
            }
            if head == "and" || head == "or" {
                pipelineValue = try evaluateStructuredShortCircuitFunction(
                    head,
                    argumentTokens: tokens.dropFirst(),
                    pipelineValue: pipelineValue,
                    context: context,
                )
                continue
            }
            let arguments = try tokens.dropFirst().map {
                try structuredTemplateValue($0, context: context)
            }
            pipelineValue = try applyStructuredTemplateFunction(
                head,
                arguments: arguments,
                pipelineValue: pipelineValue,
            )
        }
    }
    guard let pipelineValue else { throw structuredUnsupportedAction(expression) }
    return pipelineValue
}

private func evaluateStructuredShortCircuitFunction(
    _ function: String,
    argumentTokens: ArraySlice<String>,
    pipelineValue: DockerTemplateData?,
    context: StructuredTemplateContext,
) throws -> DockerTemplateData {
    var last: DockerTemplateData?
    for token in argumentTokens {
        let value = try structuredTemplateValue(token, context: context)
        last = value
        if function == "and", !value.isTruthy {
            return value
        }
        if function == "or", value.isTruthy {
            return value
        }
    }
    if let pipelineValue {
        last = pipelineValue
        if function == "and", !pipelineValue.isTruthy {
            return pipelineValue
        }
        if function == "or", pipelineValue.isTruthy {
            return pipelineValue
        }
    }
    guard let last else {
        throw structuredUnsupportedAction(function)
    }
    return last
}

private func structuredTemplateValue(
    _ token: String,
    context: StructuredTemplateContext,
) throws -> DockerTemplateData {
    switch token {
    case ".":
        return context.dot
    case "$":
        return context.root
    case "true":
        return .boolean(true)
    case "false":
        return .boolean(false)
    default:
        break
    }
    if let path = structuredTemplatePath(token) {
        let base = structuredTemplateBase(path.base, context: context)
        return path.fields.reduce(base, structuredTemplateLookup)
    }
    if let value = structuredTemplateStringLiteral(token) {
        return .string(value)
    }
    if let expression = structuredTemplateParenthesizedExpression(token) {
        return try evaluateStructuredTemplateExpression(expression, context: context)
    }
    if let value = Int(token) {
        return .integer(value)
    }
    throw structuredUnsupportedAction(token)
}

private func structuredTemplateBase(
    _ base: String,
    context: StructuredTemplateContext,
) -> DockerTemplateData {
    switch base {
    case ".":
        context.dot
    case "$":
        context.root
    default:
        context.variables[base] ?? .null
    }
}

private func structuredTemplateLookup(
    _ value: DockerTemplateData,
    _ field: String,
) -> DockerTemplateData {
    switch value {
    case let .lookupObject(values, _), let .object(values):
        values[field] ?? .null
    default:
        .null
    }
}

private func structuredTemplateLabel(
    _ key: String,
    context: StructuredTemplateContext,
) -> DockerTemplateData {
    let labels = structuredTemplateLookup(context.dot, "Labels")
    return structuredTemplateLookup(labels, key)
}

private func applyStructuredTemplateFunction(
    _ function: String,
    arguments: [DockerTemplateData],
    pipelineValue: DockerTemplateData?,
) throws -> DockerTemplateData {
    let inputs = arguments + (pipelineValue.map { [$0] } ?? [])
    switch function {
    case "and", "eq", "ne", "not", "or":
        return try applyStructuredLogicalFunction(function, inputs: inputs)
    case "json", "len", "table":
        return try applyStructuredValueFunction(function, inputs: inputs)
    case "lower", "title", "upper":
        return try applyStructuredCaseFunction(function, inputs: inputs)
    case "print", "printf", "println":
        return try applyStructuredPrintFunction(function, inputs: inputs)
    case "join", "pad", "split", "truncate":
        return try applyStructuredStringFunction(function, inputs: inputs)
    case "index", "slice":
        return try applyStructuredCollectionFunction(function, inputs: inputs)
    default:
        throw structuredUnsupportedAction(function)
    }
}

private func applyStructuredLogicalFunction(
    _ function: String,
    inputs: [DockerTemplateData],
) throws -> DockerTemplateData {
    switch function {
    case "and":
        return inputs.first(where: { !$0.isTruthy }) ?? inputs.last ?? .boolean(false)
    case "or":
        return inputs.first(where: \.isTruthy) ?? inputs.last ?? .boolean(false)
    case "not":
        guard inputs.count == 1 else { throw structuredUnsupportedAction(function) }
        return .boolean(!inputs[0].isTruthy)
    case "eq":
        guard inputs.count >= 2 else { throw structuredUnsupportedAction(function) }
        return .boolean(inputs.dropFirst().contains { structuredTemplateEqual(inputs[0], $0) })
    case "ne":
        guard inputs.count == 2 else { throw structuredUnsupportedAction(function) }
        return .boolean(!structuredTemplateEqual(inputs[0], inputs[1]))
    default:
        throw structuredUnsupportedAction(function)
    }
}

private func applyStructuredValueFunction(
    _ function: String,
    inputs: [DockerTemplateData],
) throws -> DockerTemplateData {
    let input = try structuredSingleInput(function, inputs)
    switch function {
    case "json":
        return try .string(input.json())
    case "len":
        return .integer(structuredTemplateLength(input))
    case "table":
        return input
    default:
        throw structuredUnsupportedAction(function)
    }
}

private func applyStructuredCaseFunction(
    _ function: String,
    inputs: [DockerTemplateData],
) throws -> DockerTemplateData {
    let input = try structuredStringInput(function, inputs)
    switch function {
    case "lower":
        return .string(input.lowercased())
    case "title":
        return .string(input.capitalized)
    case "upper":
        return .string(input.uppercased())
    default:
        throw structuredUnsupportedAction(function)
    }
}

private func applyStructuredPrintFunction(
    _ function: String,
    inputs: [DockerTemplateData],
) throws -> DockerTemplateData {
    switch function {
    case "print":
        return .string(inputs.map(\.display).joined())
    case "println":
        return .string(inputs.map(\.display).joined(separator: " ") + "\n")
    case "printf":
        guard let format = inputs.first else { throw structuredUnsupportedAction(function) }
        return try .string(structuredTemplatePrintf(format.display, values: Array(inputs.dropFirst())))
    default:
        throw structuredUnsupportedAction(function)
    }
}

private func applyStructuredStringFunction(
    _ function: String,
    inputs: [DockerTemplateData],
) throws -> DockerTemplateData {
    switch function {
    case "join":
        return try structuredTemplateJoin(inputs)
    case "pad":
        return try structuredTemplatePad(inputs)
    case "split":
        return try structuredTemplateSplit(inputs)
    case "truncate":
        return try structuredTemplateTruncate(inputs)
    default:
        throw structuredUnsupportedAction(function)
    }
}

private func applyStructuredCollectionFunction(
    _ function: String,
    inputs: [DockerTemplateData],
) throws -> DockerTemplateData {
    switch function {
    case "index":
        return try structuredTemplateIndex(inputs)
    case "slice":
        return try structuredTemplateSlice(inputs)
    default:
        throw structuredUnsupportedAction(function)
    }
}

private func structuredTemplateJoin(_ inputs: [DockerTemplateData]) throws -> DockerTemplateData {
    guard inputs.count == 2, case let .array(values) = inputs[0] else {
        throw structuredUnsupportedAction("join")
    }
    let separator = try structuredString(inputs[1], function: "join")
    return .string(values.map(\.display).joined(separator: separator))
}

private func structuredTemplatePad(_ inputs: [DockerTemplateData]) throws -> DockerTemplateData {
    guard inputs.count == 3 else { throw structuredUnsupportedAction("pad") }
    let value = try structuredString(inputs[0], function: "pad")
    let left = try structuredInteger(inputs[1], function: "pad")
    let right = try structuredInteger(inputs[2], function: "pad")
    return .string(
        String(repeating: " ", count: max(0, left)) + value
            + String(repeating: " ", count: max(0, right)),
    )
}

private func structuredTemplateSplit(_ inputs: [DockerTemplateData]) throws -> DockerTemplateData {
    guard inputs.count == 2 else { throw structuredUnsupportedAction("split") }
    let value = try structuredString(inputs[0], function: "split")
    let separator = try structuredString(inputs[1], function: "split")
    return .array(value.components(separatedBy: separator).map(DockerTemplateData.string))
}

private func structuredTemplateTruncate(_ inputs: [DockerTemplateData]) throws -> DockerTemplateData {
    guard inputs.count == 2 else { throw structuredUnsupportedAction("truncate") }
    let value = try structuredString(inputs[0], function: "truncate")
    let length = try structuredInteger(inputs[1], function: "truncate")
    return .string(String(value.prefix(max(0, length))))
}

private func structuredTemplateIndex(_ values: [DockerTemplateData]) throws -> DockerTemplateData {
    guard values.count == 2 else { throw structuredUnsupportedAction("index") }
    switch values[0] {
    case let .array(elements):
        let index = try structuredInteger(values[1], function: "index")
        guard elements.indices.contains(index) else { throw structuredUnsupportedAction("index") }
        return elements[index]
    case let .object(object):
        return object[values[1].display] ?? .null
    case let .lookupObject(object, _):
        return object[values[1].display] ?? .null
    case let .string(string):
        let index = try structuredInteger(values[1], function: "index")
        guard index >= 0, index < string.count else { throw structuredUnsupportedAction("index") }
        return .string(String(string[string.index(string.startIndex, offsetBy: index)]))
    default:
        throw structuredUnsupportedAction("index")
    }
}

private func structuredTemplateSlice(_ values: [DockerTemplateData]) throws -> DockerTemplateData {
    guard (2 ... 3).contains(values.count) else { throw structuredUnsupportedAction("slice") }
    let lower = try structuredInteger(values[1], function: "slice")
    switch values[0] {
    case let .array(elements):
        let upper = try values.count == 3
            ? structuredInteger(values[2], function: "slice")
            : elements.count
        guard lower >= 0, lower <= upper, upper <= elements.count else {
            throw structuredUnsupportedAction("slice")
        }
        return .array(Array(elements[lower ..< upper]))
    case let .string(string):
        let upper = try values.count == 3
            ? structuredInteger(values[2], function: "slice")
            : string.count
        guard lower >= 0, lower <= upper, upper <= string.count else {
            throw structuredUnsupportedAction("slice")
        }
        let start = string.index(string.startIndex, offsetBy: lower)
        let end = string.index(string.startIndex, offsetBy: upper)
        return .string(String(string[start ..< end]))
    default:
        throw structuredUnsupportedAction("slice")
    }
}

private func structuredTemplateEqual(
    _ lhs: DockerTemplateData,
    _ rhs: DockerTemplateData,
) -> Bool {
    lhs == rhs || lhs.display == rhs.display
}

private func collectStructuredTemplateFields(
    _ nodes: [StructuredTemplateNode],
    dotIsRoot: Bool,
    into fields: inout [String],
) {
    for node in nodes {
        switch node {
        case let .action(expression):
            collectStructuredExpressionFields(expression, dotIsRoot: dotIsRoot, into: &fields)
        case let .conditional(expression, success, failure):
            collectStructuredExpressionFields(expression, dotIsRoot: dotIsRoot, into: &fields)
            collectStructuredTemplateFields(success, dotIsRoot: dotIsRoot, into: &fields)
            collectStructuredTemplateFields(failure, dotIsRoot: dotIsRoot, into: &fields)
        case let .range(specification, success, failure):
            collectStructuredExpressionFields(specification.expression, dotIsRoot: dotIsRoot, into: &fields)
            collectStructuredTemplateFields(success, dotIsRoot: false, into: &fields)
            collectStructuredTemplateFields(failure, dotIsRoot: dotIsRoot, into: &fields)
        case .text:
            continue
        case let .with(expression, success, failure):
            collectStructuredExpressionFields(expression, dotIsRoot: dotIsRoot, into: &fields)
            collectStructuredTemplateFields(success, dotIsRoot: false, into: &fields)
            collectStructuredTemplateFields(failure, dotIsRoot: dotIsRoot, into: &fields)
        }
    }
}

private func collectStructuredExpressionFields(
    _ expression: String,
    dotIsRoot: Bool,
    into fields: inout [String],
) {
    guard let segments = structuredTemplatePipelineSegments(expression) else { return }
    for segment in segments {
        guard let tokens = structuredTemplateTokens(segment) else { continue }
        for token in tokens {
            collectStructuredValueFields(token, dotIsRoot: dotIsRoot, into: &fields)
        }
    }
}

private func collectStructuredValueFields(
    _ token: String,
    dotIsRoot: Bool,
    into fields: inout [String],
) {
    if token == ".Label", dotIsRoot {
        fields.append("Labels")
        return
    }
    if let path = structuredTemplatePath(token) {
        if path.base == ".", dotIsRoot, let field = path.fields.first {
            fields.append(field == "Label" ? "Labels" : field)
        } else if path.base == "$", let field = path.fields.first {
            fields.append(field)
        }
        return
    }
    if let expression = structuredTemplateParenthesizedExpression(token) {
        collectStructuredExpressionFields(expression, dotIsRoot: dotIsRoot, into: &fields)
    }
}
