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

indirect enum StructuredTemplateNode {
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

struct StructuredTemplateRange {
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
                if action == "else" || action == "end"
                    || structuredTemplateElseIfExpression(action) != nil
                    || structuredTemplateElseWithExpression(action) != nil
                {
                    guard acceptStops else { throw structuredUnsupportedAction(action) }
                    return (nodes, action)
                }
                if let expression = structuredTemplateControlExpression(action, keyword: "if") {
                    try nodes.append(parseConditional(expression))
                } else if let expression = structuredTemplateControlExpression(action, keyword: "with") {
                    try nodes.append(parseWith(expression))
                } else if let expression = structuredTemplateControlExpression(action, keyword: "range") {
                    try nodes.append(parseRange(expression))
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
        let failure = try parseConditionalFailure(stop: success.stop)
        return .conditional(expression: expression, success: success.nodes, failure: failure)
    }

    private mutating func parseWith(_ expression: String) throws -> StructuredTemplateNode {
        try validateStructuredExpression(expression)
        let success = try parseNodes(acceptStops: true)
        let failure = try parseWithFailure(stop: success.stop)
        return .with(expression: expression, success: success.nodes, failure: failure)
    }

    private mutating func parseRange(_ value: String) throws -> StructuredTemplateNode {
        let specification = try structuredTemplateRange(value)
        try validateStructuredExpression(specification.expression)
        let success = try parseNodes(acceptStops: true)
        let failure = try parsePlainFailure(stop: success.stop)
        return .range(specification: specification, success: success.nodes, failure: failure)
    }

    private mutating func parseConditionalFailure(
        stop: String?,
    ) throws -> [StructuredTemplateNode] {
        if let stop, let expression = structuredTemplateElseIfExpression(stop) {
            return try [parseConditional(expression)]
        }
        return try parsePlainFailure(stop: stop)
    }

    private mutating func parseWithFailure(
        stop: String?,
    ) throws -> [StructuredTemplateNode] {
        if let stop, let expression = structuredTemplateElseWithExpression(stop) {
            return try [parseWith(expression)]
        }
        return try parsePlainFailure(stop: stop)
    }

    private mutating func parsePlainFailure(
        stop: String?,
    ) throws -> [StructuredTemplateNode] {
        guard let stop else {
            throw structuredUnsupportedAction("unclosed control action")
        }
        if stop == "end" {
            return []
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

struct StructuredTemplateScanState {
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
    return try renderStructuredTemplateNodes(
        nodes,
        context: StructuredTemplateContext(root: root, dot: root),
    )
}

func validateStructuredDockerTemplate(_ template: String) throws {
    _ = try structuredDockerTemplateNodes(template)
}

func structuredDockerTemplateNodes(_ template: String) throws -> [StructuredTemplateNode] {
    var parser = try StructuredTemplateParser(lexemes: structuredTemplateLexemes(template))
    let nodes = try parser.parse()
    try validateStructuredTemplateVariables(nodes)
    return nodes
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
    let closeStart = try structuredTemplateCommentClose(
        in: template,
        from: contentStart,
    ) ?? structuredTemplateExpressionClose(in: template, from: contentStart)
    guard let closeStart else {
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

private func structuredTemplateCommentClose(
    in template: String,
    from contentStart: String.Index,
) throws -> String.Index? {
    let commentStart = template[contentStart...].firstIndex(where: { !$0.isWhitespace })
        ?? template.endIndex
    guard template[commentStart...].hasPrefix("/*") else {
        return nil
    }
    let bodyStart = template.index(commentStart, offsetBy: 2)
    guard let commentClose = template.range(
        of: "*/",
        range: bodyStart ..< template.endIndex,
    ) else {
        throw structuredUnsupportedAction("unclosed template comment")
    }
    guard let actionClose = template.range(
        of: "}}",
        range: commentClose.upperBound ..< template.endIndex,
    ) else {
        throw structuredUnsupportedAction("unclosed template action")
    }
    return actionClose.lowerBound
}

private func structuredTemplateExpressionClose(
    in template: String,
    from contentStart: String.Index,
) -> String.Index? {
    var scan = StructuredTemplateScanState()
    var index = contentStart
    while index < template.endIndex {
        if template[index] == "}", scan.isTopLevel {
            let next = template.index(after: index)
            if next < template.endIndex, template[next] == "}" {
                return scan.isBalanced ? index : nil
            }
        }
        guard scan.consume(template[index]) else {
            return nil
        }
        index = template.index(after: index)
    }
    return nil
}

private func structuredTemplateRange(_ value: String) throws -> StructuredTemplateRange {
    guard structuredTemplateTokens(value)?.isEmpty == false else {
        throw structuredUnsupportedAction("range \(value)")
    }
    guard let assignmentRange = structuredTemplateAssignmentRange(in: value) else {
        return StructuredTemplateRange(expression: value, keyVariable: nil, valueVariable: nil)
    }
    let declarationText = String(value[..<assignmentRange.lowerBound])
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
    let expression = String(value[assignmentRange.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !expression.isEmpty else {
        throw structuredUnsupportedAction("range \(value)")
    }
    return StructuredTemplateRange(
        expression: expression,
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
            rendered += structuredTemplateText(value)
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
            rendered += try renderStructuredTemplateRange(
                specification,
                success: success,
                failure: failure,
                context: context,
            )
        }
    }
    return rendered
}

private func structuredTemplateText(_ value: String) -> String {
    value
        .replacingOccurrences(of: #"\t"#, with: "\t")
        .replacingOccurrences(of: #"\n"#, with: "\n")
}

private func renderStructuredTemplateRange(
    _ specification: StructuredTemplateRange,
    success: [StructuredTemplateNode],
    failure: [StructuredTemplateNode],
    context: StructuredTemplateContext,
) throws -> String {
    let value = try evaluateStructuredTemplateExpression(specification.expression, context: context)
    let entries = try structuredTemplateRangeEntries(value)
    guard !entries.isEmpty else {
        var nested = context
        if let keyVariable = specification.keyVariable {
            nested.variables[keyVariable] = value
        }
        if let valueVariable = specification.valueVariable {
            nested.variables[valueVariable] = value
        }
        return try renderStructuredTemplateNodes(failure, context: nested)
    }
    var rendered = ""
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
    return rendered
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
        if isStructuredTemplateLabelFunction(tokens.first ?? ""),
           tokens.dropFirst().allSatisfy(isStructuredTemplateValue),
           tokens.count - 1 + (hasPipelineValue ? 1 : 0) == 1
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
        || structuredTemplateParenthesizedValue(token).map {
            (try? validateStructuredExpression($0.expression)) != nil
        } == true
        || Int(token) != nil
        || token == "true"
        || token == "false"
}

func structuredTemplatePath(_ token: String) -> (base: String, fields: [String])? {
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

func isStructuredTemplateIdentifier(_ value: String) -> Bool {
    guard let first = value.first, first.isLetter || first == "_" else {
        return false
    }
    return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

private func isStructuredTemplateVariable(_ value: String) -> Bool {
    guard value.hasPrefix("$"), value.count > 1 else { return false }
    return isStructuredTemplateIdentifier(String(value.dropFirst()))
}

func structuredTemplateStringLiteral(_ token: String) -> String? {
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

func structuredTemplateTokens(_ value: String) -> [String]? {
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

func structuredTemplatePipelineSegments(_ expression: String) -> [String]? {
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
        } else if isStructuredTemplateLabelFunction(head) {
            var inputs = try tokens.dropFirst().map {
                try structuredTemplateValue($0, context: context)
            }
            if let pipelineValue {
                inputs.append(pipelineValue)
            }
            guard inputs.count == 1 else {
                throw structuredUnsupportedAction("Label")
            }
            let key = try structuredString(inputs[0], function: "Label")
            let source = head == "$.Label" ? context.root : context.dot
            pipelineValue = try structuredTemplateLabel(key, source: source)
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
        return try path.fields.reduce(base) { value, field in
            try structuredTemplateLookup(value, field)
        }
    }
    if let value = structuredTemplateStringLiteral(token) {
        return .string(value)
    }
    if let parenthesized = structuredTemplateParenthesizedValue(token) {
        let base = try evaluateStructuredTemplateExpression(
            parenthesized.expression,
            context: context,
        )
        return try parenthesized.fields.reduce(base) { value, field in
            try structuredTemplateLookup(value, field)
        }
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
        for input in inputs.dropFirst()
            where try structuredTemplateEqual(inputs[0], input, function: function)
        {
            return .boolean(true)
        }
        return .boolean(false)
    case "ne":
        guard inputs.count == 2 else { throw structuredUnsupportedAction(function) }
        return try .boolean(!structuredTemplateEqual(inputs[0], inputs[1], function: function))
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
        return try .integer(structuredTemplateLength(input))
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
        return .string(structuredTemplatePrint(inputs))
    case "println":
        return .string(inputs.map(\.display).joined(separator: " ") + "\n")
    case "printf":
        guard let format = inputs.first else { throw structuredUnsupportedAction(function) }
        return try .string(
            structuredTemplatePrintf(
                structuredString(format, function: function),
                values: Array(inputs.dropFirst()),
            ),
        )
    default:
        throw structuredUnsupportedAction(function)
    }
}

private func structuredTemplatePrint(_ inputs: [DockerTemplateData]) -> String {
    var rendered = ""
    for (index, input) in inputs.enumerated() {
        if index > 0,
           !structuredTemplatePrintValueIsString(inputs[index - 1]),
           !structuredTemplatePrintValueIsString(input)
        {
            rendered.append(" ")
        }
        rendered += input.display
    }
    return rendered
}

private func structuredTemplatePrintValueIsString(_ value: DockerTemplateData) -> Bool {
    switch value {
    case .byteString, .lookupObject, .string:
        true
    case .array, .boolean, .integer, .null, .object, .record:
        false
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
