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

#if canImport(Darwin)
    import Darwin
#endif
import Dispatch

/// Runs an async operation while forwarding host signals to a caller-supplied handler.
public protocol ComposeSignalProxying: Sendable {
    /// Installs handlers for `signals`, runs `operation`, then removes the handlers.
    func withSignalProxy(
        signals: [String],
        handler: @escaping @Sendable (String) async -> Void,
        operation: @escaping @Sendable () async throws -> Void,
    ) async throws
}

/// Dispatch-backed signal proxy used by interactive-ish Compose operations.
public struct DispatchComposeSignalProxy: ComposeSignalProxying {
    public init() {
        // Public initializer keeps the dispatch-backed proxy constructible outside this module.
    }

    public func withSignalProxy(
        signals: [String],
        handler: @escaping @Sendable (String) async -> Void,
        operation: @escaping @Sendable () async throws -> Void,
    ) async throws {
        #if canImport(Darwin)
            let mappings = signals.compactMap(Self.signalMapping(named:))
            guard !mappings.isEmpty else {
                try await operation()
                return
            }

            let queue = DispatchQueue(label: "container-compose.signal-proxy")
            var sources: [DispatchSourceSignal] = []
            var previousHandlers: [(Int32, (@convention(c) (Int32) -> Void)?)] = []
            for mapping in mappings {
                previousHandlers.append((mapping.number, Darwin.signal(mapping.number, SIG_IGN)))
                let source = DispatchSource.makeSignalSource(signal: mapping.number, queue: queue)
                source.setEventHandler {
                    Task {
                        await handler(mapping.name)
                    }
                }
                source.resume()
                sources.append(source)
            }
            defer {
                for source in sources {
                    source.cancel()
                }
                for (number, previousHandler) in previousHandlers {
                    _ = Darwin.signal(number, previousHandler)
                }
            }

            try await operation()
        #else
            _ = signals
            _ = handler
            try await operation()
        #endif
    }

    #if canImport(Darwin)
        private static func signalMapping(named name: String) -> (name: String, number: Int32)? {
            switch name {
            case "SIGHUP":
                ("SIGHUP", SIGHUP)
            case "SIGINT":
                ("SIGINT", SIGINT)
            case "SIGQUIT":
                ("SIGQUIT", SIGQUIT)
            case "SIGTERM":
                ("SIGTERM", SIGTERM)
            default:
                nil
            }
        }
    #endif
}
