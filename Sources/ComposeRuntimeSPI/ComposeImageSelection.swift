// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

/// A provider-selected immutable image identity for one container preparation.
/// All metadata, copy-up and create operations must address this reference.
public struct ComposeImageSelection: Codable, Equatable, Sendable {
    public let reference: String
    public let platform: String

    public init(reference: String, platform: String) {
        self.reference = reference
        self.platform = platform
    }
}
