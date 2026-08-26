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
import ContainerAPIClient

/// Wires Compose policy to the matched Apple container runtime stack.
///
/// This is the composition root for the supported executable. ComposeCore
/// itself depends only on runtime contracts for these collaborators, allowing
/// another runtime package to provide an equivalent dependency graph.
public enum ComposeContainerRuntime {
    /// Returns the matched Apple-backed dependencies for one Compose invocation.
    public static func dependencies(
        runner: CommandRunning = ProcessRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
    ) -> ComposeOrchestratorDependencies {
        dependencies(
            runner: runner,
            options: options,
            discoveryClient: nil,
            makeContainerClient: ContainerClient.init,
        )
    }

    /// Returns matched dependencies with a caller-supplied discovery client.
    public static func dependencies(
        runner: CommandRunning = ProcessRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
        discoveryClient: ContainerDiscoveryAPIClienting,
    ) -> ComposeOrchestratorDependencies {
        dependencies(
            runner: runner,
            options: options,
            discoveryClient: discoveryClient,
            makeContainerClient: ContainerClient.init,
        )
    }

    static func dependencies(
        runner: CommandRunning = ProcessRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
        discoveryClient: ContainerDiscoveryAPIClienting? = nil,
        makeContainerClient: @escaping @Sendable () -> ContainerClient,
    ) -> ComposeOrchestratorDependencies {
        let invocationClients = InvocationScopedClientPool(create: makeContainerClient)
        let provideClient: ContainerClientProvider = { invocationClients.control() }
        let makeSessionClient: ContainerClientProvider = { invocationClients.session() }
        let resolvedDiscoveryClient = discoveryClient
            ?? ContainerDiscoveryAPIClient(containerClient: provideClient)

        return ComposeOrchestratorDependencies(
            runner: runner,
            options: options,
            commands: commandDependencies(
                options: options,
                discoveryClient: resolvedDiscoveryClient,
                controlClient: provideClient,
                makeSessionClient: makeSessionClient,
            ),
            runtime: runtimeDependencies(
                discoveryClient: resolvedDiscoveryClient,
                controlClient: provideClient,
            ),
            imageManager: ContainerClientImageManager(),
        )
    }

    private static func commandDependencies(
        options: ComposeExecutionOptions,
        discoveryClient: ContainerDiscoveryAPIClienting,
        controlClient: @escaping ContainerClientProvider,
        makeSessionClient: @escaping ContainerClientProvider,
    ) -> ComposeOrchestratorCommandDependencies {
        ComposeOrchestratorCommandDependencies(
            archiveManager: ContainerArchiveManager(),
            attachManager: ContainerClientAttachManager(
                client: ContainerAttachAPIClient(
                    controlClient: controlClient,
                    makeSessionClient: makeSessionClient,
                ),
            ),
            copier: ContainerClientCopier(containerClient: controlClient),
            execManager: ContainerClientExecManager(
                client: ContainerExecAPIClient(
                    controlClient: controlClient,
                    makeSessionClient: makeSessionClient,
                ),
            ),
            exporter: ContainerClientExporter(
                temporaryDirectory: options.temporaryDirectory,
                containerClient: controlClient,
            ),
            launchManager: ContainerCommandLaunchManager(),
            logManager: ContainerClientLogManager(
                client: ContainerLogAPIClient(containerClient: controlClient),
                followStateProvider: ContainerClientLogFollowStateProvider(
                    client: discoveryClient,
                ),
            ),
        )
    }

    private static func runtimeDependencies(
        discoveryClient: ContainerDiscoveryAPIClienting,
        controlClient: @escaping ContainerClientProvider,
    ) -> ComposeOrchestratorRuntimeDependencies {
        ComposeOrchestratorRuntimeDependencies(
            services: .init(
                configReader: ComposeExternalConfigReader(),
                eventsManager: ContainerClientEventsManager(
                    client: ContainerEventsAPIClient(containerClient: controlClient),
                ),
                imageVolumeInitializer: ContainerClientImageVolumeInitializer(),
                lifecycleManager: ContainerClientLifecycleManager(
                    client: ContainerLifecycleAPIClient(containerClient: controlClient),
                ),
                resourceManager: ContainerClientResourceManager(),
                secretReader: ComposeExternalSecretReader(),
            ),
            discoveryManager: ContainerClientDiscoveryManager(client: discoveryClient),
            inspection: .init(
                statsManager: ContainerClientStatsManager(
                    client: ContainerStatsAPIClient(containerClient: controlClient),
                ),
                topManager: ContainerClientTopManager(
                    client: ContainerTopAPIClient(containerClient: controlClient),
                ),
            ),
        )
    }
}
