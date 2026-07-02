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

/// Upper bound on a single debug frame payload (8 MB), applied symmetrically to
/// both the request (client → server) and the response (server → client). A
/// length header claiming more than this is rejected so a malformed peer cannot
/// force an unbounded allocation on the other side.
private let maxDebugFrameBytes = 8 * 1024 * 1024

/// Reads exactly `count` bytes from `connection`, then invokes `completion` with
/// them — or with `nil` if the peer reaches EOF (or errors) first. Shared by
/// both directions: the server reads the request frame, the client reads the
/// response frame. `accumulated` is threaded by value across the `@Sendable`
/// receive callback so nothing mutable is captured. `maximumLength` is capped at
/// the bytes still needed so a read never spills past the requested frame.
private func readExactly(
    _ count: Int, on connection: NWConnection, accumulated: Data = Data(),
    completion: @escaping @Sendable (Data?) -> Void
) {
    if accumulated.count >= count {
        completion(accumulated)
        return
    }
    connection.receive(
        minimumIncompleteLength: 1, maximumLength: count - accumulated.count
    ) { data, _, isComplete, error in
        var buffer = accumulated
        if let data { buffer.append(data) }
        if buffer.count >= count {
            completion(buffer)
        } else if isComplete || error != nil {
            completion(nil)  // EOF or error before the full frame arrived
        } else {
            readExactly(count, on: connection, accumulated: buffer, completion: completion)
        }
    }
}

/// Listens on a Unix-domain socket for one `DebugCommand` per connection and
/// writes back one `DebugResponse`.
///
/// Both directions use the same framing: a 4-byte big-endian length prefix
/// followed by exactly that many JSON bytes. Neither side depends on EOF, so
/// connection teardown can never race the payload — a slow handler no longer
/// surfaces a spurious `ENETDOWN` on the client during long replies. The client
/// treats a fully received frame as success and ignores any connection error
/// that arrives after the bytes are already in hand.
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
        readExactly(4, on: connection) { [weak self] header in
            guard let self else { return }
            guard let header else {
                connection.cancel()  // client closed before sending a full header
                return
            }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= UInt32(maxDebugFrameBytes) else {
                self.reply(.failure("invalid request length: \(length) bytes"), on: connection)
                return
            }
            readExactly(Int(length), on: connection) { [weak self] payload in
                guard let self else { return }
                guard let payload else {
                    connection.cancel()  // client closed before sending the full payload
                    return
                }
                self.dispatch(payload, on: connection)
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
        let payload = (try? JSONEncoder().encode(response)) ?? Data()
        // Frame the response symmetrically with the request: a 4-byte big-endian
        // length prefix followed by the JSON bytes. The client reads an exact
        // count and never depends on EOF, so cancelling here cannot race its
        // read. `.finalMessage` still closes the send side cleanly.
        var framed = Data(capacity: 4 + payload.count)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        connection.send(
            content: framed, contentContext: .finalMessage, isComplete: true,
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
        guard payload.count <= maxDebugFrameBytes else {
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

        // Read the framed response: a 4-byte big-endian length header, then
        // exactly that many JSON bytes. Success depends only on receiving the
        // full frame — once the bytes are in hand we `finish(.success(...))` and
        // cancel, and any later `.failed`/receive error is ignored (the server
        // cancels right after sending, which used to race the client's read and
        // surface a spurious `ENETDOWN`). `finish` records the first result
        // only, so that teardown error never overrides the delivered response.
        @Sendable func receiveResponse() {
            readExactly(4, on: connection) { header in
                guard let header else {
                    finish(.failure(DebugSocketError(reason: "no response from \(socketPath)")))
                    connection.cancel()
                    return
                }
                let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= UInt32(maxDebugFrameBytes) else {
                    finish(.failure(DebugSocketError(reason: "invalid response length: \(length) bytes")))
                    connection.cancel()
                    return
                }
                readExactly(Int(length), on: connection) { payload in
                    guard let payload else {
                        finish(.failure(DebugSocketError(reason: "truncated response from \(socketPath)")))
                        connection.cancel()
                        return
                    }
                    if let response = try? JSONDecoder().decode(DebugResponse.self, from: payload) {
                        finish(.success(response))
                    } else {
                        finish(.failure(DebugSocketError(reason: "undecodable response")))
                    }
                    connection.cancel()
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
                receiveResponse()
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
