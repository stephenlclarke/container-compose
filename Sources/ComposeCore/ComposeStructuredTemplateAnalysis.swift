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
    guard suffix.first?.isWhitespace == true || suffix.first == "(" else {
        return nil
    }
    let expression = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    return expression.isEmpty ? nil : expression
}

func structuredTemplateElseIfExpression(_ action: String) -> String? {
    guard action.hasPrefix("else") else {
        return nil
    }
    let suffix = action.dropFirst(4)
    guard suffix.first?.isWhitespace == true else {
        return nil
    }
    return structuredTemplateControlExpression(
        suffix.trimmingCharacters(in: .whitespacesAndNewlines),
        keyword: "if",
    )
}

func structuredTemplateRangeEntries(
    _ value: DockerTemplateData,
) throws -> [(key: DockerTemplateData, value: DockerTemplateData)] {
    switch value {
    case let .array(values):
        values.enumerated().map { (.integer($0.offset), $0.element) }
    case let .object(values):
        values.keys.sorted().map { (.string($0), values[$0] ?? .null) }
    case .null:
        []
    case .boolean, .byteString, .integer, .lookupObject, .record, .string:
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

func structuredDockerTemplateLabelKeys(in template: String) -> [String] {
    guard let nodes = try? structuredDockerTemplateNodes(template) else {
        return []
    }
    var keys: [String] = []
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
    if let expression = structuredTemplateParenthesizedExpression(token) {
        try validateStructuredExpressionVariables(expression, variables: variables)
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
    guard let segments = structuredTemplatePipelineSegments(expression),
          segments.count == 1,
          let tokens = structuredTemplateTokens(segments[0]),
          tokens.count == 1
    else {
        return false
    }
    return structuredTemplateValueRetainsRoot(tokens[0], dotIsRoot: dotIsRoot)
}

private func structuredTemplateValueRetainsRoot(
    _ token: String,
    dotIsRoot: Bool,
) -> Bool {
    if token == "$" {
        return true
    }
    if token == "." {
        return dotIsRoot
    }
    guard let nested = structuredTemplateParenthesizedExpression(token) else {
        return false
    }
    return structuredTemplateExpressionRetainsRoot(nested, dotIsRoot: dotIsRoot)
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

private func collectStructuredTemplateLabelKeys(
    _ nodes: [StructuredTemplateNode],
    into keys: inout [String],
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
    into keys: inout [String],
) {
    guard let segments = structuredTemplatePipelineSegments(expression) else { return }
    for segment in segments {
        guard let tokens = structuredTemplateTokens(segment) else { continue }
        for (index, token) in tokens.enumerated() {
            if token == ".Label",
               tokens.indices.contains(index + 1),
               let key = structuredTemplateStringLiteral(tokens[index + 1])
            {
                keys.append(key)
            }
            if let nested = structuredTemplateParenthesizedExpression(token) {
                collectStructuredExpressionLabelKeys(nested, into: &keys)
            }
        }
    }
}
