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

import ContainerResource
import CryptoKit
import Foundation

/// Returns a SHA-256 hex digest for stable names and labels.
func stableHash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Converts arbitrary Compose names into names accepted by runtime resources.
func slug(_ value: String) -> String {
    var result = value.map { char -> Character in
        if char.isLetter || char.isNumber || char == "." || char == "_" || char == "-" {
            return char
        }
        return "-"
    }
    while let first = result.first, !(first.isLetter || first.isNumber) {
        result.removeFirst()
    }
    if result.isEmpty {
        return "compose"
    }
    return String(result)
}

/// Quotes a command line for dry-run output and error messages.
func shellQuoted(_ parts: [String]) -> String {
    parts.map { part in
        if part.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=,".contains($0) }) {
            return part
        }
        return "'" + part.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}
