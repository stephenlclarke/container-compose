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
import Foundation

/// Tracks the appended suffix of a merged raw log replay across rotations.
struct LogDataReplayCursor {
    private var previous: Data

    init(snapshot: Data = Data()) {
        previous = snapshot
    }

    /// Returns bytes that are present in `current` but were not emitted from the previous snapshot.
    mutating func appendedData(in current: Data) -> Data {
        let overlap = LogReplayOverlap.length(previous: Array(previous), current: Array(current))
        previous = current
        guard overlap < current.count else {
            return Data()
        }
        return Data(current.dropFirst(overlap))
    }
}

/// Tracks the appended suffix of merged structured log records across rotations.
struct LogRecordReplayCursor {
    private var previous: [ContainerLogRecord]

    init(snapshot: [ContainerLogRecord] = []) {
        previous = snapshot
    }

    /// Returns records that are present in `current` but were not emitted from the previous snapshot.
    mutating func appendedRecords(in current: [ContainerLogRecord]) -> [ContainerLogRecord] {
        let overlap = LogReplayOverlap.length(previous: previous, current: current)
        previous = current
        guard overlap < current.count else {
            return []
        }
        return Array(current.dropFirst(overlap))
    }
}

/// Computes suffix/prefix overlap for retained rotated-log snapshots.
private enum LogReplayOverlap {
    /// Returns the length of the longest suffix of `previous` that is also a prefix of `current`.
    static func length<Element: Equatable>(previous: [Element], current: [Element]) -> Int {
        guard !previous.isEmpty, !current.isEmpty else {
            return 0
        }
        if current.starts(with: previous) {
            return previous.count
        }

        let table = prefixTable(for: current)
        var matched = 0
        for (index, element) in previous.enumerated() {
            while matched > 0 && element != current[matched] {
                matched = table[matched - 1]
            }
            if element == current[matched] {
                matched += 1
                if matched == current.count && index < previous.index(before: previous.endIndex) {
                    matched = table[matched - 1]
                }
            }
        }
        return matched
    }

    private static func prefixTable<Element: Equatable>(for pattern: [Element]) -> [Int] {
        guard !pattern.isEmpty else {
            return []
        }

        var table = Array(repeating: 0, count: pattern.count)
        var length = 0
        var index = 1
        while index < pattern.count {
            if pattern[index] == pattern[length] {
                length += 1
                table[index] = length
                index += 1
            } else if length > 0 {
                length = table[length - 1]
            } else {
                table[index] = 0
                index += 1
            }
        }
        return table
    }
}
