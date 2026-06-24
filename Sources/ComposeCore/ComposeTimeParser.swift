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

/// Parses Docker Compose time strings at the plugin boundary.
///
/// `apple/container` receives typed dates or Apple-native values. This parser
/// keeps Docker-shaped CLI compatibility in `container-compose`.
enum ComposeTimeParser {
    /// Parses an RFC 3339 timestamp, Unix timestamp, or relative duration.
    static func parseTimestamp(_ value: String, relativeTo referenceDate: Date) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let date = parseAbsoluteTimestamp(trimmed) {
            return date
        }
        if let date = parseUnixTimestamp(trimmed) {
            return date
        }
        if let duration = parseDuration(trimmed) {
            return referenceDate.addingTimeInterval(-duration)
        }
        return nil
    }

    /// Parses Compose and Go-style duration strings such as `30m` or `1.5s`.
    static func parseDuration(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            return nil
        }

        var index = trimmed.startIndex
        var total: TimeInterval = 0
        var parsedComponent = false
        while index < trimmed.endIndex {
            let numberStart = index
            var sawDigit = false
            var sawDecimalSeparator = false
            while index < trimmed.endIndex {
                let character = trimmed[index]
                if character.isNumber {
                    sawDigit = true
                    index = trimmed.index(after: index)
                } else if character == ".", !sawDecimalSeparator {
                    sawDecimalSeparator = true
                    index = trimmed.index(after: index)
                } else {
                    break
                }
            }

            guard sawDigit,
                  numberStart < index,
                  let amount = TimeInterval(String(trimmed[numberStart..<index])),
                  amount.isFinite,
                  amount >= 0,
                  let unit = durationUnit(in: trimmed, at: index) else {
                return nil
            }

            total += amount * unit.multiplier
            index = trimmed.index(index, offsetBy: unit.symbol.count)
            parsedComponent = true
        }

        return parsedComponent ? total : nil
    }

    private static func parseAbsoluteTimestamp(_ value: String) -> Date? {
        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
            ISO8601DateFormatter.Options([.withInternetDateTime]),
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) {
                return date
            }
        }
        if isDateOnly(value) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return parseLayoutTimestamp(value)
    }

    private static func parseUnixTimestamp(_ value: String) -> Date? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let secondsPart = parts.first,
              !secondsPart.isEmpty,
              secondsPart.allSatisfy(\.isNumber),
              let seconds = TimeInterval(String(secondsPart)),
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }

        var fractionalSeconds: TimeInterval = 0
        if parts.count == 2 {
            let fractionPart = parts[1]
            guard !fractionPart.isEmpty,
                  fractionPart.count <= 9,
                  fractionPart.allSatisfy(\.isNumber),
                  let fraction = TimeInterval("0.\(fractionPart)") else {
                return nil
            }
            fractionalSeconds = fraction
        }

        return Date(timeIntervalSince1970: seconds + fractionalSeconds)
    }

    private static func parseLayoutTimestamp(_ value: String) -> Date? {
        for format in timestampLayouts {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func isDateOnly(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts[0].count == 4
            && parts[1].count == 2
            && parts[2].count == 2
            && parts.allSatisfy { part in part.allSatisfy(\.isNumber) }
    }

    private static func durationUnit(in value: String, at index: String.Index) -> (symbol: String, multiplier: TimeInterval)? {
        for unit in durationUnits where value[index...].hasPrefix(unit.symbol) {
            return unit
        }
        return nil
    }

    private static let durationUnits: [(symbol: String, multiplier: TimeInterval)] = [
        ("µs", 0.000_001),
        ("μs", 0.000_001),
        ("ns", 0.000_000_001),
        ("us", 0.000_001),
        ("ms", 0.001),
        ("s", 1),
        ("m", 60),
        ("h", 60 * 60),
    ]

    private static let timestampLayouts = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mmXXXXX",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd",
    ]
}
