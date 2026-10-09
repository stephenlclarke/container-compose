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

/// Unresolved process overrides, before applying image defaults.
///
/// Nil entrypoint inherits the image entrypoint; an empty array clears it.
/// A non-nil entrypoint also suppresses the image CMD, even with nil command.
/// Otherwise nil command inherits CMD and an empty array explicitly clears it.
/// Keep this information separate from the resolved process used by health probes.
public struct ComposeProcessOverrides: Codable, Equatable, Sendable {
    public var command: [String]?
    public var entrypoint: [String]?
    public var environment: [String: String?]
    public var workingDirectory: String?
    public var user: String?
    public var terminal: Bool
    public var openStandardInput: Bool

    public init(
        command: [String]? = nil,
        entrypoint: [String]? = nil,
        environment: [String: String?] = [:],
        workingDirectory: String? = nil,
        user: String? = nil,
        terminal: Bool = false,
        openStandardInput: Bool = false
    ) {
        self.command = command
        self.entrypoint = entrypoint
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.user = user
        self.terminal = terminal
        self.openStandardInput = openStandardInput
    }
}
