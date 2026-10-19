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

@testable import ComposeContainerRuntime
import ComposeRuntimeSPI
import ContainerizationOCI
import ContainerResource
import Foundation
import Testing

@Suite("Container image metadata projection")
struct ContainerImageMetadataTests {
    private let arm = Platform(arch: "arm64", os: "linux")
    private let amd = Platform(arch: "amd64", os: "linux")
    private let digest = "sha256:" + String(repeating: "a", count: 64)

    @Test
    func `metadata preserves the selected platform configuration and healthcheck`() throws {
        let config = ImageConfig(
            user: "1000:1001", env: ["A=1", "B=two words"], entrypoint: ["/entry"], cmd: ["--serve"],
            workingDir: "/work", labels: ["purpose": "fixture"],
            exposedPorts: ["80/tcp": [:], "53/udp": [:]], volumes: ["/z": [:], "/a": [:]],
            stopSignal: "SIGQUIT",
        )
        let health = ImageResource.HealthCheck(
            test: ["CMD-SHELL", "test -f /ready"], intervalInNanoseconds: 20,
            timeoutInNanoseconds: 30, startPeriodInNanoseconds: 40,
            startIntervalInNanoseconds: 50, retries: 3,
        )
        let image = resource(variants: [variant(amd), variant(arm, config: config, health: health)])
        let actual = try #require(ContainerImageLiveAPIClient.metadata(
            reference: "resolved:tag", resource: image, platform: arm, allowFallback: false,
        ))
        let expected = ComposeImageMetadata(reference: "resolved:tag") {
            $0.displayReference = "example/tool:latest"
            $0.user = "1000:1001"
            $0.environment = ["A=1", "B=two words"]
            $0.entrypoint = ["/entry"]
            $0.command = ["--serve"]
            $0.workingDir = "/work"
            $0.labels = ["purpose": "fixture"]
            $0.exposedPorts = ["53/udp", "80/tcp"]
            $0.stopSignal = "SIGQUIT"
            $0.healthCheck = ComposeImageHealthCheck(
                test: ["CMD-SHELL", "test -f /ready"], intervalInNanoseconds: 20,
                timeoutInNanoseconds: 30, startPeriodInNanoseconds: 40,
                startIntervalInNanoseconds: 50, retries: 3,
            )
            $0.declaredVolumeTargets = ["/a", "/z"]
        }
        #expect(actual == expected)
    }

    @Test
    func `explicit unavailable platform never borrows another variant`() {
        let image = resource(variants: [variant(amd, config: ImageConfig(user: "foreign"))])
        #expect(ContainerImageLiveAPIClient.metadata(
            reference: "resolved", resource: image, platform: arm, allowFallback: false,
        ) == nil)
        let fallback = ContainerImageLiveAPIClient.metadata(
            reference: "resolved", resource: image, platform: arm, allowFallback: true,
        )
        #expect(fallback?.user == "foreign")
    }

    @Test
    func `empty resource and absent config preserve optional metadata defaults`() {
        for variants: [ImageResource.Variant] in [[], [variant(arm)]] {
            let image = resource(variants: variants)
            let actual = ContainerImageLiveAPIClient.metadata(
                reference: "resolved", resource: image, platform: arm, allowFallback: true,
            )
            #expect(actual == ComposeImageMetadata(reference: "resolved") {
                $0.displayReference = "example/tool:latest"
            })
        }
        #expect(ContainerImageLiveAPIClient.metadata(
            reference: "resolved", resource: resource(variants: []), platform: arm, allowFallback: false,
        ) == nil)
    }

    @Test
    func `transformer selects only labelled variants and prefers the requested platform`() throws {
        let labels = ["com.docker.compose.bridge": "transformation", "choice": "arm"]
        let selected = variant(arm, config: ImageConfig(labels: labels), size: 123)
        let other = variant(amd, config: ImageConfig(labels: ["com.docker.compose.bridge": "transformation"]))
        let image = resource(variants: [other, selected])
        let actual = try #require(ContainerImageLiveAPIClient.bridgeTransformer(resource: image, platform: arm))
        #expect(actual.id == digest)
        #expect(actual.reference == image.displayReference)
        #expect(actual.labels == labels)
        #expect(actual.createdAtUnix == 1_700_000_000)
        #expect(actual.sizeInBytes == 123)
        #expect(actual.sharedSizeInBytes == -1)
        #expect(actual.repoTags == ["example/tool:latest"])
        #expect(actual.repoDigests == ["example/tool@" + digest])

        let unlabelled = variant(arm, config: ImageConfig(labels: ["com.docker.compose.bridge": "other"]))
        #expect(ContainerImageLiveAPIClient.bridgeTransformer(
            resource: resource(variants: [unlabelled]), platform: arm,
        ) == nil)
        let fallback = ContainerImageLiveAPIClient.bridgeTransformer(
            resource: resource(variants: [unlabelled, other]), platform: arm,
        )
        #expect(fallback?.labels == other.imageConfigLabels)
    }

    @Test(arguments: ["registry.example:5000/team/tool:latest", "registry.example:5000/team/tool", "tool:latest", "tool"])
    func `repository digests retain registry ports and drop only image tags`(reference: String) throws {
        let image = resource(
            variants: [variant(arm, config: ImageConfig(labels: ["com.docker.compose.bridge": "transformation"]))],
            display: reference,
        )
        let actual = try #require(ContainerImageLiveAPIClient.bridgeTransformer(resource: image, platform: arm))
        let repository = reference.hasSuffix(":latest") ? String(reference.dropLast(7)) : reference
        #expect(actual.repoDigests == [repository + "@" + digest])
        #expect(actual.repoTags == [reference])
    }

    @Test
    func `digest-only transformers do not manufacture a repository tag`() throws {
        let reference = "registry.example:5000/tool@" + digest
        let image = resource(
            variants: [variant(arm, config: ImageConfig(labels: ["com.docker.compose.bridge": "transformation"]))],
            display: reference,
        )
        let actual = try #require(ContainerImageLiveAPIClient.bridgeTransformer(resource: image, platform: arm))
        #expect(actual.repoTags.isEmpty)
        #expect(actual.repoDigests == [reference])
    }

    private func resource(variants: [ImageResource.Variant], display: String = "example/tool:latest") -> ImageResource {
        ImageResource(
            configuration: .init(
                description: ImageDescription(
                    reference: "docker.io/" + display,
                    descriptor: .init(mediaType: MediaTypes.index, digest: digest, size: 0),
                ),
                creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            ),
            variants: variants,
            displayReference: display,
        )
    }

    private func variant(
        _ platform: Platform,
        config: ImageConfig? = nil,
        health: ImageResource.HealthCheck? = nil,
        size: Int64 = 0,
    ) -> ImageResource.Variant {
        ImageResource.Variant(
            platform: platform, digest: digest, size: size,
            config: .init(
                architecture: platform.architecture, os: platform.os,
                config: config, rootfs: .init(type: "layers", diffIDs: []),
            ),
            healthCheck: health,
        )
    }
}
