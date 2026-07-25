//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

func structuredTemplateHasLeftTrimMarker(
    _ template: String,
    at marker: String.Index,
) -> Bool {
    guard marker < template.endIndex, template[marker] == "-" else {
        return false
    }
    let whitespace = template.index(after: marker)
    return whitespace < template.endIndex && template[whitespace].isWhitespace
}

func structuredTemplateHasRightTrimMarker(
    _ template: String,
    contentStart: String.Index,
    contentEnd: String.Index,
) -> Bool {
    guard contentEnd > contentStart else {
        return false
    }
    let marker = template.index(before: contentEnd)
    guard template[marker] == "-", marker > contentStart else {
        return false
    }
    return template[template.index(before: marker)].isWhitespace
}
