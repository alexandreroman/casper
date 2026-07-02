import Foundation

/// Thrown when `install` finds an existing `settings.local.json` that is not a
/// JSON object. Casper refuses to overwrite it so the user's file is preserved.
public struct ClaudeCodeAdapterError: Error, LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }

    static func invalidExistingSettings(path: String) -> ClaudeCodeAdapterError {
        ClaudeCodeAdapterError(
            reason: "Casper refuses to overwrite \(path): the existing file is not "
                + "a valid JSON object. Fix or remove it, then re-run the setup.")
    }
}

/// Generates the Claude Code integration for a worktree: the hooks
/// `settings.local.json` and the surface environment. Confines all Claude
/// Code-specific knowledge to one place (v1 supports Claude Code only).
public enum ClaudeCodeAdapter {
    /// Casper's four canonical hook events, each mapping to Casper's entry for
    /// that event. `PostToolUse` is filtered to `TodoWrite`; the others fire on
    /// every occurrence. This is the single source of truth shared by
    /// `settingsJSON` (fresh file) and `install` (merge into an existing file).
    private static func casperHookEvents(hookCommand: String) -> [String: [[String: Any]]] {
        func entry(matcher: String?) -> [String: Any] {
            var e: [String: Any] = [
                "hooks": [["type": "command", "command": hookCommand]],
            ]
            if let matcher { e["matcher"] = matcher }
            return e
        }

        return [
            "SessionStart": [entry(matcher: nil)],
            "Stop": [entry(matcher: nil)],
            "Notification": [entry(matcher: nil)],
            "PostToolUse": [entry(matcher: "TodoWrite")],
        ]
    }

    /// The `settings.local.json` body wiring Claude Code hooks to `hookCommand`.
    /// One command serves every event; Claude Code sends the hook JSON (with
    /// `hook_event_name`) on stdin. `PostToolUse` is filtered to `TodoWrite`.
    /// This produces the body for a *fresh* file; `install` merges the same hook
    /// events into any pre-existing settings.
    public static func settingsJSON(hookCommand: String = "casper hooks feed") throws -> Data {
        let settings: [String: Any] = ["hooks": casperHookEvents(hookCommand: hookCommand)]
        return try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    /// Environment injected into every terminal surface of a workspace so that
    /// `casper hooks feed` can reach the app and the agent can bind its reserved
    /// ports. `CASPER_PORT` is the block base; `CASPER_PORT_0…9` expose the
    /// whole reserved block for convenience.
    ///
    /// When `casperDirectory` is given, it is prepended to `PATH` so the
    /// relative hook command `casper hooks feed` (written into
    /// `settings.local.json`) resolves only inside terminals Casper opens —
    /// the `casper` binary is deliberately not installed globally. Plan 5
    /// passes the app bundle's executable directory as `casperDirectory` and
    /// the terminal's inherited `PATH` as `basePath`. This function stays
    /// pure: it never reads `ProcessInfo` itself, only the values passed in.
    ///
    /// - Important: `blockSize` MUST equal the `PortAllocator` block size (fixed
    ///   at 10 by the spec). It controls how many `CASPER_PORT_0…(blockSize-1)`
    ///   variables are advertised; a larger value would spill past the
    ///   workspace's reserved block and collide with the neighboring
    ///   workspace's ports.
    public static func surfaceEnvironment(
        socketPath: String,
        workspaceId: UUID,
        portBase: Int,
        blockSize: Int = 10,
        casperDirectory: String? = nil,
        basePath: String? = nil
    ) -> [String: String] {
        var env: [String: String] = [
            "CASPER_SOCKET": socketPath,
            "CASPER_WORKSPACE_ID": workspaceId.uuidString,
            "CASPER_PORT": String(portBase),
        ]
        for offset in 0..<blockSize {
            env["CASPER_PORT_\(offset)"] = String(portBase + offset)
        }
        if let casperDirectory {
            if let basePath, !basePath.isEmpty {
                env["PATH"] = "\(casperDirectory):\(basePath)"
            } else {
                env["PATH"] = casperDirectory
            }
        }
        return env
    }

    /// The path to the generated settings file inside a worktree.
    public static func settingsPath(inWorktreeAt worktreePath: String) -> String {
        URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".claude/settings.local.json").path
    }

    /// Install Casper's Claude Code hooks into the worktree's project-local
    /// (uncommitted) `.claude/settings.local.json`, so the user's repo is never
    /// polluted. This is a read-merge-write, not a plain overwrite: that file is
    /// where Claude Code persists the user's approved permissions and any custom
    /// hooks, which must survive a re-install.
    ///
    /// - If the file is absent, write Casper's settings and create `.claude/`.
    /// - If it exists but is not a JSON object (malformed or non-object
    ///   top-level), throw `ClaudeCodeAdapterError` and write nothing, leaving
    ///   the user's file byte-for-byte intact.
    /// - Otherwise merge: every top-level key other than `hooks` is preserved,
    ///   as is every hook event other than Casper's four. For each Casper event,
    ///   prior Casper entries are dropped and the canonical entry re-appended
    ///   (idempotent), while user-added entries on those events are preserved. A
    ///   non-array value for a Casper event is treated as malformed and replaced.
    public static func install(
        intoWorktreeAt worktreePath: String, hookCommand: String = "casper hooks feed"
    ) throws {
        let claudeDir = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.local.json")

        // Parse (and possibly reject) the existing file before touching disk.
        let merged = try mergedSettings(existingAt: settingsURL, hookCommand: hookCommand)

        try FileManager.default.createDirectory(
            at: claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Compute the merged settings object to write for `install`. Returns a
    /// fresh Casper object when no file exists, and throws (without side
    /// effects) when an existing file is not a JSON object.
    private static func mergedSettings(
        existingAt url: URL, hookCommand: String
    ) throws -> [String: Any] {
        let casperEvents = casperHookEvents(hookCommand: hookCommand)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return ["hooks": casperEvents]
        }

        let existingData = try Data(contentsOf: url)
        let parsed = try? JSONSerialization.jsonObject(with: existingData)
        guard var root = parsed as? [String: Any] else {
            throw ClaudeCodeAdapterError.invalidExistingSettings(path: url.path)
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for (event, casperEntries) in casperEvents {
            var preserved: [[String: Any]] = []
            // Keep user-added entries; a non-array value is malformed → dropped.
            if let existingEntries = hooks[event] as? [[String: Any]] {
                preserved = existingEntries.filter {
                    !isCasperEntry($0, hookCommand: hookCommand)
                }
            }
            hooks[event] = preserved + casperEntries
        }

        root["hooks"] = hooks
        return root
    }

    /// Whether `entry` is a prior Casper entry: its `hooks` array contains a
    /// command equal to `hookCommand`. Used to make re-install idempotent.
    private static func isCasperEntry(_ entry: [String: Any], hookCommand: String) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String) == hookCommand }
    }
}
