/// The names of the `CASPER_*` environment variables Casper hands to every
/// terminal and reads back from the CLI. They are a contract with the agent
/// plugins and the user's own scripts, so a name never changes; spelling each one
/// once keeps the writing and the reading side from drifting apart.
public enum CasperEnvironment {
    /// The id of the workspace a terminal belongs to.
    public static let workspaceID = "CASPER_WORKSPACE_ID"
    /// The base of the workspace's 10-port block.
    public static let port = "CASPER_PORT"
    /// The control socket the `casper` CLI dials.
    public static let controlSocket = "CASPER_CONTROL_SOCKET"
    /// The `--session` name of the instance that opened the terminal.
    public static let session = "CASPER_SESSION"

    #if DEBUG
        /// The debug socket the `casper debug` CLI dials, overriding the
        /// session-derived path.
        public static let debugSocket = "CASPER_DEBUG_SOCKET"
    #endif
}
