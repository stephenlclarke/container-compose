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
        #expect(help.contains("\u{001B}[38;5;208mattach\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--progress\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--verbose\u{001B}[0m"))
    }

    @Test("root help honours ansi never")
    func rootHelpHonoursANSINever() {
        let help = ComposeCLIHelp.rootHelpText(arguments: ["--ansi", "never", "--file", "Dockerfile"])

        #expect(help.contains("Support: supported | partially supported | not supported"))
        #expect(!help.contains("\u{001B}["))
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

    @Test("run command and options are shown as supported")
    func runCommandAndOptionsAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "run"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--build\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--no-deps\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--service-ports\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--use-aliases\u{001B}[0m"))
    }

    @Test("exec command and privileged option are shown as supported")
    func execCommandAndPrivilegedOptionAreShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "exec"))

        #expect(help.contains("Support: \u{001B}[32msupported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--privileged\u{001B}[0m"))
    }

    @Test("build print option is shown as supported")
    func buildPrintOptionIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "build"))

        #expect(help.contains("Support: \u{001B}[38;5;208mpartially supported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--print\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--ssh\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--provenance\u{001B}[0m"))
        #expect(help.contains("\u{001B}[32m--sbom\u{001B}[0m"))
        #expect(help.contains("Use --provenance=false to explicitly disable."))
        #expect(help.contains("Use --sbom=false to explicitly disable."))
    }

    @Test("attach signal proxy option is shown as supported")
    func attachSignalProxyOptionIsShownAsSupported() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "attach"))

        #expect(help.contains("Support: \u{001B}[38;5;208mpartially supported\u{001B}[0m"))
        #expect(help.contains("\u{001B}[38;5;208m--detach-keys\u{001B}[0m"))
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

    @Test("up menu option shows partial support for explicit disable")
    func upMenuOptionShowsPartialSupportForExplicitDisable() throws {
        let help = try #require(ComposeCLIHelp.commandHelpText(command: "up"))

        #expect(help.contains("\u{001B}[38;5;208m--menu\u{001B}[0m"))
        #expect(help.contains("Use --menu=false to explicitly disable the helper menu."))
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
        #expect(command.services == ["api"])
    }

    @Test("config image digest flags parse")
    func configImageDigestFlagsParse() throws {
        let command = try Config.parse(["--resolve-image-digests", "--lock-image-digests", "api"])

        #expect(command.resolveImageDigests)
        #expect(command.lockImageDigests)
        #expect(command.services == ["api"])
    }

    @Test("build print flag parses")
    func buildPrintFlagParses() throws {
        let command = try Build.parse([
            "--print",
            "--provenance=false",
            "--sbom", "false",
            "--build-arg", "VERSION=2",
            "--ssh", "default",
            "--ssh", "git=/tmp/git.sock",
            "--with-dependencies",
            "api",
        ])

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
                let command = try Bridge.parse(["--dry-run", "convert"])

                #expect(command.global.dryRun)
                #expect(command.arguments == ["convert"])
            }),
            (["bridge", "convert"], ["--dry-run", "--output", "--templates", "--transformation"], {
                let command = try Bridge.parse(["--dry-run", "convert", "--output", "out", "--templates", "templates", "--transformation", "one"])

                #expect(command.global.dryRun)
                #expect(command.arguments == ["convert", "--output", "out", "--templates", "templates", "--transformation", "one"])
            }),
            (["bridge", "transformations"], ["--dry-run"], {
                let command = try Bridge.parse(["--dry-run", "transformations"])

                #expect(command.global.dryRun)
                #expect(command.arguments == ["transformations"])
            }),
            (["bridge", "transformations", "create"], ["--dry-run", "--from"], {
                let command = try Bridge.parse(["--dry-run", "transformations", "create", "--from", "base", "path"])

                #expect(command.global.dryRun)
                #expect(command.arguments == ["transformations", "create", "--from", "base", "path"])
            }),
            (["bridge", "transformations", "list"], ["--dry-run", "--format", "--quiet"], {
                let command = try Bridge.parse(["--dry-run", "transformations", "list", "--format", "json", "--quiet"])

                #expect(command.global.dryRun)
                #expect(command.arguments == ["transformations", "list", "--format", "json", "--quiet"])
            }),
            (["bridge", "transformations", "ls"], ["--dry-run", "--format", "--quiet"], {
                let command = try Bridge.parse(["--dry-run", "transformations", "ls", "--format", "json", "--quiet"])

                #expect(command.global.dryRun)
                #expect(command.arguments == ["transformations", "ls", "--format", "json", "--quiet"])
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
                #expect(command.arguments == ["--author", "Me", "--change", "CMD true", "--index", "2", "--message", "snapshot", "--pause", "api", "example/api:snapshot"])
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
                let command = try Publish.parse(["--dry-run", "--app", "demo", "--oci-version", "1.1", "--resolve-image-digests", "--with-env", "--yes", "repo/app:latest"])

                #expect(command.global.dryRun)
                #expect(command.arguments == ["--app", "demo", "--oci-version", "1.1", "--resolve-image-digests", "--with-env", "--yes", "repo/app:latest"])
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
                "--label", "--name", "--no-TTY", "--no-deps", "--publish", "--pull", "--quiet", "--quiet-build", "--quiet-pull",
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
                    "--no-TTY",
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
