extension ControlResponse: SocketFailureResponse {}

/// Listens on a Unix-domain socket for one `ControlCommand` per connection and
/// writes back one `ControlResponse`.
public typealias ControlSocketServer = SocketServerEngine<ControlCommand, ControlResponse>

/// Sends one `ControlCommand` to the app's control socket and returns the decoded
/// `ControlResponse`. Synchronous by design: `casper` CLI invocations are
/// short-lived.
public typealias ControlSocketClient = SocketClientEngine<ControlCommand, ControlResponse>
