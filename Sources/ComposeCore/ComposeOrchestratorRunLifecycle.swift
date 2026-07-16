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

private enum ComposeRunLifecycleOperationResult {
    case logsFinished
    case exitCode(Int32)
}

private actor ComposeRunLifecycleExitCode {
    private var storage: Int32?

    var value: Int32? {
        storage
    }

    func set(_ value: Int32) {
        storage = value
    }
}

private struct ComposeRunLifecycleSignalContext: @unchecked Sendable {
    let service: ComposeService
    let containerName: String
}

extension ComposeOrchestrator {
    /// Follows a non-interactive one-off run and returns its container exit status.
    func followForegroundOneOffRun(
        service: ComposeService,
        containerName: String,
    ) async throws -> Int32 {
        let signalContext = ComposeRunLifecycleSignalContext(service: service, containerName: containerName)
        let exitCode = ComposeRunLifecycleExitCode()
        try await signalProxy.withSignalProxy(
            signals: ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"],
            handler: { [self, signalContext] _ in
                try? await stopContainer(
                    service: signalContext.service,
                    containerName: signalContext.containerName,
                )
            },
            operation: { [self, exitCode] in
                let status = try await followOneOffRunLogsAndWait(containerName: containerName)
                await exitCode.set(status)
            },
        )
        guard let status = await exitCode.value else {
            throw ComposeError.invalidProject("foreground compose run did not produce an exit status")
        }
        return status
    }

    /// Streams raw one-off output while waiting for the direct runtime exit status.
    func followOneOffRunLogsAndWait(containerName: String) async throws -> Int32 {
        let logManager = logManager
        let lifecycleManager = lifecycleManager
        let emit = options.emitData
        return try await withThrowingTaskGroup(of: ComposeRunLifecycleOperationResult.self) { group in
            group.addTask {
                try await logManager.logs(
                    id: containerName,
                    tail: nil,
                    follow: true,
                    since: nil,
                    until: nil,
                    timestamps: false,
                    emit: emit,
                )
                return .logsFinished
            }
            group.addTask {
                try await .exitCode(lifecycleManager.waitContainer(id: containerName))
            }

            var exitCode: Int32?
            var logsFinished = false
            while let result = try await group.next() {
                switch result {
                case .logsFinished:
                    logsFinished = true
                case let .exitCode(status):
                    exitCode = status
                }
                if logsFinished, let exitCode {
                    return exitCode
                }
            }
            throw ComposeError.invalidProject("foreground compose run did not produce an exit status")
        }
    }
}
