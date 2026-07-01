import Foundation

/// Generates the Claude Code integration for a worktree: the hooks
/// `settings.local.json` and the surface environment. Confines all Claude
/// Code-specific knowledge to one place (v1 supports Claude Code only).
public enum ClaudeCodeAdapter {
    /// The `settings.local.json` body wiring Claude Code hooks to `hookCommand`.
    /// One command serves every event; Claude Code sends the hook JSON (with
    /// `hook_event_name`) on stdin. `PostToolUse` is filtered to `TodoWrite`.
    public static func settingsJSON(hookCommand: String = "casper hook") throws -> Data {
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
}
