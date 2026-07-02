import Foundation
import Network
import os

/// Default socket path for the debug channel. The env var only selects the
/// path; whether the channel exists at all is decided at compile time (`#if
/// DEBUG`) by the app and CLI that use this transport.
public enum DebugSocketPath {
    public static var `default`: String {
        ProcessInfo.processInfo.environment["CASPER_DEBUG_SOCKET"] ?? "/tmp/casper-debug.sock"
    }
}

/// A transport failure on the debug channel.
public struct DebugSocketError: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Listens on a Unix-domain socket for one `DebugCommand` per connection and
/// writes back one `DebugResponse`. Request framing is half-close (read to EOF),
/// matching `HookSocketServer`; the reply is sent with `isComplete: true`.
///
/// `@unchecked Sendable`: wraps `Network.framework` whose handlers are
/// `@Sendable`; all connection I/O runs on the single serial `queue`, and
/// callbacks are configured before `start()`.
public final class DebugSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "casper.debug-socket.server")
    private var listener: NWListener?

    /// Invoked on the server queue with each decoded command and a `reply`
    /// callback. The handler MUST call `reply` exactly once (it may hop threads
    /// first). `reply` writes the response and closes the connection.
    public var onCommand: ((DebugCommand, @escaping @Sendable (DebugResponse) -> Void) -> Void)?
    /// Invoked on the server queue if the listener fails.
    public var onFailure: ((Error) -> Void)?

    public init(socketPath: String) { self.socketPath = socketPath }

    public func start() throws {
        unlink(socketPath)  // remove any stale socket file before binding

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let listener = try NWListener(using: params)

        let bound = DispatchSemaphore(value: 0)
        let bindError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                bound.signal()
            case .failed(let error):
                bindError.withLock { $0 = error }
                self?.onFailure?(error)
                bound.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection)
        }
        self.listener = listener
        listener.start(queue: queue)

        bound.wait()
        if let error = bindError.withLock({ $0 }) {
            self.listener = nil
            throw error
        }
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

    private func receiveChunk(on connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if isComplete || error != nil {
                self?.dispatch(buffer, on: connection)
            } else {
                self?.receiveChunk(on: connection, accumulated: buffer)
            }
        }
    }

    private func dispatch(_ buffer: Data, on connection: NWConnection) {
        guard let command = try? JSONDecoder().decode(DebugCommand.self, from: buffer) else {
            reply(.failure("undecodable command"), on: connection)
            return
        }
        guard let onCommand else {
            reply(.failure("no handler"), on: connection)
            return
        }
        onCommand(command) { [weak self] response in
            self?.reply(response, on: connection)
        }
    }

    private func reply(_ response: DebugResponse, on connection: NWConnection) {
        let data = (try? JSONEncoder().encode(response)) ?? Data()
        // `.finalMessage` closes the send side (FIN) so the client sees EOF and
        // stops reading. A plain `isComplete: true` on the default TCP options
        // only marks a message boundary and never reaches the peer as EOF.
        connection.send(
            content: data, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Sends one `DebugCommand` to the app's debug socket and returns the decoded
/// `DebugResponse`. Synchronous by design: `casper debug` is short-lived.
public enum DebugSocketClient {
    public static func send(
        _ command: DebugCommand, toSocketAt socketPath: String, timeout: TimeInterval = 5
    ) throws -> DebugResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw DebugSocketError(reason: "no socket at \(socketPath) (is the GUI running?)")
        }

        let data = try JSONEncoder().encode(command)

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: NWEndpoint.unix(path: socketPath), using: params)
        let queue = DispatchQueue(label: "casper.debug-socket.client")
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Result<DebugResponse, Error>?>(initialState: nil)

        // `@Sendable`: these nested functions are captured by the `@Sendable`
        // Network.framework handlers below, so under Swift 6 strict concurrency
        // they must be `@Sendable` too. Their captures are all Sendable
        // (`result`, `done`, `connection`).
        @Sendable func finish(_ value: Result<DebugResponse, Error>) {
            result.withLock { if $0 == nil { $0 = value } }
            done.signal()
        }

        // Accumulate the reply until the server half-closes (EOF).
        @Sendable func receiveResponse(_ accumulated: Data) {
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 64 * 1024
            ) { chunk, _, isComplete, error in
                var buffer = accumulated
                if let chunk { buffer.append(chunk) }
                if let error {
                    finish(.failure(DebugSocketError(reason: "\(error)")))
                    connection.cancel()
                    return
                }
                if isComplete {
                    if let response = try? JSONDecoder().decode(DebugResponse.self, from: buffer) {
                        finish(.success(response))
                    } else {
                        finish(.failure(DebugSocketError(reason: "undecodable response")))
                    }
                    connection.cancel()
                } else {
                    receiveResponse(buffer)
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // `.finalMessage` half-closes the write side so the server sees
                // EOF and can reply; the read side stays open for the response.
                connection.send(
                    content: data, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(DebugSocketError(reason: "\(error)")))
                            connection.cancel()
                        }
                    })
                receiveResponse(Data())
            case .failed(let error):
                finish(.failure(DebugSocketError(reason: "\(error)")))
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)

        if done.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw DebugSocketError(reason: "timed out talking to \(socketPath)")
        }
        switch result.withLock({ $0 }) {
        case .success(let response): return response
        case .failure(let error): throw error
        case .none: throw DebugSocketError(reason: "no response from \(socketPath)")
        }
    }
}
