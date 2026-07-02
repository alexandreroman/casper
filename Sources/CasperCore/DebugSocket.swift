#if DEBUG
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

/// Upper bound on a single debug request payload (8 MB). A length header
/// claiming more than this is rejected so a malformed client cannot force an
/// unbounded allocation on the server.
private let maxDebugRequestBytes = 8 * 1024 * 1024

/// Listens on a Unix-domain socket for one `DebugCommand` per connection and
/// writes back one `DebugResponse`.
///
/// Request framing (client → server) is a 4-byte big-endian length prefix
/// followed by exactly that many JSON bytes. The client keeps its send side
/// open, so the server never depends on request EOF — a slow handler cannot
/// race the client's half-close (which previously surfaced as a spurious
/// `ENETDOWN` on the client during long replies). The reply (server → client)
/// still half-closes with `isComplete: true` so the client sees a clean EOF.
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
        // Read the 4-byte big-endian length header, then exactly that many
        // payload bytes. No reliance on request EOF anymore.
        readExactly(4, on: connection, accumulated: Data()) { [weak self] header in
            guard let self else { return }
            guard let header else {
                connection.cancel()  // client closed before sending a full header
                return
            }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= UInt32(maxDebugRequestBytes) else {
                self.reply(.failure("invalid request length: \(length) bytes"), on: connection)
                return
            }
            self.readExactly(Int(length), on: connection, accumulated: Data()) { [weak self] payload in
                guard let self else { return }
                guard let payload else {
                    connection.cancel()  // client closed before sending the full payload
                    return
                }
                self.dispatch(payload, on: connection)
            }
        }
    }

    /// Reads exactly `count` bytes from `connection`, then invokes `completion`
    /// with them — or with `nil` if the peer reaches EOF (or errors) first.
    /// `accumulated` is threaded by value across the `@Sendable` receive
    /// callback so nothing mutable is captured. `maximumLength` is capped at the
    /// bytes still needed so the read never spills past the requested frame.
    private func readExactly(
        _ count: Int, on connection: NWConnection, accumulated: Data,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        if accumulated.count >= count {
            completion(accumulated)
            return
        }
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: count - accumulated.count
        ) { [weak self] data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count >= count {
                completion(buffer)
            } else if isComplete || error != nil {
                completion(nil)  // EOF or error before the full frame arrived
            } else {
                self?.readExactly(count, on: connection, accumulated: buffer, completion: completion)
            }
        }
    }

    private func dispatch(_ payload: Data, on connection: NWConnection) {
        guard let command = try? JSONDecoder().decode(DebugCommand.self, from: payload) else {
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

        let payload = try JSONEncoder().encode(command)
        guard payload.count <= maxDebugRequestBytes else {
            throw DebugSocketError(reason: "request too large: \(payload.count) bytes")
        }
        // Frame the request with a 4-byte big-endian length prefix so the
        // server reads an exact byte count and never waits for request EOF.
        let request: Data = {
            var framed = Data(capacity: 4 + payload.count)
            let length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: length) { framed.append(contentsOf: $0) }
            framed.append(payload)
            return framed
        }()

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
                // Send the framed request WITHOUT `.finalMessage`: the send side
                // stays open so a slow handler's delayed reply cannot race a
                // premature half-close. The server reads by length, not EOF.
                connection.send(
                    content: request,
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
#endif
