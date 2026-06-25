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

/// Renders rows as a padded table.
func renderTable(_ rows: [[String]]) -> String {
    guard let firstRow = rows.first else {
        return ""
    }
    let widths = rows.reduce(Array(repeating: 0, count: firstRow.count)) { current, row in
        zip(current, row).map { max($0, $1.count) }
    }
    return rows.map { row in
        var line = row.enumerated().map { index, value in
            index == row.count - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
        while line.last == " " {
            line.removeLast()
        }
        return line
    }.joined(separator: "\n")
}
