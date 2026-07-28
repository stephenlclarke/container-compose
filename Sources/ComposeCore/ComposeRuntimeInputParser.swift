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

struct ComposeGPURequest: Equatable, Sendable {
    var driver = ""
    var count = 0
    var deviceIDs: [String] = []
    var capabilities: [String] = []
    var options: [String: String] = [:]
}

enum ComposeRuntimeInputParser {
    enum ParseError: Error {
        case invalidValue
    }

    static func validateDeviceCgroupRules(_ rules: [String]) throws {
        for rule in rules {
            let fields = rule.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, ["a", "b", "c"].contains(String(fields[0])) else {
                throw ParseError.invalidValue
            }
            let device = fields[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard device.count == 2 else {
                throw ParseError.invalidValue
            }
            for value in device where value != "*" {
                guard let number = Int64(value), number >= 0 else {
                    throw ParseError.invalidValue
                }
            }
            let access = String(fields[2])
            guard !access.isEmpty, access.allSatisfy({ "rwm".contains($0) }) else {
                throw ParseError.invalidValue
            }
        }
    }

    static func gpuRequests(_ values: [String]) throws -> [ComposeGPURequest] {
        try values.map(parseGPURequest)
    }

    private static func parseGPURequest(_ value: String) throws -> ComposeGPURequest {
        let fields = try csvFields(value)
        guard !fields.isEmpty else {
            throw ParseError.invalidValue
        }
        var result = ComposeGPURequest()
        var countWasSet = false
        var seen = Set<String>()

        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let fieldValue = parts.count == 2 ? String(parts[1]) : nil
            let effectiveKey = fieldValue == nil ? "count" : key
            guard seen.insert(effectiveKey).inserted else {
                throw ParseError.invalidValue
            }
            guard let fieldValue else {
                result.count = try gpuCount(key)
                countWasSet = true
                continue
            }
            switch key {
            case "driver":
                result.driver = fieldValue
            case "count":
                result.count = try gpuCount(fieldValue)
                countWasSet = true
            case "device":
                result.deviceIDs = fieldValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            case "capabilities":
                result.capabilities = fieldValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                result.capabilities.append("gpu")
            case "options":
                result.options = try gpuOptions(fieldValue)
            default:
                throw ParseError.invalidValue
            }
        }
        if !countWasSet, result.deviceIDs.isEmpty {
            result.count = 1
        }
        if result.capabilities.isEmpty {
            result.capabilities = ["gpu"]
        }
        return result
    }

    private static func gpuCount(_ value: String) throws -> Int {
        if value == "all" {
            return -1
        }
        guard let count = Int(value) else {
            throw ParseError.invalidValue
        }
        return count
    }

    private static func gpuOptions(_ value: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for field in try csvFields(value) {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            result[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
        }
        return result
    }

    private static func csvFields(_ value: String) throws -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if quoted {
                if character == "\"" {
                    let next = value.index(after: index)
                    if next < value.endIndex, value[next] == "\"" {
                        field.append("\"")
                        index = value.index(after: next)
                        continue
                    }
                    quoted = false
                    closedQuote = true
                } else {
                    field.append(character)
                }
            } else if character == "," {
                fields.append(field)
                field = ""
                closedQuote = false
            } else if character == "\"" {
                guard field.isEmpty else {
                    throw ParseError.invalidValue
                }
                quoted = true
                closedQuote = false
            } else {
                guard !closedQuote else {
                    throw ParseError.invalidValue
                }
                field.append(character)
            }
            index = value.index(after: index)
        }
        guard !quoted else {
            throw ParseError.invalidValue
        }
        fields.append(field)
        return fields
    }
}
