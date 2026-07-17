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
        let commands = ComposeOrchestratorCommandDependencies(
            copier: ContainerClientCopier(),
            execManager: ContainerClientExecManager(),
            exporter: ContainerClientExporter(),
            logManager: ContainerClientLogManager(),
        )
        let runtime = ComposeOrchestratorRuntimeDependencies(
            services: .init(
                configReader: ComposeExternalConfigReader(),
                eventsManager: ContainerClientEventsManager(),
                lifecycleManager: ContainerClientLifecycleManager(),
                resourceManager: ContainerClientResourceManager(),
                secretReader: ComposeExternalSecretReader(),
            ),
            discoveryManager: ContainerLiveDiscoveryManager(
                runner: runner,
                environmentLauncher: options.environmentLauncher,
                containerBinary: options.containerBinary,
            ),
            inspection: .init(
                statsManager: ContainerClientStatsManager(),
                topManager: ContainerClientTopManager(),
            ),
        )
        return ComposeOrchestratorDependencies(
            runner: runner,
            options: options,
            commands: commands,
            runtime: runtime,
            imageManager: ContainerClientImageManager(),
        )
    }
}
