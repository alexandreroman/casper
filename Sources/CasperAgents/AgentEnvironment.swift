import CasperCore
import Foundation

/// Builds the environment injected into every Casper terminal surface.
///
/// Agent-neutral by design: Casper never launches a coding agent, it only exports
/// the variables and the `PATH` entry that let whatever agent the user runs reach
/// the control channel.
public enum AgentEnvironment {
    /// Environment injected into every terminal surface of a workspace so that the
    /// `casper` CLI can reach the app's control channel and the agent can bind its
    /// reserved ports.
    ///
    /// `CASPER_PORT` is the base of the workspace's reserved port block, and is set
    /// only when `portBase` is given. A worktree workspace passes its block base so
    /// dev servers of parallel worktrees don't collide. `nil` means the workspace
    /// needs no reserved block (the Space's primary working tree): its terminals see
    /// no `CASPER_PORT`, so dev servers started there use their project default port.
    ///
    /// When `controlSocketPath` is given, it is exposed as `CASPER_CONTROL_SOCKET` so
    /// the terminal can reach the control socket. When `sessionName` is given, it is
    /// exposed as `CASPER_SESSION`.
    ///
    /// When `casperDirectory` is given, it is prepended to `PATH` so the `casper`
    /// binary resolves only inside terminals Casper opens — it is deliberately not
    /// installed globally. The app passes the bundle's executable directory as
    /// `casperDirectory` and the terminal's inherited `PATH` as `basePath`. An empty
    /// or absent `basePath` deliberately yields a single-entry `PATH` holding only
    /// `casperDirectory`, rather than a `PATH` with a trailing empty component (which
    /// a shell reads as the current directory). This function stays pure: it never
    /// reads `ProcessInfo` itself, only the values passed in.
    public static func surfaceEnvironment(
        workspaceId: UUID,
        portBase: Int?,
        casperDirectory: String? = nil,
        basePath: String? = nil,
        controlSocketPath: String? = nil,
        sessionName: String? = nil
    ) -> [String: String] {
        var env: [String: String] = ["CASPER_WORKSPACE_ID": workspaceId.casperID]
        if let portBase {
            env["CASPER_PORT"] = String(portBase)
        }
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
