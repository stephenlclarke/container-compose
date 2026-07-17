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

/// Compatibility names for clients that adopted the original adapter API.
///
/// These aliases remain runtime-neutral despite their historical Container
/// prefix, and will be removed only in a future major-version migration.
public typealias ContainerConfigReading = ComposeRuntimeConfigReading
public typealias ContainerCopying = ComposeRuntimeCopying
public typealias ContainerDiscoveryManaging = ComposeRuntimeDiscoveryManaging
public typealias ContainerEventsManaging = ComposeRuntimeEventsManaging
public typealias ContainerExecManaging = ComposeRuntimeExecManaging
public typealias ContainerExporting = ComposeRuntimeExporting
public typealias ContainerImageManaging = ComposeRuntimeImageManaging
public typealias ContainerLifecycleManaging = ComposeRuntimeLifecycleManaging
public typealias ContainerLogManaging = ComposeRuntimeLogManaging
public typealias ContainerResourceManaging = ComposeRuntimeResourceManaging
public typealias ContainerSecretReading = ComposeRuntimeSecretReading
public typealias ContainerStatsManaging = ComposeRuntimeStatsManaging
public typealias ContainerTopManaging = ComposeRuntimeTopManaging
