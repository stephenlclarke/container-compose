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
import Foundation
import Testing

@Suite("Bounded process output")
struct ProcessRunnerBoundedOutputTests {
    @Test
    func `bounded capture drains streams and records exact omitted bytes`() async throws {
        let result = try await ProcessRunner().runCapturingOutputPrefix(
            "/bin/sh",
            [
                "-c",
                """
                python3 - <<'PY'
                import os
                os.write(1, b"o" * 1048576)
                os.write(2, b"e" * 2097152)
                PY
                """,
            ],
            input: Data(),
            maximumOutputBytes: 1024,
        )

        #expect(result.succeeded)
        #expect(result.stdoutData == Data(repeating: UInt8(ascii: "o"), count: 1024))
        #expect(result.stderrData == Data(repeating: UInt8(ascii: "e"), count: 1024))
        #expect(result.stdoutOmittedByteCount == 1_047_552)
        #expect(result.stderrOmittedByteCount == 2_096_128)
    }
}
