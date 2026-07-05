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

/// How long the server keeps a replied-to connection open, waiting for the
/// client to close its side, before force-dropping it. A well-behaved client
/// closes as soon as it has read the reply (and its own `timeout`, 5s by
/// default, bounds even a stuck one), so this fallback only exists so a client
/// that never closes cannot leak the connection.
private let debugReplyLingerTimeout: TimeInterval = 15

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

/// Frames `payload` for the debug channel: a 4-byte big-endian length prefix
/// followed by the payload bytes. Both directions use this identical framing.
private func frame(_ payload: Data) -> Data {
    var framed = Data(capacity: 4 + payload.count)
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { framed.append(contentsOf: $0) }
    framed.append(payload)
    return framed
}

/// Decodes a 4-byte big-endian length header into its `UInt32` value.
private func decodeLength(_ header: Data) -> UInt32 {
    header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

/// Listens on a Unix-domain socket for one `DebugCommand` per connection and
/// writes back one `DebugResponse`.
///
/// Both directions use the same framing: a 4-byte big-endian length prefix
/// followed by exactly that many JSON bytes; neither side depends on EOF to
/// know when a frame ends. After replying, the server lingers until the client
/// closes its side rather than hard-cancelling, so tearing the connection down
/// can never discard buffered reply bytes — even a large, multi-chunk reply
/// from a slow handler reaches the client intact instead of surfacing a
/// spurious `ENETDOWN` mid-read.
///
/// `@unchecked Sendable`: wraps `Network.framework` whose handlers are
/// `@Sendable`; all connection I/O runs on the single serial `queue`, and
/// callbacks are configured before `start()`.
public final class DebugSocketServer: @unchecked Sendable {
    /// Lock-guarded server state, mirroring `HookSocketServer`'s discipline so
    /// `stop()` can tear down cleanly. `stopped` refuses connections accepted
    /// after `stop()` began (they would have no drainer); `conns` tracks every
    /// in-flight connection so `stop()` can cancel them and gate `onCommand`
    /// against firing after teardown. `uncheckedState` because `NWConnection`
    /// carries no `Sendable` guarantee across SDKs; the lock still provides the
    /// mutual exclusion.
    private struct State {
        var stopped = false
        var conns: [ObjectIdentifier: NWConnection] = [:]
    }

    private let socketPath: String
    private let bindTimeout: TimeInterval
    private let queue = DispatchQueue(label: "casper.debug-socket.server")
    private var listener: NWListener?
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    /// Invoked on the server queue with each decoded command and a `reply`
    /// callback. The handler MUST call `reply` exactly once (it may hop threads
    /// first). `reply` writes the response and closes the connection.
    public var onCommand: ((DebugCommand, @escaping @Sendable (DebugResponse) -> Void) -> Void)?
    /// Invoked on the server queue if the listener fails.
    public var onFailure: ((Error) -> Void)?

    public init(socketPath: String, bindTimeout: TimeInterval = 5) {
        self.socketPath = socketPath
        self.bindTimeout = bindTimeout
    }

    public func start() throws {
        unlink(socketPath)  // remove any stale socket file before binding

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let listener = try NWListener(using: params)

        let bound = DispatchSemaphore(value: 0)
        let bindError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        let readied = OSAllocatedUnfairLock<Bool>(initialState: false)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                readied.withLock { $0 = true }
                bound.signal()
            case .failed(let error):
                // A failure before the listener ever went live is a bind failure:
                // record it for `start()` to throw and do NOT also call
                // `onFailure` (that would surface the same error twice). A failure
                // after readiness is a runtime failure: route it to `onFailure`.
                let wasReadied = readied.withLock { $0 }
                if wasReadied {
                    self?.onFailure?(error)
                } else {
                    bindError.withLock { $0 = error }
                    bound.signal()
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection)
        }
        self.listener = listener
        listener.start(queue: queue)

        // Bound the wait so a listener that never reaches `.ready`/`.failed`
        // cannot hang the caller forever.
        if bound.wait(timeout: .now() + bindTimeout) == .timedOut {
            listener.cancel()
            self.listener = nil
            throw DebugSocketError(reason: "timed out binding debug socket at \(socketPath)")
        }
        if let error = bindError.withLock({ $0 }) {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    public func stop() {
        // Mark stopped and snapshot-and-clear the in-flight set in one locked
        // block, so a connection accepted from here on is refused by `receive(on:)`
        // (no drainer) and any later `dispatch` sees its connection gone and stays
        // silent — closing the race where a queued receive callback invokes
        // `onCommand` after `stop()` returns.
        let inflight = state.withLockUnchecked { current -> [NWConnection] in
            current.stopped = true
            let values = Array(current.conns.values)
            current.conns.removeAll()
            return values
        }
        listener?.cancel()
        listener = nil
        for connection in inflight {
            connection.cancel()
        }
        // Barrier: every receive callback (including the one that invokes
        // `onCommand`) runs as a serial-queue item, so waiting for the queue to
        // drain guarantees any callback mid-flight has fully returned before
        // `stop()` returns. This is why `stop()` must not be called from within
        // `onCommand` — it would deadlock.
        queue.sync {}
        unlink(socketPath)
    }

    private func receive(on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        // Track under the lock, but refuse if `stop()` already ran: a connection
        // accepted post-stop would have no drainer, so cancel it and bail.
        let tracked = state.withLockUnchecked { current -> Bool in
            guard !current.stopped else { return false }
            current.conns[id] = connection
            return true
        }
        guard tracked else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        // Read the 4-byte big-endian length header, then exactly that many
        // payload bytes. No reliance on request EOF anymore. There is
        // intentionally no idle/read timeout here: this is a local, single-peer,
        // DEBUG-only channel; the >8 MB length guard bounds memory, and the
        // client bounds its own wait with `timeout`.
        readExactly(4, on: connection) { [weak self] header in
            guard let self else { return }
            guard let header else {
                self.drop(connection)  // client closed before sending a full header
                return
            }
            let length = decodeLength(header)
            guard length > 0, length <= UInt32(maxDebugFrameBytes) else {
                self.reply(.failure("invalid request length: \(length) bytes"), on: connection)
                return
            }
            readExactly(Int(length), on: connection) { [weak self] payload in
                guard let self else { return }
                guard let payload else {
                    self.drop(connection)  // client closed before sending the full payload
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
        // If `stop()` already dropped this connection, don't invoke the handler.
        let live = state.withLockUnchecked { $0.conns[ObjectIdentifier(connection)] != nil }
        guard live else {
            connection.cancel()
            return
        }
        onCommand(command) { [weak self] response in
            self?.reply(response, on: connection)
        }
    }

    private func reply(_ response: DebugResponse, on connection: NWConnection) {
        let payload = (try? JSONEncoder().encode(response)) ?? Data()
        // Frame the response symmetrically with the request: a 4-byte big-endian
        // length prefix followed by the JSON bytes. `.finalMessage` half-closes
        // the send side once the bytes are queued.
        //
        // We must NOT hard-cancel the connection from `.contentProcessed`:
        // that callback only means the bytes were handed to the local network
        // stack, not that the client has drained them. For a large, multi-chunk
        // reply an immediate cancel() tears the socket down abortively and can
        // discard the still-buffered tail, surfacing a spurious `ENETDOWN` on
        // the client mid-read. Instead we linger — waiting for the client to
        // close its side (EOF) — so a fully framed reply is always delivered
        // intact before the connection is dropped.
        let framed = frame(payload)
        connection.send(
            content: framed, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.drop(connection)  // send failed; nothing to deliver, tear down now
                } else {
                    self.lingerUntilClientCloses(connection)
                }
            })
    }

    /// After a reply has been queued, wait for the client to finish draining it
    /// and close its side before tearing the connection down. Dropping only
    /// once the client's EOF is observed guarantees a hard `cancel()` can never
    /// discard buffered reply bytes. A bounded fallback drops the connection
    /// even if the client never closes, so a misbehaving peer cannot leak it.
    private func lingerUntilClientCloses(_ connection: NWConnection) {
        queue.asyncAfter(deadline: .now() + debugReplyLingerTimeout) { [weak self] in
            self?.drop(connection)  // idempotent fallback: a no-op if already dropped
        }
        waitForClientClose(on: connection)
    }

    /// Post a receive that resolves only when the client closes (EOF) or errors,
    /// then drop the connection. The client sends nothing after its request, so
    /// this blocks harmlessly until the client cancels — which it does only
    /// after reading the full reply. Any stray bytes are drained and ignored.
    private func waitForClientClose(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxDebugFrameBytes) {
            [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.drop(connection)
            } else {
                self.waitForClientClose(on: connection)
            }
        }
    }

    /// Untrack a connection and cancel it. Idempotent: a second call finds no
    /// entry and simply re-cancels the already-cancelled connection.
    private func drop(_ connection: NWConnection) {
        state.withLockUnchecked { _ = $0.conns.removeValue(forKey: ObjectIdentifier(connection)) }
        connection.cancel()
    }
}

/// Sends one `DebugCommand` to the app's debug socket and returns the decoded
/// `DebugResponse`. Synchronous by design: `casper debug` is short-lived.
public enum DebugSocketClient {
    /// Total attempts when `retriable` is true: the first try plus three retries.
    private static let maxRetriableAttempts = 4
    /// Backoff between retries. Short on purpose: a fresh connection usually
    /// succeeds immediately, so the worst-case added delay stays well under a
    /// second even after every retry.
    private static let retryBackoffMicroseconds: useconds_t = 50_000

    /// Sends `command` and returns the decoded `DebugResponse`.
    ///
    /// Set `retriable` to true ONLY for idempotent verbs. A transport-level
    /// failure (`DebugSocketError`) then triggers a bounded retry over a fresh
    /// connection, which papers over the intermittent cross-process
    /// `ENETDOWN` seen when a slow handler (e.g. `screenshot`) blocks before any
    /// response byte arrives. A decoded `DebugResponse` — even `ok: false` — is a
    /// real answer and is returned immediately, never retried, so a mutating verb
    /// is never applied twice.
    public static func send(
        _ command: DebugCommand, toSocketAt socketPath: String,
        timeout: TimeInterval = 5, retriable: Bool = false
    ) throws -> DebugResponse {
        let maxAttempts = retriable ? maxRetriableAttempts : 1
        var lastError: DebugSocketError?
        for attempt in 1...maxAttempts {
            do {
                return try sendOnce(command, toSocketAt: socketPath, timeout: timeout)
            } catch let error as DebugSocketError {
                lastError = error
                if attempt < maxAttempts {
                    usleep(retryBackoffMicroseconds)
                }
            }
        }
        // Only reached when every attempt threw a transport `DebugSocketError`.
        throw lastError ?? DebugSocketError(reason: "no response from \(socketPath)")
    }

    /// One request/response exchange over a single fresh connection. Throws a
    /// `DebugSocketError` on any transport failure; returns whatever
    /// `DebugResponse` the server delivers, including an `ok: false` one.
    private static func sendOnce(
        _ command: DebugCommand, toSocketAt socketPath: String, timeout: TimeInterval
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
        let request = frame(payload)

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
                let length = decodeLength(header)
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
