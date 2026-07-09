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
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

private let composeBuildInfo = ComposeBuildInfo.load()
private let composePluginVersionNumber = composeBuildInfo.version
private let composePluginVersionString = "container-compose \(composePluginVersionNumber)"

private struct ComposeBuildInfo: Codable {
    var version: String = "0.6.12"
    var source: String = "unspecified"
    var branch: String = "unspecified"
    var lane: String = "unspecified"
    var commit: String = "unspecified"
    var buildType: String = defaultBuildType
    var containerSource: String = "unspecified"
    var containerRef: String = "unspecified"
    var containerizationSource: String = "unspecified"
    var containerizationRef: String = "unspecified"
    var composeGoVersion: String?

    var containerDistribution: String {
        distribution(source: containerSource, appleSource: "apple/container")
    }

    var containerizationDistribution: String {
        distribution(source: containerizationSource, appleSource: "apple/containerization")
    }

    static func load() -> ComposeBuildInfo {
        if let path = ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_BUILD_INFO"],
           let info = decode(path: path) {
            return info
        }
        if let info = decode(path: packagedBuildInfoPath()) {
            return info
        }
        return localBuildInfo()
    }

    private static var defaultBuildType: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static func packagedBuildInfoPath() -> String {
        let executable = URL(fileURLWithPath: executablePath()).resolvingSymlinksInPath()
        return executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("resources/build-info.json")
            .path
    }

    private static func executablePath() -> String {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            return FileManager.default.string(
                withFileSystemRepresentation: buffer,
                length: Int(strlen(buffer))
            )
        }
        #endif

        return CommandLine.arguments.first ?? ""
    }

    private static func decode(path: String) -> ComposeBuildInfo? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode(ComposeBuildInfo.self, from: data)
    }

    private static func localBuildInfo() -> ComposeBuildInfo {
        let root = git(["rev-parse", "--show-toplevel"]) ?? FileManager.default.currentDirectoryPath
        let branch = git(["branch", "--show-current"], root: root) ?? "unspecified"
        return ComposeBuildInfo(
            version: "0.6.12",
            source: remoteSource(root: root),
            branch: branch,
            lane: lane(for: branch),
            commit: git(["rev-parse", "HEAD"], root: root) ?? "unspecified",
            buildType: defaultBuildType,
            containerSource: "stephenlclarke/container",
            containerRef: localContainerRef(root: root) ?? "unspecified",
            containerizationSource: normalizedSource(packageResolvedValue(root: root, key: "location") ?? "unspecified"),
            containerizationRef: packageResolvedState(root: root) ?? "unspecified",
            composeGoVersion: goModuleVersion(root: root, module: "github.com/compose-spec/compose-go/v2")
        )
    }

    private static func remoteSource(root: String) -> String {
        let remote = git(["remote", "get-url", "origin"], root: root) ?? "unspecified"
        return remote
            .normalizedGitHubSource()
    }

    private static func normalizedSource(_ source: String) -> String {
        source.normalizedGitHubSource()
    }

    private func distribution(source: String, appleSource: String) -> String {
        if source == appleSource {
            return "apple"
        }
        if source.isEmpty || source == "unspecified" {
            return "unknown"
        }
        return "custom"
    }
}

private struct ComposeVersionOutput: Encodable {
    let version: String
    let source: String
    let branch: String
    let lane: String
    let commit: String
    let buildType: String
    let containerSource: String
    let containerRef: String
    let containerDistribution: String
    let containerizationSource: String
    let containerizationRef: String
    let containerizationDistribution: String
    let composeGoVersion: String

    init(_ info: ComposeBuildInfo) {
        self.version = info.version
        self.source = info.source
        self.branch = info.branch
        self.lane = info.lane
        self.commit = info.commit
        self.buildType = info.buildType
        self.containerSource = info.containerSource
        self.containerRef = info.containerRef
        self.containerDistribution = info.containerDistribution
        self.containerizationSource = info.containerizationSource
        self.containerizationRef = info.containerizationRef
        self.containerizationDistribution = info.containerizationDistribution
        self.composeGoVersion = info.composeGoVersion ?? "unspecified"
    }
}

private extension String {
    func normalizedGitHubSource() -> String {
        self
            .replacingOccurrences(of: GitMetadata.httpsSourcePrefix, with: "")
            .replacingOccurrences(of: GitMetadata.sshSourcePrefix, with: "")
            .replacingOccurrences(of: GitMetadata.repositorySuffix, with: "")
    }
}

private enum GitMetadata {
    static let httpsSourcePrefix = ["https:", "", "github.com", ""].joined(separator: "/")
    static let sshSourcePrefix = "git@" + "github.com:"
    static let repositorySuffix = ".git"
    static var executablePath: String {
        ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_GIT"]
            ?? ["", "usr", "bin", "git"].joined(separator: "/")
    }
}

private extension ComposeBuildInfo {
    static func lane(for branch: String) -> String {
        if branch == "main" {
            return "main"
        }
        if branch == "release" || branch.hasPrefix("release-") {
            return "release"
        }
        if branch == "HEAD" || branch.isEmpty {
            return "detached"
        }
        return "development"
    }

    static func git(_ arguments: [String], root: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitMetadata.executablePath)
        process.arguments = root.map { ["-C", $0] + arguments } ?? arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func localContainerRef(root: String) -> String? {
        let dependencyRoot = URL(fileURLWithPath: root)
            .deletingLastPathComponent()
            .appendingPathComponent("container")
            .path
        return git(["rev-parse", "HEAD"], root: dependencyRoot)
    }

    static func packageResolvedValue(root: String, key: String) -> String? {
        packageResolvedPin(root: root)?[key] as? String
    }

    static func packageResolvedState(root: String) -> String? {
        guard let state = packageResolvedPin(root: root)?["state"] as? [String: Any] else {
            return nil
        }
        return (state["revision"] ?? state["branch"] ?? state["version"]) as? String
    }

    static func packageResolvedPin(root: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: "\(root)/Package.resolved"),
              let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = rootObject["pins"] as? [[String: Any]] else {
            return nil
        }
        return pins.first { $0["identity"] as? String == "containerization" }
    }

    static func goModuleVersion(root: String, module: String) -> String? {
        guard let text = try? String(contentsOfFile: "\(root)/Tools/compose-normalizer/go.mod", encoding: .utf8) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split { $0 == " " || $0 == "\t" }
            if fields.count >= 3 && String(fields[0]) == "require" && String(fields[1]) == module {
                return String(fields[2])
            }
            if fields.count >= 2 && String(fields[0]) == module {
                return String(fields[1])
            }
        }
        return nil
    }
}

/// Root command for the `container compose` plugin.
struct ComposePlugin: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions

    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Manage multi-container applications with Docker Compose syntax",
        version: composePluginVersionString,
        subcommands: [
            Bridge.self,
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
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ComposeCLIHelp.renderIfRequested(arguments: arguments) {
            return
        }
        if ComposeCLIHelp.renderRootIfNoCommand(arguments: arguments) {
            return
        }
        let rewritten = ComposeArgumentRewriter.rewrite(arguments)
        if let failure = ContainerPackageCompatibility.compatibilityFailure(
            arguments: rewritten,
            lane: composeBuildInfo.lane,
            expectedContainerRef: composeBuildInfo.containerRef,
            expectedContainerizationRef: composeBuildInfo.containerizationRef
        ) {
            FileHandle.standardError.write(Data((failure + "\n").utf8))
            exit(1)
        }
        await ComposePlugin.main(rewritten)
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

    @Flag(name: .customLong("all-resources"), help: "Include all resources, even those not used by services.")
    var allResources: Bool = false

    @Flag(name: .customLong("compatibility"), help: "Run compose in backward compatibility mode.")
    var compatibility: Bool = false

    @Option(name: .customLong("parallel"), help: "Control max parallel image operations.")
    var parallel: Int?

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
        try await loadProject(options: composeOptions())
    }

    /// Loads a Compose project while reporting normalizer progress.
    func loadProject(options: ComposeOptions) async throws -> ComposeProject {
        try await loadProject(
            options: options,
            progress: progressReporter(),
            normalize: { try await ComposeNormalizer().normalize(options: $0) }
        )
    }

    /// Loads a Compose project through an injectable normalizer operation.
    func loadProject(
        options: ComposeOptions,
        progress: ComposeProgressReporter,
        normalize: (ComposeOptions) async throws -> ComposeProject
    ) async throws -> ComposeProject {
        try await progress.activity("Loading Compose model") {
            try await normalize(options)
        }
    }

    /// Loads Compose variables while reporting normalizer progress.
    func loadVariables(options: ComposeOptions) async throws -> [ComposeVariable] {
        try await loadVariables(
            options: options,
            progress: progressReporter(),
            variables: { try await ComposeNormalizer().variables(options: $0) }
        )
    }

    /// Loads Compose variables through an injectable normalizer operation.
    func loadVariables(
        options: ComposeOptions,
        progress: ComposeProgressReporter,
        variables: (ComposeOptions) async throws -> [ComposeVariable]
    ) async throws -> [ComposeVariable] {
        try await progress.activity("Loading Compose variables") {
            try await variables(options)
        }
    }

    /// Creates an orchestrator configured from global runtime flags.
    func orchestrator() -> ComposeOrchestrator {
        ComposeOrchestrator(options: ComposeExecutionOptions(dryRun: dryRun, maxParallelism: parallel, progress: progressReporter()))
    }

    /// Returns whether log prefix color should be enabled for this invocation.
    func shouldColorLogs(noColor: Bool) -> Bool {
        guard !noColor else {
            return false
        }
        switch ansi?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "always":
            return true
        case "never":
            return false
        default:
            return stdoutSupportsANSI()
        }
    }

    /// Returns whether the `up --menu` shortcut controller should own attached output.
    func shouldEnableUpMenu(menu: Bool, menuDisabled: Bool, attachedOutput: Bool) -> Bool {
        guard attachedOutput, !menuDisabled else {
            return false
        }
        let requested = shouldRequestUpMenu(menu: menu, menuDisabled: menuDisabled)
        guard requested else {
            return false
        }
        guard stdinIsTerminal(), stdoutIsTerminal() else {
            return false
        }
        return progressStyle() != .plain
    }

    /// Returns whether CLI flags or COMPOSE_MENU explicitly request the attached `up` menu.
    func shouldRequestUpMenu(menu: Bool, menuDisabled: Bool) -> Bool {
        guard !menuDisabled else {
            return false
        }
        return menu || composeMenuEnvironmentEnabled()
    }

    /// Creates the progress renderer selected by Docker Compose-compatible global flags.
    func progressReporter() -> ComposeProgressReporter {
        ComposeProgressReporter(
            style: progressStyle(),
            colorEnabled: shouldColorProgress(),
            emitData: { FileHandle.standardError.write($0) }
        )
    }

    /// Maps Docker Compose progress policy names onto local progress modes.
    func progressStyle() -> ComposeProgressStyle {
        switch progress?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "quiet", "none":
            return .quiet
        case "plain":
            return .plain
        case "json":
            return .json
        case "tty":
            return .tty
        case "auto", "", nil:
            return stderrSupportsANSI() ? .tty : .plain
        default:
            return stderrSupportsANSI() ? .tty : .plain
        }
    }

    /// Returns whether progress rows should include ANSI color.
    func shouldColorProgress() -> Bool {
        switch ansi?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "always":
            return true
        case "never":
            return false
        default:
            return stderrSupportsANSI()
        }
    }
}

/// Returns Docker Compose-compatible boolean parsing for environment flags.
private func composeBooleanValue(_ value: String?) -> Bool? {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "y", "on":
        return true
    case "0", "false", "no", "n", "off":
        return false
    default:
        return nil
    }
}

/// Returns whether COMPOSE_MENU requests the attached `up` shortcut menu.
private func composeMenuEnvironmentEnabled() -> Bool {
    composeBooleanValue(ProcessInfo.processInfo.environment["COMPOSE_MENU"]) ?? false
}

/// Returns whether stdin is an interactive terminal.
private func stdinIsTerminal() -> Bool {
#if canImport(Darwin) || canImport(Glibc)
    isatty(STDIN_FILENO) == 1
#else
    false
#endif
}

/// Returns whether stdout is an interactive terminal.
private func stdoutIsTerminal() -> Bool {
#if canImport(Darwin) || canImport(Glibc)
    isatty(STDOUT_FILENO) == 1
#else
    false
#endif
}

/// Returns whether stdout is an interactive terminal that can display ANSI color.
private func stdoutSupportsANSI() -> Bool {
#if canImport(Darwin) || canImport(Glibc)
    isatty(STDOUT_FILENO) == 1
#else
    false
#endif
}

/// Returns whether stderr is an interactive terminal that can display ANSI progress.
private func stderrSupportsANSI() -> Bool {
#if canImport(Darwin) || canImport(Glibc)
    isatty(STDERR_FILENO) == 1
#else
    false
#endif
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

    /// Prints the canonical normalized project JSON.
    func printCanonicalProject() async throws {
        let loadedProject = try await project()
        print(try orchestrator().config(project: loadedProject))
    }
}

/// Reports unsupported Docker Compose bridge management commands.
struct Bridge: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bridge", abstract: "Convert compose files into another model.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the transformation runtime gap.
    func run() throws {
        throw ComposeError.unsupported("bridge: Compose Bridge transformations are not available through apple/container")
    }
}

/// Implements `compose config`.
struct Config: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Validate and print the normalized Compose project.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("environment"), help: "Print environment used for interpolation.")
    var environment = false
    @Option(name: .customLong("format"), help: "Format the output. Values: yaml or json.")
    var format: String?
    @Option(name: .customLong("hash"), help: "Print the service config hash, one per line.")
    var hash: String?
    @Flag(name: .customLong("images"), help: "Print the image names, one per line.")
    var images = false
    @Flag(name: .customLong("lock-image-digests"), help: "Produce an override file with image digests.")
    var lockImageDigests = false
    @Flag(name: .customLong("models"), help: "Print the model names, one per line.")
    var models = false
    @Flag(name: .customLong("networks"), help: "Print the network names, one per line.")
    var networks = false
    @Flag(name: .customLong("no-consistency"), help: "Do not check model consistency.")
    var noConsistency = false
    @Flag(name: .customLong("no-env-resolution"), help: "Do not resolve service env files.")
    var noEnvResolution = false
    @Flag(name: .customLong("no-interpolate"), help: "Do not interpolate environment variables.")
    var noInterpolate = false
    @Flag(name: .customLong("no-normalize"), help: "Do not normalize compose model.")
    var noNormalize = false
    @Flag(name: .customLong("no-path-resolution"), help: "Do not resolve file paths.")
    var noPathResolution = false
    @Option(name: [.customShort("o"), .customLong("output")], help: "Save to file.")
    var output: String?
    @Flag(name: .customLong("profiles"), help: "Print the profile names, one per line.")
    var profiles = false
    @Flag(name: .shortAndLong, help: "Only validate the configuration.")
    var quiet = false
    @Flag(name: .customLong("resolve-image-digests"), help: "Pin image tags to digests.")
    var resolveImageDigests = false
    @Flag(name: .customLong("services"), help: "Print the service names, one per line.")
    var servicesOnly = false
    @Flag(name: .customLong("variables"), help: "Print model variables and default values.")
    var variables = false
    @Flag(name: .customLong("volumes"), help: "Print the volume names, one per line.")
    var volumes = false
    @Argument(help: "Optional service names.")
    var services: [String] = []

    /// Prints the canonical project JSON emitted by the orchestrator.
    func run() async throws {
        var composeOptions = global.composeOptions()
        composeOptions.noConsistency = noConsistency
        composeOptions.noEnvResolution = noEnvResolution
        composeOptions.noInterpolate = noInterpolate
        composeOptions.noNormalize = noNormalize
        composeOptions.noPathResolution = noPathResolution

        if variables {
            let loadedVariables = try await global.loadVariables(options: composeOptions)
            let rendered = orchestrator().config(variables: loadedVariables)
            if let output {
                try rendered.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
                return
            }
            if !rendered.isEmpty {
                print(rendered)
            }
            return
        }

        let loadedProject = try await global.loadProject(options: composeOptions)
        let configOptions = ComposeConfigOptions {
            $0.services = services
            $0.environment = environment
            $0.format = format
            $0.hash = hash
            $0.images = images
            $0.lockImageDigests = lockImageDigests
            $0.models = models
            $0.networks = networks
            $0.profiles = profiles
            $0.quiet = quiet
            $0.resolveImageDigests = resolveImageDigests
            $0.servicesOnly = servicesOnly
            $0.volumes = volumes
        }
        let rendered: String
        if lockImageDigests || resolveImageDigests {
            rendered = try await orchestrator().config(project: loadedProject, resolvingImageDigests: configOptions)
        } else {
            rendered = try orchestrator().config(project: loadedProject, options: configOptions)
        }
        if let output {
            try rendered.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
            return
        }
        if !rendered.isEmpty {
            print(rendered)
        }
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
    @Flag(name: .customLong("quiet-pull"), help: "Pull without printing progress output.")
    var quietPull = false
    @Flag(name: .customLong("remove-orphans"), help: "Remove project containers for services not declared by the Compose file.")
    var removeOrphans = false
    @Option(name: .customLong("scale"), help: "Scale SERVICE to NUM. May be repeated.")
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
                $0.quietPull = quietPull
                $0.assumeYes = yes
            }
        )
    }
}

/// Implements `compose up`.
struct Up: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "up", abstract: "Create and start services.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("abort-on-container-exit"), help: "Stop all containers if any container stops.")
    var abortOnContainerExit = false
    @Flag(name: .customLong("abort-on-container-failure"), help: "Stop all containers if any container exits with failure.")
    var abortOnContainerFailure = false
    @Option(name: .customLong("attach"), help: "Restrict attaching to the specified service. May be repeated.")
    var attach: [String] = []
    @Flag(name: .customLong("attach-dependencies"), help: "Attach to dependent service logs.")
    var attachDependencies = false
    @Flag(name: .shortAndLong, help: "Build images before starting services.")
    var build = false
    @Flag(name: .customLong("quiet-build"), help: "Suppress build output.")
    var quietBuild = false
    @Flag(name: .customLong("no-build"), help: "Do not build images before starting services.")
    var noBuild = false
    @Flag(name: .shortAndLong, help: "Run containers in the background.")
    var detach = false
    @Option(name: .customLong("exit-code-from"), help: "Return the exit code of the selected service container.")
    var exitCodeFrom: String?
    @Flag(name: .customLong("force-recreate"), help: "Recreate containers even if they already exist.")
    var forceRecreate = false
    @Flag(name: .customLong("menu"), help: "Enable interactive shortcuts when running attached. Use --menu=false to disable.")
    var menu = false
    @Flag(name: .customLong("menu-disabled"), help: .hidden)
    var menuDisabled = false
    @Flag(name: .customLong("always-recreate-deps"), help: "Recreate dependent containers.")
    var alwaysRecreateDeps = false
    @Option(name: .customLong("no-attach"), help: "Do not attach to the specified service. May be repeated.")
    var noAttach: [String] = []
    @Flag(name: .customLong("no-recreate"), help: "Reuse existing containers.")
    var noRecreate = false
    @Flag(name: .customLong("no-color"), help: "Produce monochrome output.")
    var noColor = false
    @Flag(name: .customLong("remove-orphans"), help: "Remove project containers for services not declared by the Compose file.")
    var removeOrphans = false
    @Flag(name: .customLong("no-log-prefix"), help: "Do not print service prefixes.")
    var noLogPrefix = false
    @Option(name: .customLong("pull"), help: "Image pull policy: always, missing, if_not_present, or never.")
    var pull: String?
    @Flag(name: .customLong("quiet-pull"), help: "Pull without printing progress output.")
    var quietPull = false
    @Option(name: .customLong("scale"), help: "Scale SERVICE to NUM. May be repeated.")
    var scales: [String] = []
    @Flag(name: .customLong("no-deps"), help: "Do not start linked services.")
    var noDeps = false
    @Flag(name: .customLong("no-start"), help: "Create services without starting them.")
    var noStart = false
    @Flag(name: [.customShort("V"), .customLong("renew-anon-volumes")], help: "Recreate anonymous volumes.")
    var renewAnonVolumes = false
    @Option(name: [.customShort("t"), .customLong("timeout")], help: "Seconds to wait before killing containers during recreate shutdown.")
    var timeout: Int?
    @Flag(name: .customLong("timestamps"), help: "Show timestamps.")
    var timestamps = false
    @Flag(name: .customLong("wait"), help: "Wait for services to be running or healthy.")
    var wait = false
    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to wait for services.")
    var waitTimeout: Int?
    @Flag(name: [.customShort("w"), .customLong("watch")], help: "Watch source code and rebuild or refresh containers.")
    var watch = false
    @Flag(name: [.customShort("y"), .customLong("yes")], help: "Assume yes as answer to prompts.")
    var yes = false
    @Argument(help: "Optional service names to start.")
    var services: [String] = []

    /// Creates resources and starts selected services.
    func run() async throws {
        let formatsAttachedOutput = !(detach || wait || noStart)
        if watch && detach {
            throw ComposeError.unsupported("up --detach cannot be combined with --watch")
        }
        if watch && wait {
            throw ComposeError.unsupported("up --wait cannot be combined with --watch")
        }
        if watch && (abortOnContainerExit || abortOnContainerFailure || exitCodeFrom != nil) {
            throw ComposeError.unsupported("up --watch cannot be combined with exit-control options")
        }
        let menuRequested = global.shouldRequestUpMenu(menu: menu, menuDisabled: menuDisabled)

        let loadedProject = try await project()
        let menuEnabled = global.shouldEnableUpMenu(
            menu: menu,
            menuDisabled: menuDisabled,
            attachedOutput: formatsAttachedOutput,
        )
        let dryRunMenuWatch = global.dryRun && watch && menuRequested
        let interactiveMenuWatch = watch && menuEnabled
        let upOptions = ComposeUpOptions {
            $0.services = services
            $0.abortOnContainerExit = abortOnContainerExit
            $0.abortOnContainerFailure = abortOnContainerFailure
            $0.attach = attach
            $0.attachDependencies = attachDependencies
            $0.exitCodeFrom = exitCodeFrom
            $0.noAttach = noAttach
            $0.build = build
            $0.quietBuild = quietBuild
            $0.noBuild = noBuild
            $0.detach = detach
            $0.forceRecreate = forceRecreate
            $0.alwaysRecreateDeps = alwaysRecreateDeps
            $0.noRecreate = noRecreate
            $0.removeOrphans = removeOrphans
            $0.pullPolicy = pull
            $0.quietPull = quietPull
            $0.scales = scales
            $0.noDeps = noDeps
            $0.noStart = noStart
            $0.timeout = timeout
            $0.wait = wait
            $0.waitTimeout = waitTimeout
            $0.renewAnonymousVolumes = renewAnonVolumes
            $0.assumeYes = yes
            $0.timestamps = timestamps && formatsAttachedOutput
            $0.noLogPrefix = noLogPrefix
            $0.colorPrefixes = global.shouldColorLogs(noColor: noColor)
            $0.menu = menuEnabled || dryRunMenuWatch
            $0.menuWatch = interactiveMenuWatch
        }
        if watch && !interactiveMenuWatch && !dryRunMenuWatch {
            try await orchestrator().watch(
                project: loadedProject,
                options: ComposeWatchOptions(
                    services: services,
                    noUp: false,
                    prune: true,
                    quiet: quietBuild,
                    initialUpOptions: upOptions
                )
            )
            return
        }
        if let exitCode = try await orchestrator().up(project: loadedProject, options: upOptions), exitCode != 0 {
            throw ExitCode(exitCode)
        }
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
    @Argument(help: "Optional service names to stop and remove.")
    var services: [String] = []

    /// Stops containers and removes project-scoped resources.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().down(
            project: loadedProject,
            options: ComposeDownOptions(services: services, volumes: volumes, removeOrphans: removeOrphans, timeout: timeout, rmi: rmi)
        )
    }
}

/// Implements `compose build`.
struct Build: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build service images.")

    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("build-arg"), help: "Set build-time variables for services. May be repeated.")
    var buildArgs: [String] = []
    @Option(name: .customLong("builder"), help: "Set builder to use.")
    var builder: String?
    @Flag(name: .customLong("check"), help: "Check build configuration.")
    var check = false
    @Option(name: [.customShort("m"), .customLong("memory")], help: "Set memory limit for the build container.")
    var memory: String?
    @Flag(name: .customLong("no-cache"), help: "Do not use cached image layers.")
    var noCache = false
    @Flag(name: .customLong("print"), help: "Print equivalent bake file.")
    var printBake = false
    @Option(name: .customLong("provenance"), help: "Add a provenance attestation.")
    var provenance: String?
    @Flag(name: .customLong("pull"), help: "Always attempt to pull newer base images.")
    var pull = false
    @Flag(name: .customLong("push"), help: "Push service images after building.")
    var push = false
    @Flag(name: .shortAndLong, help: "Suppress build output.")
    var quiet = false
    @Option(name: .customLong("sbom"), help: "Add a SBOM attestation.")
    var sbom: String?
    @Option(name: .customLong("ssh"), help: "Set SSH authentications used when building service images. May be repeated.")
    var ssh: [String] = []
    @Flag(name: .customLong("with-dependencies"), help: "Also build service dependencies.")
    var withDependencies = false
    @Argument(help: "Optional services to build.")
    var services: [String] = []

    /// Builds selected service images.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().build(
            project: loadedProject,
            options: ComposeBuildOptions {
                $0.services = services
                $0.buildArguments = buildArgs
                $0.builder = builder
                $0.check = check
                $0.memory = memory
                $0.noCache = noCache
                $0.printBake = printBake
                $0.pull = pull
                $0.push = push
                $0.quiet = quiet
                $0.provenance = provenance
                $0.sbom = sbom
                $0.ssh = ssh
                $0.withDependencies = withDependencies
            }
        )
    }
}

/// Implements `compose pull`.
struct Pull: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Pull service images.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("ignore-buildable"), help: "Ignore services that can be built locally.")
    var ignoreBuildable = false
    @Flag(name: .customLong("ignore-pull-failures"), help: "Pull what can be pulled and ignore image pull failures.")
    var ignorePullFailures = false
    @Flag(name: .customLong("include-deps"), help: "Also pull images for service dependencies.")
    var includeDeps = false
    @Option(name: .customLong("policy"), help: "Image pull policy: missing or always.")
    var policy: String?
    @Flag(name: .shortAndLong, help: "Pull without printing progress output.")
    var quiet = false
    @Argument(help: "Optional services to pull.")
    var services: [String] = []

    /// Pulls selected service images.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().pull(
            project: loadedProject,
            options: ComposePullOptions {
                $0.services = services
                $0.ignoreBuildable = ignoreBuildable
                $0.ignorePullFailures = ignorePullFailures
                $0.includeDependencies = includeDeps
                $0.policy = policy
                $0.quiet = quiet
            }
        )
    }
}

/// Implements `compose push`.
struct Push: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Push service images.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("ignore-push-failures"), help: "Push what can be pushed and ignore image push failures.")
    var ignorePushFailures = false
    @Flag(name: .customLong("include-deps"), help: "Also push images for service dependencies.")
    var includeDeps = false
    @Flag(name: .shortAndLong, help: "Push without printing progress output.")
    var quiet = false
    @Argument(help: "Optional services to push.")
    var services: [String] = []

    /// Pushes selected service images.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().push(
            project: loadedProject,
            options: ComposePushOptions {
                $0.services = services
                $0.ignorePushFailures = ignorePushFailures
                $0.includeDependencies = includeDeps
                $0.quiet = quiet
            }
        )
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
    @Option(name: .customLong("format"), help: "Output format: table, json, or a custom template.")
    var format = "table"
    @Flag(name: .customLong("no-trunc"), help: "Do not truncate output.")
    var noTrunc = false
    @Flag(
        name: .customLong("orphans"),
        inversion: .prefixedNo,
        help: "Include orphaned services. Enabled by default for Compose compatibility."
    )
    var orphans = true
    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Only display container IDs.")
    var quiet = false
    @Flag(name: .customLong("services"), help: "Only display service names.")
    var services = false
    @Option(name: .customLong("status"), help: "Filter services by container status.")
    var statuses: [String] = []
    @Option(name: .customLong("filter"), help: "Filter services by a property. Supported filter: status.")
    var filters: [String] = []
    @Argument(help: "Optional service names to list.")
    var serviceNames: [String] = []

    /// Lists project containers, optionally including stopped containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().ps(
            project: loadedProject,
            options: ComposePsOptions {
                $0.all = all
                $0.quiet = quiet
                $0.services = services
                $0.selectedServices = serviceNames
                $0.statuses = statuses
                $0.filters = filters
                $0.format = format
                $0.noTrunc = noTrunc
                $0.orphans = orphans
            }
        )
    }
}

/// Implements `compose logs`.
struct Logs: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Show service logs.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("follow"), help: "Follow log output. Docker Compose shorthand -f is accepted after logs.")
    var follow = false
    @Option(name: [.customShort("n"), .customLong("tail")], help: "Number of lines to show from the end of logs, or all.")
    var tail: String?
    @Option(name: .customLong("since"), help: "Show logs after an RFC 3339 timestamp, UNIX timestamp, or relative duration.")
    var since: String?
    @Option(name: .customLong("until"), help: "Show logs before an RFC 3339 timestamp, UNIX timestamp, or relative duration.")
    var until: String?
    @Flag(name: [.customShort("t"), .customLong("timestamps")], help: "Show runtime capture timestamps.")
    var timestamps = false
    @Option(name: .customLong("index"), help: "Target one service container index instead of all matching replicas.")
    var index: Int?
    @Flag(name: .customLong("no-color"), help: "Produce monochrome log output.")
    var noColor = false
    @Flag(name: .customLong("no-log-prefix"), help: "Do not print service prefixes.")
    var noLogPrefix = false
    @Argument(help: "Optional services to show.")
    var services: [String] = []

    /// Streams or prints logs for selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().logs(
            project: loadedProject,
            services: services,
            options: ComposeLogsOptions {
                $0.follow = follow
                $0.tail = tail
                $0.index = index
                $0.since = since
                $0.until = until
                $0.timestamps = timestamps
                $0.noLogPrefix = noLogPrefix
                $0.colorPrefixes = global.shouldColorLogs(noColor: noColor)
            }
        )
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
    @Flag(name: .shortAndLong, help: "Run the command in the background.")
    var detach = false
    @Option(name: [.customShort("e"), .customLong("env")], help: "Set an environment variable for the exec process. May be repeated.")
    var environment: [String] = []
    @Option(name: .customLong("index"), help: "Target service container index.")
    var index = 1
    @Flag(name: .customLong("privileged"), help: "Give extended privileges to the process.")
    var privileged = false
    @Option(name: [.customShort("u"), .customLong("user")], help: "Run the command as this user.")
    var user: String?
    @Option(name: [.customShort("w"), .customLong("workdir")], help: "Path to the working directory inside the container.")
    var workdir: String?
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
            options: ComposeExecOptions {
                $0.command = command
                $0.interactive = interactive
                $0.tty = tty && !noTty
                $0.detach = detach
                $0.environment = environment
                $0.index = index
                $0.privileged = privileged
                $0.user = user
                $0.workingDirectory = workdir
            }
        )
    }
}

/// Implements `compose run`.
struct Run: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run a one-off command for a service.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("build"), help: "Build image before starting container.")
    var build = false
    @Flag(name: .customLong("rm"), help: "Remove the one-off container after exit.")
    var remove = false
    @Flag(name: .shortAndLong, help: "Run the one-off container in the background.")
    var detach = false
    @Flag(name: .shortAndLong, help: "Keep stdin open.")
    var interactive = false
    @Flag(name: [.customShort("T"), .customLong("no-TTY"), .customLong("no-tty")], help: "Disable pseudo-TTY allocation.")
    var noTty = false
    @Flag(name: .customLong("no-deps"), help: "Do not start linked services.")
    var noDeps = false
    @Flag(name: [.customShort("P"), .customLong("service-ports")], help: "Publish all ports declared by the service.")
    var servicePorts = false
    @Option(name: .customLong("publish"), help: "Publish a container port to the host. May be repeated. Docker Compose shorthand -p is accepted after run.")
    var publish: [String] = []
    @Option(name: .customLong("pull"), help: "Image pull policy before running: always, missing, if_not_present, or never.")
    var pull: String?
    @Flag(name: .shortAndLong, help: "Do not print anything to stdout.")
    var quiet = false
    @Flag(name: .customLong("quiet-build"), help: "Suppress build progress output.")
    var quietBuild = false
    @Flag(name: .customLong("quiet-pull"), help: "Pull without printing progress output.")
    var quietPull = false
    @Flag(name: .customLong("remove-orphans"), help: "Remove containers for services not defined in the Compose file.")
    var removeOrphans = false
    @Flag(name: .customLong("use-aliases"), help: "Use the service's network aliases.")
    var useAliases = false
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
    @Option(name: .customLong("cap-add"), help: "Add a Linux capability to the one-off container. May be repeated.")
    var capAdd: [String] = []
    @Option(name: .customLong("cap-drop"), help: "Drop a Linux capability from the one-off container. May be repeated.")
    var capDrop: [String] = []
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
                $0.build = build
                $0.remove = remove
                $0.detach = detach
                $0.interactive = interactive
                $0.noTty = noTty
                $0.noDeps = noDeps
                $0.servicePorts = servicePorts
                $0.publish = publish
                $0.pullPolicy = pull
                $0.quietBuild = quietBuild
                $0.quietPull = quietPull
                $0.quiet = quiet
                $0.removeOrphans = removeOrphans
                $0.containerName = name
                $0.entrypoint = entrypoint
                $0.workingDirectory = workdir
                $0.user = user
                $0.environment = environment
                $0.envFiles = envFiles
                $0.labels = labels
                $0.volumes = volumes
                $0.capAdd = capAdd
                $0.capDrop = capDrop
                $0.useAliases = useAliases
            }
        )
    }
}

/// Implements `compose start`.
struct Start: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start existing service containers.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("wait"), help: "Wait for services to be running or healthy.")
    var wait = false
    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to wait for services.")
    var waitTimeout: Int?
    @Argument var services: [String] = []
    /// Starts selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().start(
            project: loadedProject,
            options: ComposeStartOptions {
                $0.services = services
                $0.wait = wait
                $0.waitTimeout = waitTimeout
            }
        )
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
    @Flag(name: .customLong("no-deps"), help: "Do not restart dependent services.")
    var noDeps = false
    @Option(name: [.customShort("t"), .customLong("timeout")], help: "Seconds to wait before killing containers.")
    var timeout: Int?
    @Argument var services: [String] = []
    /// Restarts selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().restart(
            project: loadedProject,
            options: ComposeRestartOptions {
                $0.services = services
                $0.noDeps = noDeps
                $0.timeout = timeout
            }
        )
    }
}

/// Implements `compose rm`.
struct Rm: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove service containers.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("force"), help: "Don't ask to confirm removal and force container deletion. Docker Compose shorthand -f is accepted after rm.")
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
    @Flag(name: [.customShort("a"), .customLong("all")], help: "Show all service containers.")
    var all = false
    @Option(name: .customLong("format"), help: "Output format: table, json, or a custom template.")
    var format = "table"
    @Flag(name: .customLong("no-stream"), help: "Disable streaming stats and only pull the first result.")
    var noStream = false
    @Flag(name: .customLong("no-trunc"), help: "Do not truncate output.")
    var noTrunc = false
    @Argument(help: "Optional service names.")
    var services: [String] = []

    /// Displays resource usage statistics for the project or selected services.
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
    @Flag(name: .customLong("remove-orphans"), help: "Remove containers for services not defined in the Compose file.")
    var removeOrphans = false
    @Option(name: .shortAndLong, help: "Signal to send.")
    var signal: String?
    @Argument var services: [String] = []
    /// Sends the requested signal to selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().kill(project: loadedProject, services: services, signal: signal, removeOrphans: removeOrphans)
    }
}

/// Implements `compose cp`.
struct Cp: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "cp", abstract: "Copy files between service containers and local paths.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("all"), help: "Include containers created by the run command.")
    var all = false
    @Flag(name: [.customShort("a"), .customLong("archive")], help: "Archive mode. Preserve source UID/GID information.")
    var archive = false
    @Flag(name: [.customShort("L"), .customLong("follow-link")], help: "Always follow symbolic links in the source path.")
    var followLink = false
    @Option(name: .customLong("index"), help: "Target service container index.")
    var index = 1
    @Argument(parsing: .allUnrecognized) var arguments: [String]
    /// Resolves Compose service references before delegating to the runtime.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().copy(
            project: loadedProject,
            options: ComposeCopyOptions {
                $0.arguments = arguments
                $0.all = all
                $0.archive = archive
                $0.followLink = followLink
                $0.index = index
            }
        )
    }
}

/// Implements `compose top`.
struct Top: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "top", abstract: "Display running processes.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Optional service names.")
    var services: [String] = []
    /// Displays process identifiers for selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().top(project: loadedProject, options: ComposeTopOptions(services: services))
    }
}

/// Implements `compose events`.
struct Events: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "events", abstract: "Stream project events.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("json"), help: "Output events as a stream of JSON objects.")
    var json = false
    @Option(name: .customLong("since"), help: "Show events after the specified RFC 3339 timestamp, UNIX timestamp, or relative duration.")
    var since: String?
    @Option(name: .customLong("until"), help: "Stream events until the specified RFC 3339 timestamp, UNIX timestamp, or relative duration.")
    var until: String?
    @Argument(help: "Optional service names.")
    var services: [String] = []
    /// Streams Docker Compose-style project container events.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().events(
            project: loadedProject,
            options: ComposeEventsOptions(
                services: services,
                json: json,
                since: since,
                until: until
            )
        )
    }
}

/// Implements `compose port` for static Compose port bindings.
struct Port: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "port", abstract: "Print public port bindings.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("protocol"), help: "Port protocol: tcp or udp.")
    var portProtocol = "tcp"
    @Option(name: .customLong("index"), help: "Target service container index.")
    var index = 1
    @Argument(help: "Service name.")
    var service: String
    @Argument(help: "Private container port.")
    var privatePort: String
    /// Prints the host address and published port for a service binding.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().port(
            project: loadedProject,
            serviceName: service,
            privatePort: privatePort,
            protocolName: portProtocol,
            index: index
        )
    }
}

/// Validates `compose watch` service selections and develop.watch metadata.
struct Watch: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "Watch build context and service files.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("no-up"), help: "Do not build and start services before watching.")
    var noUp = false
    @Flag(name: .customLong("prune"), inversion: .prefixedNo, help: "Prune dangling images after rebuilds.")
    var prune = true
    @Flag(name: .customLong("quiet"), help: "Hide build output.")
    var quiet = false
    @Argument(help: "Optional service names.")
    var services: [String] = []
    /// Runs the validated watch plan through the orchestrator.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().watch(
            project: loadedProject,
            options: ComposeWatchOptions(
                services: services,
                noUp: noUp,
                prune: prune,
                quiet: quiet
            )
        )
    }
}

/// Implements `compose scale`.
struct Scale: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "scale", abstract: "Scale services.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("no-deps"), help: "Do not start linked services.")
    var noDeps = false
    @Argument(help: "Service scale assignments as SERVICE=REPLICAS.")
    var scales: [String] = []
    /// Scales selected services using Compose-compatible replica assignments.
    func run() async throws {
        guard !scales.isEmpty else {
            throw ComposeError.invalidProject("scale requires at least one SERVICE=REPLICAS argument")
        }
        let loadedProject = try await project()
        try await orchestrator().scale(
            project: loadedProject,
            options: ComposeScaleOptions {
                $0.scales = scales
                $0.noDeps = noDeps
            }
        )
    }
}

/// Implements output-only `compose attach` through the runtime log stream.
struct Attach: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "attach", abstract: "Attach to a service container.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("no-stdin"), help: "Do not attach stdin. Required for the supported output-only log attach path.")
    var noStdin = false
    @Option(name: .customLong("detach-keys"), help: "Override detach key sequence. Ignored with --no-stdin output-only attach.")
    var detachKeys: String?
    @Option(name: .customLong("index"), help: "Target service container index.")
    var index = 1
    @Option(name: .customLong("sig-proxy"), help: "Proxy signals to the service process for output-only attach.")
    var sigProxy = "true"
    @Argument(help: "Service name.")
    var service: String
    /// Streams the selected service container output.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().attach(
            project: loadedProject,
            serviceName: service,
            options: ComposeAttachOptions {
                $0.noStdin = noStdin
                $0.detachKeys = detachKeys
                $0.index = index
                $0.sigProxy = sigProxy
            }
        )
    }
}

/// Reports `compose commit` as unsupported until apple/container can commit containers to images.
struct Commit: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "commit", abstract: "Create an image from a service container.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the runtime gap for committing service containers.
    func run() throws {
        throw ComposeError.unsupported("commit: apple/container does not expose committing service containers to images")
    }
}

/// Implements `compose export`.
struct Export: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export a service container filesystem.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("index"), help: "Target service container index.")
    var index = 1
    @Option(name: .shortAndLong, help: "Write the archive to a file instead of stdout.")
    var output: String?
    @Argument(help: "Service name.")
    var service: String
    /// Exports the selected service container filesystem as a tar archive.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().export(
            project: loadedProject,
            serviceName: service,
            options: ComposeExportOptions(output: output, index: index)
        )
    }
}

/// Reports `compose publish` as unsupported until Compose application artifacts are available.
struct Publish: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "publish", abstract: "Publish the Compose application.")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    /// Reports the runtime gap for Compose application publishing.
    func run() throws {
        throw ComposeError.unsupported("publish: Compose application OCI artifacts are not available through apple/container")
    }
}

/// Implements `compose volumes`.
struct Volumes: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "volumes", abstract: "List Compose volumes.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("format"), help: "Output format: table, json, or a custom template.")
    var format = "table"
    @Flag(name: .shortAndLong, help: "Only display volume names.")
    var quiet = false
    @Argument(help: "Optional service names.")
    var services: [String] = []
    /// Lists existing project-scoped volumes through the resource API.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().volumes(
            project: loadedProject,
            options: ComposeVolumesOptions(services: services, quiet: quiet, format: format)
        )
    }
}

/// Implements `compose pause`.
struct Pause: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause service containers.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Service names.")
    var services: [String] = []
    /// Pauses selected service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().pause(project: loadedProject, services: services)
    }
}

/// Implements `compose unpause`.
struct Unpause: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "unpause", abstract: "Unpause service containers.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Service names.")
    var services: [String] = []
    /// Resumes selected paused service containers.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().unpause(project: loadedProject, services: services)
    }
}

/// Implements `compose wait` for running service containers.
struct Wait: AsyncParsableCommand, ComposeProjectCommand {
    static let configuration = CommandConfiguration(commandName: "wait", abstract: "Wait for service containers to exit.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("down-project"), help: "Drop the project when the first selected service container stops.")
    var downProject = false
    @Argument(help: "Service names.")
    var services: [String] = []
    /// Waits for selected service containers and prints exit codes.
    func run() async throws {
        let loadedProject = try await project()
        try await orchestrator().wait(project: loadedProject, options: ComposeWaitOptions(services: services, downProject: downProject))
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

        switch format {
        case "pretty":
            print(composePluginVersionString)
            print("  source: \(composeBuildInfo.source)")
            print("  lane: \(composeBuildInfo.lane)")
            print("  branch: \(composeBuildInfo.branch)")
            print("  commit: \(composeBuildInfo.commit)")
            print("  build: \(composeBuildInfo.buildType)")
            print("  container: \(composeBuildInfo.containerSource)@\(composeBuildInfo.containerRef) (\(composeBuildInfo.containerDistribution))")
            print("  containerization: \(composeBuildInfo.containerizationSource)@\(composeBuildInfo.containerizationRef) (\(composeBuildInfo.containerizationDistribution))")
            print("  compose-go: \(composeBuildInfo.composeGoVersion ?? "unspecified")")
        case "json":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ComposeVersionOutput(composeBuildInfo))
            print(String(decoding: data, as: UTF8.self))
        default:
            throw ComposeError.unsupported("version --format '\(format)'; supported formats are pretty and json")
        }
    }
}

/// Global options accepted after `compose version`.
struct VersionGlobalOptions: ParsableArguments {
    @Flag(name: .customLong("all-resources"), help: "Accepted for Docker Compose compatibility.")
    var allResources = false
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
    @Flag(name: .customLong("compatibility"), help: "Accepted for Docker Compose compatibility.")
    var compatibility = false
    @Option(name: .customLong("parallel"), help: "Accepted for Docker Compose compatibility.")
    var parallel: Int?
    @Flag(name: .customLong("dry-run"), help: "Accepted for Docker Compose compatibility.")
    var dryRun = false
    @Flag(name: .customLong("verbose"), help: "Accepted for Docker Compose compatibility.")
    var verbose = false
}
