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
    /// Translates one Compose build section into a `container build` command.
    func buildService(project: ComposeProject, service: ComposeService, options buildOptions: ComposeBuildOptions) async throws {
        guard let build = service.build else {
            return
        }
        try validateBuildSupport(service: service)
        var inlineDockerfileDirectory: URL?
        defer {
            if let inlineDockerfileDirectory {
                try? FileManager.default.removeItem(at: inlineDockerfileDirectory)
            }
        }
        var args = ["build"]
        if let builder = buildOptions.builder?.trimmingCharacters(in: .whitespacesAndNewlines), !builder.isEmpty {
            args.append(contentsOf: ["--builder", builder])
        }
        guard let image = serviceImage(project: project, service: service) else {
            throw ComposeError.invalidProject("service '\(service.name)' has no image or build")
        }
        args.append(contentsOf: ["--tag", image])
        for tag in build.tags ?? [] where !tag.isEmpty && tag != image {
            args.append(contentsOf: ["--tag", tag])
        }
        if let dockerfile = nonEmpty(build.dockerfile) {
            if nonEmpty(build.dockerfileInline) != nil {
                throw ComposeError.invalidProject("service '\(service.name)' cannot define both dockerfile and dockerfile_inline")
            }
            args.append(contentsOf: ["--file", buildDockerfilePath(dockerfile, build: build, project: project)])
        } else if let dockerfileInline = nonEmpty(build.dockerfileInline) {
            let dockerfileURL = try materializeInlineDockerfile(project: project, service: service, contents: dockerfileInline)
            inlineDockerfileDirectory = dockerfileURL.deletingLastPathComponent()
            args.append(contentsOf: ["--file", dockerfileURL.path])
        }
        if let target = build.target, !target.isEmpty {
            args.append(contentsOf: ["--target", target])
        }
        if buildOptions.noCache || build.noCache == true {
            args.append("--no-cache")
        }
        if buildOptions.check {
            args.append("--check")
        }
        if buildOptions.pull || build.pull == true {
            args.append("--pull")
        }
        if buildOptions.quiet {
            args.append("--quiet")
        }
        if let memory = buildOptions.memory?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
            args.append(contentsOf: ["--memory", memory])
        }
        for platform in build.platforms ?? [] where !platform.isEmpty {
            args.append(contentsOf: ["--platform", platform])
        }
        for cacheSource in build.cacheFrom ?? [] where !cacheSource.isEmpty {
            args.append(contentsOf: ["--cache-in", cacheSource])
        }
        for cacheDestination in build.cacheTo ?? [] where !cacheDestination.isEmpty {
            args.append(contentsOf: ["--cache-out", cacheDestination])
        }
        for (name, source) in try buildContextArguments(project: project, build: build).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--build-context", "\(name)=\(source)"])
        }
        for entitlement in build.entitlements ?? [] where !entitlement.isEmpty {
            args.append(contentsOf: ["--allow", entitlement])
        }
        for extraHost in build.extraHosts ?? [] where !extraHost.isEmpty {
            args.append(contentsOf: ["--add-host", extraHost])
        }
        if let network = nonEmpty(build.network) {
            args.append(contentsOf: ["--network", network])
        }
        if build.privileged == true {
            args.append("--privileged")
        }
        if let shmSize = nonEmpty(build.shmSize) {
            args.append(contentsOf: ["--shm-size", shmSize])
        }
        for ulimit in build.ulimits ?? [] where !ulimit.isEmpty {
            args.append(contentsOf: ["--ulimit", ulimit])
        }
        for (key, value) in (build.labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--label", "\(key)=\(value)"])
        }
        for secret in build.secrets ?? [] {
            try args.append(contentsOf: ["--secret", buildSecretArgument(secret)])
        }
        for ssh in buildSSHValues(build: build, options: buildOptions) {
            args.append(contentsOf: ["--ssh", ssh])
        }
        for attestation in buildAttestationArguments(build: build, options: buildOptions) {
            args.append(contentsOf: [attestation.flag, attestation.value])
        }
        for (key, value) in (build.args ?? [:]).sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--build-arg", "\(key)=\(value)"])
        }
        for buildArgument in buildOptions.buildArguments where !buildArgument.isEmpty {
            args.append(contentsOf: ["--build-arg", buildArgument])
        }
        args.append(containerBuildContext(build.context, project: project))
        try await runContainer(args)
    }

    /// Returns selected build services after runtime and `additional_contexts`
    /// service dependencies needed by the build graph.
    func orderedBuildServices(
        project: ComposeProject,
        selected: [String],
        includeRuntimeDependencies: Bool
    ) throws -> [ComposeService] {
        let selectedSet = Set(selected)
        var visiting = Set<String>()
        var visited = Set<String>()
        var ordered: [ComposeService] = []

        func visit(_ name: String) throws {
            if visited.contains(name) {
                return
            }
            if visiting.contains(name) {
                throw ComposeError.invalidProject("build dependency cycle involving '\(name)'")
            }
            guard let service = project.services[name] else {
                throw ComposeError.invalidProject("unknown service '\(name)'")
            }
            visiting.insert(name)
            if includeRuntimeDependencies {
                for (dependency, metadata) in serviceDependencies(service) {
                    if metadata.required == false, project.services[dependency] == nil {
                        continue
                    }
                    try visit(dependency)
                }
            }
            for dependency in try buildAdditionalContextServiceNames(build: service.build) {
                guard project.services[dependency] != nil else {
                    throw ComposeError.invalidProject("build additional_contexts references unknown service '\(dependency)'")
                }
                try visit(dependency)
            }
            visiting.remove(name)
            visited.insert(name)
            ordered.append(service)
        }

        let roots = selected.isEmpty ? project.services.keys.sorted() : selectedSet.sorted()
        for name in roots {
            try visit(name)
        }
        return ordered
    }

    /// Resolves Compose `dockerfile` relative to the build context for apple/container.
    func buildDockerfilePath(_ dockerfile: String, build: ComposeBuild, project: ComposeProject) -> String {
        if (dockerfile as NSString).isAbsolutePath {
            return URL(fileURLWithPath: dockerfile).standardizedFileURL.path
        }
        let context = containerBuildContext(build.context, project: project)
        guard !context.contains("://") else {
            return dockerfile
        }
        return URL(fileURLWithPath: context, isDirectory: true)
            .appendingPathComponent(dockerfile)
            .standardizedFileURL
            .path
    }

    /// Resolves local Compose build contexts before `container build` handoff.
    func containerBuildContext(_ context: String?, project: ComposeProject) -> String {
        guard let context = nonEmpty(context) else {
            return absoluteProjectPath(".", project: project)
        }
        guard !context.contains("://") else {
            return context
        }
        return absoluteProjectPath(context, project: project)
    }

    /// Writes Compose `dockerfile_inline` content to a temporary Dockerfile for apple/container build.
    func materializeInlineDockerfile(project: ComposeProject, service: ComposeService, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-\(project.name)-\(service.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dockerfile = directory.appendingPathComponent("Dockerfile", isDirectory: false)
        try contents.write(to: dockerfile, atomically: true, encoding: .utf8)
        return dockerfile
    }

    /// Renders Docker Buildx bake JSON for `compose build --print`.
    func renderBuildBakeFile(project: ComposeProject, services: [ComposeService], options buildOptions: ComposeBuildOptions) throws -> String {
        let targets = try services.compactMap { service -> ComposeBuildBakeTargetEntry? in
            guard service.build != nil else {
                return nil
            }
            return try ComposeBuildBakeTargetEntry(
                name: service.name,
                target: buildBakeTarget(project: project, service: service, options: buildOptions),
            )
        }
        let bakeFile = ComposeBuildBakeFile(
            group: ["default": ComposeBuildBakeGroup(targets: targets.map(\.name))],
            target: Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0.target) }),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bakeFile)
        return String(decoding: data, as: UTF8.self)
    }

    /// Converts one Compose build section into a Buildx bake target.
    func buildBakeTarget(project: ComposeProject, service: ComposeService, options buildOptions: ComposeBuildOptions) throws -> ComposeBuildBakeTarget {
        guard let build = service.build else {
            throw ComposeError.invalidProject("service '\(service.name)' has no build section")
        }
        try validateBuildSupport(service: service)
        if nonEmpty(build.dockerfile) != nil, nonEmpty(build.dockerfileInline) != nil {
            throw ComposeError.invalidProject("service '\(service.name)' cannot define both dockerfile and dockerfile_inline")
        }
        let context = containerBuildContext(build.context, project: project)
        let dockerfile = try buildBakeDockerfile(context: context, build: build)
        let arguments = try buildBakeArguments(project: project, build: build, buildArguments: buildOptions.buildArguments)
        let contexts = try buildBakeContexts(project: project, build: build)
        let tags = buildBakeTags(project: project, service: service, build: build)
        let secrets = try buildBakeSecrets(project: project, build: build)
        let ssh = buildSSHValues(build: build, options: buildOptions)
        let attest = buildBakeAttestations(build: build, options: buildOptions)
        return ComposeBuildBakeTarget(
            context: context,
            dockerfile: dockerfile.dockerfile,
            dockerfileInline: dockerfile.dockerfileInline,
            args: arguments.isEmpty ? nil : arguments,
            labels: (build.labels ?? [:]).isEmpty ? nil : build.labels,
            contexts: contexts.isEmpty ? nil : contexts,
            entitlements: buildBakeValues(build.entitlements),
            extraHosts: buildBakeValues(build.extraHosts),
            network: nonEmpty(build.network),
            privileged: build.privileged == true ? true : nil,
            shmSize: nonEmpty(build.shmSize),
            ulimits: buildBakeValues(build.ulimits),
            tags: tags,
            target: nonEmpty(build.target),
            secrets: secrets.isEmpty ? nil : secrets,
            ssh: ssh.isEmpty ? nil : ssh,
            cacheFrom: buildBakeValues(build.cacheFrom),
            cacheTo: buildBakeValues(build.cacheTo),
            platforms: buildBakeValues(build.platforms),
            attest: attest.isEmpty ? nil : attest,
            pull: (buildOptions.pull || build.pull == true) ? true : nil,
            noCache: (buildOptions.noCache || build.noCache == true) ? true : nil,
            output: buildOptions.check ? nil : [buildOptions.push && service.image != nil ? "type=registry" : "type=docker"],
            call: buildOptions.check ? "lint" : nil,
        )
    }

    /// Resolves a Buildx bake Dockerfile path relative to the effective build context.
    func buildBakeDockerfile(context: String, build: ComposeBuild) throws -> (dockerfile: String?, dockerfileInline: String?) {
        if let dockerfileInline = nonEmpty(build.dockerfileInline) {
            return (nil, dockerfileInline)
        }
        let dockerfile = nonEmpty(build.dockerfile) ?? "Dockerfile"
        guard !context.contains("://") else {
            return (dockerfile, nil)
        }
        if (dockerfile as NSString).isAbsolutePath {
            return (URL(fileURLWithPath: dockerfile).standardizedFileURL.path, nil)
        }
        return (
            URL(fileURLWithPath: context, isDirectory: true)
                .appendingPathComponent(dockerfile)
                .standardizedFileURL
                .path,
            nil,
        )
    }

    /// Merges Compose-file and CLI build arguments for bake JSON.
    func buildBakeArguments(project: ComposeProject, build: ComposeBuild, buildArguments: [String]) throws -> [String: String] {
        var arguments = build.args ?? [:]
        for buildArgument in buildArguments {
            let trimmed = buildArgument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else {
                throw ComposeError.invalidProject("build --build-arg requires KEY or KEY=VALUE")
            }
            if parts.count == 2 {
                arguments[name] = parts[1]
            } else if let value = project.environment[name] ?? ProcessInfo.processInfo.environment[name] {
                arguments[name] = value
            }
        }
        return arguments
    }

    /// Returns Buildx bake tags using Compose build tags plus the service image.
    func buildBakeTags(project: ComposeProject, service: ComposeService, build: ComposeBuild) -> [String] {
        var tags: [String] = []
        for tag in build.tags ?? [] where !tag.isEmpty && !tags.contains(tag) {
            tags.append(tag)
        }
        if let image = serviceImage(project: project, service: service), !tags.contains(image) {
            tags.append(image)
        }
        return tags
    }

    func buildContextArguments(project: ComposeProject, build: ComposeBuild) throws -> [String: String] {
        try (build.additionalContexts ?? [:]).reduce(into: [String: String]()) { result, item in
            let name = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw ComposeError.invalidProject("build additional_contexts name must not be empty")
            }
            result[name] = try containerBuildContextSource(project: project, source: item.value)
        }
    }

    func containerBuildContextSource(project: ComposeProject, source: String) throws -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ComposeError.invalidProject("build additional_contexts source must not be empty")
        }
        guard value.hasPrefix("service:") else {
            return value
        }
        guard let serviceName = buildServiceContextName(value) else {
            throw ComposeError.invalidProject("build additional_contexts service source must include a service name")
        }
        guard let service = project.services[serviceName], let image = serviceImage(project: project, service: service) else {
            throw ComposeError.invalidProject("build additional_contexts references unknown service '\(serviceName)'")
        }
        return "docker-image://\(image)"
    }

    func buildBakeContexts(project: ComposeProject, build: ComposeBuild) throws -> [String: String] {
        try (build.additionalContexts ?? [:]).reduce(into: [String: String]()) { result, item in
            let name = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw ComposeError.invalidProject("build additional_contexts name must not be empty")
            }
            let source = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else {
                throw ComposeError.invalidProject("build additional_contexts source must not be empty")
            }
            guard source.hasPrefix("service:") else {
                result[name] = source
                return
            }
            guard let serviceName = buildServiceContextName(source) else {
                throw ComposeError.invalidProject("build additional_contexts service source must include a service name")
            }
            guard project.services[serviceName] != nil else {
                throw ComposeError.invalidProject("build additional_contexts references unknown service '\(serviceName)'")
            }
            result[name] = "target:\(serviceName)"
        }
    }

    func buildServiceContextName(_ source: String) -> String? {
        guard source.hasPrefix("service:") else {
            return nil
        }
        let serviceName = String(source.dropFirst("service:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return serviceName.isEmpty ? nil : serviceName
    }

    func buildAdditionalContextServiceNames(build: ComposeBuild?) throws -> [String] {
        var names: [String] = []
        for source in (build?.additionalContexts ?? [:]).values {
            let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("service:") else {
                continue
            }
            guard let serviceName = buildServiceContextName(value) else {
                throw ComposeError.invalidProject("build additional_contexts service source must include a service name")
            }
            names.append(serviceName)
        }
        return Array(Set(names)).sorted()
    }

    /// Encodes supported build secrets using Buildx bake syntax.
    func buildBakeSecrets(project: ComposeProject, build: ComposeBuild) throws -> [String] {
        try (build.secrets ?? []).map { secret in
            let id = secret.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw ComposeError.invalidProject("build secret id must not be empty")
            }
            let file = secret.file?.trimmingCharacters(in: .whitespacesAndNewlines)
            let environment = secret.environment?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let file, !file.isEmpty, let environment, !environment.isEmpty {
                throw ComposeError.invalidProject("build secret '\(id)' cannot define both file and environment")
            }
            if let file, !file.isEmpty {
                return "id=\(id),type=file,src=\(absoluteProjectPath(file, project: project))"
            }
            if let environment, !environment.isEmpty {
                return "id=\(id),type=env,env=\(environment)"
            }
            throw ComposeError.invalidProject("build secret '\(id)' must define file or environment")
        }
    }

    /// Merges Compose-file and CLI SSH forwarding values for `container build --ssh`.
    func buildSSHValues(build: ComposeBuild, options buildOptions: ComposeBuildOptions) -> [String] {
        var values: [String] = []
        for value in build.ssh ?? [] {
            appendSSHValue(value, to: &values, replacingExistingID: false)
        }
        for value in buildOptions.ssh {
            appendSSHValue(value, to: &values, replacingExistingID: true)
        }
        return values
    }

    func appendSSHValue(_ value: String, to values: inout [String], replacingExistingID: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        if replacingExistingID {
            let id = sshID(trimmed)
            values.removeAll { sshID($0) == id }
        }
        values.append(trimmed)
    }

    func sshID(_ value: String) -> String {
        let separator = value.contains("=") ? "=" : ":"
        let parts = value.split(separator: Character(separator), maxSplits: 1, omittingEmptySubsequences: false)
        let id = parts.first.map(String.init) ?? ""
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedID.isEmpty ? "default" : trimmedID
    }

    /// Returns supported attestation flags for `container build`.
    func buildAttestationArguments(build: ComposeBuild, options buildOptions: ComposeBuildOptions) -> [(flag: String, value: String)] {
        var values: [(flag: String, value: String)] = []
        if let provenance = buildAttestationValue(composeValue: build.provenance, cliValue: buildOptions.provenance) {
            values.append(("--provenance", provenance))
        }
        if let sbom = buildAttestationValue(composeValue: build.sbom, cliValue: buildOptions.sbom) {
            values.append(("--sbom", sbom))
        }
        return values
    }

    /// Returns supported attestation entries for Buildx bake JSON.
    func buildBakeAttestations(build: ComposeBuild, options buildOptions: ComposeBuildOptions) -> [String] {
        var values: [String] = []
        if let provenance = buildAttestationValue(composeValue: build.provenance, cliValue: buildOptions.provenance) {
            values.append(buildBakeAttestation(type: "provenance", value: provenance))
        }
        if let sbom = buildAttestationValue(composeValue: build.sbom, cliValue: buildOptions.sbom) {
            values.append(buildBakeAttestation(type: "sbom", value: sbom))
        }
        return values
    }

    /// Resolves Docker Compose's attestation true/false shorthand.
    func buildAttestationValue(composeValue: String?, cliValue: String?) -> String? {
        guard let rawValue = cliValue ?? composeValue else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "false", "0", "no":
            return nil
        case "", "true", "1", "yes":
            return "true"
        default:
            return value
        }
    }

    func buildBakeAttestation(type: String, value: String) -> String {
        value == "true" ? "type=\(type)" : "type=\(type),\(value)"
    }

    /// Returns non-empty bake list values or nil when the Compose field is empty.
    func buildBakeValues(_ values: [String]?) -> [String]? {
        let filtered = values?.filter { !$0.isEmpty } ?? []
        return filtered.isEmpty ? nil : filtered
    }

    /// Resolves a path relative to the normalized Compose project directory.
    func absoluteProjectPath(_ path: String, project: ComposeProject) -> String {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return URL(fileURLWithPath: project.workingDirectory, isDirectory: true)
            .appendingPathComponent(path)
            .standardizedFileURL
            .path
    }

    /// Encodes one Compose build secret for apple/container `container build --secret`.
    func buildSecretArgument(_ secret: ComposeBuildSecret) throws -> String {
        let id = secret.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw ComposeError.invalidProject("build secret id must not be empty")
        }
        let file = secret.file?.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = secret.environment?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let file, !file.isEmpty, let environment, !environment.isEmpty {
            throw ComposeError.invalidProject("build secret '\(id)' cannot define both file and environment")
        }
        if let file, !file.isEmpty {
            return "id=\(id),src=\(file)"
        }
        if let environment, !environment.isEmpty {
            return "id=\(id),env=\(environment)"
        }
        throw ComposeError.invalidProject("build secret '\(id)' must define file or environment")
    }

    /// Applies the Compose `up --pull` policy before starting services.
    func applyPullPolicy(
        _ policy: String?,
        project: ComposeProject,
        services: [ComposeService],
        quiet: Bool = false,
        quietBuild: Bool = false,
        allowBuild: Bool = true,
        skipBuildableMissingImages: Bool = false,
    ) async throws {
        guard let policy, !policy.isEmpty else {
            try await applyServicePullPolicies(
                project: project,
                services: services,
                quiet: quiet,
                quietBuild: quietBuild,
                allowBuild: allowBuild,
            )
            return
        }

        switch policy {
        case "always":
            try await pull(
                project: project,
                options: ComposePullOptions {
                    $0.services = services.map(\.name)
                    $0.quiet = quiet
                },
            )
        case "missing", "if_not_present":
            try await pullMissingImages(services: services, quiet: quiet, skipBuildable: skipBuildableMissingImages)
        case "never":
            return
        default:
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)'")
        }
    }

    /// Applies `compose create` image preparation before creating containers.
    func applyCreateImagePolicy(_ create: ComposeCreateOptions, project: ComposeProject, services: [ComposeService]) async throws {
        if create.pullPolicy == "build" {
            guard !create.noBuild else {
                return
            }
            try await build(project: project, services: services.map(\.name), noCache: false, quiet: create.quietBuild)
            return
        }

        let buildBeforePull = create.build && !create.noBuild && isMissingPullPolicy(create.pullPolicy)
        if buildBeforePull {
            try await build(project: project, services: services.map(\.name), noCache: false, quiet: create.quietBuild)
        }

        try await applyPullPolicy(
            create.pullPolicy,
            project: project,
            services: services,
            quiet: create.quietPull,
            quietBuild: create.quietBuild,
            allowBuild: !create.noBuild && !create.build,
            skipBuildableMissingImages: buildBeforePull,
        )

        guard create.build, !create.noBuild, !buildBeforePull else {
            return
        }
        try await build(project: project, services: services.map(\.name), noCache: false, quiet: create.quietBuild)
    }

    /// Returns whether `create` should auto-build a service before container creation.
    func shouldBuildServiceForCreate(_ create: ComposeCreateOptions, service: ComposeService) -> Bool {
        !create.noBuild && !create.build && create.pullPolicy != "build" && service.pullPolicy != "build" && service.image == nil && service.build != nil
    }

    /// Returns whether `up` should auto-build a build-only service before start.
    func shouldBuildServiceForUp(_ up: ComposeUpOptions, service: ComposeService) -> Bool {
        !up.noBuild && !up.build && service.pullPolicy != "build" && service.image == nil && service.build != nil
    }

    /// Returns whether a global pull policy should only fill genuinely missing runtime images.
    func isMissingPullPolicy(_ policy: String?) -> Bool {
        policy == "missing" || policy == "if_not_present"
    }

    /// Applies service-level `pull_policy` when no global pull override is set.
    func applyServicePullPolicies(
        project: ComposeProject,
        services: [ComposeService],
        quiet: Bool = false,
        quietBuild: Bool = false,
        allowBuild: Bool = true,
    ) async throws {
        for service in services {
            guard let policy = service.pullPolicy, !policy.isEmpty else {
                continue
            }
            try await applyServicePullPolicy(
                policy,
                project: project,
                service: service,
                quiet: quiet,
                quietBuild: quietBuild,
                allowBuild: allowBuild,
            )
        }
    }

    /// Applies the local-runtime-backed subset of Compose service pull policies.
    func applyServicePullPolicy(
        _ policy: String,
        project: ComposeProject,
        service: ComposeService,
        quiet: Bool = false,
        quietBuild: Bool = false,
        allowBuild: Bool = true,
    ) async throws {
        guard let image = service.image else {
            if policy == "build", allowBuild, service.build != nil {
                try await build(project: project, services: [service.name], noCache: false, quiet: quietBuild)
            }
            return
        }
        switch policy {
        case "always":
            try await pullImage(image, quiet: quiet)
        case "missing", "if_not_present":
            try await pullMissingImage(image, quiet: quiet)
        case "never":
            return
        case "build":
            if allowBuild, service.build != nil {
                try await build(project: project, services: [service.name], noCache: false, quiet: quietBuild)
            }
        default:
            if let interval = stalePullPolicyInterval(policy) {
                try await pullImageIfStale(image, interval: interval, quiet: quiet)
                return
            }
            throw ComposeError.invalidProject("unsupported pull policy '\(policy)' for service '\(service.name)'")
        }
    }

    /// Applies `compose run` environment overrides to the copied service model.
    func applyRunEnvironmentOverrides(_ run: ComposeRunOptions, service: inout ComposeService) throws {
        if !run.environment.isEmpty {
            var environment = service.environment ?? [:]
            for override in run.environment {
                let parsed = try parseEnvironmentOverride(override)
                environment[parsed.key] = parsed.value
            }
            service.environment = environment
        }

        if !run.envFiles.isEmpty {
            service.envFiles = (service.envFiles ?? []) + run.envFiles
        }
    }

    /// Applies `compose run` Linux capability overrides to the copied service
    /// model.
    func applyRunCapabilityOverrides(_ run: ComposeRunOptions, service: inout ComposeService) throws {
        try validateRunCapabilities(run.capAdd, optionName: "--cap-add")
        try validateRunCapabilities(run.capDrop, optionName: "--cap-drop")
        if !run.capAdd.isEmpty {
            service.capAdd = (service.capAdd ?? []) + run.capAdd
        }
        if !run.capDrop.isEmpty {
            service.capDrop = (service.capDrop ?? []) + run.capDrop
        }
    }

    /// Validates `compose run` capability override option values.
    func validateRunCapabilities(_ capabilities: [String], optionName: String) throws {
        if capabilities.contains(where: \.isEmpty) {
            throw ComposeError.invalidProject("run \(optionName) requires a capability name")
        }
    }

    /// Applies `compose run` volume overrides to the copied service model.
    func applyRunVolumeOverrides(_ run: ComposeRunOptions, project: inout ComposeProject, service: inout ComposeService) throws {
        guard !run.volumes.isEmpty else {
            return
        }

        var volumes = service.volumes ?? []
        for override in run.volumes {
            let parsed = try parseRunVolumeOverride(override)
            volumes.append(parsed.mount)
            if let name = parsed.namedVolume, project.volumes[name] == nil {
                project.volumes[name] = ComposeVolume(name: name)
            }
        }
        service.volumes = volumes
    }

    /// Parses Docker Compose `run --volume` short syntax.
    func parseRunVolumeOverride(_ override: String) throws -> (mount: ComposeMount, namedVolume: String?) {
        let parts = override.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            let target = parts[0]
            guard !target.isEmpty else {
                throw ComposeError.invalidProject("run --volume requires SOURCE:TARGET[:ro|rw] or TARGET")
            }
            return (ComposeMount(type: "volume", target: target), nil)
        case 2, 3:
            let source = parts[0]
            let target = parts[1]
            guard !source.isEmpty, !target.isEmpty else {
                throw ComposeError.invalidProject("run --volume requires SOURCE:TARGET[:ro|rw] or TARGET")
            }
            let readOnly = try parseRunVolumeMode(parts.count == 3 ? parts[2] : nil)
            if isBindVolumeSource(source) {
                return (ComposeMount(type: "bind", source: source, target: target, readOnly: readOnly, bindCreateHostPath: true), nil)
            }
            return (ComposeMount(type: "volume", source: source, target: target, readOnly: readOnly), source)
        default:
            throw ComposeError.invalidProject("run --volume requires SOURCE:TARGET[:ro|rw] or TARGET")
        }
    }

    /// Parses the optional access mode from `compose run --volume`.
    func parseRunVolumeMode(_ mode: String?) throws -> Bool {
        guard let mode, !mode.isEmpty else {
            return false
        }
        switch mode {
        case "ro", "readonly":
            return true
        case "rw":
            return false
        default:
            throw ComposeError.invalidProject("run --volume mode '\(mode)' is not supported; use ro or rw")
        }
    }

    /// Returns whether a `run --volume` source is a host bind path.
    func isBindVolumeSource(_ source: String) -> Bool {
        source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
    }

    /// Parses a Compose CLI environment override as `NAME` or `NAME=VALUE`.
    func parseEnvironmentOverride(_ override: String) throws -> (key: String, value: String?) {
        if let equalsIndex = override.firstIndex(of: "=") {
            let key = String(override[..<equalsIndex])
            guard !key.isEmpty else {
                throw ComposeError.invalidProject("run --env requires NAME or NAME=VALUE")
            }
            let value = String(override[override.index(after: equalsIndex)...])
            return (key, value)
        }

        guard !override.isEmpty else {
            throw ComposeError.invalidProject("run --env requires NAME or NAME=VALUE")
        }
        return (override, nil)
    }

    /// Parses `compose run --label` overrides while preserving CLI order.
    func parseRunLabelOverrides(_ overrides: [String]) throws -> [ComposeLabelOverride] {
        try overrides.map { override in
            let parsed: ComposeLabelOverride
            if let equalsIndex = override.firstIndex(of: "=") {
                let key = String(override[..<equalsIndex])
                guard !key.isEmpty else {
                    throw ComposeError.invalidProject("run --label requires KEY or KEY=VALUE")
                }
                let value = String(override[override.index(after: equalsIndex)...])
                parsed = ComposeLabelOverride(key: key, value: value)
            } else {
                guard !override.isEmpty else {
                    throw ComposeError.invalidProject("run --label requires KEY or KEY=VALUE")
                }
                parsed = ComposeLabelOverride(key: override, value: nil)
            }

            guard !reservedComposeLabelPrefixes.contains(where: { parsed.key.hasPrefix($0) }) else {
                throw ComposeError.invalidProject("run --label cannot override reserved Compose tracking label '\(parsed.key)'")
            }
            return parsed
        }
    }

    /// Rejects one-off labels that would overwrite annotation metadata.
    func validateRunLabelOverridesAgainstAnnotations(_ overrides: [ComposeLabelOverride], service: ComposeService) throws {
        _ = try effectiveServiceAnnotations(
            service: service,
            conflictingLabelKeys: [],
            conflictingOverrideKeys: Set(overrides.map(\.key)),
        )
    }

    /// Pulls only service images not already present in the local image store.
    func pullMissingImages(services: [ComposeService], quiet: Bool = false, skipBuildable: Bool = false) async throws {
        for service in services {
            if skipBuildable, service.build != nil {
                continue
            }
            guard let image = service.image else {
                continue
            }
            try await pullMissingImage(image, quiet: quiet)
        }
    }

    /// Pulls one image when it is absent from the local image store.
    func pullMissingImage(_ image: String, quiet: Bool = false) async throws {
        let inspectArgs = ["image", "inspect", image]
        if options.dryRun {
            try await runContainer(inspectArgs, check: false, emitOutput: false)
            try await runContainer(imagePullArguments(image, quiet: quiet))
        } else {
            try await progressActivity("Preparing image \(image)", quiet: quiet) {
                try await imageManager.pullMissingImage(image)
            }
        }
    }

    /// Pulls one image and records its successful pull timestamp.
    func pullImage(_ image: String, quiet: Bool = false) async throws {
        if options.dryRun {
            try await runContainer(imagePullArguments(image, quiet: quiet))
            return
        }
        try await progressActivity("Pulling image \(image)", quiet: quiet) {
            try await imageManager.pullImage(image)
            try await pullMetadataStore.recordPullDate(options.currentDate(), for: image)
        }
    }

    /// Pulls an image when absent or older than a Compose time-window policy.
    func pullImageIfStale(_ image: String, interval: TimeInterval, quiet: Bool = false) async throws {
        if options.dryRun {
            try await runContainer(["image", "inspect", image], check: false, emitOutput: false)
            try await runContainer(imagePullArguments(image, quiet: quiet))
            return
        }
        let exists = try await imageManager.imageExists(image)
        if !exists {
            try await pullImage(image, quiet: quiet)
            return
        }
        guard let lastPull = try await pullMetadataStore.lastPullDate(for: image) else {
            try await pullImage(image, quiet: quiet)
            return
        }
        if options.currentDate().timeIntervalSince(lastPull) >= interval {
            try await pullImage(image, quiet: quiet)
        }
    }

    /// Builds the apple/container `container image pull` dry-run arguments.
    func imagePullArguments(_ image: String, quiet: Bool) -> [String] {
        var args = ["image", "pull"]
        if quiet {
            args.append(contentsOf: ["--progress", "none"])
        }
        args.append(image)
        return args
    }
}
