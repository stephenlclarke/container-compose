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
    /// Returns Docker-compatible apple/container restart policy arguments
    /// for service containers. Compose Deploy restart policy takes precedence
    /// over the service-level `restart` key, matching Docker Compose.
    func runtimeRestartPolicyArguments(service: ComposeService) throws -> RuntimeRestartPolicyArguments? {
        if let policy = service.deployRestartPolicy {
            return try runtimeDeployRestartPolicyArguments(service: service, policy: policy)
        }
        return try runtimeServiceRestartPolicyArguments(
            service: service,
            allowSuccessfulRestart: !isDeployJobService(service),
        )
    }

    /// Returns the typed restart policy used by direct apple/container create.
    func runtimeRestartPolicy(service: ComposeService) throws -> ContainerRestartPolicy? {
        try runtimeRestartPolicyArguments(service: service)?.restartPolicy()
    }

    /// Returns the runtime restart arguments for a Compose Deploy restart policy.
    func runtimeDeployRestartPolicyArguments(
        service: ComposeService,
        policy: ComposeDeployRestartPolicy,
    ) throws -> RuntimeRestartPolicyArguments {
        let condition = policy.condition?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let restartCondition = condition.flatMap { $0.isEmpty ? nil : $0 } ?? "any"
        let timing = try deployRestartTiming(service: service, policy: policy)
        if isDeployJobService(service), restartCondition != "none" {
            throw ComposeError.unsupported(jobRestartPolicyUnsupportedMessage(service: service, source: "deploy.restart_policy"))
        }

        switch restartCondition {
        case "none":
            if policy.maxAttempts != nil {
                throw ComposeError.unsupported("service '\(service.name)' uses deploy.restart_policy.max_attempts with condition 'none'; apple/container retry limits are only available for on-failure restart policies")
            }
            if timing.delayNanoseconds != nil || timing.windowNanoseconds != nil {
                throw ComposeError.unsupported("service '\(service.name)' uses deploy.restart_policy timing with condition 'none'; restart timing only applies to restarting policies")
            }
            return RuntimeRestartPolicyArguments(policy: "no")
        case "any":
            if policy.maxAttempts != nil {
                throw ComposeError.unsupported("service '\(service.name)' uses deploy.restart_policy.max_attempts with condition 'any'; apple/container retry limits are only available for on-failure restart policies")
            }
            return RuntimeRestartPolicyArguments(
                policy: "always",
                delayNanoseconds: timing.delayNanoseconds,
                windowNanoseconds: timing.windowNanoseconds,
            )
        case "on-failure":
            let restartPolicy: String
            if let maxAttempts = policy.maxAttempts {
                guard maxAttempts <= UInt64(UInt32.max) else {
                    throw ComposeError.invalidProject("service '\(service.name)' deploy.restart_policy.max_attempts must be between 0 and \(UInt32.max)")
                }
                restartPolicy = maxAttempts == 0 ? "on-failure" : "on-failure:\(maxAttempts)"
            } else {
                restartPolicy = "on-failure"
            }
            return RuntimeRestartPolicyArguments(
                policy: restartPolicy,
                delayNanoseconds: timing.delayNanoseconds,
                windowNanoseconds: timing.windowNanoseconds,
            )
        default:
            throw ComposeError.unsupported("service '\(service.name)' uses deploy.restart_policy.condition '\(restartCondition)'; supported values are none, on-failure, and any")
        }
    }

    /// Returns Compose Deploy restart timing values backed by apple/container
    /// restart policy timing primitives.
    func deployRestartTiming(
        service: ComposeService,
        policy: ComposeDeployRestartPolicy,
    ) throws -> (delayNanoseconds: Int64?, windowNanoseconds: Int64?) {
        if let delay = policy.delayNanoseconds, delay < 0 {
            throw ComposeError.invalidProject("service '\(service.name)' deploy.restart_policy.delay must be non-negative")
        }
        if let window = policy.windowNanoseconds, window < 0 {
            throw ComposeError.invalidProject("service '\(service.name)' deploy.restart_policy.window must be non-negative")
        }
        return (policy.delayNanoseconds, policy.windowNanoseconds)
    }

    /// Returns true for Compose Deploy modes that represent completion-oriented jobs.
    func isDeployJobService(_ service: ComposeService) -> Bool {
        guard let mode = service.deployMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return mode == "replicated-job" || mode == "global-job"
    }

    func jobRestartPolicyUnsupportedMessage(service: ComposeService, source: String) -> String {
        "service '\(service.name)' uses \(source) with deploy.mode '\(service.deployMode ?? "")'; job restart policies need a restart-aware apple/container wait primitive"
    }

    /// Returns the runtime restart arguments for the service-level `restart` key.
    func runtimeServiceRestartPolicyArguments(
        service: ComposeService,
        allowSuccessfulRestart: Bool = true,
    ) throws -> RuntimeRestartPolicyArguments? {
        guard let restart = service.restart?.trimmingCharacters(in: .whitespacesAndNewlines),
              !restart.isEmpty
        else {
            return nil
        }

        let parts = restart.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let mode = parts.first, !mode.isEmpty else {
            throw ComposeError.invalidProject("service '\(service.name)' has invalid restart policy '\(restart)'")
        }

        switch mode {
        case "no", "always", "unless-stopped":
            guard parts.count == 1 else {
                throw ComposeError.invalidProject("service '\(service.name)' restart retry count is only supported with on-failure")
            }
        case "on-failure":
            if parts.count == 2 {
                let retryValue = String(parts[1])
                guard !retryValue.isEmpty, UInt32(retryValue) != nil else {
                    throw ComposeError.invalidProject("service '\(service.name)' has invalid restart policy '\(restart)'")
                }
            }
        default:
            throw ComposeError.unsupported("service '\(service.name)' uses restart policy '\(restart)'; supported values are no, always, on-failure[:max-retries], and unless-stopped")
        }

        if !allowSuccessfulRestart, mode != "no" {
            throw ComposeError.unsupported(jobRestartPolicyUnsupportedMessage(service: service, source: "restart policy '\(restart)'"))
        }

        return RuntimeRestartPolicyArguments(policy: restart)
    }
}
