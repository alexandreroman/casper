import ArgumentParser
import CasperAgents
import Foundation

/// `casper hooks setup` — install Casper's Claude Code hooks GLOBALLY into the
/// user-level `~/.claude/settings.json`, ONCE. A user may run it manually; Plan
/// 5 also runs it at app startup. Idempotent: the hooks are merged into any
/// existing file, preserving the user's global permissions and custom hooks (a
/// malformed existing file aborts without data loss). Not meant to run per
/// worktree — a global user-level hook applies to every project, and
/// `casper hooks feed` no-ops when the Casper environment is absent.
public struct HooksSetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install Casper's Claude Code hooks globally (user-level).")

    @Option(name: .long, help: "Override the settings file path (defaults to ~/.claude/settings.json).")
    public var settings: String?

    public init() {}

    public func run() throws {
        let url = settings.map { URL(fileURLWithPath: $0) } ?? ClaudeCodeAdapter.userSettingsURL()
        do {
            try ClaudeCodeAdapter.install(intoUserSettingsAt: url)
        } catch {
            throw exitWithError(error.localizedDescription)
        }
        print("Installed Casper hooks into \(url.path)")
    }
}
