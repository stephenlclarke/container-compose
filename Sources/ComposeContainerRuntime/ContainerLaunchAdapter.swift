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

import ArgumentParser
import ComposeRuntimeSPI
import ContainerCommands
import ContainerPersistence
import ContainerResource

typealias ContainerSystemConfigProvider = @Sendable () async throws -> ContainerSystemConfig

/// Runs Container's typed create path in-process after Compose negotiation.
///
/// Non-logging command options continue to use Container's maintained parser,
/// while logging is injected as a typed authority request. This removes both
/// the process-spawn overhead and process-list exposure of protected options.
public struct ContainerCommandLaunchManager: ComposeRuntimeContainerLaunching {
    typealias Execute = @Sendable ([String], ContainerLogRequest) async throws -> Int32

    private let create: Execute
    private let run: Execute

    public init() {
        create = { arguments, loggingRequest in
            let command = try Application.ContainerCreate.parse(arguments)
            try await command.run(loggingRequest: loggingRequest, emitsCLIOutput: false)
            return 0
        }
        run = { arguments, loggingRequest in
            let command = try Application.ContainerRun.parse(arguments)
            try await command.run(loggingRequest: loggingRequest, emitsCLIOutput: false)
            return 0
        }
    }

    init(
        containerSystemConfig: @escaping ContainerSystemConfigProvider,
        controlClient: @escaping ContainerClientProvider,
        makeSessionClient: @escaping ContainerClientProvider,
    ) {
        create = { arguments, loggingRequest in
            let command = try Application.ContainerCreate.parse(arguments)
            try await command.run(
                loggingRequest: loggingRequest,
                emitsCLIOutput: false,
                containerSystemConfig: containerSystemConfig(),
                client: controlClient(),
            )
            return 0
        }
        run = { arguments, loggingRequest in
            let command = try Application.ContainerRun.parse(arguments)
            try await command.run(
                loggingRequest: loggingRequest,
                emitsCLIOutput: false,
                containerSystemConfig: containerSystemConfig(),
                client: makeSessionClient(),
            )
            return 0
        }
    }

    init(create: @escaping Execute, run: @escaping Execute) {
        self.create = create
        self.run = run
    }

    public func launchContainer(_ request: ComposeRuntimeContainerLaunchRequest) async throws -> Int32 {
        let loggingRequest = ContainerLogRequest(
            driver: request.logging.driver,
            options: request.logging.options,
        )
        do {
            switch request.command {
            case .create:
                return try await create(request.arguments, loggingRequest)
            case .run:
                return try await run(request.arguments, loggingRequest)
            }
        } catch let exitCode as ArgumentParser.ExitCode {
            return exitCode.rawValue
        }
    }
}
