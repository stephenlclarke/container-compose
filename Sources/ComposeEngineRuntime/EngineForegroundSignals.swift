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

extension EngineRuntimeProvider {
    /// Own host handlers for the attachment's lifetime, including startup.
    /// Forward by symbolic name: Darwin and Linux signal numbers differ.
    func runSignalProxiedContainer(
        id: String, terminal: Bool, standardInput: Bool, io: EngineForegroundIO
    ) async throws -> Int32 {
        let result = ForegroundSignalResult()
        try await io.signalProxy.withSignalProxy(
            signals: ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM", "SIGUSR1", "SIGUSR2"],
            handler: { [self] signal in
                // A signal can race exit/auto-removal. Like Docker's forwarder,
                // do not replace the registered guest exit with a kill failure.
                try? await killContainer(id: id, signal: signal)
            },
            operation: { [self] in
                let status = try await runAttachedContainer(
                    id: id, terminal: terminal, standardInput: standardInput, io: io
                )
                await result.set(status)
            }
        )
        guard let status = await result.value else {
            throw ComposeError.invalidProject("Foreground signal proxy returned without a container exit")
        }
        return status
    }
}

private actor ForegroundSignalResult {
    private(set) var value: Int32?
    func set(_ status: Int32) {
        value = status
    }
}
