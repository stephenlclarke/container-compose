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

extension ContainerPackageCompatibility {
    /// System-version emits the API row only after a bounded live health ping succeeds.
    static func liveAPIIdentityFailure(
        components: [ContainerSystemVersionComponent],
        backend: RuntimeBackend,
    ) -> String? {
        let clients = components.filter { $0.appName == "container" }
        let servers = components.filter { $0.appName == "container-apiserver" }
        guard clients.count == 1, servers.count == 1 else {
            return nativeAPIGuidance(
                backend: backend,
                detected: ["system version requires exactly one container and one live container-apiserver (found \(clients.count) and \(servers.count))"],
            )
        }
        let client = clients[0]
        let server = servers[0]
        guard let clientCommit = client.commit,
              validSourceRevision(clientCommit), validSourceRevision(server.commit),
              server.commit == clientCommit,
              validHealthIdentity(server.version),
              server.buildType == "debug" || server.buildType == "release"
        else {
            return nativeAPIGuidance(
                backend: backend,
                detected: ["container-apiserver: malformed or mismatched health identity (commit \(server.commit ?? "missing"), CLI commit \(client.commit ?? "missing"), version \(server.version ?? "missing"), build \(server.buildType ?? "missing"))"],
            )
        }
        return nil
    }

    private static func validSourceRevision(_ value: String?) -> Bool {
        guard let bytes = value?.utf8, bytes.count == 40 else {
            return false
        }
        return bytes.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    private static func validHealthIdentity(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !value.isEmpty && value != "unspecified" && value != "unknown"
    }

    private static func nativeAPIGuidance(backend: RuntimeBackend, detected: [String]) -> String {
        let provider = backend == .nativeAPI ? "compiled native API backend" : "selected enhanced runtime"
        return """
        container-compose requires a live matching container API server for its \(provider).

        Start the matching API service selected by the runtime owner, then run this command again.
        Detailed install instructions:
        \(installGuideURL)

        Detected API readiness:
        \(detected.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

}

extension ContainerPackageCompatibility.ExpectedRuntimeRevisions {
    /// Engine transport does not use the SDK's native Container APIs.
    static func forCompiledSDK(
        container: String?, containerization: String?,
        backend: ContainerPackageCompatibility.RuntimeBackend = ContainerPackageCompatibility.compiledRuntimeBackend,
    ) -> Self {
        guard backend == .nativeAPI else {
            return .init()
        }
        return .init(container: container, containerization: containerization)
    }
}
