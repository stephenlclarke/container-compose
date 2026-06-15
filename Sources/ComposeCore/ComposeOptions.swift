import Foundation

public struct ComposeOptions: Equatable {
    public var files: [String]
    public var projectName: String?
    public var profiles: [String]
    public var envFiles: [String]
    public var projectDirectory: String?
    public var ansi: String?
    public var progress: String?
    public var dryRun: Bool
    public var verbose: Bool

    public init(
        files: [String] = [],
        projectName: String? = nil,
        profiles: [String] = [],
        envFiles: [String] = [],
        projectDirectory: String? = nil,
        ansi: String? = nil,
        progress: String? = nil,
        dryRun: Bool = false,
        verbose: Bool = false
    ) {
        self.files = files
        self.projectName = projectName
        self.profiles = profiles
        self.envFiles = envFiles
        self.projectDirectory = projectDirectory
        self.ansi = ansi
        self.progress = progress
        self.dryRun = dryRun
        self.verbose = verbose
    }
}
