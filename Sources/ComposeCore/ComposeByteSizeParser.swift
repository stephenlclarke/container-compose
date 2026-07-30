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

enum ComposeByteSizeParser {
    enum ParseError: Error {
        case invalidSize
        case invalidUnit
    }

    static func bytes(_ input: String) throws -> Double {
        let value = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else {
            throw ParseError.invalidSize
        }
        let unitIndex = value.firstIndex { !$0.isNumber && $0 != "." }
        let numberText = unitIndex
            .map { value[..<$0].trimmingCharacters(in: .whitespaces) }
            ?? value
        let unitText = unitIndex
            .map { value[$0...].trimmingCharacters(in: .whitespaces) }
            ?? ""
        guard let number = Double(numberText), number.isFinite else {
            throw ParseError.invalidSize
        }

        let unit = unitText.first ?? "b"
        guard "bkmgtp".contains(unit) else {
            throw ParseError.invalidUnit
        }
        let suffix = String(unitText.dropFirst())
        guard suffix.isEmpty || suffix == "b" || suffix == "ib" else {
            throw ParseError.invalidUnit
        }
        let exponent = "bkmgtp".firstIndex(of: unit).map { "bkmgtp".distance(from: "bkmgtp".startIndex, to: $0) } ?? 0
        return number * pow(1024, Double(exponent))
    }
}
