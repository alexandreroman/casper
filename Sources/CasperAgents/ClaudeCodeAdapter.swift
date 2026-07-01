import Foundation

/// Generates the Claude Code integration for a worktree: the hooks
/// `settings.local.json` and the surface environment. Confines all Claude
/// Code-specific knowledge to one place (v1 supports Claude Code only).
public enum ClaudeCodeAdapter {
    /// The `settings.local.json` body wiring Claude Code hooks to `hookCommand`.
    /// One command serves every event; Claude Code sends the hook JSON (with
    /// `hook_event_name`) on stdin. `PostToolUse` is filtered to `TodoWrite`.
    public static func settingsJSON(hookCommand: String = "casper hooks feed") throws -> Data {
        func entry(matcher: String?) -> [String: Any] {
            var e: [String: Any] = [
                "hooks": [["type": "command", "command": hookCommand]],
            ]
            if let matcher { e["matcher"] = matcher }
            return e
        }

        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": [entry(matcher: nil)],
                "Stop": [entry(matcher: nil)],
                "Notification": [entry(matcher: nil)],
                "PostToolUse": [entry(matcher: "TodoWrite")],
            ],
        ]

        return try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    /// Environment injected into every terminal surface of a workspace so that
    /// `casper hooks feed` can reach the app and the agent can bind its reserved
    /// ports. `CASPER_PORT` is the block base; `CASPER_PORT_0…9` expose the
    /// whole reserved block for convenience.
    public static func surfaceEnvironment(
        socketPath: String, workspaceId: UUID, portBase: Int, blockSize: Int = 10
    ) -> [String: String] {
        var env: [String: String] = [
            "CASPER_SOCKET": socketPath,
            "CASPER_WORKSPACE_ID": workspaceId.uuidString,
            "CASPER_PORT": String(portBase),
        ]
        for offset in 0..<blockSize {
            env["CASPER_PORT_\(offset)"] = String(portBase + offset)
        }
        return env
    }

    /// The path to the generated settings file inside a worktree.
    public static func settingsPath(inWorktreeAt worktreePath: String) -> String {
        URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".claude/settings.local.json").path
    }

    /// Write `.claude/settings.local.json` into the worktree, creating the
    /// `.claude` directory if needed. Uses the project-local (uncommitted)
    /// settings file so the user's repo is never polluted.
    public static func install(
        intoWorktreeAt worktreePath: String, hookCommand: String = "casper hooks feed"
    ) throws {
        let claudeDir = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeDir, withIntermediateDirectories: true)
        let data = try settingsJSON(hookCommand: hookCommand)
        try data.write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            options: .atomic)
    }
}
