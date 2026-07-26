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

func structuredTemplateControlExpression(
    _ action: String,
    keyword: String,
) -> String? {
    guard action.hasPrefix(keyword) else {
        return nil
    }
    let suffix = action.dropFirst(keyword.count)
    guard suffix.first.map(structuredTemplateIsGoWhitespace) == true || suffix.first == "(" else {
        return nil
    }
    let expression = structuredTemplateTrimGoWhitespace(suffix)
    return expression.isEmpty ? nil : expression
}

func structuredTemplateElseIfExpression(_ action: String) -> String? {
    structuredTemplateElseControlExpression(action, keyword: "if")
}

func structuredTemplateElseWithExpression(_ action: String) -> String? {
    structuredTemplateElseControlExpression(action, keyword: "with")
}

private func structuredTemplateElseControlExpression(
    _ action: String,
    keyword: String,
) -> String? {
    guard action.hasPrefix("else") else {
        return nil
    }
    let suffix = action.dropFirst(4)
    guard suffix.first.map(structuredTemplateIsGoWhitespace) == true else {
        return nil
    }
    return structuredTemplateControlExpression(
        structuredTemplateTrimGoWhitespace(suffix),
        keyword: keyword,
    )
}

func structuredTemplateRangeEntries(
    _ value: DockerTemplateData,
) throws -> [(key: DockerTemplateData, value: DockerTemplateData)] {
    switch value {
    case let .array(values):
        values.enumerated().map { (.integer($0.offset), $0.element) }
    case let .integer(value):
        value > 0
            ? (0 ..< value).map { (.integer($0), .integer($0)) }
            : []
    case let .object(values):
        values.keys.sorted().map { (.string($0), values[$0] ?? .null) }
    case .null:
        []
    case .boolean, .byteString, .lookupObject, .record, .string:
        throw structuredUnsupportedAction("range")
    }
}

func structuredDockerTemplateFields(in template: String) -> [String] {
    guard let nodes = try? structuredDockerTemplateNodes(template) else {
        return []
    }
    var fields: [String] = []
    collectStructuredTemplateFields(nodes, dotIsRoot: true, into: &fields)
    return fields
}

struct StructuredDockerTemplateLabelKey {
    let lookupKey: String
    let headerKey: String
}

func structuredDockerTemplateLabelKeys(in template: String) -> [StructuredDockerTemplateLabelKey] {
    guard let nodes = try? structuredDockerTemplateNodes(template) else {
        return []
    }
    var keys: [StructuredDockerTemplateLabelKey] = []
    collectStructuredTemplateLabelKeys(nodes, into: &keys)
    return keys
}

func validateStructuredTemplateVariables(
    _ nodes: [StructuredTemplateNode],
    variables: Set<String> = [],
) throws {
    for node in nodes {
        switch node {
        case let .action(expression):
            try validateStructuredExpressionVariables(expression, variables: variables)
        case let .conditional(expression, success, failure),
             let .with(expression, success, failure):
            try validateStructuredExpressionVariables(expression, variables: variables)
            try validateStructuredTemplateVariables(success, variables: variables)
            try validateStructuredTemplateVariables(failure, variables: variables)
        case let .range(specification, success, failure):
            try validateStructuredExpressionVariables(specification.expression, variables: variables)
            let declared = [specification.keyVariable, specification.valueVariable].compactMap(\.self)
            let nestedVariables = variables.union(declared)
            try validateStructuredTemplateVariables(success, variables: nestedVariables)
            try validateStructuredTemplateVariables(failure, variables: nestedVariables)
        case .text:
            continue
        }
    }
}

func validateStructuredTemplateRootIndexing(
    _ nodes: [StructuredTemplateNode],
    dotIsRoot: Bool = true,
) throws {
    for node in nodes {
        switch node {
        case let .action(expression):
            try validateStructuredExpressionRootIndexing(
                expression,
                dotIsRoot: dotIsRoot,
            )
        case let .conditional(expression, success, failure):
            try validateStructuredExpressionRootIndexing(
                expression,
                dotIsRoot: dotIsRoot,
            )
            try validateStructuredTemplateRootIndexing(success, dotIsRoot: dotIsRoot)
            try validateStructuredTemplateRootIndexing(failure, dotIsRoot: dotIsRoot)
        case let .range(specification, success, failure):
            try validateStructuredExpressionRootIndexing(
                specification.expression,
                dotIsRoot: dotIsRoot,
            )
            if structuredTemplateExpressionAlwaysReturnsRoot(
                specification.expression,
                dotIsRoot: dotIsRoot,
            ) {
                throw structuredUnsupportedAction("range root value")
            }
            if specification.keyVariable != nil,
               case .integer = structuredTemplateStaticValue(specification.expression)?.value
            {
                throw structuredUnsupportedAction("range integer with two variables")
            }
            try validateStructuredTemplateRootIndexing(success, dotIsRoot: false)
            try validateStructuredTemplateRootIndexing(failure, dotIsRoot: dotIsRoot)
        case let .with(expression, success, failure):
            try validateStructuredExpressionRootIndexing(
                expression,
                dotIsRoot: dotIsRoot,
            )
            try validateStructuredTemplateRootIndexing(
                success,
                dotIsRoot: structuredTemplateExpressionRetainsRoot(
                    expression,
                    dotIsRoot: dotIsRoot,
                ),
            )
            try validateStructuredTemplateRootIndexing(failure, dotIsRoot: dotIsRoot)
        case .text:
            continue
        }
    }
}

private func validateStructuredExpressionRootIndexing(
    _ expression: String,
    dotIsRoot: Bool,
) throws {
    guard let segments = structuredTemplatePipelineSegments(expression) else {
        throw structuredUnsupportedAction(expression)
    }
    var pipelineFlow: StructuredTemplateRootFlow?
    for (index, segment) in segments.enumerated() {
        guard let tokens = structuredTemplateTokens(segment) else {
            throw structuredUnsupportedAction(expression)
        }
        let explicitInputs = tokens.dropFirst().map {
            structuredTemplateValueRootFlow($0, dotIsRoot: dotIsRoot)
        }
        let inputs = explicitInputs + (pipelineFlow.map { [$0] } ?? [])
        if tokens.first == "index" || tokens.first == "len",
           inputs.first?.retainsRoot == true
        {
            throw structuredUnsupportedAction("\(tokens.first ?? "") root value")
        }
        for token in tokens {
            if let parenthesized = structuredTemplateParenthesizedValue(token) {
                try validateStructuredExpressionRootIndexing(
                    parenthesized.expression,
                    dotIsRoot: dotIsRoot,
                )
            }
        }
        let prefix = segments.prefix(index + 1).joined(separator: " | ")
        pipelineFlow = structuredTemplateExpressionRootFlow(
            prefix,
            dotIsRoot: dotIsRoot,
        )
    }
}

private func validateStructuredExpressionVariables(
    _ expression: String,
    variables: Set<String>,
) throws {
    guard let segments = structuredTemplatePipelineSegments(expression) else {
        throw structuredUnsupportedAction(expression)
    }
    for segment in segments {
        guard let tokens = structuredTemplateTokens(segment) else {
            throw structuredUnsupportedAction(expression)
        }
        for token in tokens {
            try validateStructuredValueVariables(token, variables: variables)
        }
    }
}

private func validateStructuredValueVariables(
    _ token: String,
    variables: Set<String>,
) throws {
    if let path = structuredTemplatePath(token),
       path.base != ".",
       path.base != "$",
       !variables.contains(path.base)
    {
        throw structuredUnsupportedAction("undefined variable \(path.base)")
    }
    if let parenthesized = structuredTemplateParenthesizedValue(token) {
        try validateStructuredExpressionVariables(
            parenthesized.expression,
            variables: variables,
        )
    }
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
            collectStructuredTemplateFields(
                success,
                dotIsRoot: structuredTemplateExpressionRetainsRoot(
                    expression,
                    dotIsRoot: dotIsRoot,
                ),
                into: &fields,
            )
            collectStructuredTemplateFields(failure, dotIsRoot: dotIsRoot, into: &fields)
        }
    }
}

private func structuredTemplateExpressionRetainsRoot(
    _ expression: String,
    dotIsRoot: Bool,
) -> Bool {
    structuredTemplateExpressionRootFlow(
        expression,
        dotIsRoot: dotIsRoot,
    ).retainsRoot
}

private func structuredTemplateExpressionAlwaysReturnsRoot(
    _ expression: String,
    dotIsRoot: Bool,
) -> Bool {
    structuredTemplateExpressionRootFlow(
        expression,
        dotIsRoot: dotIsRoot,
    ).alwaysReturnsRoot
}

private struct StructuredTemplateRootFlow {
    var canReturnTruthyRoot: Bool
    var canReturnTruthyNonRoot: Bool
    var canReturnFalsey: Bool

    var canReturnTruthy: Bool {
        canReturnTruthyRoot || canReturnTruthyNonRoot
    }

    var retainsRoot: Bool {
        canReturnTruthyRoot && !canReturnTruthyNonRoot
    }

    var alwaysReturnsRoot: Bool {
        retainsRoot && !canReturnFalsey
    }

    static let other = StructuredTemplateRootFlow(
        canReturnTruthyRoot: false,
        canReturnTruthyNonRoot: true,
        canReturnFalsey: true,
    )
}

private func structuredTemplateExpressionRootFlow(
    _ expression: String,
    dotIsRoot: Bool,
) -> StructuredTemplateRootFlow {
    guard let segments = structuredTemplatePipelineSegments(expression) else {
        return .other
    }
    var pipelineFlow = StructuredTemplateRootFlow.other
    for (index, segment) in segments.enumerated() {
        guard let tokens = structuredTemplateTokens(segment), let head = tokens.first else {
            return .other
        }
        if index == 0, tokens.count == 1 {
            pipelineFlow = structuredTemplateValueRootFlow(
                head,
                dotIsRoot: dotIsRoot,
            )
            continue
        }
        var inputs = tokens.dropFirst().map {
            structuredTemplateValueRootFlow($0, dotIsRoot: dotIsRoot)
        }
        if index > 0 {
            inputs.append(pipelineFlow)
        }
        switch head {
        case "or":
            pipelineFlow = structuredTemplateOrRootFlow(inputs)
        case "and":
            pipelineFlow = structuredTemplateAndRootFlow(inputs)
        default:
            pipelineFlow = .other
        }
    }
    return pipelineFlow
}

private func structuredTemplateOrRootFlow(
    _ inputs: [StructuredTemplateRootFlow],
) -> StructuredTemplateRootFlow {
    var result = StructuredTemplateRootFlow(
        canReturnTruthyRoot: false,
        canReturnTruthyNonRoot: false,
        canReturnFalsey: false,
    )
    var canReachInput = true
    for input in inputs {
        guard canReachInput else { break }
        result.canReturnTruthyRoot =
            result.canReturnTruthyRoot || input.canReturnTruthyRoot
        result.canReturnTruthyNonRoot =
            result.canReturnTruthyNonRoot || input.canReturnTruthyNonRoot
        canReachInput = input.canReturnFalsey
    }
    result.canReturnFalsey = canReachInput
    return result
}

private func structuredTemplateAndRootFlow(
    _ inputs: [StructuredTemplateRootFlow],
) -> StructuredTemplateRootFlow {
    var result = StructuredTemplateRootFlow(
        canReturnTruthyRoot: false,
        canReturnTruthyNonRoot: false,
        canReturnFalsey: false,
    )
    guard let lastInput = inputs.last else {
        return result
    }
    var canReachLastInput = true
    for input in inputs.dropLast() {
        guard canReachLastInput else { break }
        result.canReturnFalsey =
            result.canReturnFalsey || input.canReturnFalsey
        canReachLastInput = input.canReturnTruthy
    }
    guard canReachLastInput else {
        return result
    }
    result.canReturnFalsey =
        result.canReturnFalsey || lastInput.canReturnFalsey
    result.canReturnTruthyRoot = lastInput.canReturnTruthyRoot
    result.canReturnTruthyNonRoot = lastInput.canReturnTruthyNonRoot
    return result
}

private func structuredTemplateValueRootFlow(
    _ token: String,
    dotIsRoot: Bool,
) -> StructuredTemplateRootFlow {
    if token == "$" || (token == "." && dotIsRoot) {
        return StructuredTemplateRootFlow(
            canReturnTruthyRoot: true,
            canReturnTruthyNonRoot: false,
            canReturnFalsey: false,
        )
    }
    if let staticValue = structuredTemplateStaticValue(token) {
        return StructuredTemplateRootFlow(
            canReturnTruthyRoot: false,
            canReturnTruthyNonRoot: staticValue.value.isTruthy,
            canReturnFalsey: !staticValue.value.isTruthy,
        )
    }
    if let nested = structuredTemplateParenthesizedExpression(token) {
        return structuredTemplateExpressionRootFlow(
            nested,
            dotIsRoot: dotIsRoot,
        )
    }
    return .other
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
    if isStructuredTemplateLabelFunction(token), token == "$.Label" || dotIsRoot {
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
    if let parenthesized = structuredTemplateParenthesizedValue(token) {
        collectStructuredExpressionFields(
            parenthesized.expression,
            dotIsRoot: dotIsRoot,
            into: &fields,
        )
        if structuredTemplateExpressionRetainsRoot(
            parenthesized.expression,
            dotIsRoot: dotIsRoot,
        ), let field = parenthesized.fields.first {
            fields.append(field == "Label" ? "Labels" : field)
        }
    }
}

private func collectStructuredTemplateLabelKeys(
    _ nodes: [StructuredTemplateNode],
    into keys: inout [StructuredDockerTemplateLabelKey],
) {
    for node in nodes {
        switch node {
        case let .action(expression):
            collectStructuredExpressionLabelKeys(expression, into: &keys)
        case let .conditional(expression, success, failure),
             let .with(expression, success, failure):
            collectStructuredExpressionLabelKeys(expression, into: &keys)
            collectStructuredTemplateLabelKeys(success, into: &keys)
            collectStructuredTemplateLabelKeys(failure, into: &keys)
        case let .range(specification, success, failure):
            collectStructuredExpressionLabelKeys(specification.expression, into: &keys)
            collectStructuredTemplateLabelKeys(success, into: &keys)
            collectStructuredTemplateLabelKeys(failure, into: &keys)
        case .text:
            continue
        }
    }
}

private func collectStructuredExpressionLabelKeys(
    _ expression: String,
    into keys: inout [StructuredDockerTemplateLabelKey],
) {
    guard let segments = structuredTemplatePipelineSegments(expression) else { return }
    var pipelineValue: StructuredTemplateStaticValue?
    for (index, segment) in segments.enumerated() {
        guard let tokens = structuredTemplateTokens(segment), let head = tokens.first else {
            pipelineValue = nil
            continue
        }
        for token in tokens {
            if let parenthesized = structuredTemplateParenthesizedValue(token) {
                collectStructuredExpressionLabelKeys(
                    parenthesized.expression,
                    into: &keys,
                )
            }
        }
        if isStructuredTemplateLabelFunction(head) {
            collectStructuredStaticLabelKey(
                tokens,
                pipelineValue: pipelineValue,
                into: &keys,
            )
            pipelineValue = nil
            continue
        }
        pipelineValue = structuredTemplateStaticSegmentOutput(
            tokens,
            index: index,
            pipelineValue: pipelineValue,
        )
    }
}

private func collectStructuredStaticLabelKey(
    _ tokens: [String],
    pipelineValue: StructuredTemplateStaticValue?,
    into keys: inout [StructuredDockerTemplateLabelKey],
) {
    let explicitInputs = tokens.dropFirst().map(structuredTemplateStaticValue)
    guard explicitInputs.allSatisfy({ $0 != nil }) else {
        return
    }
    var inputs = explicitInputs.compactMap(\.self)
    if let pipelineValue {
        inputs.append(pipelineValue)
    }
    guard inputs.count == 1,
          let key = try? structuredString(inputs[0].value, function: "Label")
    else {
        return
    }
    keys.append(
        StructuredDockerTemplateLabelKey(
            lookupKey: key,
            headerKey: inputs[0].headerKey ?? key,
        ),
    )
}

private func structuredTemplateStaticSegmentOutput(
    _ tokens: [String],
    index: Int,
    pipelineValue: StructuredTemplateStaticValue?,
) -> StructuredTemplateStaticValue? {
    guard let head = tokens.first else {
        return nil
    }
    if index == 0, tokens.count == 1 {
        return structuredTemplateStaticValue(head)
    }
    let explicitInputs = tokens.dropFirst().map(structuredTemplateStaticValue)
    guard explicitInputs.allSatisfy({ $0 != nil }) else {
        return nil
    }
    let inputs = explicitInputs.compactMap(\.self) + (pipelineValue.map { [$0] } ?? [])
    guard let output = try? applyStructuredTemplateFunction(
        head,
        arguments: explicitInputs.compactMap(\.self).map(\.value),
        pipelineValue: pipelineValue?.value,
    ) else {
        return nil
    }
    return StructuredTemplateStaticValue(
        value: output,
        headerKey: structuredTemplateStaticHeaderKey(
            function: head,
            inputs: inputs,
            output: output,
        ),
    )
}

private struct StructuredTemplateStaticValue {
    let value: DockerTemplateData
    let headerKey: String?
}

private func structuredTemplateStaticValue(_ token: String) -> StructuredTemplateStaticValue? {
    if let literal = structuredTemplateStringLiteral(token) {
        return StructuredTemplateStaticValue(
            value: literal,
            headerKey: try? structuredString(literal, function: "literal"),
        )
    }
    if let integer = Int(token) {
        return StructuredTemplateStaticValue(value: .integer(integer), headerKey: nil)
    }
    if token == "true" || token == "false" {
        return StructuredTemplateStaticValue(value: .boolean(token == "true"), headerKey: nil)
    }
    guard let parenthesized = structuredTemplateParenthesizedValue(token),
          parenthesized.fields.isEmpty
    else {
        return nil
    }
    return structuredTemplateStaticExpressionOutput(parenthesized.expression)
}

private func structuredTemplateStaticExpressionOutput(
    _ expression: String,
) -> StructuredTemplateStaticValue? {
    guard let segments = structuredTemplatePipelineSegments(expression) else {
        return nil
    }
    var pipelineValue: StructuredTemplateStaticValue?
    for (index, segment) in segments.enumerated() {
        guard let tokens = structuredTemplateTokens(segment),
              !isStructuredTemplateLabelFunction(tokens.first ?? "")
        else {
            return nil
        }
        guard let output = structuredTemplateStaticSegmentOutput(
            tokens,
            index: index,
            pipelineValue: pipelineValue,
        ) else {
            return nil
        }
        pipelineValue = output
    }
    return pipelineValue
}

private func structuredTemplateStaticHeaderKey(
    function: String,
    inputs: [StructuredTemplateStaticValue],
    output: DockerTemplateData,
) -> String? {
    let candidates = function == "printf" ? inputs.dropFirst() : inputs[...]
    if let source = candidates.compactMap(\.headerKey).first {
        return source
    }
    return try? structuredString(output, function: function)
}
