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
        case let .integer(value):
            return String(value)
        case let .lookupObject(_, display):
            return display
        case .null:
            return "<no value>"
        case let .object(values), let .record(values):
            let entries = values.keys.sorted().map { key in
                "\(key):\(values[key]?.display ?? "<no value>")"
            }
            return "map[\(entries.joined(separator: " "))]"
        case let .string(value):
            return value
        }
    }

    var isTruthy: Bool {
        switch self {
        case let .array(values):
            !values.isEmpty
        case let .boolean(value):
            value
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
        let data = try JSONSerialization.data(
            withJSONObject: foundationObject,
            options: [.fragmentsAllowed, .sortedKeys],
        )
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private var foundationObject: Any {
        switch self {
        case let .array(values):
            values.map(\.foundationObject)
        case let .boolean(value):
            value
        case let .integer(value):
            value
        case let .lookupObject(_, display):
            display
        case .null:
            NSNull()
        case let .object(values), let .record(values):
            values.mapValues(\.foundationObject)
        case let .string(value):
            value
        }
    }
}

extension String {
    func trimmingPrefixWhitespace() -> String {
        String(drop(while: \.isWhitespace))
    }

    func trimmingSuffixWhitespace() -> String {
        String(reversed().drop(while: \.isWhitespace).reversed())
    }
}

func structuredUnsupportedAction(_ action: String) -> ComposeError {
    ComposeError.unsupported(
        "format template action '{{\(action)}}'; supported actions are field and nested object references, if/else, with, range, variables, whitespace trimming, Docker row functions, and Go print, comparison, boolean, len, index, and slice functions",
    )
}
