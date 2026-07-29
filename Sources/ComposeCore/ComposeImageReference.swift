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

import Foundation

enum ComposeImageReference {
    struct Parsed {
        var domain: String?
        var path: String
        var tag: String?
        var digest: String?

        var name: String {
            domain.map { "\($0)/\(path)" } ?? path
        }
    }

    static func parse(_ input: String) throws -> Parsed {
        guard input.count <= 384, input.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil else {
            throw ComposeError.invalidProject("invalid image reference '\(input)'")
        }
        let (domain, remainder) = parseDomain(input)
        if let domain {
            let label = #"(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9])"#
            let domainPattern = #"^(?:localhost|\#(label)(?:\.\#(label))*|\[[A-Fa-f0-9:]+\])(?::[0-9]+)?$"#
            guard domain.range(of: domainPattern, options: .regularExpression) != nil else {
                throw ComposeError.invalidProject("invalid image reference '\(input)'")
            }
        }

        let pathPattern = #"(?<path>(?:[a-z0-9]+(?:[._]|__|-|/)?)*[a-z0-9]+)"#
        let tagPattern = #"(?::(?<tag>[\w][\w.-]{0,127}))?"#
        let digestPattern = #"(?:@(?<digest>sha256:[0-9A-Fa-f]{64}))?"#
        let pattern = #"^\#(pathPattern)\#(tagPattern)\#(digestPattern)$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(remainder.startIndex ..< remainder.endIndex, in: remainder)
        guard let match = expression.firstMatch(in: remainder, range: range), match.range == range,
              let pathRange = Range(match.range(withName: "path"), in: remainder)
        else {
            throw ComposeError.invalidProject("invalid image reference '\(input)'")
        }

        let path = String(remainder[pathRange])
        let digest = Range(match.range(withName: "digest"), in: remainder).map { String(remainder[$0]) }
        let tag = digest == nil
            ? Range(match.range(withName: "tag"), in: remainder).map { String(remainder[$0]) }
            : nil
        let parsed = Parsed(domain: domain, path: path, tag: tag, digest: digest)
        guard parsed.name.count <= 255 else {
            throw ComposeError.invalidProject("invalid image reference '\(input)'")
        }
        return parsed
    }

    private static func parseDomain(_ input: String) -> (String?, String) {
        let components = input.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else {
            return input.hasPrefix("localhost") ? (input, "") : (nil, input)
        }

        let candidate = String(components[0])
        guard candidate.hasPrefix("localhost") || candidate.contains(".") || candidate.contains(":") else {
            return (nil, input)
        }
        return (candidate, String(components[1]))
    }

    static func normalized(_ input: String) throws -> String {
        var parsed = try parse(input)
        if let domain = parsed.domain,
           ["docker.io", "registry-1.docker.io"].contains(domain),
           !parsed.path.contains("/")
        {
            parsed.path = "library/\(parsed.path)"
        }
        if let digest = parsed.digest {
            return "\(parsed.name)@\(digest)"
        }
        return "\(parsed.name):\(parsed.tag ?? "latest")"
    }
}
