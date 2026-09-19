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

import ComposeCore
import ComposeRuntimeSPI
import Foundation

extension EngineServiceCreateRequest {
    /// Parse integer byte quantities without routing large values through Double.
    static func byteQuantity(_ input: String) throws -> Int64 {
        let value = input.lowercased()
        let digits = value.prefix { $0.isASCII && $0.isNumber }
        let suffix = String(value.dropFirst(digits.count))
        let scales: [String: Int64] = ["": 1, "b": 1, "k": 1024, "kb": 1024, "kib": 1024,
                                      "m": 1 << 20, "mb": 1 << 20, "mib": 1 << 20,
                                      "g": 1 << 30, "gb": 1 << 30, "gib": 1 << 30,
                                      "t": 1 << 40, "tb": 1 << 40, "tib": 1 << 40]
        guard let number = Int64(digits), let scale = scales[suffix] else {
            throw ComposeError.invalidProject("Invalid prepared byte quantity")
        }
        let result = number.multipliedReportingOverflow(by: scale)
        guard !result.overflow else { throw ComposeError.invalidProject("Byte quantity overflow") }
        return result.partialValue
    }

    static func healthConfiguration(_ health: ComposeHealthCheck?) throws -> EngineCreateValue {
        guard let health else { return .object(["Test": .strings(["NONE"])]) }
        var value: [String: EngineCreateValue] = [
            "Test": .strings(["CMD", health.process.executable] + health.process.arguments),
            "Retries": .integer(Int64(health.retries)),
        ]
        for (key, duration) in [
            ("Interval", health.intervalInNanoseconds), ("Timeout", health.timeoutInNanoseconds),
            ("StartPeriod", health.startPeriodInNanoseconds), ("StartInterval", health.startIntervalInNanoseconds),
        ] {
            if let duration {
                guard let nanos = Int64(exactly: duration) else {
                    throw ComposeError.invalidProject("Health duration overflow")
                }
                value[key] = .integer(nanos)
            }
        }
        return .object(value)
    }
}
