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
import Testing

@Suite("Compose command option defaults")
struct ComposeCommandOptionsTests {
    @Test
    func `default constructors match Docker Compose command defaults`() {
        let start = ComposeStartOptions()
        #expect(start.services.isEmpty)
        #expect(!start.wait)
        #expect(start.waitTimeout == nil)

        let restart = ComposeRestartOptions()
        #expect(restart.services.isEmpty)
        #expect(!restart.noDeps)
        #expect(restart.timeout == nil)

        let build = ComposeBuildOptions()
        #expect(build.services.isEmpty)
        #expect(build.buildArguments.isEmpty)
        #expect(build.builder == nil)
        #expect(!build.check)
        #expect(build.memory == nil)
        #expect(!build.noCache)
        #expect(!build.printBake)
        #expect(!build.pull)
        #expect(!build.push)
        #expect(!build.quiet)
        #expect(build.provenance == nil)
        #expect(build.sbom == nil)
        #expect(build.ssh.isEmpty)
        #expect(!build.withDependencies)

        let exec = ComposeExecOptions()
        #expect(exec.command.isEmpty)
        #expect(exec.interactive)
        #expect(exec.tty)
        #expect(!exec.detach)
        #expect(exec.environment.isEmpty)
        #expect(exec.index == 1)
        #expect(!exec.privileged)
        #expect(exec.user == nil)
        #expect(exec.workingDirectory == nil)

        let copy = ComposeCopyOptions()
        #expect(copy.arguments.isEmpty)
        #expect(!copy.all)
        #expect(!copy.archive)
        #expect(!copy.followLink)
        #expect(copy.index == 1)

        let runArguments = RunArgumentOptions()
        #expect(runArguments.command == "run")
        #expect(!runArguments.detach)
        #expect(!runArguments.remove)
        #expect(!runArguments.oneOff)
        #expect(runArguments.containerIndex == nil)
        #expect(runArguments.replicaCount == nil)
        #expect(runArguments.publishedPorts == nil)
        #expect(runArguments.containerNameOverride == nil)
        #expect(runArguments.labelOverrides.isEmpty)
        #expect(runArguments.envFiles.isEmpty)
    }
}
