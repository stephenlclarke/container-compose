//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

/// Sleeps without specializing the generic clock-based `Task.sleep(for:)` API.
///
/// Swift 6.2 release builds on macOS 26 can abort while deallocating that
/// specialization. The nanosecond API has equivalent cancellation semantics
/// and avoids the affected optimizer/runtime path.
public enum ComposeTaskSleep {
    public static func sleep(for duration: Duration) async throws {
        let components = duration.components
        let seconds = UInt64(clamping: components.seconds)
        let attoseconds = UInt64(clamping: components.attoseconds)
        let secondsAsNanoseconds = seconds.multipliedReportingOverflow(
            by: 1_000_000_000,
        )
        let totalNanoseconds = secondsAsNanoseconds.partialValue.addingReportingOverflow(
            attoseconds / 1_000_000_000,
        )
        let nanoseconds = secondsAsNanoseconds.overflow || totalNanoseconds.overflow
            ? UInt64.max
            : totalNanoseconds.partialValue
        try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
    }
}
