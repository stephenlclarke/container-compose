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
    case "json", "len", "lower", "not", "table", "title", "upper":
        return total == 1
    case "pad":
        return total == 3
    case "truncate", "split", "join", "index":
        return total == 2
    case "slice":
        return (2 ... 3).contains(total)
    case "eq", "ne", "and", "or":
        return total >= 2
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
    guard case let .string(string) = value else {
        throw structuredUnsupportedAction(function)
    }
    return string
}

func structuredInteger(
    _ value: DockerTemplateData,
    function: String,
) throws -> Int {
    switch value {
    case let .integer(integer):
        return integer
    case let .string(string):
        guard let integer = Int(string) else { throw structuredUnsupportedAction(function) }
        return integer
    default:
        throw structuredUnsupportedAction(function)
    }
}

func structuredTemplateLength(_ value: DockerTemplateData) -> Int {
    switch value {
    case let .array(values):
        values.count
    case .boolean, .integer:
        1
    case let .lookupObject(_, display):
        display.count
    case .null:
        0
    case let .object(values):
        values.count
    case let .string(value):
        value.count
    }
}
