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

/// One Docker image-to-volume initialization requested by Compose lifecycle policy.
///
/// The request intentionally describes only generic runtime inputs. Compose owns
/// Docker's decisions about when a target needs copy-up, anonymous-volume
/// naming, and `nocopy` handling.
public struct ComposeImageVolumeInitializationRequest: Equatable, Sendable {
    /// Resolved image reference containing the source filesystem.
    public var image: String
    /// Optional OCI platform selected by the Compose service.
    public var platform: String?
    /// Absolute source path inside the image filesystem.
    public var imageSubpath: String
    /// Runtime name of the local target volume.
    public var volumeName: String

    public init(
        image: String,
        platform: String? = nil,
        imageSubpath: String,
        volumeName: String,
    ) {
        self.image = image
        self.platform = platform
        self.imageSubpath = imageSubpath
        self.volumeName = volumeName
    }
}

/// Initializes a local runtime volume from one unpacked image filesystem path.
///
/// Implementations must preserve populated volumes unchanged. The caller only
/// invokes this operation after Compose has created or resolved the target
/// resource and selected Docker-compatible lifecycle semantics.
public protocol ComposeRuntimeImageVolumeInitializing: Sendable {
    /// Seeds `request.volumeName` from `request.imageSubpath` when the target
    /// volume has no user data.
    func initializeImageVolume(_ request: ComposeImageVolumeInitializationRequest) async throws
}
