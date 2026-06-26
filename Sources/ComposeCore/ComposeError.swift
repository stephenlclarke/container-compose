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

/// Errors surfaced by Compose normalization and container orchestration.
public enum ComposeError: Error, CustomStringConvertible, Equatable {
    case commandFailed(command: String, status: Int32, stderr: String)
    case invalidProject(String)
    case unsupported(String)
    case missingNormalizer(String)
    case missingComposeFile

    /// A user-facing error description suitable for CLI output.
    public var description: String {
        switch self {
        case .commandFailed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(command) failed with exit code \(status)"
            }
            return "\(command) failed with exit code \(status): \(detail)"
        case .invalidProject(let message):
            return "invalid compose project: \(message)"
        case .unsupported(let message):
            return "unsupported compose feature: \(message)"
        case .missingNormalizer(let message):
            return "compose normalizer unavailable: \(message)"
        case .missingComposeFile:
            return "no configuration file provided: not found"
        }
    }
}
