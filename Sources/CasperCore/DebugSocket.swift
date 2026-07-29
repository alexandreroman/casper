#if DEBUG
import Foundation

/// Default socket path for the debug channel. The env var only selects the
/// path; whether the channel exists at all is decided at compile time (`#if
/// DEBUG`) by the app and CLI that use this transport.
public enum DebugSocketPath {
    /// Default used by the external debug CLI: the `CASPER_DEBUG_SOCKET` override
    /// wins; otherwise the session is taken from `CASPER_SESSION` (falling back to
    /// the default session), so a driver that exports `CASPER_SESSION=dev`
    /// automatically targets `/tmp/casper-debug-dev.sock`.
    public static var `default`: String {
        let session = SessionIdentity(name: ProcessInfo.processInfo.environment["CASPER_SESSION"])
            ?? .default
        return resolve(for: session)
    }

    /// The debug socket path for `session`: the `CASPER_DEBUG_SOCKET` override
    /// wins; otherwise the session-derived path. The app (server) passes its
    /// launch identity here.
    public static func resolve(for session: SessionIdentity) -> String {
        ProcessInfo.processInfo.environment["CASPER_DEBUG_SOCKET"] ?? session.debugSocketPath
    }

    /// The path the App itself must bind its listener to: always the
    /// session-derived path, ignoring any ambient `CASPER_DEBUG_SOCKET` the
    /// process may have inherited from a terminal a *different* running instance
    /// opened. Never call `resolve(for:)` for this — that intentionally honors
    /// the env override for CLI dial use.
    public static func listenPath(for session: SessionIdentity) -> String {
        session.debugSocketPath
    }
}

/// A transport failure on the debug channel.
public struct DebugSocketError: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

extension DebugSocketError: SocketTransportError {}

extension DebugResponse: SocketFailureResponse {}

/// Listens on a Unix-domain socket for one `DebugCommand` per connection and
/// writes back one `DebugResponse`.
public typealias DebugSocketServer =
    SocketServerEngine<DebugCommand, DebugResponse, DebugSocketError>

/// Sends one `DebugCommand` to the app's debug socket and returns the decoded
/// `DebugResponse`. Synchronous by design: `casper debug` is short-lived.
public typealias DebugSocketClient =
    SocketClientEngine<DebugCommand, DebugResponse, DebugSocketError>
#endif
