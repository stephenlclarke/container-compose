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
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
import Foundation

extension ComposeOrchestrator {
    /// Renders the full canonical config in a supported output format.
    func config(project: ComposeProject, format: String?) throws -> String {
        let normalizedFormat = (format ?? "yaml").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedFormat {
        case "", "json":
            return try config(project: project)
        case "yaml":
            return try configYAML(project: project)
        default:
            throw ComposeError.unsupported("config --format '\(format ?? "")'; supported formats are yaml and json")
        }
    }

    /// Returns whether the selected config projection can include service image references.
    func configOutputUsesImageDigests(options: ComposeConfigOptions) -> Bool {
        if options.quiet || options.environment {
            return false
        }
        if options.hash != nil || options.images {
            return true
        }
        if options.models || options.networks || options.profiles || options.servicesOnly || options.variables != nil || options.volumes {
            return false
        }
        return true
    }

    /// Returns an override file that pins service image tags to remote digests.
    func configImageDigestLock(project: ComposeProject, options: ComposeConfigOptions) async throws -> String {
        let selected = try selectedServices(project: project, selected: options.services)
        var services: [String: Any] = [:]
        for service in selected.sorted(by: { $0.name < $1.name }) {
            guard let image = service.image?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty else {
                continue
            }
            services[service.name] = try await [
                "image": imageReferenceWithResolvedDigest(image),
            ]
        }
        return YAMLDocumentRenderer.render(["services": services])
    }

    /// Returns a project copy with selected service image tags pinned to digests.
    func projectResolvingImageDigests(project: ComposeProject, selected: [String]) async throws -> ComposeProject {
        let selectedServices = try selectedServices(project: project, selected: selected)
        var resolvedProject = project
        for service in selectedServices {
            guard let image = service.image?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty else {
                continue
            }
            resolvedProject.services[service.name]?.image = try await imageReferenceWithResolvedDigest(image)
        }
        return resolvedProject
    }

    /// Returns `reference` with an explicit tag and remote manifest digest.
    func imageReferenceWithResolvedDigest(_ reference: String) async throws -> String {
        if reference.contains("@") {
            return reference
        }
        let taggedReference = try imageReferenceWithDefaultTag(reference)
        let digest = try await imageManager.imageDigest(taggedReference)
        return "\(taggedReference)@\(digest)"
    }

    /// Returns a display reference with a default `latest` tag when no tag or digest is present.
    func imageReferenceWithDefaultTag(_ reference: String) throws -> String {
        let parsed = try Reference.parse(reference)
        parsed.normalize()
        return parsed.description
    }

    /// Returns images referenced by selected services, including generated build tags.
    func configImages(project: ComposeProject, services: [String]) throws -> [String] {
        let selected = try selectedServices(project: project, selected: services)
        return Array(Set(selected.compactMap { serviceImage(project: project, service: $0) })).sorted()
    }

    /// Returns the interpolation environment loaded by compose-go.
    func configEnvironment(project: ComposeProject) -> String {
        lineProjection(project.environment.keys.sorted().map { key in
            "\(key)=\(project.environment[key] ?? "")"
        })
    }

    /// Returns the interpolation variable table loaded by compose-go.
    func configVariables(_ variables: [ComposeVariable]) -> String {
        let rows = [["NAME", "REQUIRED", "DEFAULT VALUE", "ALTERNATE VALUE"]]
            + variables.map { variable in
                [
                    variable.name,
                    variable.required ? "true" : "false",
                    variable.defaultValue,
                    variable.alternateValue,
                ]
            }
        return renderTable(rows)
    }

    /// Returns service config hashes using the same fingerprint as recreate decisions.
    func configHashes(project: ComposeProject, services: [String], hash: String) throws -> String {
        let requestedHash = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected: [ComposeService]
        if requestedHash.isEmpty || requestedHash == "*" {
            selected = try selectedServices(project: project, selected: services)
        } else {
            if !services.isEmpty, !services.contains(requestedHash) {
                throw ComposeError.invalidProject("config --hash '\(requestedHash)' is outside the selected services")
            }
            selected = try selectedServices(project: project, selected: [requestedHash])
        }
        let lines = try selected.sorted(by: { $0.name < $1.name }).map { service in
            try "\(service.name) \(configHash(project: project, service: service))"
        }
        return lineProjection(lines)
    }

    /// Renders one value per line, matching Docker Compose projection commands.
    func lineProjection(_ values: [String]) -> String {
        guard !values.isEmpty else {
            return ""
        }
        return values.joined(separator: "\n")
    }

    /// Builds the Compose-owned typed projection that will feed direct
    /// apple/container service creation once image/kernel resolution is wired.
    func serviceCreatePlan(
        project: ComposeProject,
        service: ComposeService,
        runtimeName: String,
        planOptions: ContainerServiceCreatePlanOptions,
        externalVolumeMounts: ExternalVolumeMounts,
        labelOverrides: [ComposeLabelOverride],
        imageHealthCheckCache: ComposeImageHealthCheckCache?,
    ) async throws -> ContainerServiceCreatePlan {
        guard let image = serviceImage(project: project, service: service) else {
            throw ComposeError.invalidProject("service '\(service.name)' has no image or build")
        }
        let baseProcess = serviceCreateBaseProcess(service: service)
        let healthCheck = planOptions.resolveHealthCheck
            ? try await runtimeHealthCheck(
                project: project,
                service: service,
                cache: imageHealthCheckCache,
                baseProcess: baseProcess,
            )
            : nil
        let restartPolicy = planOptions.includeRestartPolicy
            ? try runtimeRestartPolicy(service: service) ?? .no
            : .no
        let identity = try ContainerServiceCreateIdentity(
            name: runtimeName,
            imageReference: image,
            oneOff: planOptions.oneOff,
            autoRemove: planOptions.autoRemove,
            labels: serviceCreateLabels(
                project: project,
                service: service,
                oneOff: planOptions.oneOff,
                externalVolumeMounts: externalVolumeMounts,
                labelOverrides: labelOverrides,
            ),
        )
        var runtime = ContainerServiceCreateRuntime()
        runtime.initProcess = baseProcess
        runtime.logging = try runtimeLogConfiguration(service: service)
        runtime.healthCheck = healthCheck
        runtime.restartPolicy = restartPolicy
        runtime.hostname = try runtimeHostnameArgument(service: service)
        runtime.domainname = try runtimeDomainnameArgument(service: service)
        runtime.hosts = try runtimeHostEntries(service: service)
        runtime.sysctls = try runtimeSysctls(service: service)
        runtime.blockIO = try runtimeBlockIO(service: service)
        return ContainerServiceCreatePlan(identity: identity, runtime: runtime)
    }

    /// Resolves an optional service selection into deterministic services.
    func selectedServices(project: ComposeProject, selected: [String]) throws -> [ComposeService] {
        if selected.isEmpty {
            return project.services.values.sorted { $0.name < $1.name }
        }
        return try selected.map { name in
            guard let service = project.services[name] else {
                throw ComposeError.invalidProject("unknown service '\(name)'")
            }
            return service
        }
    }

    /// Emits the Compose-owned direct runtime event read used by dry-run output.
    func emitComposeRuntimeEventRead(since: String?, until: String?) {
        emitComposeRuntimeOperation(composeRuntimeEventReadArguments(since: since, until: until))
    }

    /// Builds the Compose-owned runtime event read for dry-run output.
    func composeRuntimeEventReadArguments(since: String?, until: String?) -> [String] {
        var args = ["events"]
        if let since, !since.isEmpty {
            args.append(contentsOf: ["--since", since])
        }
        if let until, !until.isEmpty {
            args.append(contentsOf: ["--until", until])
        }
        return args
    }

    /// Adds active legacy-link aliases to the target services they reference.
    func projectByApplyingLinks(project: ComposeProject, activeServiceNames: Set<String>) throws -> ComposeProject {
        var result = project
        var projectedAliases: [ComposeProjectedLinkAlias] = []
        for sourceName in activeServiceNames.sorted() {
            guard let source = project.services[sourceName] else {
                continue
            }
            for link in try serviceLinkReferences(service: source, project: project) where activeServiceNames.contains(link.serviceName) {
                guard var target = result.services[link.serviceName] else {
                    continue
                }
                let network = try linkNetwork(source: source, target: target, link: link)
                var aliasesByNetwork = target.networkAliases ?? [:]
                var aliases = aliasesByNetwork[network] ?? []
                projectedAliases.append(ComposeProjectedLinkAlias(serviceName: target.name, network: network, alias: link.alias))
                if !aliases.contains(link.alias) {
                    aliases.append(link.alias)
                }
                aliasesByNetwork[network] = aliases
                target.networkAliases = aliasesByNetwork
                result.services[target.name] = target
            }
        }
        try validateProjectedLinkAliases(
            project: project,
            aliases: projectedAliases,
            activeServiceNames: activeServiceNames,
        )
        return result
    }

    /// Resolves Compose `external_links` into runtime host entries for the supported local subset.
    func projectByResolvingExternalLinks(project: ComposeProject, services: [ComposeService]) async throws -> ComposeProject {
        var result = project
        for serviceReference in services.sorted(by: { $0.name < $1.name }) {
            guard var service = result.services[serviceReference.name] else {
                continue
            }
            let hostEntries = try await runtimeExternalLinkHostArguments(project: result, service: service)
            guard !hostEntries.isEmpty else {
                continue
            }
            service.extraHosts = (service.extraHosts ?? []) + hostEntries
            result.services[service.name] = service
        }
        return result
    }

    /// Returns generated `extra_hosts`-compatible values for Compose `external_links`.
    func runtimeExternalLinkHostArguments(project: ComposeProject, service: ComposeService) async throws -> [String] {
        let references = try serviceExternalLinkReferences(service: service)
        guard !references.isEmpty else {
            return []
        }
        let network = try externalLinkRuntimeNetwork(project: project, service: service)
        var entries: [String] = []
        for reference in references {
            guard let container = try await discoveryManager.getContainer(id: reference.containerName) else {
                throw ComposeError.invalidProject("service '\(service.name)' external_links references missing container '\(reference.containerName)'")
            }
            let attachments = container.networks.filter { $0.network == network }
            guard attachments.count == 1, let attachment = attachments.first else {
                throw ComposeError.unsupported("service '\(service.name)' external_links to '\(reference.containerName)'; external container must share exactly one runtime network with the service")
            }
            entries.append("\(reference.alias)=\(attachment.ipv4Address)")
        }
        return entries
    }

    /// Returns the single runtime network that can safely back legacy external links.
    func externalLinkRuntimeNetwork(project: ComposeProject, service: ComposeService) throws -> String {
        let networks = service.networks ?? []
        guard networks.count == 1, let network = networks.first else {
            throw ComposeError.unsupported("service '\(service.name)' uses external_links; external links require exactly one Compose network until apple/container exposes source-scoped DNS links")
        }
        return networkRuntimeName(project: project, composeName: network)
    }

    /// Returns the single shared network a legacy link can use.
    func linkNetwork(source: ComposeService, target: ComposeService, link: ComposeLinkReference) throws -> String {
        let sourceNetworks = Set(source.networks ?? [])
        let targetNetworks = Set(target.networks ?? [])
        let sharedNetworks = sourceNetworks.intersection(targetNetworks).sorted()
        guard sharedNetworks.count == 1 else {
            throw ComposeError.unsupported("service '\(source.name)' links to '\(link.serviceName)'; links require both services to share exactly one Compose network until apple/container exposes source-scoped DNS links")
        }
        return sharedNetworks[0]
    }

    /// Rejects projected link aliases the current apple/container DNS lookup cannot disambiguate.
    func validateProjectedLinkAliases(
        project: ComposeProject,
        aliases projectedAliases: [ComposeProjectedLinkAlias],
        activeServiceNames: Set<String>,
    ) throws {
        var ownersByNetwork: [String: [String: String]] = [:]
        for projectedAlias in projectedAliases {
            if let existingOwner = ownersByNetwork[projectedAlias.network]?[projectedAlias.alias],
               existingOwner != projectedAlias.serviceName
            {
                throw ComposeError.unsupported("services '\(existingOwner)' and '\(projectedAlias.serviceName)' share network alias '\(projectedAlias.alias)' on network '\(projectedAlias.network)'; shared aliases need apple/container source-scoped DNS support")
            }
            ownersByNetwork[projectedAlias.network, default: [:]][projectedAlias.alias] = projectedAlias.serviceName

            for serviceName in activeServiceNames.sorted() where serviceName != projectedAlias.serviceName {
                guard let service = project.services[serviceName],
                      service.networks?.count == 1,
                      service.networks?.first == projectedAlias.network
                else {
                    continue
                }
                if try networkAliasValues(service: service, network: projectedAlias.network).contains(projectedAlias.alias) {
                    throw ComposeError.unsupported("services '\(service.name)' and '\(projectedAlias.serviceName)' share network alias '\(projectedAlias.alias)' on network '\(projectedAlias.network)'; shared aliases need apple/container source-scoped DNS support")
                }
            }
        }
    }
}
