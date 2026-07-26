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

private struct StructuredPrintfDirective {
    var leftAligned: Bool
    var width: Int?
    var verb: Character
    var nextCursor: String.Index
}

func structuredTemplatePrintf(
    _ format: String,
    values: [DockerTemplateData],
) throws -> [UInt8] {
    var rendered: [UInt8] = []
    var cursor = format.startIndex
    var valueIndex = 0
    while cursor < format.endIndex {
        guard format[cursor] == "%" else {
            rendered.append(contentsOf: String(format[cursor]).utf8)
            cursor = format.index(after: cursor)
            continue
        }
        let next = format.index(after: cursor)
        guard next < format.endIndex else {
            throw structuredUnsupportedAction("printf \(format)")
        }
        if format[next] == "%" {
            rendered.append(UInt8(ascii: "%"))
            cursor = format.index(after: next)
            continue
        }

        let directive = try structuredPrintfDirective(in: format, from: next)
        if valueIndex < values.count {
            let replacement = try structuredPrintfReplacement(
                values[valueIndex],
                directive: directive,
            )
            rendered.append(contentsOf: replacement)
            valueIndex += 1
        } else {
            rendered.append(contentsOf: "%!\(directive.verb)(MISSING)".utf8)
        }
        cursor = directive.nextCursor
    }
    for value in values.dropFirst(valueIndex) {
        rendered.append(contentsOf: structuredPrintfExtraDiagnostic(value))
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
) throws -> [UInt8] {
    switch value {
    case let .array(values):
        let elements = try values.map {
            try structuredPrintfReplacement($0, directive: directive)
        }
        return structuredPrintfJoinedBytes(
            elements,
            prefix: "[",
            separator: " ",
            suffix: "]",
        )
    case let .object(values):
        let entries = try values.keys.sorted().map { key in
            let renderedKey = try structuredPrintfReplacement(.string(key), directive: directive)
            let renderedValue = try structuredPrintfReplacement(
                values[key] ?? .null,
                directive: directive,
            )
            return renderedKey + Array(":".utf8) + renderedValue
        }
        return structuredPrintfJoinedBytes(
            entries,
            prefix: "map[",
            separator: " ",
            suffix: "]",
        )
    case let .record(values):
        let fields = try structuredTemplateRecordValues(values).map {
            try structuredPrintfReplacement($0, directive: directive)
        }
        return structuredPrintfJoinedBytes(
            fields,
            prefix: "{",
            separator: " ",
            suffix: "}",
        )
    case .boolean, .byteString, .integer, .lookupObject, .null, .string:
        return try structuredPrintfScalarReplacement(value, directive: directive)
    }
}

private func structuredPrintfScalarReplacement(
    _ value: DockerTemplateData,
    directive: StructuredPrintfDirective,
) throws -> [UInt8] {
    switch directive.verb {
    case "d":
        return structuredPrintfDecimalReplacement(value, directive: directive)
    case "q":
        return try structuredPrintfQuotedReplacement(value, directive: directive)
    case "s":
        return try structuredPrintfStringReplacement(value, directive: directive)
    case "v":
        return structuredPrintfPadded(value.outputBytes, directive: directive)
    default:
        throw structuredUnsupportedAction("printf")
    }
}

private func structuredPrintfDecimalReplacement(
    _ value: DockerTemplateData,
    directive: StructuredPrintfDirective,
) -> [UInt8] {
    guard case let .integer(integer) = value else {
        return structuredPrintfTypeDiagnostic(value, directive: directive)
    }
    return structuredPrintfPadded(Array(String(integer).utf8), directive: directive)
}

private func structuredPrintfQuotedReplacement(
    _ value: DockerTemplateData,
    directive: StructuredPrintfDirective,
) throws -> [UInt8] {
    let replacement: String
    switch value {
    case let .byteString(bytes):
        replacement = structuredGoQuotedBytes(bytes)
    case let .integer(integer):
        replacement = structuredGoQuotedRune(integer)
    case let .lookupObject(_, display):
        replacement = structuredGoQuotedString(display)
    case let .string(string):
        replacement = structuredGoQuotedString(string)
    case .boolean, .null:
        return structuredPrintfTypeDiagnostic(value, directive: directive)
    case .array, .object, .record:
        throw structuredUnsupportedAction("printf")
    }
    return structuredPrintfPadded(Array(replacement.utf8), directive: directive)
}

private func structuredPrintfStringReplacement(
    _ value: DockerTemplateData,
    directive: StructuredPrintfDirective,
) throws -> [UInt8] {
    let replacement: [UInt8]
    switch value {
    case let .byteString(bytes):
        replacement = bytes
    case let .lookupObject(_, display):
        replacement = Array(display.utf8)
    case let .string(string):
        replacement = Array(string.utf8)
    case .boolean, .integer, .null:
        return structuredPrintfTypeDiagnostic(value, directive: directive)
    case .array, .object, .record:
        throw structuredUnsupportedAction("printf")
    }
    return structuredPrintfPadded(replacement, directive: directive)
}

private func structuredPrintfTypeDiagnostic(
    _ value: DockerTemplateData,
    directive: StructuredPrintfDirective,
) -> [UInt8] {
    if value == .null {
        return Array("%!\(directive.verb)(<nil>)".utf8)
    }
    return Array("%!\(directive.verb)(\(structuredPrintfTypeName(value))=".utf8)
        + structuredPrintfPadded(value.outputBytes, directive: directive)
        + Array(")".utf8)
}

private func structuredPrintfTypeName(_ value: DockerTemplateData) -> String {
    switch value {
    case .boolean:
        "bool"
    case .integer:
        "int"
    case .byteString, .lookupObject, .string:
        "string"
    case .array:
        "[]interface {}"
    case .null:
        "<nil>"
    case .object:
        "map[string]interface {}"
    case .record:
        "formatter.Port"
    }
}

private func structuredPrintfExtraDiagnostic(
    _ value: DockerTemplateData,
) -> [UInt8] {
    if value == .null {
        return Array("%!(EXTRA <nil>)".utf8)
    }
    return Array("%!(EXTRA \(structuredPrintfTypeName(value))=".utf8)
        + value.outputBytes
        + Array(")".utf8)
}

private func structuredPrintfPadded(
    _ replacement: [UInt8],
    directive: StructuredPrintfDirective,
) -> [UInt8] {
    let replacementWidth = structuredTemplateUTF8Sequences(replacement).count
    guard let width = directive.width, replacementWidth < width else {
        return replacement
    }
    let padding = Array(repeating: UInt8(ascii: " "), count: width - replacementWidth)
    return directive.leftAligned ? replacement + padding : padding + replacement
}

private func structuredPrintfJoinedBytes(
    _ values: [[UInt8]],
    prefix: String,
    separator: String,
    suffix: String,
) -> [UInt8] {
    var output = Array(prefix.utf8)
    for (index, value) in values.enumerated() {
        if index > 0 {
            output.append(contentsOf: separator.utf8)
        }
        output.append(contentsOf: value)
    }
    output.append(contentsOf: suffix.utf8)
    return output
}

private func structuredGoQuotedBytes(_ bytes: [UInt8]) -> String {
    guard let value = String(bytes: bytes, encoding: .utf8) else {
        let escaped = bytes.map(structuredGoEscapedByte).joined()
        return "\"\(escaped)\""
    }
    return structuredGoQuotedString(value)
}

private func structuredGoQuotedString(_ value: String) -> String {
    let escaped = value.unicodeScalars.map {
        structuredGoEscapedScalar($0, quote: "\"")
    }.joined()
    return "\"\(escaped)\""
}

private func structuredGoQuotedRune(_ value: Int) -> String {
    let scalar = UnicodeScalar(value) ?? "\u{FFFD}"
    return "'\(structuredGoEscapedScalar(scalar, quote: "'"))'"
}

private func structuredGoEscapedByte(_ byte: UInt8) -> String {
    if let escape = structuredGoNamedEscape(UInt32(byte)) {
        return escape
    }
    return switch byte {
    case 0x20 ... 0x21, 0x23 ... 0x5B, 0x5D ... 0x7E:
        String(UnicodeScalar(byte))
    case 0x22:
        "\\\""
    case 0x5C:
        "\\\\"
    default:
        String(format: "\\x%02x", byte)
    }
}

private func structuredGoEscapedScalar(
    _ scalar: UnicodeScalar,
    quote: UnicodeScalar,
) -> String {
    if let escape = structuredGoNamedEscape(scalar.value) {
        return escape
    }
    switch scalar.value {
    case quote.value:
        return "\\\(Character(quote))"
    case 0x5C:
        return "\\\\"
    default:
        if !structuredGoScalarIsPrint(scalar) {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return String(format: "\\x%02x", scalar.value)
            }
            if scalar.value <= 0xFFFF {
                return String(format: "\\u%04x", scalar.value)
            }
            return String(format: "\\U%08x", scalar.value)
        }
        return String(scalar)
    }
}

private func structuredGoScalarIsPrint(_ scalar: UnicodeScalar) -> Bool {
    if scalar.value == 0x20 {
        return true
    }
    return switch scalar.properties.generalCategory {
    case .uppercaseLetter,
         .lowercaseLetter,
         .titlecaseLetter,
         .modifierLetter,
         .otherLetter,
         .nonspacingMark,
         .spacingMark,
         .enclosingMark,
         .decimalNumber,
         .letterNumber,
         .otherNumber,
         .connectorPunctuation,
         .dashPunctuation,
         .openPunctuation,
         .closePunctuation,
         .initialPunctuation,
         .finalPunctuation,
         .otherPunctuation,
         .mathSymbol,
         .currencySymbol,
         .modifierSymbol,
         .otherSymbol:
        true
    default:
        false
    }
}

private func structuredGoNamedEscape(_ value: UInt32) -> String? {
    switch value {
    case 0x07:
        "\\a"
    case 0x08:
        "\\b"
    case 0x09:
        "\\t"
    case 0x0A:
        "\\n"
    case 0x0B:
        "\\v"
    case 0x0C:
        "\\f"
    case 0x0D:
        "\\r"
    default:
        nil
    }
}
