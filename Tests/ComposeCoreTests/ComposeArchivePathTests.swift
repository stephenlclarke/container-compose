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

@testable import ComposeCore
import Foundation
import Testing

@Suite("Compose archive paths")
struct ComposeArchivePathTests {
    @Test
    func `root contents source selects root archive contents`() {
        let source = ComposeArchivePath.source(ComposeArchivePath.rootContents)

        #expect(source.path == ComposeArchivePath.root)
        #expect(source.copyContents)
    }

    @Test
    func `nested contents source strips only the contents suffix`() {
        let directory = "\(ComposeArchivePath.root)workspace"
        let source = ComposeArchivePath.source("\(directory)\(ComposeArchivePath.rootContents)")

        #expect(source.path == directory)
        #expect(source.copyContents)
        #expect(ComposeArchivePath.source(directory).copyContents == false)
    }

    @Test
    func `copy contents source normalizes root and trailing separators`() {
        let directory = "\(ComposeArchivePath.root)workspace"

        #expect(ComposeArchivePath.contentsSource(ComposeArchivePath.root) == ComposeArchivePath.rootContents)
        #expect(ComposeArchivePath.contentsSource(directory) == "\(directory)\(ComposeArchivePath.rootContents)")
        #expect(
            ComposeArchivePath.contentsSource("\(directory)\(ComposeArchivePath.root)")
                == "\(directory)\(ComposeArchivePath.rootContents)",
        )
    }

    @Test
    func `legacy commit request API forwards to grouped image configuration`() {
        let baseImage = ComposeImageMetadata(reference: "example/base:latest")
        let healthCheck = ComposeImageHealthCheck(test: ["CMD", "true"])
        let createdAt = Date(timeIntervalSince1970: 1_785_400_000)
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/compose-legacy-request")
        var request = ComposeCommitImageArchiveRequest(
            rootfsArchive: temporaryDirectory.appending(path: "rootfs.tar"),
            output: temporaryDirectory.appending(path: "image.tar"),
            service: ComposeService(name: "app", image: "example/app:latest"),
            options: ComposeCommitOptions(),
            baseImage: baseImage,
            healthCheck: healthCheck,
            createdAt: createdAt,
            shellPath: "/bin/bash",
            temporaryDirectory: temporaryDirectory,
        )

        #expect(request.baseImage == baseImage)
        #expect(request.healthCheck == healthCheck)
        #expect(request.createdAt == createdAt)
        #expect(request.shellPath == "/bin/bash")
        request.shellPath = "/bin/zsh"
        #expect(request.image.shellPath == "/bin/zsh")
    }
}
