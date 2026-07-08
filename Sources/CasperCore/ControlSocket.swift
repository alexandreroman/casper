import Foundation

/// Socket path for the control channel. The env var only selects the path; this
/// channel ships in release and is always available.
public enum ControlSocketPath {
    /// The path the App itself must bind its listener to: always the
    /// session-derived path, ignoring any ambient `CASPER_CONTROL_SOCKET` the
    /// process may have inherited from a terminal a *different* running instance
    /// opened.
    public static func listenPath(for session: SessionIdentity) -> String {
        session.controlSocketPath()
    }
}

/// A transport failure on the control channel.
public struct ControlSocketError: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

extension ControlSocketError: SocketTransportError {}

extension ControlResponse: SocketFailureResponse {}

/// Listens on a Unix-domain socket for one `ControlCommand` per connection and
/// writes back one `ControlResponse`. Thin facade over the shared
/// `SocketServerEngine`.
public final class ControlSocketServer: @unchecked Sendable {
    private let engine: SocketServerEngine<ControlCommand, ControlResponse, ControlSocketError>

    /// Invoked on the server queue with each decoded command and a `reply`
    /// callback. The handler MUST call `reply` exactly once (it may hop threads
    /// first). `reply` writes the response and closes the connection.
    public var onCommand: ((ControlCommand, @escaping @Sendable (ControlResponse) -> Void) -> Void)? {
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
            queueLabel: "casper.control-socket.server")
    }

    public func start() throws { try engine.start() }

    public func stop() { engine.stop() }
}

/// Sends one `ControlCommand` to the app's control socket and returns the decoded
/// `ControlResponse`. Synchronous by design: `casper` CLI invocations are
/// short-lived. Thin facade over the shared `SocketClientEngine`.
public enum ControlSocketClient {
    public static func send(
        _ command: ControlCommand, toSocketAt socketPath: String,
        timeout: TimeInterval = 5, retriable: Bool = false
    ) throws -> ControlResponse {
        try SocketClientEngine<ControlCommand, ControlResponse, ControlSocketError>.send(
            command, toSocketAt: socketPath, timeout: timeout, retriable: retriable,
            queueLabel: "casper.control-socket.client")
    }
}
