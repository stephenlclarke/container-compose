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

/// Tracks the appended suffix of a merged raw log replay across rotations.
struct LogDataReplayCursor {
    private var previous: Data

    init(snapshot: Data = Data()) {
        previous = snapshot
    }

    /// Returns bytes that are present in `current` but were not emitted from the previous snapshot.
    mutating func appendedData(in current: Data) -> Data {
        let overlap = LogReplayOverlap.length(previous: previous, current: current)
        previous = current
        guard overlap < current.count else {
            return Data()
        }
        return Data(current.dropFirst(overlap))
    }
}

/// Computes suffix/prefix overlap for retained rotated-log snapshots.
private enum LogReplayOverlap {
    /// Returns the length of the longest byte suffix of `previous` that is also a prefix of `current`.
    static func length(previous: Data, current: Data) -> Int {
        guard !previous.isEmpty, !current.isEmpty else {
            return 0
        }
        if current.starts(with: previous) {
            return previous.count
        }

        let table = prefixTable(for: current)
        var matched = 0
        for (index, value) in previous.enumerated() {
            while matched > 0 && value != byte(at: matched, in: current) {
                matched = table[matched - 1]
            }
            if value == byte(at: matched, in: current) {
                matched += 1
                if matched == current.count && index < previous.index(before: previous.endIndex) {
                    matched = table[matched - 1]
                }
            }
        }
        return matched
    }

    private static func prefixTable(for pattern: Data) -> [Int] {
        guard !pattern.isEmpty else {
            return []
        }

        var table = Array(repeating: 0, count: pattern.count)
        var matched = 0
        for index in 1..<pattern.count {
            let value = byte(at: index, in: pattern)
            while matched > 0 && value != byte(at: matched, in: pattern) {
                matched = table[matched - 1]
            }
            if value == byte(at: matched, in: pattern) {
                matched += 1
                table[index] = matched
            }
        }
        return table
    }

    private static func byte(at offset: Int, in data: Data) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }
}
