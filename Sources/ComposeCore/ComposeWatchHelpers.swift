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

/// One service trigger and its last observed filesystem state.
struct ComposeWatchPlan {
    var service: ComposeService
    var trigger: ComposeDevelopWatch
    var snapshot: [String: ComposeWatchEntry]

    var action: String {
        trigger.action.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A host file tracked by a `develop.watch` trigger.
struct ComposeWatchEntry: Equatable {
    var relativePath: String
    var sourcePath: String
    var modifiedAt: Date?
    var size: UInt64?
}

/// A host-side change that must be reflected into service containers.
enum ComposeWatchChange {
    case upsert(ComposeWatchEntry)
    case delete(relativePath: String)

    var entry: ComposeWatchEntry? {
        guard case let .upsert(entry) = self else {
            return nil
        }
        return entry
    }

    var deletedRelativePath: String? {
        guard case let .delete(relativePath) = self else {
            return nil
        }
        return relativePath
    }
}

/// Validated `sync+exec` hook settings.
struct ComposeWatchExecHook {
    var command: [String]
    var user: String?
    var workingDirectory: String?
    var environment: [String]
    var privileged: Bool
}

/// Returns a project suitable for ordinary runtime orchestration while
/// `compose watch` owns the Develop Specification behavior.
func projectWithoutDevelopMetadata(_ project: ComposeProject) -> ComposeProject {
    var copy = project
    for (name, service) in copy.services {
        var runtimeService = service
        runtimeService.develop = nil
        copy.services[name] = runtimeService
    }
    return copy
}

/// Captures the current files matched by one watch trigger.
func watchSnapshot(project: ComposeProject, trigger: ComposeDevelopWatch) throws -> [String: ComposeWatchEntry] {
    let rootURL = resolvedWatchURL(project: project, path: trigger.path)
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
        throw ComposeError.invalidProject("develop.watch path does not exist: \(trigger.path)")
    }

    if !isDirectory.boolValue {
        let matchPath = rootURL.lastPathComponent
        guard watchPathIncluded(matchPath, trigger: trigger) else {
            return [:]
        }
        return try [".": watchEntry(url: rootURL, relativePath: ".")]
    }

    let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
    guard let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants],
    ) else {
        return [:]
    }

    var snapshot: [String: ComposeWatchEntry] = [:]
    for case let url as URL in enumerator {
        let relativePath = watchRelativePath(rootURL: rootURL, url: url)
        let values = try url.resourceValues(forKeys: Set(keys))
        if values.isDirectory == true {
            if watchPathIgnored(relativePath, trigger: trigger) {
                enumerator.skipDescendants()
            }
            continue
        }
        guard watchPathIncluded(relativePath, trigger: trigger) else {
            continue
        }
        snapshot[relativePath] = ComposeWatchEntry(
            relativePath: relativePath,
            sourcePath: url.path,
            modifiedAt: values.contentModificationDate,
            size: values.fileSize.map(UInt64.init),
        )
    }
    return snapshot
}

/// Resolves relative Compose watch paths from the project directory.
func resolvedWatchURL(project: ComposeProject, path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: project.workingDirectory)).standardizedFileURL
}

/// Builds a stable relative path with POSIX separators for matching.
func watchRelativePath(rootURL: URL, url: URL) -> String {
    let root = rootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard path.hasPrefix(prefix) else {
        return url.lastPathComponent
    }
    return String(path.dropFirst(prefix.count))
}

/// Creates a watch entry from a host file URL.
func watchEntry(url: URL, relativePath: String) throws -> ComposeWatchEntry {
    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return ComposeWatchEntry(
        relativePath: relativePath,
        sourcePath: url.path,
        modifiedAt: values.contentModificationDate,
        size: values.fileSize.map(UInt64.init),
    )
}

/// Diffs two snapshots into deterministic upsert/delete changes.
func watchChanges(
    previous: [String: ComposeWatchEntry],
    latest: [String: ComposeWatchEntry],
) -> [ComposeWatchChange] {
    let upserts = latest.keys.sorted().compactMap { key -> ComposeWatchChange? in
        guard previous[key] != latest[key], let entry = latest[key] else {
            return nil
        }
        return .upsert(entry)
    }
    let deletes = previous.keys
        .filter { latest[$0] == nil }
        .sorted()
        .map { ComposeWatchChange.delete(relativePath: $0) }
    return upserts + deletes
}

/// Returns the target path for a watched file relative to the trigger target.
func watchTargetPath(trigger: ComposeDevelopWatch, relativePath: String) throws -> String {
    guard let target = nonEmpty(trigger.target) else {
        throw ComposeError.invalidProject("develop.watch action '\(trigger.action)' requires a target")
    }
    guard relativePath != "." && !relativePath.isEmpty else {
        return target
    }
    return target.hasSuffix("/") ? target + relativePath : target + "/" + relativePath
}

/// Converts Compose key/value environment metadata to exec arguments.
func environmentArguments(_ values: [String: String?]) -> [String] {
    values.keys.sorted().map { key in
        guard let value = values[key] ?? nil else {
            return key
        }
        return "\(key)=\(value)"
    }
}

/// Applies include and ignore rules to a normalized relative path.
func watchPathIncluded(_ relativePath: String, trigger: ComposeDevelopWatch) -> Bool {
    guard !watchPathIgnored(relativePath, trigger: trigger) else {
        return false
    }
    guard let include = trigger.include, !include.isEmpty else {
        return true
    }
    return include.contains { watchPattern($0, matches: relativePath) }
}

/// Returns true when any ignore pattern excludes the path.
func watchPathIgnored(_ relativePath: String, trigger: ComposeDevelopWatch) -> Bool {
    guard let ignore = trigger.ignore, !ignore.isEmpty else {
        return false
    }
    return ignore.contains { watchPattern($0, matches: relativePath) }
}

/// Matches Compose watch glob patterns against relative paths or basenames.
func watchPattern(_ rawPattern: String, matches rawRelativePath: String) -> Bool {
    let pattern = normalizedWatchPath(rawPattern)
    let relativePath = normalizedWatchPath(rawRelativePath)
    guard !pattern.isEmpty else {
        return false
    }
    if pattern.hasSuffix("/") {
        let directory = String(pattern.dropLast())
        return relativePath == directory || relativePath.hasPrefix(directory + "/")
    }
    if pattern.contains("/") {
        return glob(pattern, matches: relativePath)
    }
    return glob(pattern, matches: (relativePath as NSString).lastPathComponent)
}

/// Normalizes watch paths to POSIX separators for deterministic matching.
func normalizedWatchPath(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "/")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

/// Minimal glob matching for Compose watch include/ignore filters.
func glob(_ pattern: String, matches value: String) -> Bool {
    var regex = "^"
    for character in pattern {
        switch character {
        case "*":
            regex += ".*"
        case "?":
            regex += "."
        case ".", "+", "(", ")", "^", "$", "|", "{", "}", "[", "]", "\\":
            regex += "\\\(character)"
        default:
            regex.append(character)
        }
    }
    regex += "$"
    return value.range(of: regex, options: .regularExpression) != nil
}

/// Splits log output bytes into records without requiring UTF-8 decoding.
func recordsForCompleteLogData(_ output: Data) -> [Data] {
    guard !output.isEmpty else {
        return []
    }

    var records: [Data] = []
    var current = Data()
    var index = output.startIndex
    while index < output.endIndex {
        let byte = output[index]
        if byte == UInt8(ascii: "\n") {
            records.append(current)
            current.removeAll()
            index = output.index(after: index)
        } else if byte == UInt8(ascii: "\r") {
            records.append(current)
            current.removeAll()
            let next = output.index(after: index)
            if next < output.endIndex, output[next] == UInt8(ascii: "\n") {
                index = output.index(after: next)
            } else {
                index = next
            }
        } else {
            current.append(byte)
            index = output.index(after: index)
        }
    }
    if !current.isEmpty {
        records.append(current)
    }
    return records
}
