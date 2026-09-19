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

/// A normalized mount together with its final native source identity.
/// The original definition retains access, ownership and subpath policy.
public struct ComposeResolvedMount: Codable, Equatable, Sendable {
    public var definition: ComposeMount
    public var source: String?

    public init(definition: ComposeMount, source: String?) {
        self.definition = definition
        self.source = source
    }
}
