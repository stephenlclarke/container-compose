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
    public var copier: ContainerCopying
    public var execManager: ContainerExecManaging
    public var exporter: ContainerExporting
    public var logManager: ContainerLogManaging
    public var upMenuController: ComposeUpMenuControlling
    public var signalProxy: ComposeSignalProxying

    public init(
        copier: ContainerCopying = ContainerClientCopier(),
        execManager: ContainerExecManaging = ContainerClientExecManager(),
        exporter: ContainerExporting = ContainerClientExporter(),
        logManager: ContainerLogManaging = ContainerClientLogManager(),
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
    public var configReader: ContainerConfigReading
    public var discoveryManager: ContainerDiscoveryManaging
    public var eventsManager: ContainerEventsManaging
    public var lifecycleManager: ContainerLifecycleManaging
    public var resourceManager: ContainerResourceManaging
    public var statsManager: ContainerStatsManaging
    public var topManager: ContainerTopManaging
    public var secretReader: ContainerSecretReading

    public init(
        configReader: ContainerConfigReading = ContainerClientConfigReader(),
        discoveryManager: ContainerDiscoveryManaging = ContainerLiveDiscoveryManager(),
        eventsManager: ContainerEventsManaging = ContainerClientEventsManager(),
        lifecycleManager: ContainerLifecycleManaging = ContainerClientLifecycleManager(),
        resourceManager: ContainerResourceManaging = ContainerClientResourceManager(),
        statsManager: ContainerStatsManaging = ContainerClientStatsManager(),
        topManager: ContainerTopManaging = ContainerClientTopManager(),
        secretReader: ContainerSecretReading = ContainerClientSecretReader(),
    ) {
        self.configReader = configReader
        self.discoveryManager = discoveryManager
        self.eventsManager = eventsManager
        self.lifecycleManager = lifecycleManager
        self.resourceManager = resourceManager
        self.statsManager = statsManager
        self.topManager = topManager
        self.secretReader = secretReader
    }

    public init(
        runner: CommandRunning,
        options: ComposeExecutionOptions,
        configReader: ContainerConfigReading = ContainerClientConfigReader(),
        eventsManager: ContainerEventsManaging = ContainerClientEventsManager(),
        lifecycleManager: ContainerLifecycleManaging = ContainerClientLifecycleManager(),
        resourceManager: ContainerResourceManaging = ContainerClientResourceManager(),
        statsManager: ContainerStatsManaging = ContainerClientStatsManager(),
        topManager: ContainerTopManaging = ContainerClientTopManager(),
        secretReader: ContainerSecretReading = ContainerClientSecretReader(),
    ) {
        self.init(
            configReader: configReader,
            discoveryManager: ContainerLiveDiscoveryManager(
                runner: runner,
                environmentLauncher: options.environmentLauncher,
                containerBinary: options.containerBinary,
            ),
            eventsManager: eventsManager,
            lifecycleManager: lifecycleManager,
            resourceManager: resourceManager,
            statsManager: statsManager,
            topManager: topManager,
            secretReader: secretReader,
        )
    }
}

/// Runtime collaborators used by the Compose orchestrator.
public struct ComposeOrchestratorDependencies: Sendable {
    public var commands: ComposeOrchestratorCommandDependencies
    public var runtime: ComposeOrchestratorRuntimeDependencies
    public var imageManager: ContainerImageManaging
    public var pullMetadataStore: ComposePullMetadataStoring

    public init(
        runner: CommandRunning = ProcessRunner(),
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
        commands: ComposeOrchestratorCommandDependencies = ComposeOrchestratorCommandDependencies(),
        runtime: ComposeOrchestratorRuntimeDependencies? = nil,
        imageManager: ContainerImageManaging = ContainerClientImageManager(),
        pullMetadataStore: ComposePullMetadataStoring = FileComposePullMetadataStore(),
    ) {
        self.commands = commands
        self.runtime = runtime ?? ComposeOrchestratorRuntimeDependencies(runner: runner, options: options)
        self.imageManager = imageManager
        self.pullMetadataStore = pullMetadataStore
    }

    public var copier: ContainerCopying {
        get { commands.copier }
        set { commands.copier = newValue }
    }

    public var configReader: ContainerConfigReading {
        get { runtime.configReader }
        set { runtime.configReader = newValue }
    }

    public var secretReader: ContainerSecretReading {
        get { runtime.secretReader }
        set { runtime.secretReader = newValue }
    }

    public var discoveryManager: ContainerDiscoveryManaging {
        get { runtime.discoveryManager }
        set { runtime.discoveryManager = newValue }
    }

    public var eventsManager: ContainerEventsManaging {
        get { runtime.eventsManager }
        set { runtime.eventsManager = newValue }
    }

    public var execManager: ContainerExecManaging {
        get { commands.execManager }
        set { commands.execManager = newValue }
    }

    public var exporter: ContainerExporting {
        get { commands.exporter }
        set { commands.exporter = newValue }
    }

    public var lifecycleManager: ContainerLifecycleManaging {
        get { runtime.lifecycleManager }
        set { runtime.lifecycleManager = newValue }
    }

    public var logManager: ContainerLogManaging {
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

    public var resourceManager: ContainerResourceManaging {
        get { runtime.resourceManager }
        set { runtime.resourceManager = newValue }
    }

    public var statsManager: ContainerStatsManaging {
        get { runtime.statsManager }
        set { runtime.statsManager = newValue }
    }

    public var topManager: ContainerTopManaging {
        get { runtime.topManager }
        set { runtime.topManager = newValue }
    }
}
