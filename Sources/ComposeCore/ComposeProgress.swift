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

/// Rendering mode for Compose-owned progress feedback.
public enum ComposeProgressStyle: Equatable, Sendable {
    case quiet
    case plain
    case json
    case tty
}

/// Emits lightweight progress rows around long-running Compose phases.
public struct ComposeProgressReporter: Sendable {
    public static let disabled = ComposeProgressReporter(style: .quiet)

    public var style: ComposeProgressStyle
    public var colorEnabled: Bool
    public var emitData: @Sendable (Data) -> Void
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        style: ComposeProgressStyle,
        colorEnabled: Bool = false,
        emitData: @escaping @Sendable (Data) -> Void = { _ in
            // Silent until the CLI wires progress output to stderr.
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ) {
        self.style = style
        self.colorEnabled = colorEnabled
        self.emitData = emitData
        self.sleep = sleep
    }

    /// Runs one asynchronous operation while rendering a progress activity.
    public func activity<T>(_ message: String, operation: () async throws -> T) async throws -> T {
        switch style {
        case .quiet:
            try await operation()
        case .plain:
            try await plainActivity(message, operation: operation)
        case .json:
            try await jsonActivity(message, operation: operation)
        case .tty:
            try await ttyActivity(message, operation: operation)
        }
    }

    /// Emits the first progress frame before handing terminal control to the runtime.
    public func handoff(_ message: String) {
        switch style {
        case .quiet:
            return
        case .plain:
            emitLine(mark: Self.pendingMark, color: Self.progressColor, message: message)
        case .json:
            emitJSON(status: "running", message: message)
        case .tty:
            emit("\(colored(Self.frames[0], color: Self.progressColor)) \(message)\n")
        }
    }

    private func plainActivity<T>(_ message: String, operation: () async throws -> T) async throws -> T {
        emitLine(mark: Self.pendingMark, color: Self.progressColor, message: message)
        do {
            let result = try await operation()
            emitLine(mark: Self.doneMark, color: Self.successColor, message: message)
            return result
        } catch {
            emitLine(mark: Self.failedMark, color: Self.failureColor, message: message)
            throw error
        }
    }

    private func jsonActivity<T>(_ message: String, operation: () async throws -> T) async throws -> T {
        emitJSON(status: "running", message: message)
        do {
            let result = try await operation()
            emitJSON(status: "done", message: message)
            return result
        } catch {
            emitJSON(status: "error", message: message)
            throw error
        }
    }

    private func ttyActivity<T>(_ message: String, operation: () async throws -> T) async throws -> T {
        emit(renderedTTYFrame(message: message, frameIndex: 0))
        let spinner = Task<Void, Never> {
            var frameIndex = 1
            while !Task.isCancelled {
                do {
                    try await sleep(.milliseconds(100))
                } catch {
                    return
                }
                emit(renderedTTYFrame(message: message, frameIndex: frameIndex))
                frameIndex += 1
            }
        }
        do {
            let result = try await operation()
            await stop(spinner: spinner, mark: Self.doneMark, color: Self.successColor, message: message)
            return result
        } catch {
            await stop(spinner: spinner, mark: Self.failedMark, color: Self.failureColor, message: message)
            throw error
        }
    }

    private func stop(spinner: Task<Void, Never>, mark: String, color: String, message: String) async {
        spinner.cancel()
        await spinner.value
        emit("\r\u{001B}[K")
        emitLine(mark: mark, color: color, message: message)
    }

    private func renderedTTYFrame(message: String, frameIndex: Int) -> String {
        "\r\(colored(Self.frames[frameIndex % Self.frames.count], color: Self.progressColor)) \(message)"
    }

    private func emitLine(mark: String, color: String, message: String) {
        emit("\(colored(mark, color: color)) \(message)\n")
    }

    private func emitJSON(status: String, message: String) {
        let event = ProgressEvent(id: Self.progressID, status: status, text: message)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event) else {
            return
        }
        emitData(data)
        emit("\n")
    }

    private func colored(_ value: String, color: String) -> String {
        guard colorEnabled else {
            return value
        }
        return "\(color)\(value)\(Self.resetColor)"
    }

    private func emit(_ text: String) {
        emitData(Data(text.utf8))
    }

    private static let progressID = "container-compose"
    private static let frames = ["⠓", "⠋", "⠙", "⠚", "⠖", "⡆", "⣄", "⣠", "⢰", "⠲"]
    private static let pendingMark = "⠓"
    private static let doneMark = "✓"
    private static let failedMark = "✘"
    private static let progressColor = "\u{001B}[38;5;63m"
    private static let successColor = "\u{001B}[32m"
    private static let failureColor = "\u{001B}[31m"
    private static let resetColor = "\u{001B}[0m"
}

private struct ProgressEvent: Encodable {
    var id: String
    var status: String
    var text: String
}
