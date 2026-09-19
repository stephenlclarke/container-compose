// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

extension ComposeService {
    /// Preserve the declared service for labels and config hashes. Only image
    /// metadata and copy-up use this provider-selected preparation view.
    func selectingImage(_ selection: ComposeImageSelection?) -> ComposeService {
        guard let selection else { return self }
        var selected = self
        selected.image = selection.reference
        selected.platform = selection.platform
        return selected
    }
}
