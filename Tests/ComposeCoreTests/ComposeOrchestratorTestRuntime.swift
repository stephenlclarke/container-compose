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

extension ComposeOrchestrator {
    convenience init(
        runner: CommandRunning,
        options: ComposeExecutionOptions = ComposeExecutionOptions(),
    ) {
        self.init(
            runner: runner,
            options: options,
            dependencies: ComposeOrchestratorDependencies(
                runner: runner,
                options: options,
                imageManager: NoDeclaredVolumeImageManager(),
            ),
        )
    }
}

actor NoDeclaredVolumeImageManager: ComposeRuntimeImageManaging {
    func imageExists(_: String) async throws -> Bool {
        true
    }

    func imageDigest(_ reference: String) async throws -> String {
        reference
    }

    func imageHealthCheck(_: String, platform _: String?) async throws -> ComposeImageHealthCheck? {
        nil
    }

    func imageMetadata(_ reference: String) async throws -> ComposeImageMetadata {
        ComposeImageMetadata(reference: reference)
    }

    func bridgeTransformers() async throws -> [ComposeBridgeTransformer] {
        []
    }

    func pullImage(_: String) async throws {}

    func pushImage(_ reference: String, emit: @escaping @Sendable (String) -> Void) async throws {
        emit(reference)
    }

    func deleteImage(
        _ reference: String,
        force _: Bool,
        emit: @escaping @Sendable (String) -> Void,
    ) async throws {
        emit(reference)
    }

    func loadImageArchive(_: String, emit _: @escaping @Sendable (String) -> Void) async throws {}
}
