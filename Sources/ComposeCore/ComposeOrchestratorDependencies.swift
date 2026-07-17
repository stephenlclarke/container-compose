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

/// Container command collaborators used by the Compose orchestrator.
public struct ComposeOrchestratorCommandDependencies: Sendable {
    public var copier: ComposeRuntimeCopying
    public var execManager: ComposeRuntimeExecManaging
    public var exporter: ComposeRuntimeExporting
    public var logManager: ComposeRuntimeLogManaging
    public var upMenuController: ComposeUpMenuControlling
    public var signalProxy: ComposeSignalProxying

    public init(
        copier: ComposeRuntimeCopying = ComposeRuntimeProviderDefaults.copying(),
        execManager: ComposeRuntimeExecManaging = ComposeRuntimeProviderDefaults.executing(),
        exporter: ComposeRuntimeExporting = ComposeRuntimeProviderDefaults.exporting(),
        logManager: ComposeRuntimeLogManaging = ComposeRuntimeProviderDefaults.logs(),
        upMenuController: ComposeUpMenuControlling = TerminalComposeUpMenuController(),
        signalProxy: ComposeSignalProxying = DispatchComposeSignalProxy(),
    ) {
        self.copier = copier
        self.execManager = execManager
        self.exporter = exporter
        self.logManager = logManager
        self.upMenuController = upMenuController
        self.signalProxy = signalProxy
    }
}

/// Container lifecycle collaborators used by the Compose orchestrator.
public struct ComposeOrchestratorRuntimeDependencies: Sendable {
    /// Runtime collaborators that execute Compose operations.
    public struct Services: Sendable {
        public var configReader: ComposeRuntimeConfigReading
        public var eventsManager: ComposeRuntimeEventsManaging
        public var lifecycleManager: ComposeRuntimeLifecycleManaging
        public var resourceManager: ComposeRuntimeResourceManaging
        public var secretReader: ComposeRuntimeSecretReading

        public init(
            configReader: ComposeRuntimeConfigReading = ComposeRuntimeProviderDefaults.configReader(),
            eventsManager: ComposeRuntimeEventsManaging = ComposeRuntimeProviderDefaults.events(),
            lifecycleManager: ComposeRuntimeLifecycleManaging = ComposeRuntimeProviderDefaults.lifecycle(),
            resourceManager: ComposeRuntimeResourceManaging = ComposeRuntimeProviderDefaults.resources(),
            secretReader: ComposeRuntimeSecretReading = ComposeRuntimeProviderDefaults.secretReader(),
        ) {
            self.configReader = configReader
            self.eventsManager = eventsManager
            self.lifecycleManager = lifecycleManager
            self.resourceManager = resourceManager
            self.secretReader = secretReader
        }
    }

    /// Runtime collaborators that report process and resource state.
    public struct Inspection: Sendable {
        public var statsManager: ComposeRuntimeStatsManaging
        public var topManager: ComposeRuntimeTopManaging

        public init(
            statsManager: ComposeRuntimeStatsManaging = ComposeRuntimeProviderDefaults.stats(),
            topManager: ComposeRuntimeTopManaging = ComposeRuntimeProviderDefaults.top(),
        ) {
            self.statsManager = statsManager
            self.topManager = topManager
        }
    }

    public var configReader: ComposeRuntimeConfigReading
    public var discoveryManager: ComposeRuntimeDiscoveryManaging
    public var eventsManager: ComposeRuntimeEventsManaging
    public var lifecycleManager: ComposeRuntimeLifecycleManaging
    public var resourceManager: ComposeRuntimeResourceManaging
    public var statsManager: ComposeRuntimeStatsManaging
    public var topManager: ComposeRuntimeTopManaging
    public var secretReader: ComposeRuntimeSecretReading

    public init(
        services: Services = Services(),
        discoveryManager: ComposeRuntimeDiscoveryManaging = ComposeRuntimeProviderDefaults.discovery(),
        inspection: Inspection = Inspection(),
    ) {
        configReader = services.configReader
        self.discoveryManager = discoveryManager
        eventsManager = services.eventsManager
        lifecycleManager = services.lifecycleManager
        resourceManager = services.resourceManager
        statsManager = inspection.statsManager
        topManager = inspection.topManager
        secretReader = services.secretReader
    }

    public init(
        runner _: CommandRunning,
        options _: ComposeExecutionOptions,
        services: Services = Services(),
        inspection: Inspection = Inspection(),
    ) {
        self.init(
            services: services,
            discoveryManager: ComposeRuntimeProviderDefaults.discovery(),
            inspection: inspection,
        )
    }
}

/// Runtime collaborators used by the Compose orchestrator.
public struct ComposeOrchestratorDependencies: Sendable {
    public var commands: ComposeOrchestratorCommandDependencies
    public var runtime: ComposeOrchestratorRuntimeDependencies
    public var imageManager: ComposeRuntimeImageManaging
    public var pullMetadataStore: ComposePullMetadataStoring

    public init(
        runner: CommandRunning = ProcessRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
        commands: ComposeOrchestratorCommandDependencies = ComposeOrchestratorCommandDependencies(),
        runtime: ComposeOrchestratorRuntimeDependencies? = nil,
        imageManager: ComposeRuntimeImageManaging = ComposeRuntimeProviderDefaults.images(),
        pullMetadataStore: ComposePullMetadataStoring = FileComposePullMetadataStore(),
    ) {
        self.commands = commands
        self.runtime = runtime ?? ComposeOrchestratorRuntimeDependencies(runner: runner, options: options)
        self.imageManager = imageManager
        self.pullMetadataStore = pullMetadataStore
    }

    public var copier: ComposeRuntimeCopying {
        get { commands.copier }
        set { commands.copier = newValue }
    }

    public var configReader: ComposeRuntimeConfigReading {
        get { runtime.configReader }
        set { runtime.configReader = newValue }
    }

    public var secretReader: ComposeRuntimeSecretReading {
        get { runtime.secretReader }
        set { runtime.secretReader = newValue }
    }

    public var discoveryManager: ComposeRuntimeDiscoveryManaging {
        get { runtime.discoveryManager }
        set { runtime.discoveryManager = newValue }
    }

    public var eventsManager: ComposeRuntimeEventsManaging {
        get { runtime.eventsManager }
        set { runtime.eventsManager = newValue }
    }

    public var execManager: ComposeRuntimeExecManaging {
        get { commands.execManager }
        set { commands.execManager = newValue }
    }

    public var exporter: ComposeRuntimeExporting {
        get { commands.exporter }
        set { commands.exporter = newValue }
    }

    public var lifecycleManager: ComposeRuntimeLifecycleManaging {
        get { runtime.lifecycleManager }
        set { runtime.lifecycleManager = newValue }
    }

    public var logManager: ComposeRuntimeLogManaging {
        get { commands.logManager }
        set { commands.logManager = newValue }
    }

    public var upMenuController: ComposeUpMenuControlling {
        get { commands.upMenuController }
        set { commands.upMenuController = newValue }
    }

    public var signalProxy: ComposeSignalProxying {
        get { commands.signalProxy }
        set { commands.signalProxy = newValue }
    }

    public var resourceManager: ComposeRuntimeResourceManaging {
        get { runtime.resourceManager }
        set { runtime.resourceManager = newValue }
    }

    public var statsManager: ComposeRuntimeStatsManaging {
        get { runtime.statsManager }
        set { runtime.statsManager = newValue }
    }

    public var topManager: ComposeRuntimeTopManaging {
        get { runtime.topManager }
        set { runtime.topManager = newValue }
    }
}
