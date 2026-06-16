import ComposeCore
import Testing

@Suite("Compose argument rewriter")
struct ComposeArgumentRewriterTests {
    @Test("moves root compose options after the subcommand")
    func movesRootComposeOptionsAfterSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "-f",
            "compose.yml",
            "--project-name",
            "demo",
            "--profile=dev",
            "--dry-run",
            "config",
        ])

        #expect(rewritten == [
            "config",
            "-f",
            "compose.yml",
            "--project-name",
            "demo",
            "--profile=dev",
            "--dry-run",
        ])
    }

    @Test("leaves subcommand options and arguments in place")
    func leavesSubcommandOptionsAndArgumentsInPlace() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--ansi",
            "never",
            "up",
            "--detach",
            "api",
        ])

        #expect(rewritten == [
            "up",
            "--ansi",
            "never",
            "--detach",
            "api",
        ])
    }

    @Test("keeps unknown root options before the subcommand")
    func keepsUnknownRootOptionsBeforeSubcommand() {
        let rewritten = ComposeArgumentRewriter.rewrite([
            "--not-a-compose-option",
            "--file",
            "compose.yml",
            "config",
        ])

        #expect(rewritten == [
            "--not-a-compose-option",
            "config",
            "--file",
            "compose.yml",
        ])
    }

    @Test("returns arguments unchanged when no subcommand is present")
    func returnsArgumentsUnchangedWhenNoSubcommandIsPresent() {
        let arguments = ["--help", "--verbose"]

        #expect(ComposeArgumentRewriter.rewrite(arguments) == arguments)
    }
}
