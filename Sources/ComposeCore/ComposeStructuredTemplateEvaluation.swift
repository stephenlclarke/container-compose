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

struct StructuredTemplateEvaluation {
    var value: DockerTemplateData
    var isRoot: Bool
}

func evaluateStructuredTemplateExpression(
    _ expression: String,
    context: StructuredTemplateContext,
) throws -> DockerTemplateData {
    try evaluateStructuredTemplateExpressionWithRoot(
        expression,
        context: context,
    ).value
}

func evaluateStructuredTemplateExpressionWithRoot(
    _ expression: String,
    context: StructuredTemplateContext,
) throws -> StructuredTemplateEvaluation {
    guard let segments = structuredTemplatePipelineSegments(expression) else {
        throw structuredUnsupportedAction(expression)
    }
    var pipelineEvaluation: StructuredTemplateEvaluation?
    for (index, segment) in segments.enumerated() {
        guard let tokens = structuredTemplateTokens(segment), let head = tokens.first else {
            throw structuredUnsupportedAction(expression)
        }
        if index == 0, tokens.count == 1, isStructuredTemplateValue(head) {
            pipelineEvaluation = try structuredTemplateEvaluation(head, context: context)
        } else if isStructuredTemplateLabelFunction(head) {
            pipelineEvaluation = try evaluateStructuredTemplateLabel(
                head,
                argumentTokens: tokens.dropFirst(),
                pipelineEvaluation: pipelineEvaluation,
                context: context,
            )
        } else {
            pipelineEvaluation = try evaluateStructuredTemplateFunction(
                head,
                argumentTokens: tokens.dropFirst(),
                pipelineEvaluation: pipelineEvaluation,
                context: context,
                expression: expression,
            )
        }
    }
    guard let pipelineEvaluation else { throw structuredUnsupportedAction(expression) }
    return pipelineEvaluation
}

private func evaluateStructuredTemplateLabel(
    _ function: String,
    argumentTokens: ArraySlice<String>,
    pipelineEvaluation: StructuredTemplateEvaluation?,
    context: StructuredTemplateContext,
) throws -> StructuredTemplateEvaluation {
    var inputs = try argumentTokens.map {
        try structuredTemplateValue($0, context: context)
    }
    if let pipelineEvaluation {
        inputs.append(pipelineEvaluation.value)
    }
    guard inputs.count == 1 else {
        throw structuredUnsupportedAction("Label")
    }
    let key = try structuredString(inputs[0], function: "Label")
    let source = function == "$.Label" ? context.root : context.dot
    return try StructuredTemplateEvaluation(
        value: structuredTemplateLabel(key, source: source),
        isRoot: false,
    )
}

private func evaluateStructuredTemplateFunction(
    _ function: String,
    argumentTokens: ArraySlice<String>,
    pipelineEvaluation: StructuredTemplateEvaluation?,
    context: StructuredTemplateContext,
    expression: String,
) throws -> StructuredTemplateEvaluation {
    guard structuredTemplateFunctions.contains(function) else {
        throw structuredUnsupportedAction(expression)
    }
    if function == "and" || function == "or" {
        return try evaluateStructuredShortCircuitFunction(
            function,
            argumentTokens: argumentTokens,
            pipelineEvaluation: pipelineEvaluation,
            context: context,
        )
    }
    var argumentEvaluations = try argumentTokens.map {
        try structuredTemplateEvaluation($0, context: context)
    }
    if let pipelineEvaluation {
        argumentEvaluations.append(pipelineEvaluation)
    }
    if function == "index" || function == "len",
       argumentEvaluations.first?.isRoot == true
    {
        throw structuredUnsupportedAction("\(function) root value")
    }
    return try StructuredTemplateEvaluation(
        value: applyStructuredTemplateFunction(
            function,
            arguments: argumentEvaluations.map(\.value),
            pipelineValue: nil,
        ),
        isRoot: false,
    )
}

private func evaluateStructuredShortCircuitFunction(
    _ function: String,
    argumentTokens: ArraySlice<String>,
    pipelineEvaluation: StructuredTemplateEvaluation?,
    context: StructuredTemplateContext,
) throws -> StructuredTemplateEvaluation {
    var last: StructuredTemplateEvaluation?
    for token in argumentTokens {
        let evaluation = try structuredTemplateEvaluation(token, context: context)
        last = evaluation
        if function == "and", !evaluation.value.isTruthy {
            return evaluation
        }
        if function == "or", evaluation.value.isTruthy {
            return evaluation
        }
    }
    if let pipelineEvaluation {
        last = pipelineEvaluation
        if function == "and", !pipelineEvaluation.value.isTruthy {
            return pipelineEvaluation
        }
        if function == "or", pipelineEvaluation.value.isTruthy {
            return pipelineEvaluation
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
    try structuredTemplateEvaluation(token, context: context).value
}

private func structuredTemplateEvaluation(
    _ token: String,
    context: StructuredTemplateContext,
) throws -> StructuredTemplateEvaluation {
    switch token {
    case ".":
        return StructuredTemplateEvaluation(
            value: context.dot,
            isRoot: context.dotIsRoot,
        )
    case "$":
        return StructuredTemplateEvaluation(value: context.root, isRoot: true)
    case "true":
        return StructuredTemplateEvaluation(value: .boolean(true), isRoot: false)
    case "false":
        return StructuredTemplateEvaluation(value: .boolean(false), isRoot: false)
    default:
        break
    }
    if let path = structuredTemplatePath(token) {
        let base = structuredTemplateBaseEvaluation(path.base, context: context)
        let value = try path.fields.reduce(base.value) { value, field in
            try structuredTemplateLookup(value, field)
        }
        return StructuredTemplateEvaluation(
            value: value,
            isRoot: path.fields.isEmpty && base.isRoot,
        )
    }
    if let value = structuredTemplateStringLiteral(token) {
        return StructuredTemplateEvaluation(value: .string(value), isRoot: false)
    }
    if let parenthesized = structuredTemplateParenthesizedValue(token) {
        let base = try evaluateStructuredTemplateExpressionWithRoot(
            parenthesized.expression,
            context: context,
        )
        let value = try parenthesized.fields.reduce(base.value) { value, field in
            try structuredTemplateLookup(value, field)
        }
        return StructuredTemplateEvaluation(
            value: value,
            isRoot: parenthesized.fields.isEmpty && base.isRoot,
        )
    }
    if let value = Int(token) {
        return StructuredTemplateEvaluation(value: .integer(value), isRoot: false)
    }
    throw structuredUnsupportedAction(token)
}

private func structuredTemplateBaseEvaluation(
    _ base: String,
    context: StructuredTemplateContext,
) -> StructuredTemplateEvaluation {
    switch base {
    case ".":
        StructuredTemplateEvaluation(
            value: context.dot,
            isRoot: context.dotIsRoot,
        )
    case "$":
        StructuredTemplateEvaluation(value: context.root, isRoot: true)
    default:
        StructuredTemplateEvaluation(
            value: context.variables[base] ?? .null,
            isRoot: false,
        )
    }
}
