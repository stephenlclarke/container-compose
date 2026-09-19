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
import Foundation

extension EngineRuntimeProvider {
    public func validateHealthCheckArguments(_ arguments: [String]) async throws {
        guard let policy = try ComposeNativeHealthPolicy.resolve(arguments: arguments) else { return }
        _ = try policy.encodedLabel()
        try await requireHealthPolicySupport()
    }

    /// Scan only Container options, never arguments belonging to the guest process.
    func healthLaunchArguments(_ arguments: [String]) async throws -> [String] {
        var result: [String] = []
        var health: [String] = []
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            if option == "--" || !option.hasPrefix("-") {
                break
            }
            try Self.rejectImageReferenceLabel(option: option, next: next)
            let parts = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            if name.hasPrefix("--health-") || name == "--no-healthcheck" {
                health.append(name)
                if name == "--no-healthcheck" {
                    guard parts.count == 1 else {
                        throw ComposeError.invalidProject("Disabled health-check flag takes no value")
                    }
                    index += 1
                } else if parts.count == 2 {
                    health.append(String(parts[1]))
                    index += 1
                } else {
                    guard let next else { throw ComposeError.invalidProject("Health-check option lacks a value") }
                    health.append(next)
                    index += 2
                }
                continue
            }
            let shortTakesNext = try Self.shortOptionConsumesNext(option, next: next)
            let takesNext = Self.containerLaunchValueOptions.contains(option) || shortTakesNext
            result.append(option)
            index += 1
            if takesNext, let next {
                result.append(next)
                index += 1
            }
        }
        if let policy = try ComposeNativeHealthPolicy.resolve(arguments: health) {
            let label = try policy.encodedLabel()
            let imageIndex = index + (arguments.indices.contains(index) && arguments[index] == "--" ? 1 : 0)
            guard arguments.indices.contains(imageIndex), !arguments[imageIndex].isEmpty else {
                throw ComposeError.invalidProject("Health-check launch lacks an image")
            }
            try await requireHealthPolicySupport()
            // Insert after native provenance/volume processing, whose input
            // rejects caller-supplied policy labels, including short spellings.
            let native = try await nativeHealthFreeArguments(result + arguments[index...])
            return ["--label", label] + native
        }
        return try await nativeHealthFreeArguments(result + arguments[index...])
    }

    private func requireHealthPolicySupport() async throws {
        let version: NativeHealthVersion = try await request(.get, "/v1.53/version")
        let engines = version.components.filter { $0.name == "Engine" }
        guard engines.count == 1,
              engines[0].details["NativeComposeHealthPolicy"] == "1"
        else {
            throw ComposeError.unsupported("Selected gateway does not support stock Compose health policy v1")
        }
    }
}

private struct NativeHealthVersion: Decodable {
    let components: [NativeHealthComponent]
    enum CodingKeys: String, CodingKey { case components = "Components" }
}

private struct NativeHealthComponent: Decodable {
    let name: String
    let details: [String: String]
    enum CodingKeys: String, CodingKey { case name = "Name", details = "Details" }
}
