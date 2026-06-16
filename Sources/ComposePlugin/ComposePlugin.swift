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

/// Root command for the `container compose` plugin.
struct ComposePlugin: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions

    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Manage multi-container applications with Docker Compose syntax",
        version: "container-compose 0.1.0",
        subcommands: [
            Config.self,
            Up.self,
            Down.self,
            Build.self,
            Pull.self,
            Push.self,
            Ps.self,
            Logs.self,
            Exec.self,
            Run.self,
            Start.self,
            Stop.self,
            Restart.self,
            Rm.self,
            Images.self,
            Top.self,
            Events.self,
            Port.self,
            Cp.self,
            Kill.self,
            Pause.self,
            Unpause.self,
            Wait.self,
            Version.self,
        ]
    )
}

@main
struct ComposePluginMain {
    static func main() async {
        // Docker Compose allows global options before the subcommand. Rewrite
        // them before handing arguments to Swift Argument Parser.
        await ComposePlugin.main(ComposeArgumentRewriter.rewrite(Array(CommandLine.arguments.dropFirst())))
    }
}

/// Global Docker Compose compatible options accepted by every subcommand.
struct GlobalOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Compose file path. May be repeated.")
    var file: [String] = []

    @Option(name: [.customShort("p"), .customLong("project-name")], help: "Compose project name.")
    var projectName: String?

    @Option(name: .customLong("profile"), help: "Enable a Compose profile. May be repeated.")
    var profile: [String] = []

    @Option(name: .customLong("env-file"), help: "Environment file. May be repeated.")
    var envFile: [String] = []

    @Option(name: .customLong("project-directory"), help: "Project directory.")
    var projectDirectory: String?

    @Option(name: .customLong("ansi"), help: "ANSI control policy, accepted for Docker Compose compatibility.")
    var ansi: String?

    @Option(name: .customLong("progress"), help: "Progress output policy, accepted for Docker Compose compatibility.")
    var progress: String?

    @Flag(name: .customLong("dry-run"), help: "Print container commands instead of running them.")
    var dryRun: Bool = false

    @Flag(name: .customLong("verbose"), help: "Enable verbose compose output.")
    var verbose: Bool = false

    func composeOptions() -> ComposeOptions {
        ComposeOptions(
            files: file,
            projectName: projectName,
            profiles: profile,
            envFiles: envFile,
            projectDirectory: projectDirectory,
            ansi: ansi,
            progress: progress,
            dryRun: dryRun,
            verbose: verbose
        )
    }

    func loadProject() async throws -> ComposeProject {
        try await ComposeNormalizer().normalize(options: composeOptions())
    }

    func orchestrator() -> ComposeOrchestrator {
        ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: dryRun))
    }
}

protocol ComposeProjectCommand {
    var global: GlobalOptions { get }
}

extension ComposeProjectCommand {
    /// Loads and normalizes the Compose project for commands that need it.
    func project() async throws -> ComposeProject {
        try await global.loadProject()
    }

    /// Creates the runtime orchestrator for commands that execute containers.
    func orchestrator() -> ComposeOrchestrator {
        global.orchestrator()
    }
}

struct Config: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Validate and print the normalized Compose project.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let project = try await project()
        print(try orchestrator().config(project: project))
    }
}

struct Up: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "up", abstract: "Create and start services.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "Build images before starting services.")
    var build = false
    @Flag(name: .shortAndLong, help: "Run containers in the background.")
    var detach = false
    @Flag(name: .customLong("force-recreate"), help: "Recreate containers even if they already exist.")
    var forceRecreate = false
    @Flag(name: .customLong("no-recreate"), help: "Reuse existing containers.")
    var noRecreate = false
    @Flag(name: .customLong("remove-orphans"), help: "Accepted for compatibility; orphan cleanup is label scoped.")
    var removeOrphans = false
    @Option(name: .customLong("pull"), help: "Image pull policy: always, missing, or never.")
    var pull: String?
    @Argument(help: "Optional service names to start.")
    var services: [String] = []

    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().up(
            project: loadedProject,
            options: ComposeUpOptions(
                services: services,
                build: build,
                detach: detach,
                forceRecreate: forceRecreate,
                noRecreate: noRecreate,
                removeOrphans: removeOrphans,
                pullPolicy: pull
            )
        )
    }
}

struct Down: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Stop and remove project resources.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: [.customShort("v"), .customLong("volumes")], help: "Remove named volumes declared by the Compose project.")
    var volumes = false
    @Flag(name: .customLong("remove-orphans"), help: "Accepted for compatibility; orphan cleanup is label scoped.")
    var removeOrphans = false

    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().down(project: loadedProject, options: ComposeDownOptions(volumes: volumes, removeOrphans: removeOrphans))
    }
}

struct Build: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build service images.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("no-cache"), help: "Do not use cached image layers.")
    var noCache = false
    @Argument(help: "Optional services to build.")
    var services: [String] = []

    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().build(project: loadedProject, services: services, noCache: noCache)
    }
}

struct Pull: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Pull service images.")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Optional services to pull.")
    var services: [String] = []

    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().pull(project: loadedProject, services: services)
    }
}

struct Push: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Push service images.")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Optional services to push.")
    var services: [String] = []

    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().push(project: loadedProject, services: services)
    }
}

struct Ps: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List project containers.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "Include stopped containers.")
    var all = false

    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().ps(project: loadedProject, all: all)
    }
}

struct Logs: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Show service logs.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "Follow log output.")
    var follow = false
    @Option(name: .customLong("tail"), help: "Number of lines to show from the end of logs.")
    var tail: Int?
    @Argument(help: "Optional services to show.")
    var services: [String] = []

    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().logs(project: loadedProject, services: services, follow: follow, tail: tail)
    }
}

struct Exec: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "exec", abstract: "Execute a command in a running service container.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "Keep stdin open.")
    var interactive = false
    @Flag(name: .shortAndLong, help: "Allocate a TTY.")
    var tty = false
    @Argument(help: "Service name.")
    var service: String
    @Argument(parsing: .captureForPassthrough, help: "Command and arguments.")
    var command: [String]

    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().exec(project: loadedProject, serviceName: service, command: command, interactive: interactive, tty: tty)
    }
}

struct Run: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run a one-off command for a service.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("rm"), help: "Remove the one-off container after exit.")
    var remove = false
    @Argument(help: "Service name.")
    var service: String
    @Argument(parsing: .captureForPassthrough, help: "Optional replacement command.")
    var command: [String] = []

    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().run(project: loadedProject, serviceName: service, command: command, remove: remove)
    }
}

struct Start: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start existing service containers.")
    @OptionGroup var global: GlobalOptions
    @Argument var services: [String] = []
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().start(project: loadedProject, services: services)
    }
}

struct Stop: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop service containers.")
    @OptionGroup var global: GlobalOptions
    @Argument var services: [String] = []
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().stop(project: loadedProject, services: services)
    }
}

struct Restart: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart service containers.")
    @OptionGroup var global: GlobalOptions
    @Argument var services: [String] = []
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().restart(project: loadedProject, services: services)
    }
}

struct Rm: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove service containers.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: [.customShort("s"), .customLong("stop")], help: "Stop containers before removing them.")
    var stop = false
    @Argument var services: [String] = []
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().rm(project: loadedProject, services: services, stopFirst: stop)
    }
}

struct Images: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "images", abstract: "List images used by services.")
    @OptionGroup var global: GlobalOptions
    @Argument var services: [String] = []
    func run() async throws {
        let loadedProject = try await project()
        for image in try orchestrator().images(project: loadedProject, services: services) {
            print(image)
        }
    }
}

struct Kill: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "kill", abstract: "Kill service containers.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .shortAndLong, help: "Signal to send.")
    var signal: String?
    @Argument var services: [String] = []
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().kill(project: loadedProject, services: services, signal: signal)
    }
}

struct Cp: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "cp", abstract: "Copy files using the underlying container cp command.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .captureForPassthrough) var arguments: [String]
    func run() async throws { try await orchestrator().copy(arguments: arguments) }
}

struct Top: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "top", abstract: "Display running processes.")
    @OptionGroup var global: GlobalOptions
    func run() throws { try global.orchestrator().unsupported("top", reason: "Apple container does not expose a process-list command yet") }
}

struct Events: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "events", abstract: "Stream project events.")
    @OptionGroup var global: GlobalOptions
    func run() throws { try global.orchestrator().unsupported("events", reason: "Apple container does not expose an event stream yet") }
}

struct Port: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "port", abstract: "Print public port bindings.")
    @OptionGroup var global: GlobalOptions
    func run() throws { try global.orchestrator().unsupported("port", reason: "published port lookup needs richer inspect output") }
}

struct Pause: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause service containers.")
    @OptionGroup var global: GlobalOptions
    func run() throws { try global.orchestrator().unsupported("pause", reason: "Apple container does not expose pause yet") }
}

struct Unpause: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "unpause", abstract: "Unpause service containers.")
    @OptionGroup var global: GlobalOptions
    func run() throws { try global.orchestrator().unsupported("unpause", reason: "Apple container does not expose unpause yet") }
}

struct Wait: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "wait", abstract: "Wait for service containers to exit.")
    @OptionGroup var global: GlobalOptions
    func run() throws { try global.orchestrator().unsupported("wait", reason: "exit code and completion time need an apple/container runtime gap PR") }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Print compose plugin version.")
    func run() {
        print("container-compose 0.1.0")
    }
}
