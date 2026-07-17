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
    /// Validates service healthcheck fields without requiring image metadata.
    func validateHealthCheckSupport(service: ComposeService) throws {
        let fields = try healthCheckFields(service: service)
        guard fields["disable"]?.boolValue != true else {
            return
        }
        if let test = fields["test"] {
            _ = try runtimeHealthCheckCommand(test: test, serviceName: service.name)
        }
        for field in healthCheckDurationFields {
            if let value = fields[field.composeName] {
                _ = try healthCheckDuration(value, field: field.composeName, serviceName: service.name)
            }
        }
        if let retries = fields["retries"] {
            _ = try healthCheckRetries(retries, serviceName: service.name)
        }
    }

    /// Returns Docker-compatible apple/container healthcheck arguments for
    /// service create/run.
    func runtimeHealthCheckArguments(
        project: ComposeProject,
        service: ComposeService,
        cache: ComposeImageHealthCheckCache?,
    ) async throws -> [String] {
        let fields = try healthCheckFields(service: service)
        guard fields["disable"]?.boolValue != true else {
            return ["--no-healthcheck"]
        }
        if let test = fields["test"] {
            return try explicitHealthCheckArguments(test: test, fields: fields, serviceName: service.name)
        }

        guard !options.dryRun else {
            if healthCheckRequiresInheritedCommand(fields) {
                throw ComposeError.unsupported("service '\(service.name)' tunes an image healthcheck; dry-run cannot resolve image HEALTHCHECK metadata")
            }
            return []
        }

        let imageHealthCheck: ComposeImageHealthCheck?
        do {
            imageHealthCheck = try await inheritedImageHealthCheck(project: project, service: service, cache: cache)
        } catch {
            guard healthCheckRequiresInheritedCommand(fields) else {
                return []
            }
            throw error
        }

        guard let imageHealthCheck else {
            if healthCheckRequiresInheritedCommand(fields) {
                let image = serviceImage(project: project, service: service) ?? "<none>"
                throw ComposeError.unsupported("service '\(service.name)' tunes an image healthcheck, but image '\(image)' does not expose Dockerfile HEALTHCHECK metadata")
            }
            return []
        }

        return try inheritedHealthCheckArguments(
            imageHealthCheck,
            fields: fields,
            serviceName: service.name,
        )
    }

    /// Resolves healthcheck runtime arguments before creating project resources.
    func validateRuntimeHealthChecks(
        project: ComposeProject,
        services: [ComposeService],
        cache: ComposeImageHealthCheckCache,
    ) async throws {
        for service in services {
            guard serviceImage(project: project, service: service) != nil else {
                continue
            }
            _ = try await runtimeHealthCheckArguments(project: project, service: service, cache: cache)
        }
    }

    /// Returns the typed healthcheck used by direct apple/container create.
    func runtimeHealthCheck(
        project: ComposeProject,
        service: ComposeService,
        cache: ComposeImageHealthCheckCache?,
        baseProcess: ProcessConfiguration,
    ) async throws -> ContainerHealthCheck? {
        let fields = try healthCheckFields(service: service)
        guard fields["disable"]?.boolValue != true else {
            return nil
        }
        if let test = fields["test"] {
            return try explicitHealthCheck(
                test: test,
                fields: fields,
                serviceName: service.name,
                baseProcess: baseProcess,
            )
        }

        let imageHealthCheck: ComposeImageHealthCheck?
        do {
            imageHealthCheck = try await inheritedImageHealthCheck(project: project, service: service, cache: cache)
        } catch {
            guard healthCheckRequiresInheritedCommand(fields) else {
                return nil
            }
            throw error
        }

        guard let imageHealthCheck else {
            if healthCheckRequiresInheritedCommand(fields) {
                let image = serviceImage(project: project, service: service) ?? "<none>"
                throw ComposeError.unsupported("service '\(service.name)' tunes an image healthcheck, but image '\(image)' does not expose Dockerfile HEALTHCHECK metadata")
            }
            return nil
        }

        return try inheritedHealthCheck(
            imageHealthCheck,
            fields: fields,
            serviceName: service.name,
            baseProcess: baseProcess,
        )
    }

    /// Resolves the image config healthcheck a Compose commit should retain.
    ///
    /// `commit` creates an image, so it must preserve the Docker image form of
    /// the effective probe rather than the runtime command-vector projection.
    package func commitImageHealthCheck(
        service: ComposeService,
        inherited: ComposeImageHealthCheck?,
    ) throws -> ComposeImageHealthCheck? {
        let fields = try healthCheckFields(service: service)
        guard fields["disable"]?.boolValue != true else {
            return ComposeImageHealthCheck(test: ["NONE"])
        }

        guard let test = fields["test"] else {
            guard healthCheckRequiresInheritedCommand(fields),
                  let inherited,
                  let inheritedTest = inherited.test,
                  !inheritedTest.isEmpty
            else {
                return inherited
            }
            let inheritedValue = ComposeValue.array(inheritedTest.map { .string($0) })
            guard case .command = try runtimeHealthCheckCommand(test: inheritedValue, serviceName: service.name) else {
                return inherited
            }
            return try resolvedCommitImageHealthCheck(
                test: inheritedTest,
                fields: fields,
                inherited: inherited,
                serviceName: service.name,
            )
        }

        let dockerTest = try commitImageHealthCheckTest(test, serviceName: service.name)
        guard dockerTest != ["NONE"] else {
            return ComposeImageHealthCheck(test: dockerTest)
        }
        return try resolvedCommitImageHealthCheck(
            test: dockerTest,
            fields: fields,
            inherited: nil,
            serviceName: service.name,
        )
    }

    /// Returns validated Compose healthcheck fields.
    func healthCheckFields(service: ComposeService) throws -> [String: ComposeValue] {
        guard let healthcheck = service.healthcheck else {
            return [:]
        }
        guard case let .object(fields) = healthcheck else {
            throw ComposeError.invalidProject("service '\(service.name)' healthcheck must be an object")
        }
        guard fields.keys.allSatisfy({ supportedHealthCheckKeys.contains($0) }) else {
            let unsupported = fields.keys
                .filter { !supportedHealthCheckKeys.contains($0) }
                .sorted()
                .joined(separator: ", ")
            throw ComposeError.unsupported("service '\(service.name)' uses unsupported healthcheck fields \(unsupported)")
        }
        return fields
    }

    /// Returns whether Compose overrides require an image-level healthcheck command.
    func healthCheckRequiresInheritedCommand(_ fields: [String: ComposeValue]) -> Bool {
        fields.keys.contains { $0 != "disable" }
    }

    /// Reads inherited Dockerfile healthcheck metadata for the service image.
    func inheritedImageHealthCheck(
        project: ComposeProject,
        service: ComposeService,
        cache: ComposeImageHealthCheckCache?,
    ) async throws -> ComposeImageHealthCheck? {
        guard let image = serviceImage(project: project, service: service) else {
            return nil
        }
        if let cache {
            return try await cache.healthCheck(reference: image, platform: service.platform, imageManager: imageManager)
        }
        return try await imageManager.imageHealthCheck(image, platform: service.platform)
    }

    /// Converts explicit Compose healthcheck fields to a typed healthcheck.
    func explicitHealthCheck(
        test: ComposeValue,
        fields: [String: ComposeValue],
        serviceName: String,
        baseProcess: ProcessConfiguration,
    ) throws -> ContainerHealthCheck? {
        switch try runtimeHealthCheckCommand(test: test, serviceName: serviceName) {
        case .disabled:
            nil
        case let .command(command):
            try containerHealthCheck(
                command: command,
                fields: fields,
                inherited: nil,
                serviceName: serviceName,
                baseProcess: baseProcess,
            )
        }
    }

    /// Converts explicit Compose healthcheck fields to runtime arguments.
    func explicitHealthCheckArguments(
        test: ComposeValue,
        fields: [String: ComposeValue],
        serviceName: String,
    ) throws -> [String] {
        var args: [String] = switch try runtimeHealthCheckCommand(test: test, serviceName: serviceName) {
        case .disabled:
            ["--no-healthcheck"]
        case let .command(command):
            ["--health-cmd", command]
        }

        try appendHealthCheckOverrides(fields: fields, serviceName: serviceName, args: &args)
        return args
    }

    /// Converts Dockerfile healthcheck metadata plus Compose overrides to a typed healthcheck.
    func inheritedHealthCheck(
        _ imageHealthCheck: ComposeImageHealthCheck,
        fields: [String: ComposeValue],
        serviceName: String,
        baseProcess: ProcessConfiguration,
    ) throws -> ContainerHealthCheck? {
        guard let test = imageHealthCheck.test, !test.isEmpty else {
            _ = try handleMissingInheritedHealthCheckCommand(fields: fields, serviceName: serviceName)
            return nil
        }

        let testValue = ComposeValue.array(test.map { .string($0) })
        switch try runtimeHealthCheckCommand(test: testValue, serviceName: serviceName) {
        case .disabled:
            _ = try handleMissingInheritedHealthCheckCommand(fields: fields, serviceName: serviceName)
            return nil
        case let .command(command):
            return try containerHealthCheck(
                command: command,
                fields: fields,
                inherited: imageHealthCheck,
                serviceName: serviceName,
                baseProcess: baseProcess,
            )
        }
    }

    /// Converts Dockerfile healthcheck metadata plus Compose overrides to runtime arguments.
    func inheritedHealthCheckArguments(
        _ imageHealthCheck: ComposeImageHealthCheck,
        fields: [String: ComposeValue],
        serviceName: String,
    ) throws -> [String] {
        guard let test = imageHealthCheck.test, !test.isEmpty else {
            return try handleMissingInheritedHealthCheckCommand(fields: fields, serviceName: serviceName)
        }

        let testValue = ComposeValue.array(test.map { .string($0) })
        var args: [String]
        switch try runtimeHealthCheckCommand(test: testValue, serviceName: serviceName) {
        case .disabled:
            return try handleMissingInheritedHealthCheckCommand(fields: fields, serviceName: serviceName)
        case let .command(command):
            args = ["--health-cmd", command]
        }

        try appendInheritedHealthCheckDefaults(imageHealthCheck, fields: fields, serviceName: serviceName, args: &args)
        try appendHealthCheckOverrides(fields: fields, serviceName: serviceName, args: &args)
        return args
    }

    /// Returns the no-op or error result for an image without an inherited command.
    func handleMissingInheritedHealthCheckCommand(
        fields: [String: ComposeValue],
        serviceName: String,
    ) throws -> [String] {
        guard healthCheckRequiresInheritedCommand(fields) else {
            return []
        }
        throw ComposeError.unsupported("service '\(serviceName)' tunes an image healthcheck, but the image disables Dockerfile HEALTHCHECK")
    }

    /// Builds the typed container healthcheck from Compose overrides and optional image defaults.
    func containerHealthCheck(
        command: String,
        fields: [String: ComposeValue],
        inherited: ComposeImageHealthCheck?,
        serviceName: String,
        baseProcess: ProcessConfiguration,
    ) throws -> ContainerHealthCheck {
        let interval = try healthCheckDurationNanoseconds(
            fields["interval"],
            inherited: inherited?.intervalInNanoseconds,
            field: "interval",
            serviceName: serviceName,
        ) ?? ContainerHealthCheck.defaultIntervalInNanoseconds
        let timeout = try healthCheckDurationNanoseconds(
            fields["timeout"],
            inherited: inherited?.timeoutInNanoseconds,
            field: "timeout",
            serviceName: serviceName,
        ) ?? ContainerHealthCheck.defaultTimeoutInNanoseconds
        let startPeriod = try healthCheckDurationNanoseconds(
            fields["start_period"],
            inherited: inherited?.startPeriodInNanoseconds,
            field: "start_period",
            serviceName: serviceName,
        ) ?? ContainerHealthCheck.defaultStartPeriodInNanoseconds
        let startInterval = try healthCheckDurationNanoseconds(
            fields["start_interval"],
            inherited: inherited?.startIntervalInNanoseconds,
            field: "start_interval",
            serviceName: serviceName,
        )
        let retries = try healthCheckRetries(
            fields["retries"],
            inherited: inherited?.retries,
            serviceName: serviceName,
        )

        return ContainerHealthCheck(
            process: ProcessConfiguration(
                executable: ComposeRuntimeDefaults.shellExecutable,
                arguments: ["-c", command],
                environment: baseProcess.environment,
                workingDirectory: baseProcess.workingDirectory,
                terminal: false,
                user: baseProcess.user,
                supplementalGroups: baseProcess.supplementalGroups,
                supplementalGroupNames: baseProcess.supplementalGroupNames,
                rlimits: baseProcess.rlimits,
            ),
            intervalInNanoseconds: interval,
            timeoutInNanoseconds: timeout,
            startPeriodInNanoseconds: startPeriod,
            startIntervalInNanoseconds: startInterval,
            retries: retries,
        )
    }

    /// Appends image-level healthcheck defaults that are not overridden by Compose.
    func appendInheritedHealthCheckDefaults(
        _ imageHealthCheck: ComposeImageHealthCheck,
        fields: [String: ComposeValue],
        serviceName: String,
        args: inout [String],
    ) throws {
        for field in healthCheckDurationFields where fields[field.composeName] == nil {
            guard let duration = try inheritedHealthCheckDuration(
                imageHealthCheck,
                field: field.composeName,
                serviceName: serviceName,
            ) else {
                continue
            }
            args.append(contentsOf: [field.runtimeName, duration])
        }
        if fields["retries"] == nil, let retries = imageHealthCheck.retries, retries > 0 {
            args.append(contentsOf: ["--health-retries", String(retries)])
        }
    }

    /// Appends Compose healthcheck overrides.
    func appendHealthCheckOverrides(
        fields: [String: ComposeValue],
        serviceName: String,
        args: inout [String],
    ) throws {
        for field in healthCheckDurationFields {
            if let value = fields[field.composeName] {
                let duration = try healthCheckDuration(value, field: field.composeName, serviceName: serviceName)
                args.append(contentsOf: [field.runtimeName, duration])
            }
        }

        if let retries = fields["retries"] {
            let value = try healthCheckRetries(retries, serviceName: serviceName)
            args.append(contentsOf: ["--health-retries", String(value)])
        }
    }

    /// Returns an image-level healthcheck duration for one Compose field.
    func inheritedHealthCheckDuration(
        _ imageHealthCheck: ComposeImageHealthCheck,
        field: String,
        serviceName: String,
    ) throws -> String? {
        let nanoseconds: Int64? = switch field {
        case "interval":
            imageHealthCheck.intervalInNanoseconds
        case "timeout":
            imageHealthCheck.timeoutInNanoseconds
        case "start_period":
            imageHealthCheck.startPeriodInNanoseconds
        case "start_interval":
            imageHealthCheck.startIntervalInNanoseconds
        default:
            nil
        }
        guard let nanoseconds, nanoseconds != 0 else {
            return nil
        }
        guard nanoseconds > 0 else {
            throw ComposeError.invalidProject("service '\(serviceName)' inherited healthcheck.\(field) must be non-negative")
        }
        return runtimeDurationArgument(nanoseconds)
    }

    /// Converts Compose healthcheck `test` to the container CLI command form.
    func runtimeHealthCheckCommand(test: ComposeValue, serviceName: String) throws -> RuntimeHealthCheckCommand {
        switch test {
        case let .string(command):
            return .command(command)
        case let .array(values):
            return try runtimeHealthCheckCommand(parts: values, serviceName: serviceName)
        default:
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test must be a string or list")
        }
    }

    /// Converts list-form Compose healthcheck `test` values to a container CLI command.
    private func runtimeHealthCheckCommand(
        parts values: [ComposeValue],
        serviceName: String,
    ) throws -> RuntimeHealthCheckCommand {
        let parts = try values.map { value -> String in
            guard let string = value.stringValue else {
                throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test entries must be strings")
            }
            return string
        }
        guard let directive = parts.first else {
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test cannot be empty")
        }
        switch directive {
        case "NONE":
            return .disabled
        case "CMD-SHELL":
            let command = parts.dropFirst().joined(separator: " ")
            guard !command.isEmpty else {
                throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test CMD-SHELL requires a command")
            }
            return .command(command)
        case "CMD":
            let command = Array(parts.dropFirst())
            guard !command.isEmpty else {
                throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test CMD requires a command")
            }
            return .command(shellQuoted(command))
        default:
            throw ComposeError.unsupported("service '\(serviceName)' healthcheck.test uses unsupported directive '\(directive)'")
        }
    }

    /// Returns a Compose healthcheck duration string to pass through to apple/container.
    func healthCheckDuration(_ value: ComposeValue, field: String, serviceName: String) throws -> String {
        guard let duration = value.stringValue,
              ComposeTimeParser.parseDuration(duration) != nil
        else {
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.\(field) must be a Compose duration")
        }
        return duration
    }

    /// Returns a Compose healthcheck duration in nanoseconds for typed create.
    func healthCheckDurationNanoseconds(
        _ value: ComposeValue?,
        inherited inheritedNanoseconds: Int64?,
        field: String,
        serviceName: String,
    ) throws -> UInt64? {
        if let value {
            let duration = try healthCheckDuration(value, field: field, serviceName: serviceName)
            guard let seconds = ComposeTimeParser.parseDuration(duration) else {
                throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.\(field) must be a Compose duration")
            }
            let nanoseconds = seconds * 1_000_000_000
            guard nanoseconds.isFinite, nanoseconds >= 0, nanoseconds <= Double(UInt64.max) else {
                throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.\(field) is outside the supported range")
            }
            return UInt64(nanoseconds.rounded())
        }

        guard let inheritedNanoseconds, inheritedNanoseconds != 0 else {
            return nil
        }
        guard inheritedNanoseconds > 0 else {
            throw ComposeError.invalidProject("service '\(serviceName)' inherited healthcheck.\(field) must be non-negative")
        }
        return UInt64(inheritedNanoseconds)
    }

    /// Returns the Compose healthcheck retry count.
    func healthCheckRetries(_ value: ComposeValue, serviceName: String) throws -> Int {
        guard let retries = value.intValue, retries >= 0, retries <= Int(UInt32.max) else {
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.retries must be between 0 and \(UInt32.max)")
        }
        return retries
    }

    /// Returns the typed Compose healthcheck retry count.
    func healthCheckRetries(_ value: ComposeValue?, inherited: Int?, serviceName: String) throws -> UInt32 {
        let retries: Int
        if let value {
            retries = try healthCheckRetries(value, serviceName: serviceName)
        } else if let inherited, inherited > 0 {
            retries = inherited
        } else {
            return ContainerHealthCheck.defaultRetries
        }
        guard retries <= Int(UInt32.max) else {
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.retries must be between 0 and \(UInt32.max)")
        }
        return UInt32(retries)
    }

    /// Converts the effective Compose healthcheck to Docker image config data.
    private func resolvedCommitImageHealthCheck(
        test: [String],
        fields: [String: ComposeValue],
        inherited: ComposeImageHealthCheck?,
        serviceName: String,
    ) throws -> ComposeImageHealthCheck {
        ComposeImageHealthCheck(
            test: test,
            intervalInNanoseconds: try commitHealthCheckDuration(
                fields["interval"],
                inherited: inherited?.intervalInNanoseconds,
                field: "interval",
                serviceName: serviceName,
            ) ?? Int64(ContainerHealthCheck.defaultIntervalInNanoseconds),
            timeoutInNanoseconds: try commitHealthCheckDuration(
                fields["timeout"],
                inherited: inherited?.timeoutInNanoseconds,
                field: "timeout",
                serviceName: serviceName,
            ) ?? Int64(ContainerHealthCheck.defaultTimeoutInNanoseconds),
            startPeriodInNanoseconds: try commitHealthCheckDuration(
                fields["start_period"],
                inherited: inherited?.startPeriodInNanoseconds,
                field: "start_period",
                serviceName: serviceName,
            ) ?? Int64(ContainerHealthCheck.defaultStartPeriodInNanoseconds),
            startIntervalInNanoseconds: try commitHealthCheckDuration(
                fields["start_interval"],
                inherited: inherited?.startIntervalInNanoseconds,
                field: "start_interval",
                serviceName: serviceName,
            ),
            retries: Int(try healthCheckRetries(
                fields["retries"],
                inherited: inherited?.retries,
                serviceName: serviceName,
            )),
        )
    }

    /// Maps Compose duration values to Docker image config's signed nanoseconds.
    private func commitHealthCheckDuration(
        _ value: ComposeValue?,
        inherited: Int64?,
        field: String,
        serviceName: String,
    ) throws -> Int64? {
        guard let nanoseconds = try healthCheckDurationNanoseconds(
            value,
            inherited: inherited,
            field: field,
            serviceName: serviceName,
        ) else {
            return nil
        }
        guard let signedNanoseconds = Int64(exactly: nanoseconds) else {
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.\(field) is outside the Docker image config range")
        }
        return signedNanoseconds
    }

    /// Preserves Compose's test form while validating it against the runtime projection.
    private func commitImageHealthCheckTest(_ test: ComposeValue, serviceName: String) throws -> [String] {
        let runtimeCommand = try runtimeHealthCheckCommand(test: test, serviceName: serviceName)
        guard case .command = runtimeCommand else {
            return ["NONE"]
        }

        switch test {
        case let .string(command):
            return ["CMD-SHELL", command]
        case let .array(values):
            return try values.map { value in
                guard let value = value.stringValue else {
                    throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test entries must be strings")
                }
                return value
            }
        default:
            throw ComposeError.invalidProject("service '\(serviceName)' healthcheck.test must be a string or list")
        }
    }
}
