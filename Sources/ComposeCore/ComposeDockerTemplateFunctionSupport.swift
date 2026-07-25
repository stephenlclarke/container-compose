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

func structuredTemplateArgumentsAreSupported(
    _ function: String,
    count: Int,
    hasPipelineValue: Bool,
) -> Bool {
    let total = count + (hasPipelineValue ? 1 : 0)
    switch function {
    case "json", "len", "lower", "not", "title", "upper":
        return total == 1
    case "pad":
        return total == 3
    case "truncate", "split", "join", "index":
        return total == 2
    case "slice":
        return (2 ... 3).contains(total)
    case "eq":
        return total >= 2
    case "ne":
        return total == 2
    case "and", "or":
        return total >= 1
    case "printf":
        return total >= 1
    case "print", "println":
        return true
    default:
        return false
    }
}

func structuredSingleInput(
    _ function: String,
    _ values: [DockerTemplateData],
) throws -> DockerTemplateData {
    guard values.count == 1, let value = values.first else {
        throw structuredUnsupportedAction(function)
    }
    return value
}

func structuredStringInput(
    _ function: String,
    _ values: [DockerTemplateData],
) throws -> String {
    try structuredString(structuredSingleInput(function, values), function: function)
}

func structuredString(
    _ value: DockerTemplateData,
    function: String,
) throws -> String {
    switch value {
    case let .byteString(bytes):
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw structuredUnsupportedAction(function)
        }
        return string
    case let .lookupObject(_, display):
        return display
    case let .string(string):
        return string
    default:
        throw structuredUnsupportedAction(function)
    }
}

func structuredInteger(
    _ value: DockerTemplateData,
    function: String,
) throws -> Int {
    switch value {
    case let .integer(integer):
        return integer
    case .array, .boolean, .byteString, .lookupObject, .null, .object, .record, .string:
        throw structuredUnsupportedAction(function)
    }
}

func structuredTemplateLength(_ value: DockerTemplateData) throws -> Int {
    switch value {
    case let .array(values):
        values.count
    case let .byteString(value):
        value.count
    case let .lookupObject(_, display):
        display.utf8.count
    case let .object(values):
        values.count
    case let .string(value):
        value.utf8.count
    case .boolean, .integer, .null, .record:
        throw structuredUnsupportedAction("len")
    }
}

func structuredTemplateEqual(
    _ lhs: DockerTemplateData,
    _ rhs: DockerTemplateData,
    function: String,
) throws -> Bool {
    let lhs = structuredTemplateComparableValue(lhs)
    let rhs = structuredTemplateComparableValue(rhs)
    switch (lhs, rhs) {
    case let (.boolean(lhs), .boolean(rhs)):
        return lhs == rhs
    case let (.integer(lhs), .integer(rhs)):
        return lhs == rhs
    case let (.byteString(lhs), .byteString(rhs)):
        return lhs == rhs
    case let (.byteString(lhs), .string(rhs)):
        return lhs == Array(rhs.utf8)
    case let (.string(lhs), .string(rhs)):
        return lhs == rhs
    case let (.string(lhs), .byteString(rhs)):
        return Array(lhs.utf8) == rhs
    case (.null, .null):
        return true
    case (.null, _), (_, .null):
        return false
    case (.array, _), (.object, _), (.record, _),
         (_, .array), (_, .object), (_, .record),
         (.lookupObject, _), (_, .lookupObject):
        throw structuredUnsupportedAction(function)
    default:
        throw structuredUnsupportedAction(function)
    }
}

func structuredTemplateIndex(_ values: [DockerTemplateData]) throws -> DockerTemplateData {
    guard values.count == 2 else { throw structuredUnsupportedAction("index") }
    switch values[0] {
    case let .array(elements):
        let index = try structuredInteger(values[1], function: "index")
        guard elements.indices.contains(index) else { throw structuredUnsupportedAction("index") }
        return elements[index]
    case let .object(object):
        guard let key = try structuredTemplateMapKey(values[1]) else { return .null }
        return object[key] ?? .null
    case let .lookupObject(_, display):
        return try structuredTemplateByteIndex(Array(display.utf8), index: values[1])
    case let .byteString(bytes):
        return try structuredTemplateByteIndex(bytes, index: values[1])
    case let .string(string):
        return try structuredTemplateByteIndex(Array(string.utf8), index: values[1])
    default:
        throw structuredUnsupportedAction("index")
    }
}

func structuredTemplateSlice(_ values: [DockerTemplateData]) throws -> DockerTemplateData {
    guard (2 ... 3).contains(values.count) else { throw structuredUnsupportedAction("slice") }
    let lower = try structuredInteger(values[1], function: "slice")
    switch values[0] {
    case let .array(elements):
        let upper = try values.count == 3
            ? structuredInteger(values[2], function: "slice")
            : elements.count
        guard lower >= 0, lower <= upper, upper <= elements.count else {
            throw structuredUnsupportedAction("slice")
        }
        return .array(Array(elements[lower ..< upper]))
    case let .byteString(bytes):
        return try structuredTemplateByteSlice(bytes, lower: lower, values: values)
    case let .lookupObject(_, display):
        return try structuredTemplateByteSlice(Array(display.utf8), lower: lower, values: values)
    case let .string(string):
        return try structuredTemplateByteSlice(Array(string.utf8), lower: lower, values: values)
    default:
        throw structuredUnsupportedAction("slice")
    }
}

private func structuredTemplateMapKey(
    _ value: DockerTemplateData,
) throws -> String? {
    switch value {
    case let .byteString(bytes):
        return String(bytes: bytes, encoding: .utf8)
    case let .string(key):
        return key
    default:
        throw structuredUnsupportedAction("index")
    }
}

private func structuredTemplateByteIndex(
    _ bytes: [UInt8],
    index value: DockerTemplateData,
) throws -> DockerTemplateData {
    let index = try structuredInteger(value, function: "index")
    guard bytes.indices.contains(index) else {
        throw structuredUnsupportedAction("index")
    }
    return .integer(Int(bytes[index]))
}

private func structuredTemplateByteSlice(
    _ bytes: [UInt8],
    lower: Int,
    values: [DockerTemplateData],
) throws -> DockerTemplateData {
    let upper = try values.count == 3
        ? structuredInteger(values[2], function: "slice")
        : bytes.count
    guard lower >= 0, lower <= upper, upper <= bytes.count else {
        throw structuredUnsupportedAction("slice")
    }
    return .byteString(Array(bytes[lower ..< upper]))
}

private func structuredTemplateComparableValue(
    _ value: DockerTemplateData,
) -> DockerTemplateData {
    guard case let .lookupObject(_, display) = value else {
        return value
    }
    return .string(display)
}
