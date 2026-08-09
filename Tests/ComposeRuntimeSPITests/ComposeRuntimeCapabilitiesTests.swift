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

import ComposeRuntimeSPI
import Testing

@Suite("Runtime capability selection")
struct ComposeRuntimeCapabilitiesTests {
    @Test
    func `logging v2 requires its exact negotiated identifier`() {
        #expect(!ComposeRuntimeCapabilities().supportsLoggingDriversV1)
        #expect(!ComposeRuntimeCapabilities(
            identifiers: ["io.github.stephenlclarke.container.logging-drivers.v2"],
        ).supportsLoggingDriversV1)
        #expect(ComposeRuntimeCapabilities(
            identifiers: [ComposeRuntimeCapabilities.loggingDriversV1Identifier],
        ).supportsLoggingDriversV1)
    }

    @Test
    func `unknown capabilities remain available without duplicates`() {
        let capabilities = ComposeRuntimeCapabilities(identifiers: ["example.future.v1", "example.future.v1"])

        #expect(capabilities.identifiers == ["example.future.v1"])
    }
}
