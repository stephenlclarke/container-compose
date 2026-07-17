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

/// Compose-owned labels shared by orchestration and runtime providers.
public enum ComposeRuntimeLabels {
    public static let project = "com.apple.container.compose.project"
    public static let service = "com.apple.container.compose.service"
    public static let oneOff = "com.apple.container.compose.oneoff"
    public static let reservedPrefix = "com.apple.container.compose."
    public static let reservedDockerComposePrefix = "com.docker.compose."
}
