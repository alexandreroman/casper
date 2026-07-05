import Foundation

/// Thrown when `install` finds an existing `settings.json` with non-empty
/// content that is not a JSON object. Casper refuses to overwrite it so the
/// user's file is preserved. An empty or whitespace-only file is treated as
/// absent (a fresh Casper file is written), not as invalid.
public struct ClaudeCodeAdapterError: Error, LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }

    static func invalidExistingSettings(path: String) -> ClaudeCodeAdapterError {
        ClaudeCodeAdapterError(
            reason: "Casper refuses to overwrite \(path): the existing file is not "
                + "a valid JSON object. Fix or remove it, then re-run the setup.")
    }
}

/// Generates the Claude Code integration: the global user-level hooks
/// `settings.json` and the per-surface environment. Confines all Claude
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

    /// The `~/.claude/settings.json` body wiring Claude Code hooks to `hookCommand`.
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
    /// `~/.claude/settings.json`) resolves only inside terminals Casper opens —
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

    /// The user-level Claude Code settings file (~/.claude/settings.json), where
    /// Casper installs its hooks globally. `home` is injectable for tests.
    public static func userSettingsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    /// Install Casper's Claude Code hooks GLOBALLY into `settingsURL` (default
    /// ~/.claude/settings.json), merging into any existing file. This is a
    /// read-merge-write, not a plain overwrite: that file holds the user's own
    /// global Claude Code config — approved permissions and custom hooks — which
    /// must survive a re-install. Idempotent; refuses a malformed existing file
    /// without writing.
    ///
    /// - If the file is absent (or present but empty/whitespace-only), write
    ///   Casper's settings and create `.claude/`.
    /// - If it exists with non-empty content that is not a JSON object
    ///   (malformed or non-object top-level), throw `ClaudeCodeAdapterError` and
    ///   write nothing, leaving the user's file byte-for-byte intact.
    /// - Otherwise merge: every top-level key other than `hooks` is preserved,
    ///   as is every hook event other than Casper's four. For each Casper event,
    ///   prior Casper entries are dropped and the canonical entry re-appended
    ///   (idempotent), while user-added entries on those events are preserved. A
    ///   non-array value for a Casper event is treated as malformed and replaced.
    ///
    /// - Note: The merged object is re-serialized with `.sortedKeys` and
    ///   `.prettyPrinted`, so non-hook top-level content the user wrote is
    ///   normalized on install — keys are reordered, indentation is Casper's,
    ///   and numbers may be re-formatted by `JSONSerialization`. Values and
    ///   semantics are preserved; only the on-disk formatting changes.
    /// - Note: This read-merge-write is not atomic against a concurrent
    ///   installer. Concurrent installs are not supported; correctness relies on
    ///   the single-startup-install invariant (hooks are installed once, either
    ///   via the CLI or at app startup — see the `hooks-install-once` note), so
    ///   no file locking is used here.
    public static func install(
        intoUserSettingsAt settingsURL: URL = userSettingsURL(),
        hookCommand: String = "casper hooks feed"
    ) throws {
        // Parse (and possibly reject) the existing file before touching disk.
        let merged = try mergedSettings(existingAt: settingsURL, hookCommand: hookCommand)

        let claudeDir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Compute the merged settings object to write for `install`. Returns a
    /// fresh Casper object when no file exists (or the file is empty/
    /// whitespace-only), and throws (without side effects) when an existing file
    /// has non-empty content that is not a JSON object.
    private static func mergedSettings(
        existingAt url: URL, hookCommand: String
    ) throws -> [String: Any] {
        let casperEvents = casperHookEvents(hookCommand: hookCommand)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return ["hooks": casperEvents]
        }

        let existingData = try Data(contentsOf: url)
        // A 0-byte or whitespace-only file (e.g. a touched-but-never-written
        // settings.json) is treated as absent rather than malformed.
        if String(decoding: existingData, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty {
            return ["hooks": casperEvents]
        }
        guard var root = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any] else {
            throw ClaudeCodeAdapterError.invalidExistingSettings(path: url.path)
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for (event, casperEntries) in casperEvents {
            // Keep user-added entries; a non-array value is malformed → dropped.
            let preserved = (hooks[event] as? [[String: Any]])?.filter {
                !isCasperEntry($0, hookCommand: hookCommand)
            } ?? []
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
