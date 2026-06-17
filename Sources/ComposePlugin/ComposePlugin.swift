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

private let composePluginVersionNumber = "0.1.0"
private let composePluginVersionString = "container-compose \(composePluginVersionNumber)"

/// Root command for the `container compose` plugin.
struct ComposePlugin: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions

    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Manage multi-container applications with Docker Compose syntax",
        version: composePluginVersionString,
        subcommands: [
            Config.self,
            Create.self,
            Up.self,
            Down.self,
            Build.self,
            Pull.self,
            Push.self,
            Ls.self,
            Ps.self,
            Logs.self,
            Exec.self,
            Run.self,
            Start.self,
            Stop.self,
            Restart.self,
            Rm.self,
            Images.self,
            Stats.self,
            Top.self,
            Events.self,
            Port.self,
            Watch.self,
            Scale.self,
            Attach.self,
            Commit.self,
            Convert.self,
            Export.self,
            Publish.self,
            Volumes.self,
            Cp.self,
            Kill.self,
            Pause.self,
            Unpause.self,
            Wait.self,
            Version.self,
        ]
    )
}

/// Entry point that normalizes Docker Compose argument ordering before parse.
@main
struct ComposePluginMain {
    /// Rewrites process arguments and starts the async command tree.
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

    /// Converts parser state into the normalization options model.
    func composeOptions() -> ComposeOptions {
        ComposeOptions(
            files: file,
            projectName: projectName,
            profiles: profile,
            envFiles: envFile,
            projectDirectory: projectDirectory
        )
    }

    /// Loads the Compose project through the compose-go normalizer.
    func loadProject() async throws -> ComposeProject {
        try await ComposeNormalizer().normalize(options: composeOptions())
    }

    /// Creates an orchestrator configured from global runtime flags.
    func orchestrator() -> ComposeOrchestrator {
        ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: dryRun))
    }
}

/// Shared contract for subcommands that operate on a Compose project.
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

/// Implements `compose config`.
struct Config: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Validate and print the normalized Compose project.")

    @OptionGroup var global: GlobalOptions

    /// Prints the canonical project JSON emitted by the orchestrator.
    func run() async throws {
        let project = try await project()
        print(try orchestrator().config(project: project))
    }
}

/// Implements `compose create`.
struct Create: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create service containers without starting them.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("build"), help: "Build images before creating containers.")
    var build = false
    @Flag(name: .customLong("no-build"), help: "Do not build images before creating containers.")
    var noBuild = false
    @Flag(name: .customLong("force-recreate"), help: "Recreate containers even if they already exist.")
    var forceRecreate = false
    @Flag(name: .customLong("no-recreate"), help: "Reuse existing containers.")
    var noRecreate = false
    @Option(name: .customLong("pull"), help: "Image pull policy: always, missing, if_not_present, never, or build.")
    var pull: String?
    @Flag(name: .customLong("quiet-pull"), help: "Accepted for Docker Compose compatibility.")
    var quietPull = false
    @Flag(name: .customLong("remove-orphans"), help: "Remove project containers for services not declared by the Compose file.")
    var removeOrphans = false
    @Option(name: .customLong("scale"), help: "Scale SERVICE to NUM. Replica scaling is not supported yet.")
    var scales: [String] = []
    @Flag(name: [.customShort("y"), .customLong("yes")], help: "Accepted for Docker Compose compatibility.")
    var yes = false
    @Argument(help: "Optional service names to create.")
    var services: [String] = []

    /// Creates selected service containers without starting them.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().create(
            project: loadedProject,
            options: ComposeCreateOptions {
                $0.services = services
                $0.build = build
                $0.noBuild = noBuild
                $0.forceRecreate = forceRecreate
                $0.noRecreate = noRecreate
                $0.removeOrphans = removeOrphans
                $0.pullPolicy = pull
                $0.scales = scales
            }
        )
    }
}

/// Implements `compose up`.
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
    @Flag(name: .customLong("remove-orphans"), help: "Remove project containers for services not declared by the Compose file.")
    var removeOrphans = false
    @Option(name: .customLong("pull"), help: "Image pull policy: always, missing, if_not_present, or never.")
    var pull: String?
    @Option(name: .customLong("scale"), help: "Scale SERVICE to NUM. Replica scaling is not supported yet.")
    var scales: [String] = []
    @Flag(name: .customLong("no-deps"), help: "Do not start linked services.")
    var noDeps = false
    @Argument(help: "Optional service names to start.")
    var services: [String] = []

    /// Creates resources and starts selected services.
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
                pullPolicy: pull,
                scales: scales,
                noDeps: noDeps
            )
        )
    }
}

/// Implements `compose down`.
struct Down: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Stop and remove project resources.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: [.customShort("v"), .customLong("volumes")], help: "Remove named volumes declared by the Compose project.")
    var volumes = false
    @Flag(name: .customLong("remove-orphans"), help: "Remove project containers for services not declared by the Compose file.")
    var removeOrphans = false
    @Option(name: [.customShort("t"), .customLong("timeout")], help: "Seconds to wait before killing containers.")
    var timeout: Int?
    @Option(name: .customLong("rmi"), help: "Remove images used by services: local or all.")
    var rmi: String?

    /// Stops containers and removes project-scoped resources.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().down(
            project: loadedProject,
            options: ComposeDownOptions(volumes: volumes, removeOrphans: removeOrphans, timeout: timeout, rmi: rmi)
        )
    }
}

/// Implements `compose build`.
struct Build: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build service images.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("no-cache"), help: "Do not use cached image layers.")
    var noCache = false
    @Argument(help: "Optional services to build.")
    var services: [String] = []

    /// Builds selected service images.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().build(project: loadedProject, services: services, noCache: noCache)
    }
}

/// Implements `compose pull`.
struct Pull: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Pull service images.")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Optional services to pull.")
    var services: [String] = []

    /// Pulls selected service images.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().pull(project: loadedProject, services: services)
    }
}

/// Implements `compose push`.
struct Push: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Push service images.")

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Optional services to push.")
    var services: [String] = []

    /// Pushes selected service images.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().push(project: loadedProject, services: services)
    }
}

/// Implements `compose ls`.
struct Ls: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List Compose projects.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "Show stopped Compose projects.")
    var all = false
    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Only display project names.")
    var quiet = false
    @Option(name: .customLong("format"), help: "Output format: table or json.")
    var format = "table"
    @Option(name: .customLong("filter"), help: "Filter projects. Supported filter: name.")
    var filters: [String] = []

    /// Lists project names and status without loading a Compose file.
    func run() async throws {
        try await global.orchestrator().ls(options: ComposeLsOptions(all: all, quiet: quiet, format: format, filters: filters))
    }
}

/// Implements `compose ps`.
struct Ps: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List project containers.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "Include stopped containers.")
    var all = false
    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Only display container IDs.")
    var quiet = false
    @Flag(name: .customLong("services"), help: "Only display service names.")
    var services = false
    @Option(name: .customLong("status"), help: "Filter services by container status.")
    var statuses: [String] = []
    @Option(name: .customLong("filter"), help: "Filter services by a property. Supported filter: status.")
    var filters: [String] = []

    /// Lists project containers, optionally including stopped containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().ps(
            project: loadedProject,
            all: all,
            quiet: quiet,
            services: services,
            statuses: statuses,
            filters: filters
        )
    }
}

/// Implements `compose logs`.
struct Logs: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Show service logs.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("follow"), help: "Follow log output.")
    var follow = false
    @Option(name: [.customShort("n"), .customLong("tail")], help: "Number of lines to show from the end of logs, or all.")
    var tail: String?
    @Argument(help: "Optional services to show.")
    var services: [String] = []

    /// Streams or prints logs for selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().logs(project: loadedProject, services: services, follow: follow, tail: tail)
    }
}

/// Implements `compose exec`.
struct Exec: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "exec", abstract: "Execute a command in a running service container.")

    @OptionGroup var global: GlobalOptions
    @Flag(
        name: .shortAndLong,
        inversion: .prefixedNo,
        help: "Keep stdin open. Enabled by default for Compose compatibility."
    )
    var interactive = true
    @Flag(
        name: .shortAndLong,
        inversion: .prefixedNo,
        help: "Allocate a TTY. Enabled by default for Compose compatibility."
    )
    var tty = true
    @Flag(name: .customShort("T"), help: "Disable pseudo-TTY allocation.")
    var noTty = false
    @Argument(help: "Service name.")
    var service: String
    @Argument(parsing: .allUnrecognized, help: "Command and arguments.")
    var command: [String]

    /// Executes the requested command in an existing service container.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().exec(
            project: loadedProject,
            serviceName: service,
            command: command,
            interactive: interactive,
            tty: tty && !noTty
        )
    }
}

/// Implements `compose run`.
struct Run: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run a one-off command for a service.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("rm"), help: "Remove the one-off container after exit.")
    var remove = false
    @Flag(name: .shortAndLong, help: "Run the one-off container in the background.")
    var detach = false
    @Flag(name: [.customShort("T"), .customLong("no-tty")], help: "Disable pseudo-TTY allocation.")
    var noTty = false
    @Flag(name: [.customShort("P"), .customLong("service-ports")], help: "Publish all ports declared by the service.")
    var servicePorts = false
    @Option(name: .customLong("publish"), help: "Publish a container port to the host. May be repeated.")
    var publish: [String] = []
    @Option(name: .customLong("pull"), help: "Image pull policy before running: always, missing, if_not_present, or never.")
    var pull: String?
    @Option(name: .customLong("name"), help: "Assign a name to the one-off container.")
    var name: String?
    @Option(name: .customLong("entrypoint"), help: "Override the service entrypoint for the one-off container.")
    var entrypoint: String?
    @Option(name: [.customShort("w"), .customLong("workdir")], help: "Override the working directory for the one-off container.")
    var workdir: String?
    @Option(name: [.customShort("u"), .customLong("user")], help: "Override the user for the one-off container.")
    var user: String?
    @Option(name: [.customShort("e"), .customLong("env")], help: "Set an environment variable for the one-off container. May be repeated.")
    var environment: [String] = []
    @Option(name: .customLong("env-from-file"), help: "Read environment variables for the one-off container from a file. May be repeated.")
    var envFiles: [String] = []
    @Option(name: [.customShort("l"), .customLong("label")], help: "Add or override a label for the one-off container. May be repeated.")
    var labels: [String] = []
    @Option(name: [.customShort("v"), .customLong("volume")], help: "Bind mount a volume for the one-off container. May be repeated.")
    var volumes: [String] = []
    @Argument(help: "Service name.")
    var service: String
    @Argument(parsing: .allUnrecognized, help: "Optional replacement command.")
    var command: [String] = []

    /// Runs a one-off service container with an optional command override.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().run(
            project: loadedProject,
            serviceName: service,
            options: ComposeRunOptions {
                $0.command = command
                $0.remove = remove
                $0.detach = detach
                $0.noTty = noTty
                $0.servicePorts = servicePorts
                $0.publish = publish
                $0.pullPolicy = pull
                $0.containerName = name
                $0.entrypoint = entrypoint
                $0.workingDirectory = workdir
                $0.user = user
                $0.environment = environment
                $0.envFiles = envFiles
                $0.labels = labels
                $0.volumes = volumes
            }
        )
    }
}

/// Implements `compose start`.
struct Start: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start existing service containers.")
    @OptionGroup var global: GlobalOptions
    @Argument var services: [String] = []
    /// Starts selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().start(project: loadedProject, services: services)
    }
}

/// Implements `compose stop`.
struct Stop: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop service containers.")
    @OptionGroup var global: GlobalOptions
    @Option(name: [.customShort("t"), .customLong("timeout")], help: "Seconds to wait before killing containers.")
    var timeout: Int?
    @Argument var services: [String] = []
    /// Stops selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().stop(project: loadedProject, services: services, timeout: timeout)
    }
}

/// Implements `compose restart`.
struct Restart: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart service containers.")
    @OptionGroup var global: GlobalOptions
    @Option(name: [.customShort("t"), .customLong("timeout")], help: "Seconds to wait before killing containers.")
    var timeout: Int?
    @Argument var services: [String] = []
    /// Restarts selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().restart(project: loadedProject, services: services, timeout: timeout)
    }
}

/// Implements `compose rm`.
struct Rm: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove service containers.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("force"), help: "Don't ask to confirm removal and force container deletion.")
    var force = false
    @Flag(name: [.customShort("s"), .customLong("stop")], help: "Stop containers before removing them.")
    var stop = false
    @Flag(name: [.customShort("v"), .customLong("volumes")], help: "Remove anonymous volumes attached to selected containers.")
    var volumes = false
    @Argument var services: [String] = []
    /// Removes selected service containers, optionally stopping them first.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().rm(project: loadedProject, services: services, stopFirst: stop, force: force, volumes: volumes)
    }
}

/// Implements `compose images`.
struct Images: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "images", abstract: "List images used by created service containers.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("format"), help: "Output format: table or json.")
    var format = "table"
    @Flag(name: .shortAndLong, help: "Only display image IDs.")
    var quiet = false
    @Argument var services: [String] = []
    /// Lists images used by project containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().images(project: loadedProject, services: services, options: ComposeImagesOptions(quiet: quiet, format: format))
    }
}

/// Implements `compose stats`.
struct Stats: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "stats", abstract: "Display service container resource usage statistics.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: [.customShort("a"), .customLong("all")], help: "Show all containers. Not supported by apple/container stats yet.")
    var all = false
    @Option(name: .customLong("format"), help: "Output format: table or json.")
    var format = "table"
    @Flag(name: .customLong("no-stream"), help: "Disable streaming stats and only pull the first result.")
    var noStream = false
    @Flag(name: .customLong("no-trunc"), help: "Do not truncate output. Not supported by apple/container stats yet.")
    var noTrunc = false
    @Argument(help: "Optional service name.")
    var services: [String] = []

    /// Displays resource usage statistics for the project or one selected service.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().stats(
            project: loadedProject,
            options: ComposeStatsOptions(
                services: services,
                all: all,
                format: format,
                noStream: noStream,
                noTrunc: noTrunc
            )
        )
    }
}

/// Implements `compose kill`.
struct Kill: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "kill", abstract: "Kill service containers.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .shortAndLong, help: "Signal to send.")
    var signal: String?
    @Argument var services: [String] = []
    /// Sends the requested signal to selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().kill(project: loadedProject, services: services, signal: signal)
    }
}

/// Implements `compose cp`.
struct Cp: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "cp", abstract: "Copy files between service containers and local paths.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String]
    /// Resolves Compose service references before delegating to the runtime.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().copy(project: loadedProject, arguments: arguments)
    }
}

/// Placeholder for `compose top` until apple/container exposes process listing.
struct Top: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "top", abstract: "Display running processes.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the runtime gap for process listing.
    func run() throws {
        try global.orchestrator().unsupported("top", reason: "apple/container does not expose a process-list command yet")
    }
}

/// Placeholder for `compose events` until apple/container exposes event streams.
struct Events: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "events", abstract: "Stream project events.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the runtime gap for event streaming.
    func run() throws {
        try global.orchestrator().unsupported("events", reason: "apple/container does not expose an event stream yet")
    }
}

/// Implements `compose port` for static Compose port bindings.
struct Port: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "port", abstract: "Print public port bindings.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("protocol"), help: "Port protocol: tcp or udp.")
    var portProtocol = "tcp"
    @Option(name: .customLong("index"), help: "Container index. Only 1 is supported until replica-aware runtime lookup is available.")
    var index = 1
    @Argument(help: "Service name.")
    var service: String
    @Argument(help: "Private container port.")
    var privatePort: String
    /// Prints the host address and published port for a static service binding.
    func run() async throws {
        let loadedProject = try await project()
        try orchestrator().port(
            project: loadedProject,
            serviceName: service,
            privatePort: privatePort,
            protocolName: portProtocol,
            index: index
        )
    }
}

/// Placeholder for `compose watch` until develop/watch orchestration exists.
struct Watch: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "Watch build context and service files.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the plugin gap for watch orchestration.
    func run() throws {
        try global.orchestrator().unsupported("watch", reason: "develop/watch workflows are not implemented by container-compose yet")
    }
}

/// Placeholder for `compose scale` until replica orchestration exists.
struct Scale: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "scale", abstract: "Scale services.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the plugin gap for service replica scaling.
    func run() throws {
        try global.orchestrator().unsupported("scale", reason: "service replica scaling is not implemented by container-compose yet")
    }
}

/// Placeholder for `compose attach` until attach streaming is designed.
struct Attach: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "attach", abstract: "Attach to a service container.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the plugin gap for attach streaming.
    func run() throws {
        try global.orchestrator().unsupported("attach", reason: "service attach streaming is not implemented by container-compose yet")
    }
}

/// Placeholder for `compose commit` until image snapshot mapping exists.
struct Commit: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "commit", abstract: "Create an image from a service container.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the plugin gap for committing service containers.
    func run() throws {
        try global.orchestrator().unsupported("commit", reason: "service container commit is not implemented by container-compose yet")
    }
}

/// Placeholder for `compose convert` until alternate output conversion exists.
struct Convert: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "convert", abstract: "Convert the Compose model.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the plugin gap for Compose model conversion.
    func run() throws {
        try global.orchestrator().unsupported("convert", reason: "Compose model conversion is not implemented by container-compose yet")
    }
}

/// Placeholder for `compose export` until container export mapping exists.
struct Export: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export a service container filesystem.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the plugin gap for service container export.
    func run() throws {
        try global.orchestrator().unsupported("export", reason: "service container export is not implemented by container-compose yet")
    }
}

/// Placeholder for `compose publish` until project publishing is designed.
struct Publish: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "publish", abstract: "Publish the Compose application.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the plugin gap for project publishing.
    func run() throws {
        try global.orchestrator().unsupported("publish", reason: "Compose application publishing is not implemented by container-compose yet")
    }
}

/// Placeholder for `compose volumes` until volume subcommands are designed.
struct Volumes: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "volumes", abstract: "Manage Compose volumes.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the plugin gap for the Compose volumes command group.
    func run() throws {
        try global.orchestrator().unsupported("volumes", reason: "Compose volume command group is not implemented by container-compose yet")
    }
}

/// Placeholder for `compose pause` until apple/container exposes pause.
struct Pause: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause service containers.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the runtime gap for pausing containers.
    func run() throws {
        try global.orchestrator().unsupported("pause", reason: "apple/container does not expose pause yet")
    }
}

/// Placeholder for `compose unpause` until apple/container exposes unpause.
struct Unpause: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "unpause", abstract: "Unpause service containers.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the runtime gap for unpausing containers.
    func run() throws {
        try global.orchestrator().unsupported("unpause", reason: "apple/container does not expose unpause yet")
    }
}

/// Placeholder for `compose wait` until exit metadata is available.
struct Wait: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "wait", abstract: "Wait for service containers to exit.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the runtime gap for wait semantics.
    func run() throws {
        try global.orchestrator().unsupported("wait", reason: "exit code and completion time need an apple/container runtime gap PR")
    }
}

/// Implements `compose version`.
struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Print compose plugin version.")
    @OptionGroup var global: VersionGlobalOptions
    @Option(name: [.customShort("f"), .customLong("format")], help: "Format the output: pretty or json.")
    var format = "pretty"
    @Flag(name: .customLong("short"), help: "Show only the compose plugin version number.")
    var short = false

    /// Prints the plugin version in a Docker Compose compatible format.
    func run() throws {
        if short {
            print(composePluginVersionNumber)
            return
        }

        switch format.lowercased() {
        case "pretty":
            print(composePluginVersionString)
        case "json":
            print(#"{"version":"\#(composePluginVersionNumber)"}"#)
        default:
            throw ComposeError.unsupported("version --format '\(format)'; supported formats are pretty and json")
        }
    }
}

/// Global options accepted after `compose version`.
struct VersionGlobalOptions: ParsableArguments {
    @Option(name: .customLong("file"), help: "Accepted for Docker Compose compatibility.")
    var file: [String] = []
    @Option(name: [.customShort("p"), .customLong("project-name")], help: "Accepted for Docker Compose compatibility.")
    var projectName: String?
    @Option(name: .customLong("profile"), help: "Accepted for Docker Compose compatibility.")
    var profile: [String] = []
    @Option(name: .customLong("env-file"), help: "Accepted for Docker Compose compatibility.")
    var envFile: [String] = []
    @Option(name: .customLong("project-directory"), help: "Accepted for Docker Compose compatibility.")
    var projectDirectory: String?
    @Option(name: .customLong("ansi"), help: "Accepted for Docker Compose compatibility.")
    var ansi: String?
    @Option(name: .customLong("progress"), help: "Accepted for Docker Compose compatibility.")
    var progress: String?
    @Flag(name: .customLong("dry-run"), help: "Accepted for Docker Compose compatibility.")
    var dryRun = false
    @Flag(name: .customLong("verbose"), help: "Accepted for Docker Compose compatibility.")
    var verbose = false
}
