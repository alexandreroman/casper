import Foundation

/// A transport failure on the control channel.
public struct ControlSocketError: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

extension ControlSocketError: SocketTransportError {}

extension ControlResponse: SocketFailureResponse {}

/// Listens on a Unix-domain socket for one `ControlCommand` per connection and
/// writes back one `ControlResponse`.
public typealias ControlSocketServer =
    SocketServerEngine<ControlCommand, ControlResponse, ControlSocketError>

/// Sends one `ControlCommand` to the app's control socket and returns the decoded
/// `ControlResponse`. Synchronous by design: `casper` CLI invocations are
/// short-lived.
public typealias ControlSocketClient =
    SocketClientEngine<ControlCommand, ControlResponse, ControlSocketError>
