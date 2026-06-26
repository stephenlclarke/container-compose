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

/// Options that influence Compose file normalization.
public struct ComposeOptions: Equatable {
    public struct NormalizationOptions: Equatable {
        public var noConsistency: Bool = false
        public var noEnvResolution: Bool = false
        public var noInterpolate: Bool = false
        public var noNormalize: Bool = false
        public var noPathResolution: Bool = false

        public init(
            noConsistency: Bool = false,
            noEnvResolution: Bool = false,
            noInterpolate: Bool = false,
            noNormalize: Bool = false,
            noPathResolution: Bool = false,
        ) {
            self.noConsistency = noConsistency
            self.noEnvResolution = noEnvResolution
            self.noInterpolate = noInterpolate
            self.noNormalize = noNormalize
            self.noPathResolution = noPathResolution
        }

        public init(_ configure: (inout NormalizationOptions) -> Void) {
            self.init()
            configure(&self)
        }
    }

    public var files: [String]
    public var projectName: String?
    public var profiles: [String]
    public var envFiles: [String]
    public var projectDirectory: String?
    public var noConsistency: Bool
    public var noEnvResolution: Bool
    public var noInterpolate: Bool
    public var noNormalize: Bool
    public var noPathResolution: Bool

    public init(
        files: [String] = [],
        projectName: String? = nil,
        profiles: [String] = [],
        envFiles: [String] = [],
        projectDirectory: String? = nil,
        normalization: NormalizationOptions = NormalizationOptions(),
    ) {
        self.files = files
        self.projectName = projectName
        self.profiles = profiles
        self.envFiles = envFiles
        self.projectDirectory = projectDirectory
        noConsistency = normalization.noConsistency
        noEnvResolution = normalization.noEnvResolution
        noInterpolate = normalization.noInterpolate
        noNormalize = normalization.noNormalize
        noPathResolution = normalization.noPathResolution
    }
}
