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
        structuredPrintfQuoted(value)
    case "s", "v":
        value.display
    default:
        throw structuredUnsupportedAction("printf")
    }
    let replacementWidth = replacement.unicodeScalars.count
    guard let width = directive.width, replacementWidth < width else {
        return replacement
    }
    let padding = String(repeating: " ", count: width - replacementWidth)
    return directive.leftAligned ? replacement + padding : padding + replacement
}

private func structuredPrintfQuoted(_ value: DockerTemplateData) -> String {
    switch value {
    case let .array(values):
        return "[\(values.map(structuredPrintfQuoted).joined(separator: " "))]"
    case let .boolean(value):
        return "%!q(bool=\(value ? "true" : "false"))"
    case let .byteString(bytes):
        return structuredGoQuotedBytes(bytes)
    case let .integer(value):
        return structuredGoQuotedRune(value)
    case let .lookupObject(_, display):
        return structuredGoQuotedString(display)
    case .null:
        return "%!q(<nil>)"
    case let .object(values):
        let entries = values.keys.sorted().map { key in
            "\(structuredGoQuotedString(key)):\(structuredPrintfQuoted(values[key] ?? .null))"
        }
        return "map[\(entries.joined(separator: " "))]"
    case let .record(values):
        let fields = structuredTemplateRecordValues(values).map(structuredPrintfQuoted)
        return "{\(fields.joined(separator: " "))}"
    case let .string(value):
        return structuredGoQuotedString(value)
    }
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
