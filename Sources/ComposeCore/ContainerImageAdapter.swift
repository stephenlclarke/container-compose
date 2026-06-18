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

/// Low-level Apple image calls used by `ContainerClientImageManager`.
public protocol ContainerImageAPIClienting: Sendable {
    /// Returns whether `reference` exists in the local image store.
    func imageExists(reference: String) async throws -> Bool

    /// Pulls and unpacks `reference`.
    func pullImage(reference: String) async throws

    /// Pushes `reference` and returns the runtime image reference that was pushed.
    func pushImage(reference: String) async throws -> String

    /// Deletes `reference`, returning the runtime image reference that was deleted.
    func deleteImage(reference: String, force: Bool) async throws -> String?
}

/// Direct Apple container image APIs used for Compose image workflows.
public protocol ContainerImageManaging: Sendable {
    /// Returns whether `reference` exists in the local image store.
    func imageExists(_ reference: String) async throws -> Bool

    /// Pulls `reference`.
    func pullImage(_ reference: String) async throws

    /// Pulls `reference` only when it is missing from the local image store.
    func pullMissingImage(_ reference: String) async throws

    /// Pushes `reference` and emits the pushed runtime reference when available.
    func pushImage(_ reference: String, emit: @escaping @Sendable (String) -> Void) async throws

    /// Deletes `reference` and emits the deleted runtime reference when available.
    func deleteImage(_ reference: String, force: Bool, emit: @escaping @Sendable (String) -> Void) async throws
}

/// Thin Apple `container` client wrapper around image API calls.
public struct ContainerImageAPIClient: ContainerImageAPIClienting {
    public typealias Exists = @Sendable (String) async throws -> Bool
    public typealias Pull = @Sendable (String) async throws -> Void
    public typealias Push = @Sendable (String) async throws -> String
    public typealias Delete = @Sendable (String, Bool) async throws -> String?

    private let existsOperation: Exists
    private let pullOperation: Pull
    private let pushOperation: Push
    private let deleteOperation: Delete

    /// Creates a facade around another image API client.
    public init(client: ContainerImageAPIClienting) {
        self.init(
            exists: { try await client.imageExists(reference: $0) },
            pull: { try await client.pullImage(reference: $0) },
            push: { try await client.pushImage(reference: $0) },
            delete: { try await client.deleteImage(reference: $0, force: $1) }
        )
    }

    /// Creates a facade from explicit image operation closures.
    public init(
        exists: @escaping Exists,
        pull: @escaping Pull,
        push: @escaping Push,
        delete: @escaping Delete
    ) {
        self.existsOperation = exists
        self.pullOperation = pull
        self.pushOperation = push
        self.deleteOperation = delete
    }

    /// Creates a facade around the live Apple `container` image API bridge.
    public init() {
        self.init(client: ContainerImageLiveAPIClient())
    }

    /// Checks the local image store through `ClientImage.get(names:)`.
    public func imageExists(reference: String) async throws -> Bool {
        try await existsOperation(reference)
    }

    /// Pulls and unpacks an image through `ClientImage`.
    public func pullImage(reference: String) async throws {
        try await pullOperation(reference)
    }

    /// Pushes an image through `ClientImage`.
    public func pushImage(reference: String) async throws -> String {
        try await pushOperation(reference)
    }

    /// Deletes an image through `ClientImage`.
    public func deleteImage(reference: String, force: Bool) async throws -> String? {
        try await deleteOperation(reference, force)
    }
}

/// `ClientImage`-backed manager for Compose image operations.
public struct ContainerClientImageManager: ContainerImageManaging {
    private let client: ContainerImageAPIClienting

    public init(client: ContainerImageAPIClienting = ContainerImageAPIClient()) {
        self.client = client
    }

    /// Checks the local image store through the direct Apple image API.
    public func imageExists(_ reference: String) async throws -> Bool {
        try await client.imageExists(reference: reference)
    }

    /// Pulls an image through the direct Apple image API.
    public func pullImage(_ reference: String) async throws {
        try await client.pullImage(reference: reference)
    }

    /// Pulls an image only when `ClientImage.get` cannot resolve it locally.
    public func pullMissingImage(_ reference: String) async throws {
        let exists = try await client.imageExists(reference: reference)
        guard !exists else {
            return
        }
        try await client.pullImage(reference: reference)
    }

    /// Pushes an image and emits the pushed reference.
    public func pushImage(_ reference: String, emit: @escaping @Sendable (String) -> Void) async throws {
        let pushed = try await client.pushImage(reference: reference)
        if !pushed.isEmpty {
            emit(pushed)
        }
    }

    /// Deletes an image and emits the deleted reference when one was found.
    public func deleteImage(_ reference: String, force: Bool, emit: @escaping @Sendable (String) -> Void) async throws {
        guard let deleted = try await client.deleteImage(reference: reference, force: force), !deleted.isEmpty else {
            return
        }
        emit(deleted)
    }
}
