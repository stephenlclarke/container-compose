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

import ArgumentParser
import ComposeCore
import Foundation
@testable import ComposePlugin
import Testing

@Suite("Compose CLI help")
struct ComposeCLIHelpTests {
    @Test("root help rendered for missing subcommand includes support colours")
    func rootHelpRenderedForMissingSubcommandIncludesSupportColours() {
        let help = ComposeCLIHelp.rootHelpText(arguments: ["--file", "Dockerfile"])

        #expect(help.contains("Support:"))
        #expect(help.contains("\u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[38;5;208mpartially supported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[31mnot supported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32mattach\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--progress\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--verbose\u{001B}[0m"))
    }

    @Test("root help honours ansi never")
    func rootHelpHonoursANSINever() {
        let help = ComposeCLIHelp.rootHelpText(arguments: ["--ansi", "never", "--file", "Dockerfile"])

        #expect(help.contains("Support: supported | partially supported | not supported"))
        #expect(!help.contains("\u{001B}["))
    }

    @Test("root help lists help command")
    func rootHelpListsHelpCommand() {
        let plain = ComposeCLIHelp.rootHelpText(arguments: ["--ansi", "never"])
        let coloured = ComposeCLIHelp.rootHelpText(arguments: [])

        #expect(plain.contains("  help                    Help about any command"))
        #expect(coloured.contains("  \u{001B}[32mhelp\u{001B}[0m                    Help about any command"))
    }

    @Test("every rendered help option has support metadata")
    func everyRenderedHelpOptionHasSupportMetadata() throws {
        let rootOptions = Set(
            ComposeCLIHelp.optionSupportSnapshots
                .filter { $0.commandPath.isEmpty }
                .map(\.option)
        )
        let optionsByPath = Dictionary(grouping: ComposeCLIHelp.optionSupportSnapshots, by: \.commandPath)

        for commandPath in ComposeCLIHelp.documentedHelpCommandPaths {
            let help = try #require(ComposeCLIHelp.helpText(commandPath: commandPath, arguments: ["--ansi", "never"]))
            let renderedOptions = longOptions(in: help)
            let explicitOptions = Set(optionsByPath[commandPath, default: []].map(\.option))
            let supportedOptions = explicitOptions.union(rootOptions)
            let missing = renderedOptions.subtracting(supportedOptions)

            #expect(missing.isEmpty, "\(format(commandPath: commandPath)) renders unclassified options: \(missing.sorted())")
        }
    }

    @Test("every support metadata option appears in help")
    func everySupportMetadataOptionAppearsInHelp() throws {
        for snapshot in ComposeCLIHelp.optionSupportSnapshots {
            let help = try #require(ComposeCLIHelp.helpText(commandPath: snapshot.commandPath, arguments: ["--ansi", "never"]))
            let renderedOptions = longOptions(in: help)

            #expect(
                renderedOptions.contains(snapshot.option),
                "\(format(commandPath: snapshot.commandPath)) support metadata lists \(snapshot.option), but help renders \(renderedOptions.sorted())"
            )
        }
    }

    @Test("every support metadata option receives its support colour")
    func everySupportMetadataOptionReceivesItsSupportColour() throws {
        for snapshot in ComposeCLIHelp.optionSupportSnapshots {
            let help = try #require(ComposeCLIHelp.helpText(commandPath: snapshot.commandPath))
            let expected = "\(snapshot.color)\(snapshot.option)\u{001B}[0m"

            #expect(help.contains(expected), "\(format(commandPath: snapshot.commandPath)) does not colour \(snapshot.option) as \(snapshot.support)")
        }
    }

    @Test("all command support entries are fully supported")
    func allCommandSupportEntriesAreFullySupported() throws {
        let partialCommands = ComposeCLIHelp.commandSupportSnapshots
            .filter { $0.support == "partially supported" }
        let commitHelp = try #require(ComposeCLIHelp.commandHelpText(command: "commit"))

        #expect(partialCommands.isEmpty)
        #expect(commitHelp.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(commitHelp.contains("best-effort snapshot"))
        #expect(commitHelp.contains("\u{001B}[32m--pause\u{001B}[0m"))
    }

    @Test("every documented command option is covered by a parse representative")
    func everyDocumentedCommandOptionIsCoveredByAParseRepresentative() {
        let documented = Set(ComposeCLIHelp.optionSupportSnapshots.map { OptionIdentity(commandPath: $0.commandPath, option: $0.option) })
        let represented = Set(representativeParses().flatMap { representative in
            representative.options.map { OptionIdentity(commandPath: representative.commandPath, option: $0) }
        })
        let missing = documented.subtracting(represented)
        let extra = represented.subtracting(documented)

        #expect(missing.isEmpty, "missing parser representatives: \(missing.sorted().map(\.description))")
        #expect(extra.isEmpty, "unknown parser representatives: \(extra.sorted().map(\.description))")
    }

    @Test("representative command options parse")
    func representativeCommandOptionsParse() throws {
        for representative in representativeParses() {
            try representative.parse()
        }
    }

    @Test("publish preflights before image push and live artifact publish")
    func publishPreflightsBeforeImagePushAndLiveArtifactPublish() async throws {
        let command = try Publish.parse([
            "--app",
            "--oci-version", "1.1",
            "--resolve-image-digests",
            "--with-env",
            "--yes",
            "registry.example.com/team/app:latest",
        ])
        let recorder = PublishWorkflowRecorder()

        let result = try await command.executePublish(
            normalizerPublish: { options in
                recorder.record("normalizer:\(options.dryRun ? "preflight" : "publish")", options: options)
                return ComposePublishResult(
                    repository: options.repository,
                    ociVersion: options.ociVersion ?? "auto",
                    dryRun: options.dryRun,
                    descriptor: ComposePublishDescriptor(
                        mediaType: "application/vnd.oci.image.manifest.v1+json",
                        digest: "sha256:abc",
                        size: 42
                    )
                )
            },
            pushImages: {
                recorder.record("push-images")
            }
        )

        let snapshot = recorder.snapshot()
        #expect(snapshot.calls == ["normalizer:preflight", "push-images", "normalizer:publish"])
        #expect(snapshot.options.map(\.dryRun) == [true, false])
        #expect(snapshot.options.map(\.resolveImageDigests) == [false, true])
        #expect(snapshot.options.map(\.app) == [false, true])
        #expect(snapshot.options.allSatisfy { $0.repository == "registry.example.com/team/app:latest" })
        #expect(snapshot.options.allSatisfy { $0.withEnv })
        #expect(snapshot.options.allSatisfy { $0.assumeYes })
        #expect(result.descriptor?.digest == "sha256:abc")
        #expect(!result.dryRun)
    }

    @Test("publish app implies image digest resolution after image push")
    func publishAppImpliesImageDigestResolutionAfterImagePush() async throws {
        let command = try Publish.parse([
            "--app",
            "registry.example.com/team/app:latest",
        ])
        let recorder = PublishWorkflowRecorder()

        _ = try await command.executePublish(
            normalizerPublish: { options in
                recorder.record("normalizer:\(options.dryRun ? "preflight" : "publish")", options: options)
                return ComposePublishResult(
                    repository: options.repository,
                    ociVersion: "auto",
                    dryRun: options.dryRun,
                    descriptor: ComposePublishDescriptor(
                        mediaType: "application/vnd.oci.image.manifest.v1+json",
                        digest: "sha256:compose",
                        size: 42
                    ),
                    application: options.app ? ComposePublishDescriptor(
                        mediaType: "application/vnd.oci.image.index.v1+json",
                        digest: "sha256:application",
                        size: 99
                    ) : nil
                )
            },
            pushImages: {
                recorder.record("push-images")
            }
        )

        let snapshot = recorder.snapshot()
        #expect(snapshot.calls == ["normalizer:preflight", "push-images", "normalizer:publish"])
        #expect(snapshot.options.map(\.dryRun) == [true, false])
        #expect(snapshot.options.map(\.app) == [false, true])
        #expect(snapshot.options.map(\.resolveImageDigests) == [false, true])
    }

    @Test("publish dry run stops after preflight and dry-run image push")
    func publishDryRunStopsAfterPreflightAndDryRunImagePush() async throws {
        let command = try Publish.parse([
            "--dry-run",
            "--with-env",
            "registry.example.com/team/app:latest",
        ])
        let recorder = PublishWorkflowRecorder()

        let result = try await command.executePublish(
            normalizerPublish: { options in
                recorder.record("normalizer:\(options.dryRun ? "preflight" : "publish")", options: options)
                return ComposePublishResult(
                    repository: options.repository,
                    ociVersion: "auto",
                    dryRun: options.dryRun,
                    layers: [
                        ComposePublishLayer(
                            kind: "compose",
                            path: "compose.yaml",
                            mediaType: "application/vnd.docker.compose.file+yaml",
                            digest: "sha256:def",
                            size: 7
                        ),
                    ]
                )
            },
            pushImages: {
                recorder.record("push-images")
            }
        )

        let snapshot = recorder.snapshot()
        #expect(snapshot.calls == ["normalizer:preflight", "push-images"])
        #expect(snapshot.options.map(\.dryRun) == [true])
        #expect(result.dryRun)
        #expect(result.layers.first?.digest == "sha256:def")
    }

    @Test("publish dry run resolves image digests after dry-run image push")
    func publishDryRunResolvesImageDigestsAfterDryRunImagePush() async throws {
        let command = try Publish.parse([
            "--dry-run",
            "--resolve-image-digests",
            "registry.example.com/team/app:latest",
        ])
        let recorder = PublishWorkflowRecorder()

        let result = try await command.executePublish(
            normalizerPublish: { options in
                recorder.record("normalizer:\(options.resolveImageDigests ? "resolve" : "preflight")", options: options)
                return ComposePublishResult(
                    repository: options.repository,
                    ociVersion: "auto",
                    dryRun: options.dryRun,
                    layers: [
                        ComposePublishLayer(
                            kind: options.resolveImageDigests ? "image-digests" : "compose",
                            path: options.resolveImageDigests ? "image-digests.yaml" : "compose.yaml",
                            mediaType: "application/vnd.docker.compose.file+yaml",
                            digest: options.resolveImageDigests ? "sha256:resolved" : "sha256:base",
                            size: 7
                        ),
                    ]
                )
            },
            pushImages: {
                recorder.record("push-images")
            }
        )

        let snapshot = recorder.snapshot()
        #expect(snapshot.calls == ["normalizer:preflight", "push-images", "normalizer:resolve"])
        #expect(snapshot.options.map(\.dryRun) == [true, true])
        #expect(snapshot.options.map(\.resolveImageDigests) == [false, true])
        #expect(result.layers.first?.path == "image-digests.yaml")
        #expect(result.layers.first?.digest == "sha256:resolved")
    }

    @Test("publish app dry run resolves image digests after dry-run image push")
    func publishAppDryRunResolvesImageDigestsAfterDryRunImagePush() async throws {
        let command = try Publish.parse([
            "--dry-run",
            "--app",
            "registry.example.com/team/app:latest",
        ])
        let recorder = PublishWorkflowRecorder()

        let result = try await command.executePublish(
            normalizerPublish: { options in
                recorder.record("normalizer:\(options.resolveImageDigests ? "resolve" : "preflight")", options: options)
                return ComposePublishResult(
                    repository: options.repository,
                    ociVersion: "auto",
                    dryRun: options.dryRun,
                    layers: [
                        ComposePublishLayer(
                            kind: options.resolveImageDigests ? "image-digests" : "compose",
                            path: options.resolveImageDigests ? "image-digests.yaml" : "compose.yaml",
                            mediaType: "application/vnd.docker.compose.file+yaml",
                            digest: options.resolveImageDigests ? "sha256:resolved" : "sha256:base",
                            size: 7
                        ),
                    ]
                )
            },
            pushImages: {
                recorder.record("push-images")
            }
        )

        let snapshot = recorder.snapshot()
        #expect(snapshot.calls == ["normalizer:preflight", "push-images", "normalizer:resolve"])
        #expect(snapshot.options.map(\.dryRun) == [true, true])
        #expect(snapshot.options.map(\.app) == [false, true])
        #expect(snapshot.options.map(\.resolveImageDigests) == [false, true])
        #expect(result.layers.first?.path == "image-digests.yaml")
    }

    @Test("publish activates every profile before pushing service images")
    func publishActivatesEveryProfileBeforePushingServiceImages() throws {
        let command = try Publish.parse([
            "--profile", "dev",
            "--profile", "*",
            "registry.example.com/team/app:latest",
        ])

        #expect(command.composeOptionsForPublishing().profiles == ["dev", "*"])
    }

    @Test("version format rejects uppercase json")
    func versionFormatRejectsUppercaseJSON() throws {
        let command = try Version.parse(["--format", "JSON"])

        do {
            try command.run()
            Issue.record("Expected uppercase JSON format to be rejected")
        } catch let error as ComposeError {
            #expect(error == .unsupported("version --format 'JSON'; supported formats are pretty and json"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("up no-attach is shown as supported")
    func upNoAttachIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--no-attach\u{001B}[0m"))
    }

    @Test("down command is shown as supported")
    func downCommandIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "down"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
    }

    @Test("create command and options are shown as supported")
    func createCommandAndOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "create"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--build\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--scale\u{001B}[0m"))
    }

    @Test("config command and digest options are shown as supported")
    func configCommandAndDigestOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "config"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--lock-image-digests\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--resolve-image-digests\u{001B}[0m"))
    }

    @Test("ps command and options are shown as supported")
    func psCommandAndOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "ps"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--filter\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--format\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--services\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--status\u{001B}[0m"))
    }

    @Test("watch command and options are shown as supported")
    func watchCommandAndOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "watch"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--no-up\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--prune\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--quiet\u{001B}[0m"))
    }

    @Test("alpha namespace and aliases are shown as supported")
    func alphaNamespaceAndAliasesAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.helpText(commandPath: ["alpha"]))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("  \u{001B}[32mdry-run\u{001B}[0m"))
        #expect(help.contains("  \u{001B}[32mscale\u{001B}[0m"))
        #expect(help.contains("  \u{001B}[32mwatch\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--dry-run\u{001B}[0m"))
    }

    @Test("run command and options accurately report support")
    func runCommandAndOptionsAccuratelyReportSupport() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "run"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--build\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--no-deps\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--service-ports\u{001B}[0m"))
        #expect(help.contains("\u{001B}[38;5;208m--use-aliases\u{001B}[0m"))
        #expect(help.contains("requires container-facing DNS"))
    }

    @Test("exec command and privileged option are shown as supported")
    func execCommandAndPrivilegedOptionAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "exec"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--privileged\u{001B}[0m"))
    }

    @Test("build command and options are shown as supported")
    func buildCommandAndOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "build"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--print\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--check\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--ssh\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--provenance\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--sbom\u{001B}[0m"))
        #expect(help.contains("Use --provenance=false to explicitly disable."))
        #expect(help.contains("Use --sbom=false to explicitly disable."))
    }

    @Test("attach options are shown as supported")
    func attachOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "attach"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--detach-keys\u{001B}[0m"))
        #expect(help.contains("Ignored with --no-stdin output-only attach."))
        #expect(help.contains("\u{001B}[32m--index\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--no-stdin\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--sig-proxy\u{001B}[0m"))
    }

    @Test("up raw attached output flags are shown as supported")
    func upRawAttachedOutputFlagsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--no-color\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--no-log-prefix\u{001B}[0m"))
    }

    @Test("up timestamps is shown as supported")
    func upTimestampsIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--timestamps\u{001B}[0m"))
    }

    @Test("up attach options are shown as supported")
    func upAttachOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--attach\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--attach-dependencies\u{001B}[0m"))
    }

    @Test("up exit-control options are shown as supported")
    func upExitControlOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--abort-on-container-exit\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--abort-on-container-failure\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--exit-code-from\u{001B}[0m"))
    }

    @Test("up menu option shows supported interactive shortcut help")
    func upMenuOptionShowsSupportedInteractiveShortcutHelp() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[32m--menu\u{001B}[0m"))
        #expect(help.contains("Use --menu=false to explicitly disable the helper menu."))
    }

    @Test("up wait options show full health support")
    func upWaitOptionsShowFullHealthSupport() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--wait\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--wait-timeout\u{001B}[0m"))
    }

    @Test("up raw attached output flags parse")
    func upRawAttachedOutputFlagsParse() throws {
        let command = try Up.parse([
            "--abort-on-container-failure",
            "--attach", "api",
            "--attach", "worker",
            "--attach-dependencies",
            "--exit-code-from", "api",
            "--no-color",
            "--no-log-prefix",
            "--timestamps",
            "api",
        ])

        #expect(command.abortOnContainerFailure)
        #expect(command.attach == ["api", "worker"])
        #expect(command.attachDependencies)
        #expect(command.exitCodeFrom == "api")
        #expect(command.noColor)
        #expect(command.noLogPrefix)
        #expect(command.timestamps)
        #expect(command.services == ["api"])
    }

    @Test("up menu false value parses through Docker Compose rewriter")
    func upMenuFalseValueParsesThroughDockerComposeRewriter() throws {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "up",
            "--menu=false",
            "api",
        ])
        let command = try Up.parse(Array(rewritten.dropFirst()))

        #expect(!command.menu)
        #expect(command.menuDisabled)
        #expect(command.services == ["api"])
    }

    @Test("config image digest flags parse")
    func configImageDigestFlagsParse() throws {
        let command = try Config.parse(["--resolve-image-digests", "--lock-image-digests", "api"])

        #expect(command.resolveImageDigests)
        #expect(command.lockImageDigests)
        #expect(command.services == ["api"])
    }

    @Test("convert command and projections parse")
    func convertCommandAndProjectionsParse() throws {
        let command = try Convert.parse([
            "--format", "json",
            "--hash", "api",
            "--images",
            "--no-consistency",
            "--no-interpolate",
            "--no-normalize",
            "--output", "model.yml",
            "--profiles",
            "--quiet",
            "--resolve-image-digests",
            "--services",
            "--volumes",
            "api",
        ])

        #expect(command.format == "json")
        #expect(command.hash == "api")
        #expect(command.images)
        #expect(command.noConsistency)
        #expect(command.noInterpolate)
        #expect(command.noNormalize)
        #expect(command.output == "model.yml")
        #expect(command.profiles)
        #expect(command.quiet)
        #expect(command.resolveImageDigests)
        #expect(command.servicesOnly)
        #expect(command.volumes)
        #expect(command.services == ["api"])
    }

    @Test("build print flag parses")
    func buildPrintFlagParses() throws {
        let command = try Build.parse([
            "--check",
            "--print",
            "--provenance=false",
            "--sbom", "false",
            "--build-arg", "VERSION=2",
            "--ssh", "default",
            "--ssh", "git=/tmp/git.sock",
            "--with-dependencies",
            "api",
        ])

        #expect(command.check)
        #expect(command.printBake)
        #expect(command.provenance == "false")
        #expect(command.sbom == "false")
        #expect(command.buildArgs == ["VERSION=2"])
        #expect(command.ssh == ["default", "git=/tmp/git.sock"])
        #expect(command.withDependencies)
        #expect(command.services == ["api"])
    }

    @Test("attach signal proxy flag parses")
    func attachSignalProxyFlagParses() throws {
        let command = try Attach.parse(["--no-stdin", "--detach-keys", "ctrl-x", "--sig-proxy=false", "--index", "2", "api"])

        #expect(command.noStdin)
        #expect(command.detachKeys == "ctrl-x")
        #expect(command.sigProxy == "false")
        #expect(command.index == 2)
        #expect(command.service == "api")
    }

    @Test("global progress option maps Docker Compose policies")
    func globalProgressOptionMapsDockerComposePolicies() {
        var options = GlobalOptions()

        options.progress = "quiet"
        #expect(options.progressStyle() == .quiet)

        options.progress = "none"
        #expect(options.progressStyle() == .quiet)

        options.progress = "plain"
        #expect(options.progressStyle() == .plain)

        options.progress = "json"
        #expect(options.progressStyle() == .json)

        options.progress = "tty"
        #expect(options.progressStyle() == .tty)
    }

    @Test("global ansi option controls progress colour")
    func globalANSIOptionControlsProgressColour() {
        var options = GlobalOptions()

        options.ansi = "always"
        #expect(options.shouldColorProgress())

        options.ansi = "never"
        #expect(!options.shouldColorProgress())
    }

    @Test("STATUS command surface matches help support metadata")
    func statusCommandSurfaceMatchesHelpSupportMetadata() throws {
        let status = try statusMarkdown()
        let commandSection = try statusSection("CLI Command Surface", in: status)
        let commandRows = commandSection
            .split(separator: "\n")
            .filter { $0.hasPrefix("| `") }
        let documentedUnsupportedCommands: [String] = []

        #expect(commandRows.count == ComposeCLIHelp.commandSupportSnapshots.count + documentedUnsupportedCommands.count)
        for snapshot in ComposeCLIHelp.commandSupportSnapshots {
            let command = format(commandPath: snapshot.commandPath)
            let expected = statusIndicator(for: snapshot.support)

            #expect(
                commandSection.contains("| `\(command)` | \(expected) |"),
                "STATUS.md does not list \(command) as \(expected)"
            )
        }

        for command in documentedUnsupportedCommands {
            #expect(
                commandSection.contains("| `\(command)` | ❌ No |"),
                "STATUS.md does not list Docker-documented unsupported command \(command)"
            )
        }
    }

    @Test("STATUS command totals match help support metadata")
    func statusCommandTotalsMatchHelpSupportMetadata() throws {
        let status = try statusMarkdown()
        let supported = ComposeCLIHelp.commandSupportSnapshots.filter { $0.support == "supported" }.count
        let partial = ComposeCLIHelp.commandSupportSnapshots.filter { $0.support == "partially supported" }.count
        let unsupported = ComposeCLIHelp.commandSupportSnapshots.filter { $0.support == "not supported" }.count
        let unsupportedVerb = unsupported == 1 ? "is" : "are"

        #expect(
            status.contains("\(supported) commands are ✅, \(partial) are ⚠️, and \(unsupported) \(unsupportedVerb) ❌"),
            "STATUS.md CLI command totals do not match ComposeCLIHelp metadata"
        )
    }

    @Test("STATUS option totals match help support metadata")
    func statusOptionTotalsMatchHelpSupportMetadata() throws {
        let status = try statusMarkdown()
        let supported = ComposeCLIHelp.optionSupportSnapshots.filter { $0.support == "supported" }.count
        let partial = ComposeCLIHelp.optionSupportSnapshots.filter { $0.support == "partially supported" }.count
        let unsupported = ComposeCLIHelp.optionSupportSnapshots.filter { $0.support == "not supported" }.count
        let dockerDocumentedUnsupported = 0

        #expect(
            status.contains("\(supported) documented long options are ✅, \(partial) are ⚠️, and \(unsupported + dockerDocumentedUnsupported) are ❌"),
            "STATUS.md CLI option totals do not match ComposeCLIHelp metadata plus Docker-documented unsupported surfaces"
        )
    }

    @Test("STATUS option surface lists every help option")
    func statusOptionSurfaceListsEveryHelpOption() throws {
        let section = try statusSection("CLI Option Surface", in: try statusMarkdown())
        let optionRows: [(String, String)] = statusTableRows(in: section).compactMap { row -> (String, String)? in
            let columns = row.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard columns.count > 3, columns[1] != "Option Surface" else {
                return nil
            }
            return (columns[1], row)
        }
        let rowsBySurface = Dictionary(uniqueKeysWithValues: optionRows)

        let snapshotsByPath = Dictionary(grouping: ComposeCLIHelp.optionSupportSnapshots, by: \.commandPath)
        for (commandPath, snapshots) in snapshotsByPath {
            let surface = commandPath.isEmpty ? "Root options" : "`\(format(commandPath: commandPath))` options"
            let row = rowsBySurface[surface]

            #expect(row != nil, "STATUS.md CLI Option Surface does not list \(surface)")
            guard let row else {
                continue
            }

            let expected = optionGroupIndicator(for: snapshots.map(\.support))
            #expect(
                row.contains("| \(surface) | \(expected) |"),
                "STATUS.md lists \(surface) with the wrong option parity"
            )

            for snapshot in snapshots {
                let symbol = statusSymbol(for: snapshot.support)
                #expect(
                    row.contains("\(symbol) `\(snapshot.option)`"),
                    "STATUS.md \(surface) does not list \(snapshot.option) as \(symbol)"
                )
            }
        }
    }

    @Test("STATUS compose file surface lists required parity rows")
    func statusComposeFileSurfaceListsRequiredParityRows() throws {
        let section = try statusSection("Compose File Surface", in: try statusMarkdown())
        let requiredRows = [
            "Project file discovery and sources",
            "Top-level `name` and legacy `version`",
            "Top-level `services`",
            "Top-level `networks`",
            "Top-level `volumes`",
            "Top-level `configs`",
            "Top-level `secrets`",
            "Extensions, fragments, merge, and include",
            "Compose Build Specification",
            "Compose Deploy Specification",
            "Compose Develop Specification",
            "Provider services and models",
        ]

        for row in requiredRows {
            #expect(
                section.contains("| \(row) |"),
                "STATUS.md Compose File Surface does not list \(row)"
            )
        }
    }

    @Test("STATUS names every current Compose specification surface")
    func statusNamesEveryCurrentComposeSpecificationSurface() throws {
        let status = try statusMarkdown()
        let composeFileSection = try statusSection("Compose File Surface", in: status)
        let serviceSection = try statusSection("Service Attribute Surface", in: status)
        let buildSection = try statusSection("Dockerfile And Build Surface", in: status)

        expectCodeSpans([
            "attachable", "driver", "driver_opts", "enable_ipv4", "enable_ipv6",
            "external", "ipam", "internal", "labels", "name",
        ], in: try statusTableRow(named: "Top-level `networks`", in: composeFileSection))
        expectCodeSpans([
            "driver", "driver_opts", "external", "labels", "name",
        ], in: try statusTableRow(named: "Top-level `volumes`", in: composeFileSection))
        expectCodeSpans([
            "file", "environment", "content", "external", "name",
        ], in: try statusTableRow(named: "Top-level `configs`", in: composeFileSection))
        expectCodeSpans([
            "file", "environment", "external", "name",
        ], in: try statusTableRow(named: "Top-level `secrets`", in: composeFileSection))
        expectCodeSpans([
            "path", "project_directory", "env_file",
        ], in: try statusTableRow(named: "Extensions, fragments, merge, and include", in: composeFileSection))
        expectCodeSpans([
            "type", "options", "model", "context_size", "runtime_flags", "endpoint_var", "model_var",
        ], in: try statusTableRow(named: "Provider services and models", in: composeFileSection))
        expectCodeSpans([
            "endpoint_mode", "labels", "mode", "placement", "replicas", "resources", "restart_policy",
            "rollback_config", "update_config",
        ], in: try statusTableRow(named: "Compose Deploy Specification", in: composeFileSection))
        expectCodeSpans([
            "watch", "path", "action", "target", "ignore", "include", "initial_sync", "exec",
        ], in: try statusTableRow(named: "Compose Develop Specification", in: composeFileSection))

        expectCodeSpans(Self.currentServiceAttributes, in: serviceSection)
        expectCodeSpans(Self.currentBuildAttributes.map { "build.\($0)" }, in: buildSection)
        expectCodeSpans(Self.currentDockerfileInstructions, in: buildSection)
    }

    @Test("STATUS Dockerfile and build surface lists build specification rows")
    func statusDockerfileAndBuildSurfaceListsBuildSpecificationRows() throws {
        let section = try statusSection("Dockerfile And Build Surface", in: try statusMarkdown())
        let requiredRows = [
            "Dockerfile instruction set and parser directives",
            "`.dockerignore` context filtering",
            "Build context string syntax",
            "`build.context`",
            "`build.dockerfile`",
            "`build.dockerfile_inline`",
            "`build.additional_contexts`",
            "`build.args` and `build --build-arg`",
            "`build.cache_from` and `build.cache_to`",
            "`build.entitlements`",
            "`build.extra_hosts`",
            "`build.isolation`",
            "`build.labels`",
            "`build.network`",
            "`build.no_cache` and `--no-cache`",
            "`build.platforms`",
            "`build.privileged`",
            "`build.provenance`",
            "`build.pull` and `--pull`",
            "`build.sbom`",
            "`build.secrets`",
            "`build.ssh` and `build --ssh`",
            "`build.shm_size`",
            "`build.tags`",
            "`build.target`",
            "`build.ulimits`",
            "`build --builder`",
            "`build --check`",
            "`build --print`",
            "Dockerfile `HEALTHCHECK` inheritance",
        ]

        for row in requiredRows {
            #expect(
                section.contains("| \(row) |"),
                "STATUS.md Dockerfile And Build Surface does not list \(row)"
            )
        }
    }

    @Test("STATUS partial parity rows include gap details")
    func statusPartialParityRowsIncludeGapDetails() throws {
        let status = try statusMarkdown()
        for sectionName in [
            "Compose Surface Matrix",
            "Compose File Surface",
            "Dockerfile And Build Surface",
            "CLI Command Surface",
            "CLI Option Surface",
        ] {
            let section = try statusSection(sectionName, in: status)
            for row in statusTableRows(in: section) where row.contains("| ⚠️ Partial |") {
                let columns = row.split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let detail = columns.count > 3 ? columns[3] : ""

                #expect(!detail.isEmpty, "STATUS.md \(sectionName) partial row has no gap details: \(row)")
            }
        }
    }

    private struct OptionIdentity: Comparable, CustomStringConvertible, Hashable {
        var commandPath: [String]
        var option: String

        var description: String {
            "\(format(commandPath: commandPath)) \(option)"
        }

        static func < (lhs: OptionIdentity, rhs: OptionIdentity) -> Bool {
            if lhs.commandPath == rhs.commandPath {
                return lhs.option < rhs.option
            }
            return lhs.commandPath.lexicographicallyPrecedes(rhs.commandPath)
        }
    }

    private typealias RepresentativeParse = (commandPath: [String], options: Set<String>, parse: () throws -> Void)

    private func optionGroupIndicator(for supportLabels: [String]) -> String {
        if supportLabels.allSatisfy({ $0 == "supported" }) {
            return "✅ Yes"
        }
        if supportLabels.allSatisfy({ $0 == "not supported" }) {
            return "❌ No"
        }
        return "⚠️ Partial"
    }

    private func statusSymbol(for support: String) -> String {
        switch support {
        case "supported":
            return "✅"
        case "partially supported":
            return "⚠️"
        case "not supported":
            return "❌"
        default:
            return "unknown"
        }
    }

    private func statusIndicator(for support: String) -> String {
        switch support {
        case "supported":
            return "✅ Yes"
        case "partially supported":
            return "⚠️ Partial"
        case "not supported":
            return "❌ No"
        default:
            return "unknown"
        }
    }

    private func statusMarkdown() throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        var directory = fileURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let statusURL = directory.appendingPathComponent("STATUS.md")
            if FileManager.default.fileExists(atPath: statusURL.path) {
                return try String(contentsOf: statusURL, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw ComposeError.invalidProject("STATUS.md was not found from \(fileURL.path)")
    }

    private func statusTableRows(in markdown: String) -> [String] {
        markdown
            .split(separator: "\n")
            .map(String.init)
            .filter { row in
                row.hasPrefix("| ") && !row.hasPrefix("| ---")
            }
    }

    private func statusTableRow(named name: String, in markdown: String) throws -> String {
        guard let row = statusTableRows(in: markdown).first(where: { $0.hasPrefix("| \(name) |") }) else {
            throw ComposeError.invalidProject("STATUS.md is missing the \(name) row")
        }
        return row
    }

    private func expectCodeSpans(_ names: [String], in markdown: String) {
        for name in names {
            #expect(markdown.contains("`\(name)`"), "STATUS.md does not name current Compose surface \(name)")
        }
    }

    private func statusSection(_ heading: String, in markdown: String) throws -> String {
        let marker = "## \(heading)"
        guard let start = markdown.range(of: marker)?.upperBound else {
            throw ComposeError.invalidProject("STATUS.md is missing \(marker)")
        }
        let remainder = markdown[start...]
        let end = remainder.range(of: "\n## ")?.lowerBound ?? remainder.endIndex
        return String(remainder[..<end])
    }

    private static let currentServiceAttributes = """
    annotations attach build blkio_config cpu_count cpu_percent cpu_shares cpu_period cpu_quota
    cpu_rt_runtime cpu_rt_period cpus cpuset cap_add cap_drop cgroup cgroup_parent command configs
    container_name credential_spec depends_on deploy develop device_cgroup_rules devices dns dns_opt
    dns_search domainname driver_opts entrypoint env_file environment expose extends external_links
    extra_hosts gpus group_add healthcheck hostname image init ipc isolation labels label_file links
    logging mac_address mem_limit mem_reservation mem_swappiness memswap_limit models network_mode
    networks oom_kill_disable oom_score_adj pid pids_limit platform ports post_start pre_start pre_stop
    privileged profiles provider pull_policy read_only restart runtime scale secrets security_opt
    shm_size stdin_open stop_grace_period stop_signal storage_opt sysctls tmpfs tty ulimits
    use_api_socket user userns_mode uts volumes volumes_from working_dir
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    private static let currentBuildAttributes = """
    additional_contexts args cache_from cache_to context dockerfile dockerfile_inline entitlements
    extra_hosts isolation labels network no_cache platforms privileged provenance pull sbom secrets
    ssh shm_size tags target ulimits
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    private static let currentDockerfileInstructions = """
    ADD ARG CMD COPY ENTRYPOINT ENV EXPOSE FROM HEALTHCHECK LABEL MAINTAINER ONBUILD RUN SHELL
    STOPSIGNAL USER VOLUME WORKDIR
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    private func representativeParses() -> [RepresentativeParse] {
        [
            ([], [
                "--all-resources", "--ansi", "--compatibility", "--dry-run", "--env-file", "--file", "--parallel", "--profile",
                "--progress", "--project-directory", "--project-name", "--verbose",
            ], {
                let command = try GlobalOptions.parse([
                    "--all-resources",
                    "--ansi", "never",
                    "--compatibility",
                    "--dry-run",
                    "--env-file", ".env",
                    "--file", "compose.yml",
                    "--parallel", "2",
                    "--profile", "dev",
                    "--progress", "plain",
                    "--project-directory", ".",
                    "--project-name", "demo",
                    "--verbose",
                ])

                #expect(command.allResources)
                #expect(command.ansi == "never")
                #expect(command.compatibility)
                #expect(command.dryRun)
                #expect(command.envFile == [".env"])
                #expect(command.file == ["compose.yml"])
                #expect(command.parallel == 2)
                #expect(command.profile == ["dev"])
                #expect(command.progress == "plain")
                #expect(command.projectDirectory == ".")
                #expect(command.projectName == "demo")
                #expect(command.verbose)
            }),
            (["alpha"], ["--dry-run"], {
                let command = try Alpha.parse(["--dry-run"])

                #expect(command.global.dryRun)
            }),
            (["alpha", "dry-run"], ["--dry-run"], {
                let command = try AlphaDryRun.parse(["--dry-run", "--", "up", "api"])

                #expect(command.global.dryRun)
                #expect(command.command == ["--", "up", "api"])
            }),
            (["alpha", "scale"], ["--dry-run", "--no-deps"], {
                let command = try AlphaScale.parse(["--dry-run", "--no-deps", "api=2"])

                #expect(command.global.dryRun)
                #expect(command.noDeps)
                #expect(command.scales == ["api=2"])
            }),
            (["alpha", "watch"], ["--dry-run", "--no-up", "--quiet"], {
                let command = try AlphaWatch.parse(["--dry-run", "--no-up", "--quiet", "api"])

                #expect(command.global.dryRun)
                #expect(command.noUp)
                #expect(command.quiet)
                #expect(command.services == ["api"])
            }),
            (["attach"], ["--detach-keys", "--dry-run", "--index", "--no-stdin", "--sig-proxy"], {
                let command = try Attach.parse(["--dry-run", "--no-stdin", "--detach-keys", "ctrl-x", "--index", "2", "--sig-proxy=false", "api"])

                #expect(command.global.dryRun)
                #expect(command.noStdin)
                #expect(command.detachKeys == "ctrl-x")
                #expect(command.index == 2)
                #expect(command.sigProxy == "false")
                #expect(command.service == "api")
            }),
            (["bridge"], ["--dry-run"], {
                let command = try Bridge.parse(["--dry-run"])

                #expect(command.global.dryRun)
            }),
            (["bridge", "convert"], ["--dry-run", "--output", "--templates", "--transformation"], {
                let command = try BridgeConvert.parse([
                    "--dry-run",
                    "--output", "out",
                    "--templates", "templates",
                    "--transformation", "one",
                    "--transformation", "two",
                ])

                #expect(command.global.dryRun)
                #expect(command.output == "out")
                #expect(command.templates == "templates")
                #expect(command.transformations == ["one", "two"])
            }),
            (["bridge", "transformations"], ["--dry-run"], {
                let command = try BridgeTransformations.parse(["--dry-run"])

                #expect(command.global.dryRun)
            }),
            (["bridge", "transformations", "create"], ["--dry-run", "--from"], {
                let command = try BridgeTransformationsCreate.parse(["--dry-run", "--from", "base", "path"])

                #expect(command.global.dryRun)
                #expect(command.from == "base")
                #expect(command.path == "path")
            }),
            (["bridge", "transformations", "list"], ["--dry-run", "--format", "--quiet"], {
                let command = try BridgeTransformationsList.parse(["--dry-run", "--format", "json", "--quiet"])

                #expect(command.global.dryRun)
                #expect(command.format == "json")
                #expect(command.quiet)
            }),
            (["bridge", "transformations", "ls"], ["--dry-run", "--format", "--quiet"], {
                let command = try BridgeTransformationsList.parse(["--dry-run", "--format", "json", "--quiet"])

                #expect(command.global.dryRun)
                #expect(command.format == "json")
                #expect(command.quiet)
            }),
            (["build"], [
                "--build-arg", "--builder", "--check", "--dry-run", "--memory", "--no-cache", "--print", "--provenance", "--pull",
                "--push", "--quiet", "--sbom", "--ssh", "--with-dependencies",
            ], {
                let command = try Build.parse([
                    "--dry-run",
                    "--build-arg", "VERSION=2",
                    "--builder", "default",
                    "--check",
                    "--memory", "256m",
                    "--no-cache",
                    "--print",
                    "--provenance=true",
                    "--pull",
                    "--push",
                    "--quiet",
                    "--sbom", "true",
                    "--ssh", "default",
                    "--with-dependencies",
                    "api",
                ])

                #expect(command.global.dryRun)
                #expect(command.buildArgs == ["VERSION=2"])
                #expect(command.builder == "default")
                #expect(command.check)
                #expect(command.memory == "256m")
                #expect(command.noCache)
                #expect(command.printBake)
                #expect(command.provenance == "true")
                #expect(command.pull)
                #expect(command.push)
                #expect(command.quiet)
                #expect(command.sbom == "true")
                #expect(command.ssh == ["default"])
                #expect(command.withDependencies)
                #expect(command.services == ["api"])
            }),
            (["commit"], ["--author", "--change", "--dry-run", "--index", "--message", "--pause"], {
                let defaultIndex = try Commit.parse([
                    "api",
                ])
                #expect(defaultIndex.index == 0)

                let command = try Commit.parse([
                    "--dry-run",
                    "--author", "Me",
                    "--change", "CMD true",
                    "--index", "2",
                    "--message", "snapshot",
                    "--pause",
                    "api",
                    "example/api:snapshot",
                ])

                #expect(command.global.dryRun)
                #expect(command.author == "Me")
                #expect(command.changes == ["CMD true"])
                #expect(command.index == 2)
                #expect(command.message == "snapshot")
                #expect(command.pause)
                #expect(command.service == "api")
                #expect(command.reference == "example/api:snapshot")

                let noPause = try Commit.parse(["--no-pause", "api"])
                #expect(!noPause.pause)
            }),
            (["config"], [
                "--dry-run", "--environment", "--format", "--hash", "--images", "--lock-image-digests", "--models", "--networks",
                "--no-consistency", "--no-env-resolution", "--no-interpolate", "--no-normalize", "--no-path-resolution", "--output",
                "--profiles", "--quiet", "--resolve-image-digests", "--services", "--variables", "--volumes",
            ], {
                let command = try Config.parse([
                    "--dry-run",
                    "--environment",
                    "--format", "json",
                    "--hash", "api",
                    "--images",
                    "--lock-image-digests",
                    "--models",
                    "--networks",
                    "--no-consistency",
                    "--no-env-resolution",
                    "--no-interpolate",
                    "--no-normalize",
                    "--no-path-resolution",
                    "--output", "out.yml",
                    "--profiles",
                    "--quiet",
                    "--resolve-image-digests",
                    "--services",
                    "--variables",
                    "--volumes",
                    "api",
                ])

                #expect(command.global.dryRun)
                #expect(command.environment)
                #expect(command.format == "json")
                #expect(command.hash == "api")
                #expect(command.images)
                #expect(command.lockImageDigests)
                #expect(command.models)
                #expect(command.networks)
                #expect(command.noConsistency)
                #expect(command.noEnvResolution)
                #expect(command.noInterpolate)
                #expect(command.noNormalize)
                #expect(command.noPathResolution)
                #expect(command.output == "out.yml")
                #expect(command.profiles)
                #expect(command.quiet)
                #expect(command.resolveImageDigests)
                #expect(command.servicesOnly)
                #expect(command.variables)
                #expect(command.volumes)
                #expect(command.services == ["api"])
            }),
            (["convert"], [
                "--dry-run", "--format", "--hash", "--images", "--no-consistency", "--no-interpolate", "--no-normalize", "--output",
                "--profiles", "--quiet", "--resolve-image-digests", "--services", "--volumes",
            ], {
                let command = try Convert.parse([
                    "--dry-run",
                    "--format", "json",
                    "--hash", "api",
                    "--images",
                    "--no-consistency",
                    "--no-interpolate",
                    "--no-normalize",
                    "--output", "model.yml",
                    "--profiles",
                    "--quiet",
                    "--resolve-image-digests",
                    "--services",
                    "--volumes",
                    "api",
                ])

                #expect(command.global.dryRun)
                #expect(command.format == "json")
                #expect(command.hash == "api")
                #expect(command.images)
                #expect(command.noConsistency)
                #expect(command.noInterpolate)
                #expect(command.noNormalize)
                #expect(command.output == "model.yml")
                #expect(command.profiles)
                #expect(command.quiet)
                #expect(command.resolveImageDigests)
                #expect(command.servicesOnly)
                #expect(command.volumes)
                #expect(command.services == ["api"])
            }),
            (["cp"], ["--all", "--archive", "--dry-run", "--follow-link", "--index"], {
                let command = try Cp.parse(["--dry-run", "--all", "--archive", "--follow-link", "--index", "2", "api:/src", "dest"])

                #expect(command.global.dryRun)
                #expect(command.all)
                #expect(command.archive)
                #expect(command.followLink)
                #expect(command.index == 2)
                #expect(command.arguments == ["api:/src", "dest"])
            }),
            (["create"], [
                "--build", "--dry-run", "--force-recreate", "--no-build", "--no-recreate", "--pull", "--quiet-pull",
                "--remove-orphans", "--scale", "--yes",
            ], {
                let command = try Create.parse([
                    "--dry-run",
                    "--build",
                    "--force-recreate",
                    "--no-build",
                    "--no-recreate",
                    "--pull", "always",
                    "--quiet-pull",
                    "--remove-orphans",
                    "--scale", "api=2",
                    "--yes",
                    "api",
                ])

                #expect(command.global.dryRun)
                #expect(command.build)
                #expect(command.forceRecreate)
                #expect(command.noBuild)
                #expect(command.noRecreate)
                #expect(command.pull == "always")
                #expect(command.quietPull)
                #expect(command.removeOrphans)
                #expect(command.scales == ["api=2"])
                #expect(command.yes)
                #expect(command.services == ["api"])
            }),
            (["down"], ["--dry-run", "--remove-orphans", "--rmi", "--timeout", "--volumes"], {
                let command = try Down.parse(["--dry-run", "--remove-orphans", "--rmi", "local", "--timeout", "5", "--volumes", "api"])

                #expect(command.global.dryRun)
                #expect(command.removeOrphans)
                #expect(command.rmi == "local")
                #expect(command.timeout == 5)
                #expect(command.volumes)
                #expect(command.services == ["api"])
            }),
            (["events"], ["--dry-run", "--json", "--since", "--until"], {
                let command = try Events.parse(["--dry-run", "--json", "--since", "2026-01-01T00:00:00Z", "--until", "2026-01-01T00:01:00Z", "api"])

                #expect(command.global.dryRun)
                #expect(command.json)
                #expect(command.since == "2026-01-01T00:00:00Z")
                #expect(command.until == "2026-01-01T00:01:00Z")
                #expect(command.services == ["api"])
            }),
            (["exec"], ["--detach", "--dry-run", "--env", "--index", "--no-tty", "--privileged", "--user", "--workdir"], {
                let command = try Exec.parse([
                    "--dry-run",
                    "--detach",
                    "--env", "A=B",
                    "--index", "2",
                    "--no-tty",
                    "--privileged",
                    "--user", "1000",
                    "--workdir", "/srv",
                    "api",
                    "sh",
                    "-lc",
                    "true",
                ])

                #expect(command.global.dryRun)
                #expect(command.detach)
                #expect(command.environment == ["A=B"])
                #expect(command.index == 2)
                #expect(!command.tty)
                #expect(command.privileged)
                #expect(command.user == "1000")
                #expect(command.workdir == "/srv")
                #expect(command.service == "api")
                #expect(command.command == ["sh", "-lc", "true"])
            }),
            (["export"], ["--dry-run", "--index", "--output"], {
                let command = try Export.parse(["--dry-run", "--index", "2", "--output", "rootfs.tar", "api"])

                #expect(command.global.dryRun)
                #expect(command.index == 2)
                #expect(command.output == "rootfs.tar")
                #expect(command.service == "api")
            }),
            (["images"], ["--dry-run", "--format", "--quiet"], {
                let command = try Images.parse(["--dry-run", "--format", "json", "--quiet", "api"])

                #expect(command.global.dryRun)
                #expect(command.format == "json")
                #expect(command.quiet)
                #expect(command.services == ["api"])
            }),
            (["kill"], ["--dry-run", "--remove-orphans", "--signal"], {
                let command = try Kill.parse(["--dry-run", "--remove-orphans", "--signal", "SIGTERM", "api"])

                #expect(command.global.dryRun)
                #expect(command.removeOrphans)
                #expect(command.signal == "SIGTERM")
                #expect(command.services == ["api"])
            }),
            (["logs"], ["--dry-run", "--follow", "--index", "--no-color", "--no-log-prefix", "--since", "--tail", "--timestamps", "--until"], {
                let command = try Logs.parse([
                    "--dry-run",
                    "--follow",
                    "--index", "2",
                    "--no-color",
                    "--no-log-prefix",
                    "--since", "1h",
                    "--tail", "5",
                    "--timestamps",
                    "--until", "now",
                    "api",
                ])

                #expect(command.global.dryRun)
                #expect(command.follow)
                #expect(command.index == 2)
                #expect(command.noColor)
                #expect(command.noLogPrefix)
                #expect(command.since == "1h")
                #expect(command.tail == "5")
                #expect(command.timestamps)
                #expect(command.until == "now")
                #expect(command.services == ["api"])
            }),
            (["ls"], ["--all", "--dry-run", "--filter", "--format", "--quiet"], {
                let command = try Ls.parse(["--dry-run", "--all", "--filter", "name=demo", "--format", "json", "--quiet"])

                #expect(command.global.dryRun)
                #expect(command.all)
                #expect(command.filters == ["name=demo"])
                #expect(command.format == "json")
                #expect(command.quiet)
            }),
            (["pause"], ["--dry-run"], {
                let command = try Pause.parse(["--dry-run", "api"])

                #expect(command.global.dryRun)
                #expect(command.services == ["api"])
            }),
            (["port"], ["--dry-run", "--index", "--protocol"], {
                let command = try Port.parse(["--dry-run", "--index", "2", "--protocol", "udp", "api", "53"])

                #expect(command.global.dryRun)
                #expect(command.index == 2)
                #expect(command.portProtocol == "udp")
                #expect(command.service == "api")
                #expect(command.privatePort == "53")
            }),
            (["ps"], ["--all", "--dry-run", "--filter", "--format", "--no-trunc", "--orphans", "--quiet", "--services", "--status"], {
                let command = try Ps.parse([
                    "--dry-run",
                    "--all",
                    "--filter", "status=running",
                    "--format", "json",
                    "--no-trunc",
                    "--orphans",
                    "--quiet",
                    "--services",
                    "--status", "running",
                    "api",
                ])

                #expect(command.global.dryRun)
                #expect(command.all)
                #expect(command.filters == ["status=running"])
                #expect(command.format == "json")
                #expect(command.noTrunc)
                #expect(command.orphans)
                #expect(command.quiet)
                #expect(command.services)
                #expect(command.statuses == ["running"])
                #expect(command.serviceNames == ["api"])
            }),
            (["publish"], ["--app", "--dry-run", "--oci-version", "--resolve-image-digests", "--with-env", "--yes"], {
                let command = try Publish.parse(["--dry-run", "--app", "--oci-version", "1.1", "--resolve-image-digests", "--with-env", "--yes", "repo/app:latest"])

                #expect(command.global.dryRun)
                #expect(command.app)
                #expect(command.ociVersion == "1.1")
                #expect(command.resolveImageDigests)
                #expect(command.withEnv)
                #expect(command.yes)
                #expect(command.repository == "repo/app:latest")
            }),
            (["pull"], ["--dry-run", "--ignore-buildable", "--ignore-pull-failures", "--include-deps", "--policy", "--quiet"], {
                let command = try Pull.parse(["--dry-run", "--ignore-buildable", "--ignore-pull-failures", "--include-deps", "--policy", "always", "--quiet", "api"])

                #expect(command.global.dryRun)
                #expect(command.ignoreBuildable)
                #expect(command.ignorePullFailures)
                #expect(command.includeDeps)
                #expect(command.policy == "always")
                #expect(command.quiet)
                #expect(command.services == ["api"])
            }),
            (["push"], ["--dry-run", "--ignore-push-failures", "--include-deps", "--quiet"], {
                let command = try Push.parse(["--dry-run", "--ignore-push-failures", "--include-deps", "--quiet", "api"])

                #expect(command.global.dryRun)
                #expect(command.ignorePushFailures)
                #expect(command.includeDeps)
                #expect(command.quiet)
                #expect(command.services == ["api"])
            }),
            (["restart"], ["--dry-run", "--no-deps", "--timeout"], {
                let command = try Restart.parse(["--dry-run", "--no-deps", "--timeout", "5", "api"])

                #expect(command.global.dryRun)
                #expect(command.noDeps)
                #expect(command.timeout == 5)
                #expect(command.services == ["api"])
            }),
            (["rm"], ["--dry-run", "--force", "--stop", "--volumes"], {
                let command = try Rm.parse(["--dry-run", "--force", "--stop", "--volumes", "api"])

                #expect(command.global.dryRun)
                #expect(command.force)
                #expect(command.stop)
                #expect(command.volumes)
                #expect(command.services == ["api"])
            }),
            (["run"], [
                "--build", "--cap-add", "--cap-drop", "--detach", "--dry-run", "--entrypoint", "--env", "--env-from-file", "--interactive",
                "--label", "--name", "--no-tty", "--no-deps", "--publish", "--pull", "--quiet", "--quiet-build", "--quiet-pull",
                "--remove-orphans", "--rm", "--service-ports", "--use-aliases", "--user", "--volume", "--workdir",
            ], {
                let command = try Run.parse([
                    "--dry-run",
                    "--build",
                    "--cap-add", "NET_ADMIN",
                    "--cap-drop", "MKNOD",
                    "--detach",
                    "--entrypoint", "/bin/sh",
                    "--env", "A=B",
                    "--env-from-file", ".env",
                    "--interactive",
                    "--label", "x=y",
                    "--name", "oneoff",
                    "--no-tty",
                    "--no-deps",
                    "--publish", "127.0.0.1:8080:80",
                    "--pull", "always",
                    "--quiet",
                    "--quiet-build",
                    "--quiet-pull",
                    "--remove-orphans",
                    "--rm",
                    "--service-ports",
                    "--use-aliases",
                    "--user", "1000",
                    "--volume", "/tmp:/tmp",
                    "--workdir", "/srv",
                    "api",
                    "echo",
                    "ok",
                ])

                #expect(command.global.dryRun)
                #expect(command.build)
                #expect(command.capAdd == ["NET_ADMIN"])
                #expect(command.capDrop == ["MKNOD"])
                #expect(command.detach)
                #expect(command.entrypoint == "/bin/sh")
                #expect(command.environment == ["A=B"])
                #expect(command.envFiles == [".env"])
                #expect(command.interactive)
                #expect(command.labels == ["x=y"])
                #expect(command.name == "oneoff")
                #expect(command.noTty)
                #expect(command.noDeps)
                #expect(command.publish == ["127.0.0.1:8080:80"])
                #expect(command.pull == "always")
                #expect(command.quiet)
                #expect(command.quietBuild)
                #expect(command.quietPull)
                #expect(command.removeOrphans)
                #expect(command.remove)
                #expect(command.servicePorts)
                #expect(command.useAliases)
                #expect(command.user == "1000")
                #expect(command.volumes == ["/tmp:/tmp"])
                #expect(command.workdir == "/srv")
                #expect(command.service == "api")
                #expect(command.command == ["echo", "ok"])
            }),
            (["scale"], ["--dry-run", "--no-deps"], {
                let command = try Scale.parse(["--dry-run", "--no-deps", "api=2"])

                #expect(command.global.dryRun)
                #expect(command.noDeps)
                #expect(command.scales == ["api=2"])
            }),
            (["start"], ["--dry-run", "--wait", "--wait-timeout"], {
                let command = try Start.parse(["--dry-run", "--wait", "--wait-timeout", "10", "api"])

                #expect(command.global.dryRun)
                #expect(command.wait)
                #expect(command.waitTimeout == 10)
                #expect(command.services == ["api"])
            }),
            (["stats"], ["--all", "--dry-run", "--format", "--no-stream", "--no-trunc"], {
                let command = try Stats.parse(["--dry-run", "--all", "--format", "json", "--no-stream", "--no-trunc", "api"])

                #expect(command.global.dryRun)
                #expect(command.all)
                #expect(command.format == "json")
                #expect(command.noStream)
                #expect(command.noTrunc)
                #expect(command.services == ["api"])
            }),
            (["stop"], ["--dry-run", "--timeout"], {
                let command = try Stop.parse(["--dry-run", "--timeout", "5", "api"])

                #expect(command.global.dryRun)
                #expect(command.timeout == 5)
                #expect(command.services == ["api"])
            }),
            (["top"], ["--dry-run"], {
                let command = try Top.parse(["--dry-run", "api"])

                #expect(command.global.dryRun)
                #expect(command.services == ["api"])
            }),
            (["unpause"], ["--dry-run"], {
                let command = try Unpause.parse(["--dry-run", "api"])

                #expect(command.global.dryRun)
                #expect(command.services == ["api"])
            }),
            (["up"], [
                "--abort-on-container-exit", "--abort-on-container-failure", "--always-recreate-deps", "--attach", "--attach-dependencies",
                "--build", "--detach", "--dry-run", "--exit-code-from", "--force-recreate", "--menu", "--no-attach", "--no-build",
                "--no-color", "--no-deps", "--no-log-prefix", "--no-recreate", "--no-start", "--pull", "--quiet-build", "--quiet-pull",
                "--remove-orphans", "--renew-anon-volumes", "--scale", "--timeout", "--timestamps", "--wait", "--wait-timeout", "--watch",
                "--yes",
            ], {
                let rewritten = ComposeArgumentRewriter.rewrite([
                    "up",
                    "--dry-run",
                    "--abort-on-container-exit",
                    "--abort-on-container-failure",
                    "--always-recreate-deps",
                    "--attach", "api",
                    "--attach-dependencies",
                    "--build",
                    "--detach",
                    "--exit-code-from", "api",
                    "--force-recreate",
                    "--menu=false",
                    "--no-attach", "worker",
                    "--no-build",
                    "--no-color",
                    "--no-deps",
                    "--no-log-prefix",
                    "--no-recreate",
                    "--no-start",
                    "--pull", "always",
                    "--quiet-build",
                    "--quiet-pull",
                    "--remove-orphans",
                    "--renew-anon-volumes",
                    "--scale", "api=2",
                    "--timeout", "5",
                    "--timestamps",
                    "--wait",
                    "--wait-timeout", "10",
                    "--watch",
                    "--yes",
                    "api",
                ])
                let command = try Up.parse(Array(rewritten.dropFirst()))

                #expect(command.global.dryRun)
                #expect(command.abortOnContainerExit)
                #expect(command.abortOnContainerFailure)
                #expect(command.alwaysRecreateDeps)
                #expect(command.attach == ["api"])
                #expect(command.attachDependencies)
                #expect(command.build)
                #expect(command.detach)
                #expect(command.exitCodeFrom == "api")
                #expect(command.forceRecreate)
                #expect(!command.menu)
                #expect(command.menuDisabled)
                #expect(command.noAttach == ["worker"])
                #expect(command.noBuild)
                #expect(command.noColor)
                #expect(command.noDeps)
                #expect(command.noLogPrefix)
                #expect(command.noRecreate)
                #expect(command.noStart)
                #expect(command.pull == "always")
                #expect(command.quietBuild)
                #expect(command.quietPull)
                #expect(command.removeOrphans)
                #expect(command.renewAnonVolumes)
                #expect(command.scales == ["api=2"])
                #expect(command.timeout == 5)
                #expect(command.timestamps)
                #expect(command.wait)
                #expect(command.waitTimeout == 10)
                #expect(command.watch)
                #expect(command.yes)
                #expect(command.services == ["api"])
            }),
            (["version"], ["--dry-run", "--format", "--short"], {
                let command = try Version.parse([
                    "--all-resources",
                    "--ansi", "never",
                    "--compatibility",
                    "--dry-run",
                    "--env-file", ".env",
                    "--file", "compose.yml",
                    "--format", "json",
                    "--parallel", "2",
                    "--profile", "dev",
                    "--progress", "plain",
                    "--project-directory", ".",
                    "--project-name", "demo",
                    "--short",
                    "--verbose",
                ])

                #expect(command.global.allResources)
                #expect(command.global.ansi == "never")
                #expect(command.global.compatibility)
                #expect(command.global.dryRun)
                #expect(command.global.envFile == [".env"])
                #expect(command.global.file == ["compose.yml"])
                #expect(command.format == "json")
                #expect(command.global.parallel == 2)
                #expect(command.global.profile == ["dev"])
                #expect(command.global.progress == "plain")
                #expect(command.global.projectDirectory == ".")
                #expect(command.global.projectName == "demo")
                #expect(command.short)
                #expect(command.global.verbose)
            }),
            (["volumes"], ["--dry-run", "--format", "--quiet"], {
                let command = try Volumes.parse(["--dry-run", "--format", "json", "--quiet", "data"])

                #expect(command.global.dryRun)
                #expect(command.format == "json")
                #expect(command.quiet)
                #expect(command.services == ["data"])
            }),
            (["wait"], ["--down-project", "--dry-run"], {
                let command = try Wait.parse(["--dry-run", "--down-project", "api", "worker"])

                #expect(command.global.dryRun)
                #expect(command.downProject)
                #expect(command.services == ["api", "worker"])
            }),
            (["watch"], ["--dry-run", "--no-up", "--prune", "--quiet"], {
                let command = try Watch.parse(["--dry-run", "--no-up", "--prune", "--quiet", "api"])

                #expect(command.global.dryRun)
                #expect(command.noUp)
                #expect(command.prune)
                #expect(command.quiet)
                #expect(command.services == ["api"])
            }),
        ]
    }

    private func longOptions(in help: String) -> Set<String> {
        var options: Set<String> = []
        let separators = CharacterSet(charactersIn: ",")

        for line in help.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else {
                continue
            }

            for word in trimmed.split(separator: " ") {
                let option = word.trimmingCharacters(in: separators)
                if option.hasPrefix("--") {
                    options.insert(option.split(separator: "=", maxSplits: 1).first.map(String.init) ?? option)
                } else if !options.isEmpty && !option.hasPrefix("-") {
                    break
                }
            }
        }

        return options
    }

    private static func format(commandPath: [String]) -> String {
        if commandPath.isEmpty {
            return "root"
        }
        return commandPath.joined(separator: " ")
    }

    private func format(commandPath: [String]) -> String {
        Self.format(commandPath: commandPath)
    }
}

private final class PublishWorkflowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var options: [ComposePublishOptions] = []

    func record(_ call: String, options option: ComposePublishOptions? = nil) {
        lock.lock()
        calls.append(call)
        if let option {
            options.append(option)
        }
        lock.unlock()
    }

    func snapshot() -> (calls: [String], options: [ComposePublishOptions]) {
        lock.lock()
        let snapshot = (calls, options)
        lock.unlock()
        return snapshot
    }
}
