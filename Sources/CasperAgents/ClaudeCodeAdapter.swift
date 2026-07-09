import Foundation

/// Generates the Claude Code integration's per-surface environment. Confines all
/// Claude Code-specific knowledge to one place (v1 supports Claude Code only).
public enum ClaudeCodeAdapter {
    /// Environment injected into every terminal surface of a workspace so that the
    /// `casper` CLI can reach the app's control channel and the agent can bind its
    /// reserved ports. `CASPER_PORT` is the block base. When `controlSocketPath` is
    /// given, it is exposed as `CASPER_CONTROL_SOCKET` so the terminal can reach
    /// the control socket. When `sessionName` is given, it is exposed as
    /// `CASPER_SESSION`.
    ///
    /// When `casperDirectory` is given, it is prepended to `PATH` so the `casper`
    /// binary resolves only inside terminals Casper opens — it is deliberately not
    /// installed globally. The app passes the bundle's executable directory as
    /// `casperDirectory` and the terminal's inherited `PATH` as `basePath`. This
    /// function stays pure: it never reads `ProcessInfo` itself, only the values
    /// passed in.
    public static func surfaceEnvironment(
        workspaceId: UUID,
        portBase: Int,
        casperDirectory: String? = nil,
        basePath: String? = nil,
        controlSocketPath: String? = nil,
        sessionName: String? = nil
    ) -> [String: String] {
        var env: [String: String] = [
            "CASPER_WORKSPACE_ID": workspaceId.uuidString,
            "CASPER_PORT": String(portBase),
        ]
        if let controlSocketPath {
            env["CASPER_CONTROL_SOCKET"] = controlSocketPath
        }
        if let sessionName {
            env["CASPER_SESSION"] = sessionName
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
}
