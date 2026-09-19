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

extension ComposeOrchestrator {
    /// Runs a Compose-owned progress activity unless output was explicitly quieted.
    func progressActivity<T>(
        _ message: String,
        quiet: Bool,
        emitsExternalOutput: Bool = false,
        operation: () async throws -> T
    ) async throws -> T {
        if quiet || options.dryRun {
            return try await operation()
        }
        if emitsExternalOutput {
            return try await options.progress.activityWithExternalOutput(message, operation: operation)
        }
        return try await options.progress.activity(message, operation: operation)
    }

    /// Builds the `container run` argument vector for a service.
    func runArguments(
        project: ComposeProject,
        service: ComposeService,
        options run: RunArgumentOptions = RunArgumentOptions(),
        externalVolumeMounts: ExternalVolumeMounts = [:],
        imageHealthCheckCache: ComposeImageHealthCheckCache? = nil
    ) async throws -> [String] {
        try await serviceLaunchPlan(
            project: project, service: service, options: run,
            externalVolumeMounts: externalVolumeMounts, imageHealthCheckCache: imageHealthCheckCache
        ).arguments
    }

    /// Resolves once for both the existing CLI and the typed provider handoff.
    func serviceLaunchPlan(
        project: ComposeProject,
        service: ComposeService,
        options run: RunArgumentOptions = RunArgumentOptions(),
        externalVolumeMounts: ExternalVolumeMounts = [:],
        imageHealthCheckCache: ComposeImageHealthCheckCache? = nil
    ) async throws -> ContainerServiceLaunchPlan {
        var args = [run.command]
        let runtimeName: String = if let containerNameOverride = run.containerNameOverride {
            slug(containerNameOverride)
        } else if let containerIndex = run.containerIndex {
            try serviceContainerName(project: project, service: service, index: containerIndex)
        } else {
            containerName(project: project, service: service, oneOff: run.oneOff)
        }
        var createPlan = try await serviceCreatePlan(request: ServiceCreatePlanRequest(
            project: project,
            service: service,
            runtimeName: runtimeName,
            options: ContainerServiceCreatePlanOptions(
                name: runtimeName,
                oneOff: run.oneOff,
                autoRemove: run.remove,
                includeRestartPolicy: !run.oneOff,
                resolveHealthCheck: !options.dryRun
            ),
            externalVolumeMounts: externalVolumeMounts,
            labelOverrides: run.labelOverrides,
            imageHealthCheckCache: imageHealthCheckCache
        ))
        createPlan.environmentFiles = run.envFiles
        createPlan.detach = run.detach
        let metadataService = service.selectingImage(createPlan.imageSelection)
        args.append(contentsOf: ["--name", runtimeName])
        if createPlan.detach {
            args.append("--detach")
        }
        if run.remove {
            args.append("--rm")
        }
        if createPlan.launchOptions.useEngineAPISocket {
            args.append("--engine-api-socket")
        }

        for label in try serviceLabels(
            project: project,
            service: service,
            oneOff: run.oneOff,
            externalVolumeMounts: externalVolumeMounts,
            materializedConfigSecretRoot: options.materializedConfigSecretDirectory
        ) {
            args.append(contentsOf: ["--label", label])
        }
        let effectiveLabels = try effectiveServiceLabels(project: project, service: service)
        let overriddenLabelKeys = Set(run.labelOverrides.map(\.key))
        let effectiveAnnotations = try effectiveServiceAnnotations(service: service)
        for (key, value) in effectiveLabels.sorted(by: { $0.key < $1.key }) where !overriddenLabelKeys.contains(key) {
            args.append(contentsOf: ["--label", "\(key)=\(value)"])
        }
        for (key, value) in effectiveAnnotations.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--annotation", "\(key)=\(value)"])
        }
        for port in createPlan.exposedPorts {
            args.append(contentsOf: ["--expose", port])
        }
        for label in run.labelOverrides {
            args.append(contentsOf: ["--label", label.rawValue])
        }
        if !options.runtimeCapabilities.supportsLoggingDriversV1 || options.dryRun {
            if let logDriver = try runtimeLogDriverArgument(service: service) {
                args.append(contentsOf: ["--log-driver", logDriver])
            }
            try args.append(contentsOf: runtimeLogOptionArguments(service: service))
        }
        try await args.append(contentsOf: runtimeHealthCheckArguments(
            project: project,
            service: metadataService,
            cache: imageHealthCheckCache
        ))
        if !run.oneOff, let restartPolicy = try runtimeRestartPolicyArguments(service: service) {
            args.append(contentsOf: restartPolicy.arguments)
        }
        for (key, value) in createPlan.processOverrides.environment.sorted(by: { $0.key < $1.key }) {
            if let value {
                args.append(contentsOf: ["--env", "\(key)=\(value)"])
            } else {
                args.append(contentsOf: ["--env", key])
            }
        }
        for envFile in createPlan.environmentFiles {
            args.append(contentsOf: ["--env-file", envFile])
        }
        let publishedPorts = try publishedPortBindings(
            ports: run.publishedPorts ?? service.ports ?? [],
            serviceName: service.name,
            replicaIndex: run.containerIndex,
            replicaCount: run.replicaCount
        )
        createPlan.publishedPorts = publishedPorts
        for port in publishedPorts {
            args.append(contentsOf: ["--publish", publishedPortArgument(port)])
        }
        let mountContext = MountRenderContext(
            project: project,
            service: service,
            containerName: runtimeName,
            oneOff: run.oneOff,
            containerIndex: run.containerIndex
        )
        if !options.dryRun {
            try await materializeExternalConfigSecrets(project: project, service: service)
        }
        let mounts = try effectiveServiceVolumes(
            project: project,
            service: service,
            externalVolumeMounts: externalVolumeMounts,
            materializedConfigSecretRoot: options.materializedConfigSecretDirectory,
            materializeConfigSecrets: !options.dryRun
        )
        let composeDeclaredMounts = try effectiveServiceVolumes(
            project: project,
            service: service,
            materializedConfigSecretRoot: options.materializedConfigSecretDirectory
        )
        try prepareBindMountSources(project: project, service: service, mounts: composeDeclaredMounts)
        let imageVolumeMounts = try await prepareRuntimeImageVolumes(
            project: project,
            service: metadataService,
            context: mountContext,
            mounts: mounts,
        )
        let resolvedMounts = try (mounts + imageVolumeMounts).map {
            try resolvedMount($0, context: mountContext)
        }
        createPlan.resolvedMounts = resolvedMounts
        for mount in resolvedMounts {
            try appendResolvedMount(mount, args: &args)
        }
        for tmpfs in createPlan.tmpfs {
            args.append(contentsOf: ["--tmpfs", tmpfs])
        }
        for attachment in createPlan.networkAttachments {
            args.append(contentsOf: ["--network", attachment.nativeArgument])
        }
        if let isolation = createPlan.launchOptions.namespaces.isolation {
            args.append(contentsOf: ["--isolation", isolation])
        }
        if let pid = createPlan.launchOptions.namespaces.pid {
            args.append(contentsOf: ["--pid", pid])
        }
        if let cgroupNamespace = createPlan.launchOptions.namespaces.cgroup {
            args.append(contentsOf: ["--cgroupns", cgroupNamespace])
        }
        if let ipcNamespace = createPlan.launchOptions.namespaces.ipc {
            args.append(contentsOf: ["--ipc", ipcNamespace])
        }
        if let utsNamespace = createPlan.launchOptions.namespaces.uts {
            args.append(contentsOf: ["--uts", utsNamespace])
        }
        if let userNamespace = createPlan.launchOptions.namespaces.user {
            args.append(contentsOf: ["--userns", userNamespace])
        }
        if let platform = createPlan.launchOptions.platform {
            args.append(contentsOf: ["--platform", platform])
        }
        if let runtime = createPlan.launchOptions.runtime {
            args.append(contentsOf: ["--runtime", runtime])
        }
        if let workingDir = createPlan.processOverrides.workingDirectory {
            args.append(contentsOf: ["--workdir", workingDir])
        }
        if let user = createPlan.processOverrides.user {
            args.append(contentsOf: ["--user", user])
        }
        for group in createPlan.launchOptions.security.supplementalGroups {
            args.append(contentsOf: ["--group-add", group])
        }
        if let oomScoreAdj = createPlan.launchOptions.resources.oomScoreAdjustment {
            args.append(contentsOf: ["--oom-score-adj", "\(oomScoreAdj)"])
        }
        if createPlan.processOverrides.terminal {
            args.append("--tty")
        }
        if createPlan.processOverrides.openStandardInput {
            args.append("--interactive")
        }
        if createPlan.launchOptions.security.privileged {
            args.append("--privileged")
        }
        if let hostname = createPlan.hostname {
            args.append(contentsOf: ["--hostname", hostname])
        }
        if let domainName = createPlan.domainname {
            args.append(contentsOf: ["--domainname", domainName])
        }
        for cap in createPlan.launchOptions.security.capabilitiesAdded {
            args.append(contentsOf: ["--cap-add", cap])
        }
        for cap in createPlan.launchOptions.security.capabilitiesDropped {
            args.append(contentsOf: ["--cap-drop", cap])
        }
        for securityOption in createPlan.launchOptions.security.options {
            args.append(contentsOf: ["--security-opt", securityOption])
        }
        if let stopSignal = createPlan.launchOptions.stopSignal {
            args.append(contentsOf: ["--stop-signal", stopSignal])
        }
        if let stopTimeout = createPlan.launchOptions.stopTimeoutSeconds {
            args.append(contentsOf: ["--stop-timeout", "\(stopTimeout)"])
        }
        for dns in createPlan.launchOptions.dnsServers {
            args.append(contentsOf: ["--dns", dns])
        }
        for dnsSearch in createPlan.launchOptions.dnsSearch {
            args.append(contentsOf: ["--dns-search", dnsSearch])
        }
        for dnsOption in createPlan.launchOptions.dnsOptions {
            args.append(contentsOf: ["--dns-option", dnsOption])
        }
        for extraHost in try runtimeExtraHostArguments(service: service) {
            args.append(contentsOf: ["--add-host", extraHost])
        }
        for sysctl in try runtimeSysctlArguments(service: service) {
            args.append(contentsOf: ["--sysctl", sysctl])
        }
        for blkio in try runtimeBlkioArguments(service: service) {
            args.append(contentsOf: ["--blkio", blkio])
        }
        for rule in createPlan.launchOptions.security.deviceCgroupRules {
            args.append(contentsOf: ["--device-cgroup-rule", rule])
        }
        for device in createPlan.launchOptions.resources.deviceMappings {
            args.append(contentsOf: ["--device", device])
        }
        for gpu in createPlan.launchOptions.resources.gpuRequests {
            args.append(contentsOf: ["--gpus", gpu])
        }
        if let pidsLimit = createPlan.launchOptions.resources.pidsLimit {
            args.append(contentsOf: ["--pids-limit", "\(pidsLimit)"])
        }
        if let cpuShares = createPlan.cpuShares {
            args.append(contentsOf: ["--cpu-shares", "\(cpuShares)"])
        }
        if let cgroupParent = createPlan.cgroupParent {
            args.append(contentsOf: ["--cgroup-parent", cgroupParent])
        }
        if let cpuSet = createPlan.launchOptions.resources.cpuSet {
            args.append(contentsOf: ["--cpuset-cpus", cpuSet])
        }
        if let cpuPeriod = createPlan.launchOptions.resources.cpuPeriod {
            args.append(contentsOf: ["--cpu-period", "\(cpuPeriod)"])
        }
        if let cpuQuota = createPlan.launchOptions.resources.cpuQuota {
            args.append(contentsOf: ["--cpu-quota", "\(cpuQuota)"])
        }
        if let memLimit = createPlan.launchOptions.resources.memoryLimit {
            args.append(contentsOf: ["--memory", memLimit])
        }
        if let memoryReservationInBytes = createPlan.memoryReservationInBytes {
            args.append(contentsOf: ["--memory-reservation", "\(memoryReservationInBytes)"])
        }
        if let memorySwapLimitInBytes = createPlan.memorySwapLimitInBytes {
            args.append(contentsOf: ["--memory-swap", "\(memorySwapLimitInBytes)"])
        }
        if let cpus = createPlan.launchOptions.resources.cpus {
            args.append(contentsOf: ["--cpus", cpus])
        }
        if let shmSize = createPlan.launchOptions.resources.sharedMemorySize {
            args.append(contentsOf: ["--shm-size", shmSize])
        }
        for ulimit in createPlan.launchOptions.resources.ulimits {
            args.append(contentsOf: ["--ulimit", ulimit])
        }
        var entrypointCommandPrefix: [String] = []
        if let entrypoint = createPlan.processOverrides.entrypoint {
            if entrypoint.isEmpty {
                args.append("--clear-entrypoint")
            } else {
                args.append(contentsOf: ["--entrypoint", entrypoint[0]])
                entrypointCommandPrefix = Array(entrypoint.dropFirst())
            }
        }
        if createPlan.launchOptions.security.readOnlyRootFilesystem {
            args.append("--read-only")
        }
        if createPlan.launchOptions.initEnabled {
            args.append("--init")
        }
        if let initImage = createPlan.launchOptions.initImage {
            args.append(contentsOf: ["--init-image", initImage])
        }

        guard let image = serviceImage(project: project, service: service) else {
            throw ComposeError.invalidProject("service '\(service.name)' has no image or build")
        }
        args.append(image)
        args.append(contentsOf: entrypointCommandPrefix)
        args.append(contentsOf: createPlan.processOverrides.command ?? [])
        return ContainerServiceLaunchPlan(arguments: args, configuration: createPlan)
    }

    /// Rewrites `SERVICE:/path` copy operands to the matching service container.
    func copyEndpoint(
        _ argument: String,
        project: ComposeProject,
        index: Int,
        includeOneOff: Bool
    ) async throws -> ComposeCopyEndpoint {
        guard let delimiter = argument.firstIndex(of: ":") else {
            return .local(argument)
        }
        let serviceName = String(argument[..<delimiter])
        guard isCopyServiceReference(serviceName) else {
            return .local(argument)
        }
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }
        let rawPath = String(argument[argument.index(after: delimiter)...])
        guard !rawPath.isEmpty else {
            throw ComposeError.invalidProject("container copy path for service '\(serviceName)' cannot be empty")
        }
        let path = Self.normalizedCopyContainerPath(rawPath)
        if includeOneOff {
            let containers = try await copyTargets(project: project, service: service, path: path, index: index)
            guard !containers.isEmpty else {
                throw ComposeError.invalidProject("no container found for service '\(serviceName)'")
            }
            return .containers(containers)
        }
        let id = try await serviceContainerID(project: project, service: service, index: index)
        return .containers([ComposeCopyContainerTarget(id: id, path: path)])
    }

    private static func normalizedCopyContainerPath(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/\(path)"
    }

    /// Returns service and one-off containers that can be targeted by `cp --all`.
    func copyTargets(project: ComposeProject, service: ComposeService, path: String, index: Int) async throws -> [ComposeCopyContainerTarget] {
        let containers = try await projectContainers(projectName: project.name, all: true)
            .filter { $0.serviceName == service.name }
            .sorted(by: compareCopyTargetContainers)

        if index == 1 {
            return containers.map { ComposeCopyContainerTarget(id: $0.runtimeIdentifier, path: path) }
        }

        let indexedID = try serviceContainerName(project: project, service: service, index: index)
        guard serviceContainerExists(containers, service: service, id: indexedID) else {
            throw ComposeError.invalidProject("service '\(service.name)' container '\(indexedID)' does not exist")
        }
        return containers
            .filter { $0.displayName == indexedID || $0.bundleKey == indexedID || $0.isOneOff }
            .map { ComposeCopyContainerTarget(id: $0.runtimeIdentifier, path: path) }
    }

    /// Returns whether a copy operand prefix has Compose service-reference shape.
    func isCopyServiceReference(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && value != "." && value != ".."
    }

    /// Starts dependency services for `compose run` before the one-off container.
    func startDependencyServices(
        project: ComposeProject,
        services: [ComposeService],
        externalVolumeMounts: ExternalVolumeMounts = [:],
        imageHealthCheckCache: ComposeImageHealthCheckCache = ComposeImageHealthCheckCache()
    ) async throws -> ComposeProject {
        var workingProject = project
        try await applyPullPolicy(nil, project: workingProject, services: services)
        for serviceReference in services {
            let service = workingProject.services[serviceReference.name] ?? serviceReference
            if service.provider != nil {
                let variables = try await runProvider(project: workingProject, service: service, action: .up)
                if !variables.isEmpty {
                    workingProject = projectByInjectingProviderEnvironment(
                        project: workingProject,
                        providerServiceName: service.name,
                        variables: variables
                    )
                }
                continue
            }

            if service.image == nil, service.pullPolicy != "build", service.build != nil {
                try await build(project: workingProject, services: [service.name], noCache: false)
            }

            let name = containerName(project: workingProject, service: service, oneOff: false)
            let existing = try await inspectContainer(name)
            if let existing, try existing.configHash == configHash(
                project: workingProject,
                service: service,
                externalVolumeMounts: externalVolumeMounts,
                materializedConfigSecretRoot: options.materializedConfigSecretDirectory
            ) {
                options.emit("compose: reusing existing container \(name)")
                if hasPreStartHooks(service) {
                    try await startServiceTargets(
                        project: workingProject,
                        service: service,
                        targets: [
                            ServiceContainerTarget(
                                service: service,
                                index: 1,
                                name: name,
                                status: existing.status,
                            ),
                        ],
                    )
                }
                continue
            }
            if existing != nil {
                try await stopContainer(service: service, containerName: name)
                try await deleteContainer(name)
            }

            let arguments = try await runArguments(
                project: workingProject,
                service: service,
                options: RunArgumentOptions {
                    $0.command = hasPreStartHooks(service) ? "create" : "run"
                    $0.detach = !hasPreStartHooks(service)
                },
                externalVolumeMounts: externalVolumeMounts,
                imageHealthCheckCache: imageHealthCheckCache
            )
            try await runContainer(
                arguments,
                logging: try runtimeLogConfiguration(service: service)
            )
            if hasPreStartHooks(service) {
                try await startServiceTargets(
                    project: workingProject,
                    service: service,
                    targets: [
                        ServiceContainerTarget(
                            service: service,
                            index: 1,
                            name: name,
                            status: "created",
                        ),
                    ],
                )
            } else {
                try await runPostStartHooks(service: service, containerID: name)
            }
        }
        return workingProject
    }

    /// Removes images referenced by services according to `down --rmi`.
    func removeImages(project: ComposeProject, services: [ComposeService], policy: DownImageRemovalPolicy) async throws {
        for image in removableDownImages(project: project, services: services, policy: policy) {
            let args = ["image", "delete", "--force", image]
            if options.dryRun {
                try await runContainer(args, check: false)
            } else {
                try await imageManager.deleteImage(image, force: true, emit: options.emit)
            }
        }
    }
}
