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

/// Structured values exposed to Docker-compatible output templates.
public indirect enum DockerTemplateData: Sendable, Equatable {
    case array([DockerTemplateData])
    case boolean(Bool)
    case byteString([UInt8])
    case integer(Int)
    case lookupObject([String: DockerTemplateData], display: String)
    case null
    case object([String: DockerTemplateData])
    case record([String: DockerTemplateData])
    case string(String)

    var display: String {
        switch self {
        case let .array(values):
            return "[\(values.map(\.display).joined(separator: " "))]"
        case let .boolean(value):
            return value ? "true" : "false"
        case let .byteString(value):
            return String(bytes: value, encoding: .utf8) ?? "\u{FFFD}"
        case let .integer(value):
            return String(value)
        case let .lookupObject(_, display):
            return display
        case .null:
            return "<no value>"
        case let .object(values):
            let entries = values.keys.sorted().map { key in
                "\(key):\(values[key]?.display ?? "<no value>")"
            }
            return "map[\(entries.joined(separator: " "))]"
        case let .record(values):
            let fields = structuredTemplateRecordValues(values).map(\.display)
            return "{\(fields.joined(separator: " "))}"
        case let .string(value):
            return value
        }
    }

    var outputBytes: [UInt8] {
        switch self {
        case let .array(values):
            return structuredTemplateJoinedBytes(
                values.map(\.outputBytes),
                prefix: "[",
                separator: " ",
                suffix: "]",
            )
        case let .boolean(value):
            return Array((value ? "true" : "false").utf8)
        case let .byteString(value):
            return value
        case let .integer(value):
            return Array(String(value).utf8)
        case let .lookupObject(_, display):
            return Array(display.utf8)
        case .null:
            return Array("<no value>".utf8)
        case let .object(values):
            let entries = values.keys.sorted().map { key in
                Array("\(key):".utf8) + (values[key]?.outputBytes ?? [])
            }
            return structuredTemplateJoinedBytes(
                entries,
                prefix: "map[",
                separator: " ",
                suffix: "]",
            )
        case let .record(values):
            return structuredTemplateJoinedBytes(
                structuredTemplateRecordValues(values).map(\.outputBytes),
                prefix: "{",
                separator: " ",
                suffix: "}",
            )
        case let .string(value):
            return Array(value.utf8)
        }
    }

    var isTruthy: Bool {
        switch self {
        case let .array(values):
            !values.isEmpty
        case let .boolean(value):
            value
        case let .byteString(value):
            !value.isEmpty
        case let .integer(value):
            value != 0
        case let .lookupObject(_, display):
            !display.isEmpty
        case .null:
            false
        case let .object(values), let .record(values):
            !values.isEmpty
        case let .string(value):
            !value.isEmpty
        }
    }

    func json() throws -> String {
        switch self {
        case let .array(values):
            return try "[\(values.map { try $0.json() }.joined(separator: ","))]"
        case let .boolean(value):
            return value ? "true" : "false"
        case let .byteString(value):
            return try structuredTemplateJSONString(bytes: value)
        case let .integer(value):
            return String(value)
        case let .lookupObject(_, display):
            return try structuredTemplateJSONString(display)
        case .null:
            return "null"
        case let .object(values), let .record(values):
            let entries = try values.keys.sorted().map { key in
                let encodedKey = try structuredTemplateJSONString(key)
                let encodedValue = try values[key]?.json() ?? "null"
                return "\(encodedKey):\(encodedValue)"
            }
            return "{\(entries.joined(separator: ","))}"
        case let .string(value):
            return try structuredTemplateJSONString(value)
        }
    }
}

private func structuredTemplateJSONString(_ value: String) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed],
    )
    return String(bytes: data, encoding: .utf8) ?? ""
}

private func structuredTemplateJSONString(bytes: [UInt8]) throws -> String {
    var decoder = Unicode.UTF8()
    var iterator = bytes.makeIterator()
    var valid = ""
    var content = ""
    var decoding = true
    while decoding {
        switch decoder.decode(&iterator) {
        case let .scalarValue(scalar):
            valid.unicodeScalars.append(scalar)
        case .error:
            content += try structuredTemplateJSONString(valid).dropQuotes
            content += #"\ufffd"#
            valid = ""
        case .emptyInput:
            content += try structuredTemplateJSONString(valid).dropQuotes
            decoding = false
        }
    }
    return "\"\(content)\""
}

private extension String {
    var dropQuotes: String {
        String(dropFirst().dropLast())
    }
}

private func structuredTemplateJoinedBytes(
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

func structuredTemplateRecordValues(
    _ values: [String: DockerTemplateData],
) -> [DockerTemplateData] {
    let preferredOrder = ["URL", "TargetPort", "PublishedPort", "Protocol"]
    let orderedKeys = preferredOrder.filter { values[$0] != nil }
        + values.keys.filter { !preferredOrder.contains($0) }.sorted()
    return orderedKeys.map { values[$0] ?? .null }
}

extension String {
    func trimmingPrefixWhitespace() -> String {
        String(drop(while: structuredTemplateIsGoWhitespace))
    }

    func trimmingSuffixWhitespace() -> String {
        String(reversed().drop(while: structuredTemplateIsGoWhitespace).reversed())
    }
}

func structuredUnsupportedAction(_ action: String) -> ComposeError {
    ComposeError.unsupported(
        "format template action '{{\(action)}}'; supported actions are field and nested object references, if/else, with, range, variables, whitespace trimming, Docker row functions, and Go print, comparison, boolean, len, index, and slice functions",
    )
}
