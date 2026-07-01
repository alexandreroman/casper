import ArgumentParser
import CasperAgents
import Foundation

/// `casper hooks setup [<worktree>]` — write Casper's Claude Code hooks into a
/// worktree's `.claude/settings.local.json`, ONCE. Casper runs this when a
/// workspace is created; a user may also run it manually. Idempotent
/// (overwrites the file); not meant to run on every terminal open — per-surface
/// environment injection handles runtime identity separately.
public struct HooksSetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install Casper's Claude Code hooks into a worktree.")

    @Argument(help: "Worktree directory (defaults to the current directory).")
    public var worktree: String?

    public init() {}

    public func run() throws {
        let path = worktree ?? FileManager.default.currentDirectoryPath
        try ClaudeCodeAdapter.install(intoWorktreeAt: path)
        print("Installed Casper hooks into "
            + ClaudeCodeAdapter.settingsPath(inWorktreeAt: path))
    }
}
