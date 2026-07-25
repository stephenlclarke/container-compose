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

func isStructuredTemplateLabelFunction(_ token: String) -> Bool {
    token == ".Label" || token == "$.Label"
}

func structuredTemplateLookup(
    _ value: DockerTemplateData,
    _ field: String,
) throws -> DockerTemplateData {
    switch value {
    case let .lookupObject(values, _), let .object(values):
        return values[field] ?? .null
    case let .record(values):
        guard let value = values[field] else {
            throw structuredUnsupportedAction("unknown record field .\(field)")
        }
        return value
    case .array, .boolean, .byteString, .integer, .null, .string:
        throw structuredUnsupportedAction("field .\(field)")
    }
}

func structuredTemplateLabel(
    _ key: String,
    source: DockerTemplateData,
) throws -> DockerTemplateData {
    let labels: DockerTemplateData
    switch source {
    case let .lookupObject(values, _), let .object(values):
        guard let value = values["Labels"] else {
            return .string("")
        }
        labels = value
    case let .record(values):
        guard let value = values["Labels"] else {
            throw structuredUnsupportedAction("unknown record field .Labels")
        }
        labels = value
    case .array, .boolean, .byteString, .integer, .null, .string:
        throw structuredUnsupportedAction("field .Labels")
    }
    let value = try structuredTemplateLookup(labels, key)
    return value == .null ? .string("") : value
}
