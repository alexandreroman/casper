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
/// writes back one `DebugResponse`. Thin facade over the shared
/// `SocketServerEngine`.
public final class DebugSocketServer: @unchecked Sendable {
    private let engine: SocketServerEngine<DebugCommand, DebugResponse, DebugSocketError>

    /// Invoked on the server queue with each decoded command and a `reply`
    /// callback. The handler MUST call `reply` exactly once (it may hop threads
    /// first). `reply` writes the response and closes the connection.
    public var onCommand: ((DebugCommand, @escaping @Sendable (DebugResponse) -> Void) -> Void)? {
        get { engine.onCommand }
        set { engine.onCommand = newValue }
    }
    /// Invoked on the server queue if the listener fails.
    public var onFailure: ((Error) -> Void)? {
        get { engine.onFailure }
        set { engine.onFailure = newValue }
    }

    public init(socketPath: String, bindTimeout: TimeInterval = 5) {
        engine = SocketServerEngine(
            socketPath: socketPath, bindTimeout: bindTimeout,
            queueLabel: "casper.debug-socket.server")
    }

    public func start() throws { try engine.start() }

    public func stop() { engine.stop() }
}

/// Sends one `DebugCommand` to the app's debug socket and returns the decoded
/// `DebugResponse`. Synchronous by design: `casper debug` is short-lived. Thin
/// facade over the shared `SocketClientEngine`.
public enum DebugSocketClient {
    public static func send(
        _ command: DebugCommand, toSocketAt socketPath: String,
        timeout: TimeInterval = 5, retriable: Bool = false
    ) throws -> DebugResponse {
        try SocketClientEngine<DebugCommand, DebugResponse, DebugSocketError>.send(
            command, toSocketAt: socketPath, timeout: timeout, retriable: retriable,
            queueLabel: "casper.debug-socket.client")
    }
}
#endif
