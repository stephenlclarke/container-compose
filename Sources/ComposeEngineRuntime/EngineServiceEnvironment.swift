// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
import ComposeRuntimeSPI
import Foundation

/// Resolves captured env-file bytes without shell evaluation or hidden file IO.
/// The caller owns bounded acquisition; all files must be captured in plan order.
enum EngineServiceEnvironment {
    static func resolve(
        _ plan: ContainerServiceCreatePlan, fileContents: [Data], hostEnvironment: [String: String]
    ) throws -> ComposeProcessOverrides {
        guard plan.environmentFiles.count == fileContents.count else {
            throw ComposeError.invalidProject("Environment files have not all been captured")
        }
        var result = plan.processOverrides
        var environment: [String: String?] = [:]
        for data in fileContents {
            for (key, value) in try parse(data, hostEnvironment: hostEnvironment) {
                environment[key] = .some(value)
            }
        }
        // Mirrors the current launch provider: explicit service/run environment
        // wins over file values; a later file wins over an earlier file.
        for (key, value) in plan.processOverrides.environment {
            let resolved = value ?? hostEnvironment[key]
            environment[key] = .some(resolved)
        }
        result.environment = environment
        return result
    }

    static func parse(_ data: Data, hostEnvironment: [String: String]) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComposeError.invalidProject("Environment file is not valid UTF-8")
        }
        var environment: [String: String] = [:]
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            // Match the line scanner's bound without including secret contents
            // in errors. CRLF is one delimiter; embedded CR is not a new line.
            guard rawLine.utf8.count < 65_536 else {
                throw ComposeError.invalidProject("Environment file line exceeds its size limit")
            }
            var line = rawLine[...]
            if line.last == "\r" { line = line.dropLast() }
            if index == 0, line.first == "\u{FEFF}" { line = line.dropFirst() }
            line = line.drop { $0.isWhitespace }
            if line.isEmpty || line.first == "#" { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard !key.isEmpty, !key.contains(where: { $0 == " " || $0 == "\t" }), !line.contains("\0") else {
                throw ComposeError.invalidProject("Invalid environment file key or value at line \(index + 1)")
            }
            if parts.count == 2 {
                environment[key] = String(parts[1])
            } else if let value = hostEnvironment[key] {
                environment[key] = value
            }
        }
        return environment
    }
}
