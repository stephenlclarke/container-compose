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

import Foundation

/// Carries the requested immutable image spelling through native create/run.
/// Only options before the image belong to Container; later tokens are guest argv.
public enum ComposeNativeImageProvenance {
    public static let label = "com.apple.container.compose.image-reference"

    public static func arguments(
        _ arguments: [String], expectedImage: String? = nil
    ) throws -> [String] {
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--" {
                index += 1
                break
            }
            guard option.hasPrefix("-") else { break }
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            try rejectReservedLabel(option: option, next: next)
            let consumesNext = try shortOptionConsumesNext(option, next: next)
                || valueOptions.contains(option)
            index += consumesNext ? 2 : 1
        }
        guard arguments.indices.contains(index), !arguments[index].isEmpty else {
            throw ComposeError.invalidProject("Native launch lacks an image")
        }
        let image = arguments[index]
        if let expectedImage, image != expectedImage {
            throw ComposeError.invalidProject("Native launch image differs from the typed service plan")
        }
        let provenance: String?
        if image.hasPrefix("sha256:") || image.contains("@") {
            guard image.range(of: #"^sha256:[0-9a-f]{64}$|^[^\s@]+@sha256:[0-9a-f]{64}$"#,
                              options: .regularExpression) != nil
            else {
                throw ComposeError.invalidProject("Native image provenance requires a complete sha256 image reference")
            }
            provenance = "\(label)=\(image)"
        } else {
            provenance = nil
        }
        guard let provenance else { return arguments }
        var result = arguments
        let insertion = index > 0 && arguments[index - 1] == "--" ? index - 1 : index
        result.insert(contentsOf: ["--label", provenance], at: insertion)
        return result
    }

    public static func rejectReservedLabel(option: String, next: String?) throws {
        let value: String?
        if option == "--label" || option == "-l" {
            value = next
        } else if option.hasPrefix("--label=") {
            value = String(option.dropFirst("--label=".count))
        } else if option.hasPrefix("-l") {
            let suffix = option.dropFirst(2)
            value = String(suffix.hasPrefix("=") ? suffix.dropFirst() : suffix)
        } else {
            value = nil
        }
        let reserved = [label, ComposeNativeHealthPolicy.label]
        guard !reserved.contains(where: { value?.split(separator: "=", maxSplits: 1).first == Substring($0) }) else {
            throw ComposeError.invalidProject("The native policy/provenance label is reserved")
        }
    }

    public static func shortOptionConsumesNext(_ argument: String, next: String?) throws -> Bool {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { return false }
        var flags = argument.dropFirst()
        while let flag = flags.first {
            flags = flags.dropFirst()
            if "aceklmpuvw".contains(flag) {
                let value = flags.isEmpty ? next : String(flags.hasPrefix("=") ? flags.dropFirst() : flags)
                if flag == "l" {
                    try rejectReservedLabel(option: "--label", next: value)
                }
                return flags.isEmpty
            }
            guard "dith".contains(flag) else {
                throw ComposeError.invalidProject("Unsupported native short option -\(flag)")
            }
        }
        return false
    }

    public static let valueOptions: Set<String> = [
        "--add-host", "--annotation", "--arch", "--blkio", "--cap-add", "--cap-drop",
        "--cidfile", "--cwd", "--gid", "--uid", "--kernel", "--kernel-arg",
        "--masked-path", "--os", "--publish-socket", "--read-only-path",
        "--progress", "--max-concurrent-downloads", "--cgroup-parent", "--cgroupns",
        "--cpu-period", "--cpu-quota", "--cpu-shares", "--cpus", "--cpuset-cpus",
        "--device", "--device-cgroup-rule", "--dns", "--dns-domain", "--dns-option",
        "--dns-search", "--domainname", "--entrypoint", "--env", "--env-file",
        "--expose", "--gpus", "--group-add", "--hostname", "--health-cmd",
        "--health-interval", "--health-retries", "--health-start-interval",
        "--health-start-period", "--health-timeout", "--init-image", "--ipc",
        "--isolation", "--label", "-l", "--log-driver", "--log-opt", "--memory",
        "--memory-reservation", "--memory-swap", "--name", "--network",
        "--memory-reclaim-floor", "--memory-reclaim-headroom", "--memory-reclaim-hysteresis",
        "--memory-reclaim-interval", "--memory-reclaim-cooldown",
        "--oom-score-adj", "--pid", "--pids-limit", "--platform", "--publish",
        "--scheme", "--restart", "--restart-delay", "--restart-window",
        "--runtime", "--security-opt", "--shm-size", "--stop-signal",
        "--stop-timeout", "--sysctl", "--tmpfs", "--ulimit", "--user",
        "--userns", "--uts", "--volume", "--mount", "--workdir",
    ]
}
