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

import ComposeCore
import Foundation
@testable import ComposePlugin
import Testing

@Suite("Compose loading progress")
struct ComposeProgressLoadingTests {
    @Test("project loading emits first progress row before normalizer starts")
    func projectLoadingEmitsFirstProgressRowBeforeNormalizerStarts() async throws {
        let emitted = LockedDataRecorder()
        let progress = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append($0) },
        )
        let project = try await GlobalOptions().loadProject(
            options: ComposeOptions(files: ["compose.yml"]),
            progress: progress,
            normalize: { options in
                #expect(options.files == ["compose.yml"])
                #expect(emitted.string == "⠓ Loading Compose model\n")
                return ComposeProject(name: "demo", services: [:])
            }
        )

        #expect(project.name == "demo")
        #expect(emitted.string == "⠓ Loading Compose model\n✔︎ Loading Compose model\n")
    }

    @Test("variable loading emits first progress row before normalizer starts")
    func variableLoadingEmitsFirstProgressRowBeforeNormalizerStarts() async throws {
        let emitted = LockedDataRecorder()
        let progress = ComposeProgressReporter(
            style: .plain,
            emitData: { emitted.append($0) },
        )
        let variables = try await GlobalOptions().loadVariables(
            options: ComposeOptions(files: ["compose.yml"]),
            progress: progress,
            variables: { options in
                #expect(options.files == ["compose.yml"])
                #expect(emitted.string == "⠓ Loading Compose variables\n")
                return [ComposeVariable(name: "TAG", defaultValue: "latest")]
            }
        )

        #expect(variables == [ComposeVariable(name: "TAG", defaultValue: "latest")])
        #expect(emitted.string == "⠓ Loading Compose variables\n✔︎ Loading Compose variables\n")
    }
}

private final class LockedDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer {
            lock.unlock()
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
