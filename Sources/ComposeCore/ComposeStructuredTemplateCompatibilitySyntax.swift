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

func structuredTemplateAssignmentRange(
    in value: String,
) -> Range<String.Index>? {
    var scan = StructuredTemplateScanState()
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(after: index)
        if scan.isTopLevel, value[index] == ":", next < value.endIndex, value[next] == "=" {
            return index ..< value.index(after: next)
        }
        guard scan.consume(value[index]) else {
            return nil
        }
        index = next
    }
    return nil
}

func structuredTemplateParenthesizedExpression(_ token: String) -> String? {
    guard let value = structuredTemplateParenthesizedValue(token), value.fields.isEmpty else {
        return nil
    }
    return value.expression
}

func structuredTemplateParenthesizedValue(
    _ token: String,
) -> (expression: String, fields: [String])? {
    guard token.count >= 3, token.first == "(" else {
        return nil
    }
    var scan = StructuredTemplateScanState()
    var close: String.Index?
    var index = token.startIndex
    while index < token.endIndex {
        let character = token[index]
        guard scan.consume(character) else {
            return nil
        }
        if index != token.startIndex, character == ")", scan.isTopLevel {
            close = index
            break
        }
        index = token.index(after: index)
    }
    guard let close else {
        return nil
    }
    let expressionStart = token.index(after: token.startIndex)
    let expression = String(token[expressionStart ..< close])
    guard !expression.isEmpty else {
        return nil
    }
    let suffixStart = token.index(after: close)
    guard suffixStart < token.endIndex else {
        return (expression, [])
    }
    let suffix = token[suffixStart...]
    guard suffix.first == "." else {
        return nil
    }
    let fields = suffix.dropFirst().split(
        separator: ".",
        omittingEmptySubsequences: false,
    ).map(String.init)
    guard !fields.isEmpty, fields.allSatisfy(isStructuredTemplateIdentifier) else {
        return nil
    }
    return (expression, fields)
}
