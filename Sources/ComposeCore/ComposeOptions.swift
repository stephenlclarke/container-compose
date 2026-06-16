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

/// Global Compose options shared by all subcommands.
public struct ComposeOptions: Equatable {
    public var files: [String]
    public var projectName: String?
    public var profiles: [String]
    public var envFiles: [String]
    public var projectDirectory: String?
    public var ansi: String?
    public var progress: String?
    public var dryRun: Bool
    public var verbose: Bool

    public init(
        files: [String] = [],
        projectName: String? = nil,
        profiles: [String] = [],
        envFiles: [String] = [],
        projectDirectory: String? = nil,
        ansi: String? = nil,
        progress: String? = nil,
        dryRun: Bool = false,
        verbose: Bool = false
    ) {
        self.files = files
        self.projectName = projectName
        self.profiles = profiles
        self.envFiles = envFiles
        self.projectDirectory = projectDirectory
        self.ansi = ansi
        self.progress = progress
        self.dryRun = dryRun
        self.verbose = verbose
    }
}
