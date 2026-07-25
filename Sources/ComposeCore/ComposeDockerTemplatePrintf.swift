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

private struct StructuredPrintfDirective {
    var leftAligned: Bool
    var width: Int?
    var verb: Character
    var nextCursor: String.Index
}

func structuredTemplatePrintf(
    _ format: String,
    values: [DockerTemplateData],
) throws -> String {
    var rendered = ""
    var cursor = format.startIndex
    var valueIndex = 0
    while cursor < format.endIndex {
        guard format[cursor] == "%" else {
            rendered.append(format[cursor])
            cursor = format.index(after: cursor)
            continue
        }
        let next = format.index(after: cursor)
        guard next < format.endIndex else {
            throw structuredUnsupportedAction("printf \(format)")
        }
        if format[next] == "%" {
            rendered.append("%")
            cursor = format.index(after: next)
            continue
        }

        let directive = try structuredPrintfDirective(in: format, from: next)
        guard valueIndex < values.count else {
            throw structuredUnsupportedAction("printf \(format)")
        }
        let replacement = try structuredPrintfReplacement(
            values[valueIndex],
            directive: directive,
        )
        rendered += replacement
        valueIndex += 1
        cursor = directive.nextCursor
    }
    guard valueIndex == values.count else {
        throw structuredUnsupportedAction("printf \(format)")
    }
    return rendered
}

private func structuredPrintfDirective(
    in format: String,
    from start: String.Index,
) throws -> StructuredPrintfDirective {
    var cursor = start
    let leftAligned = format[cursor] == "-"
    if leftAligned {
        cursor = format.index(after: cursor)
    }
    var widthText = ""
    while cursor < format.endIndex, format[cursor].isNumber {
        widthText.append(format[cursor])
        cursor = format.index(after: cursor)
    }
    guard cursor < format.endIndex, "dsvq".contains(format[cursor]) else {
        throw structuredUnsupportedAction("printf \(format)")
    }
    return StructuredPrintfDirective(
        leftAligned: leftAligned,
        width: Int(widthText),
        verb: format[cursor],
        nextCursor: format.index(after: cursor),
    )
}

private func structuredPrintfReplacement(
    _ value: DockerTemplateData,
    directive: StructuredPrintfDirective,
) throws -> String {
    let replacement = switch directive.verb {
    case "d":
        try String(structuredInteger(value, function: "printf"))
    case "q":
        try value.json()
    case "s", "v":
        value.display
    default:
        throw structuredUnsupportedAction("printf")
    }
    guard let width = directive.width, replacement.count < width else {
        return replacement
    }
    let padding = String(repeating: " ", count: width - replacement.count)
    return directive.leftAligned ? replacement + padding : padding + replacement
}
