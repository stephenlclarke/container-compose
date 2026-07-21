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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

/// Converts a normalized Compose project into deterministic `container`
/// commands.
public final class ComposeOrchestrator: @unchecked Sendable {
    let runner: CommandRunning
    let options: ComposeExecutionOptions
    let copier: ComposeRuntimeCopying
    let configReader: ComposeRuntimeConfigReading
    let discoveryManager: ComposeRuntimeDiscoveryManaging
    let eventsManager: ComposeRuntimeEventsManaging
    let execManager: ComposeRuntimeExecManaging
    let exporter: ComposeRuntimeExporting
    let imageManager: ComposeRuntimeImageManaging
    let imageVolumeInitializer: ComposeRuntimeImageVolumeInitializing
    let lifecycleManager: ComposeRuntimeLifecycleManaging
    let logManager: ComposeRuntimeLogManaging
    let upMenuController: ComposeUpMenuControlling
    let pullMetadataStore: ComposePullMetadataStoring
    let resourceManager: ComposeRuntimeResourceManaging
    let secretReader: ComposeRuntimeSecretReading
    let signalProxy: ComposeSignalProxying
    let statsManager: ComposeRuntimeStatsManaging
    let topManager: ComposeRuntimeTopManaging

    public init(
        runner: CommandRunning = ProcessRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
        dependencies: ComposeOrchestratorDependencies? = nil,
    ) {
        let dependencies = dependencies ?? ComposeOrchestratorDependencies(runner: runner, options: options)
        self.runner = runner
        self.options = options
        copier = dependencies.copier
        configReader = dependencies.configReader
        discoveryManager = dependencies.discoveryManager
        eventsManager = dependencies.eventsManager
        execManager = dependencies.execManager
        exporter = dependencies.exporter
        imageManager = dependencies.imageManager
        imageVolumeInitializer = dependencies.imageVolumeInitializer
        lifecycleManager = dependencies.lifecycleManager
        logManager = dependencies.logManager
        upMenuController = dependencies.upMenuController
        pullMetadataStore = dependencies.pullMetadataStore
        resourceManager = dependencies.resourceManager
        secretReader = dependencies.secretReader
        signalProxy = dependencies.signalProxy
        statsManager = dependencies.statsManager
        topManager = dependencies.topManager
    }
}
