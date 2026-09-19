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
import ComposeRuntimeSPI
import Foundation
import Testing

struct ComposeImageSelectionTests {
    private let identity = ComposeImageSelection(
        reference: "sha256:" + String(repeating: "a", count: 64), platform: "linux/arm64"
    )

    @Test func healthAndVolumePreparationShareTheSelectedImage() async throws {
        let images = RecordingContainerImageManager(
            platformHealthChecks: [.init(reference: identity.reference, platform: identity.platform):
                ComposeImageHealthCheck(test: ["CMD", "/selected-health"])],
            platformImageVolumeTargets: [.init(reference: identity.reference, platform: identity.platform): ["/data"]]
        )
        await images.setCreationSelection(identity, for: "fixture:mutable")
        let volumes = RecordingContainerImageVolumeInitializer()
        let resources = RecordingContainerResourceManager()
        let dependencies = orchestratorDependencies {
            $0.imageManager = images
            $0.imageVolumeInitializer = volumes
            $0.resourceManager = resources
        }
        let service = composeService(name: "app", image: "fixture:mutable")
        let project = composeProject(name: "demo", services: ["app": service])
        let launch = try await ComposeOrchestrator(dependencies: dependencies)
            .serviceLaunchPlan(project: project, service: service)
        #expect(launch.configuration.imageReference == "fixture:mutable")
        #expect(launch.configuration.imageSelection == identity)
        #expect(launch.configuration.healthCheck?.process.executable == "/bin/sh")
        #expect(launch.configuration.healthCheck?.process.arguments == ["-c", "/selected-health"])
        #expect(launch.arguments.containsSequence(["--health-cmd", "/selected-health"]))
        #expect(await images.creationSelectionRequests == [.init(reference: "fixture:mutable", platform: nil)])
        let requests = await images.requests
        #expect(requests.contains(.healthCheck(reference: identity.reference, platform: identity.platform)))
        #expect(!requests.contains(.healthCheck(reference: "fixture:mutable", platform: nil)))
        #expect(requests.contains(.volumeTargets(reference: identity.reference, platform: identity.platform)))
        let initializations = await volumes.requests
        #expect(initializations.count == 1)
        #expect(initializations.first?.image == identity.reference)
        #expect(initializations.first?.platform == identity.platform)
        let data = try JSONEncoder().encode(launch.configuration)
        #expect(try JSONDecoder().decode(ContainerServiceCreatePlan.self, from: data) == launch.configuration)
    }

    @Test func dryRunDoesNotSelectOrInspectAnImage() async throws {
        let images = RecordingContainerImageManager()
        await images.setCreationSelection(identity, for: "fixture:mutable")
        let dependencies = orchestratorDependencies { $0.imageManager = images }
        let service = composeService(name: "app", image: "fixture:mutable")
        let launch = try await ComposeOrchestrator(options: .init(dryRun: true), dependencies: dependencies)
            .serviceLaunchPlan(project: composeProject(name: "demo", services: ["app": service]), service: service)
        #expect(launch.configuration.imageSelection == nil)
        #expect(await images.creationSelectionRequests.isEmpty)
        #expect(await images.requests.isEmpty)
    }

    @Test func oldPlansDecodeWithoutSelection() throws {
        let plan = ContainerServiceCreatePlan(identity: .init(name: "app", imageReference: "fixture:mutable"))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        json.removeValue(forKey: "imageSelection")
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(ContainerServiceCreatePlan.self, from: data).imageSelection == nil)
    }
}
