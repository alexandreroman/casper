import Foundation
import Network

/// Listens on a Unix-domain socket for `HookMessage`s sent by `casper hook`.
/// One connection carries one message (client writes JSON, then half-closes);
/// the server reads to EOF, decodes, and invokes `onMessage`.
///
/// `@unchecked Sendable`: the type wraps Network.framework APIs whose handlers
/// are `@Sendable`, and all connection I/O runs on the single serial `queue`.
/// Callbacks are configured before `start()`; the listener lifecycle is driven
/// from `start()`/`stop()`. The compiler cannot verify this discipline, so the
/// conformance is asserted rather than derived.
public final class HookSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "casper.hook-socket.server")
    private var listener: NWListener?

    /// Called on the server queue with each decoded message.
    public var onMessage: ((HookMessage) -> Void)?
    /// Called on the server queue if the listener fails.
    public var onFailure: ((Error) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func start() throws {
        unlink(socketPath)  // remove any stale socket file before binding

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onFailure?(error)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        unlink(socketPath)
    }

    private func receive(on connection: NWConnection) {
        connection.start(queue: queue)
        receiveChunk(on: connection, accumulated: Data())
    }

    /// Reads one chunk and either delivers the accumulated bytes at EOF or
    /// recurses for more. `accumulated` is threaded by value (Data is a
    /// Sendable value type) so nothing mutable is captured across the
    /// `@Sendable` receive handler.
    private func receiveChunk(on connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if isComplete || error != nil {
                self?.deliver(buffer)
                connection.cancel()
            } else {
                self?.receiveChunk(on: connection, accumulated: buffer)
            }
        }
    }

    private func deliver(_ buffer: Data) {
        guard !buffer.isEmpty,
              let message = try? JSONDecoder().decode(HookMessage.self, from: buffer)
        else { return }
        onMessage?(message)
    }
}
