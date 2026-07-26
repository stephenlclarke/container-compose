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

func applyStructuredPrintFunction(
    _ function: String,
    inputs: [DockerTemplateData],
) throws -> DockerTemplateData {
    switch function {
    case "print":
        return .byteString(structuredTemplatePrint(inputs))
    case "println":
        var output = structuredTemplateJoinedOutputBytes(
            inputs.map(\.outputBytes),
            separator: " ",
        )
        output.append(UInt8(ascii: "\n"))
        return .byteString(output)
    case "printf":
        guard let format = inputs.first else {
            throw structuredUnsupportedAction(function)
        }
        return try .byteString(
            structuredTemplatePrintf(
                structuredString(format, function: function),
                values: Array(inputs.dropFirst()),
            ),
        )
    default:
        throw structuredUnsupportedAction(function)
    }
}

func structuredTemplatePrint(_ inputs: [DockerTemplateData]) -> [UInt8] {
    var rendered: [UInt8] = []
    for (index, input) in inputs.enumerated() {
        if index > 0,
           !structuredTemplatePrintValueIsString(inputs[index - 1]),
           !structuredTemplatePrintValueIsString(input)
        {
            rendered.append(UInt8(ascii: " "))
        }
        rendered.append(contentsOf: input.outputBytes)
    }
    return rendered
}

func structuredTemplateJoinedOutputBytes(
    _ values: [[UInt8]],
    separator: String,
) -> [UInt8] {
    var output: [UInt8] = []
    for (index, value) in values.enumerated() {
        if index > 0 {
            output.append(contentsOf: separator.utf8)
        }
        output.append(contentsOf: value)
    }
    return output
}

private func structuredTemplatePrintValueIsString(
    _ value: DockerTemplateData,
) -> Bool {
    switch value {
    case .byteString, .lookupObject, .string:
        true
    case .array, .boolean, .integer, .null, .object, .record:
        false
    }
}
