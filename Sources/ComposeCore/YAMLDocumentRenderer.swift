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

import ContainerResource
import CoreFoundation
import CryptoKit
import Foundation

/// Renders JSON-compatible Foundation values as deterministic block YAML.
enum YAMLDocumentRenderer {
    static func render(_ value: Any) -> String {
        var lines: [String] = []
        append(value, indent: 0, to: &lines)
        return lines.joined(separator: "\n")
    }

    static func render(_ value: BridgeModelValue) -> String {
        var lines: [String] = []
        appendComposeValue(value, indent: 0, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func append(_ value: Any, indent: Int, to lines: inout [String]) {
        let prefix = String(repeating: " ", count: indent)
        if let object = value as? [String: Any] {
            appendObject(object, prefix: prefix, indent: indent, to: &lines)
        } else if let array = value as? [Any] {
            appendArray(array, prefix: prefix, indent: indent, to: &lines)
        } else {
            lines.append(prefix + scalar(value))
        }
    }

    private static func appendObject(_ object: [String: Any], prefix: String, indent: Int, to lines: inout [String]) {
        guard !object.isEmpty else {
            lines.append(prefix + "{}")
            return
        }
        for key in object.keys.sorted() {
            guard let value = object[key] else {
                continue
            }
            if isBlockValue(value) {
                lines.append("\(prefix)\(renderKey(key)):")
                append(value, indent: indent + 2, to: &lines)
            } else {
                lines.append("\(prefix)\(renderKey(key)): \(scalar(value))")
            }
        }
    }

    private static func appendArray(_ array: [Any], prefix: String, indent: Int, to lines: inout [String]) {
        guard !array.isEmpty else {
            lines.append(prefix + "[]")
            return
        }
        for value in array {
            if isBlockValue(value) {
                lines.append(prefix + "-")
                append(value, indent: indent + 2, to: &lines)
            } else {
                lines.append("\(prefix)- \(scalar(value))")
            }
        }
    }

    private static func isBlockValue(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return !object.isEmpty
        }
        if let array = value as? [Any] {
            return !array.isEmpty
        }
        return false
    }

    private static func scalar(_ value: Any) -> String {
        switch value {
        case _ as NSNull:
            "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                number.boolValue ? "true" : "false"
            } else {
                number.stringValue
            }
        case let string as String:
            quoted(string)
        case let object as [String: Any] where object.isEmpty:
            "{}"
        case let array as [Any] where array.isEmpty:
            "[]"
        default:
            quoted(String(describing: value))
        }
    }

    private static func appendComposeValue(_ value: BridgeModelValue, indent: Int, to lines: inout [String]) {
        let prefix = String(repeating: " ", count: indent)
        switch value {
        case let .object(object) where !object.isEmpty:
            for key in object.keys.sorted() {
                guard let child = object[key] else {
                    continue
                }
                if composeValueIsBlock(child) {
                    lines.append("\(prefix)\(renderKey(key)):")
                    appendComposeValue(child, indent: indent + 2, to: &lines)
                } else {
                    lines.append("\(prefix)\(renderKey(key)): \(composeScalar(child))")
                }
            }
        case let .array(array) where !array.isEmpty:
            for child in array {
                if composeValueIsBlock(child) {
                    lines.append(prefix + "-")
                    appendComposeValue(child, indent: indent + 2, to: &lines)
                } else {
                    lines.append("\(prefix)- \(composeScalar(child))")
                }
            }
        default:
            lines.append(prefix + composeScalar(value))
        }
    }

    private static func composeValueIsBlock(_ value: BridgeModelValue) -> Bool {
        switch value {
        case let .object(object):
            !object.isEmpty
        case let .array(array):
            !array.isEmpty
        default:
            false
        }
    }

    private static func composeScalar(_ value: BridgeModelValue) -> String {
        switch value {
        case .null:
            "null"
        case let .bool(value):
            value ? "true" : "false"
        case let .number(value):
            NSDecimalNumber(decimal: value).stringValue
        case let .string(value):
            quoted(value)
        case let .binary(value):
            "!!binary \(value.base64EncodedString())"
        case .object:
            "{}"
        case .array:
            "[]"
        }
    }

    private static func renderKey(_ key: String) -> String {
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else {
            return quoted(key)
        }
        return key
    }

    private static func quoted(_ value: String) -> String {
        var rendered = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                rendered += "\\\""
            case "\\":
                rendered += "\\\\"
            case "\n":
                rendered += "\\n"
            case "\r":
                rendered += "\\r"
            case "\t":
                rendered += "\\t"
            case let control where control.value < 0x20 || control.value == 0x7F:
                rendered += String(format: "\\u%04X", Int(control.value))
            default:
                rendered.unicodeScalars.append(scalar)
            }
        }
        rendered += "\""
        return rendered
    }
}
