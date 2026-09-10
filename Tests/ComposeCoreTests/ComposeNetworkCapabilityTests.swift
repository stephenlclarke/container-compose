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

@testable import ComposeCore
import Testing

@Suite("Network runtime capability projection")
struct ComposeNetworkCapabilityTests {
    @Test
    func `stock capability set omits unsupported attachment extensions`() throws {
        var options = ComposeExecutionOptions()
        options.runtimeCapabilities = ComposeRuntimeCapabilities()
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: options,
        )
        let service = composeService(name: "api", image: "example/api") {
            $0.networks = ["backend"]
            $0.networkAliases = ["backend": ["api", "api.internal"]]
            $0.networkOptions = [
                "backend": ComposeNetworkOptions(
                    interfaceName: "eth0",
                    addressing: .init(
                        ipv4Address: "192.0.2.10",
                        linkLocalIPs: ["169.254.8.8"],
                    ),
                ),
            ]
        }
        let project = composeProject(
            name: "demo",
            services: ["api": service],
        ) {
            $0.networks = ["backend": ComposeNetwork(name: "backend")]
        }

        #expect(try orchestrator.networkAttachmentArgument(
            project: project,
            service: service,
            network: "backend",
        ) == "demo_backend")
    }
}
