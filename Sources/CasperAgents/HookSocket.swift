import Foundation
import Network
import os

/// Listens on a Unix-domain socket for `HookMessage`s sent by `casper hooks feed`.
/// One connection carries one message (client writes JSON, then half-closes);
/// the server reads to EOF, decodes, and invokes `onMessage`.
///
/// Each connection is bounded on both size and time: the accumulated buffer is
/// capped at `maxMessageBytes` and the whole read must finish within
/// `readTimeout`. Exceeding either drops the connection without a partial decode,
/// so a malformed or stalled peer cannot pin an unbounded allocation or hold a
/// socket open forever.
///
/// Once `stop()` returns, `onMessage` never fires again: a receive completion
/// that was mid-flight has finished (its `onMessage` call included), and any
/// completion that starts later observes the stopped flag and stays silent. This
/// holds because `stop()` snapshots-and-clears under the lock and then barriers
/// on `queue` (see `stop()`).
///
/// Threading: `start()` and `stop()` must be driven from a single
/// lifecycle-owning thread — they are not thread-safe against each other, which
/// is what makes the unsynchronized `listener` access sound. Because `stop()`
/// synchronizes with the internal serial `queue`, it MUST NOT be called from
/// within `onMessage`/`onFailure` (which run on that queue) — that would deadlock.
///
/// `@unchecked Sendable`: the type wraps Network.framework APIs whose handlers
/// are `@Sendable`, and all connection I/O runs on the single serial `queue`.
/// Callbacks are injected at construction (stored `let`). Mutable state shared
/// across the `@Sendable` handlers and the caller's thread (the tracked
/// connection set, the stopped/readied flags) is guarded by
/// `OSAllocatedUnfairLock`. The compiler cannot verify the queue-confinement
/// discipline, so the conformance is asserted rather than derived.
public final class HookSocketServer: @unchecked Sendable {
    /// A single accepted connection plus its read-deadline work item, tracked so
    /// `stop()` can tear both down and so any finishing path can cancel the
    /// deadline exactly once.
    private struct Connection {
        let connection: NWConnection
        let deadline: DispatchWorkItem
    }

    /// Lock-guarded server state. `stopped` gates new connections and closes the
    /// stop-vs-accept race; `readied` distinguishes a synchronous bind failure
    /// (thrown by `start()`) from a later runtime failure (routed to
    /// `onFailure`); `conns` tracks every in-flight connection.
    private struct State {
        var stopped = false
        var readied = false
        var conns: [ObjectIdentifier: Connection] = [:]
    }

    private let socketPath: String
    private let queue = DispatchQueue(label: "casper.hook-socket.server")
    /// Plain `var` on purpose: only ever touched by `start()`/`stop()`, which the
    /// class contract requires to run on one lifecycle-owning thread, so no lock
    /// is needed for it.
    private var listener: NWListener?

    /// Called on the server queue with each decoded message.
    private let onMessage: (HookMessage) -> Void
    /// Called on the server queue if the listener fails after becoming ready.
    private let onFailure: ((Error) -> Void)?
    private let bindTimeout: TimeInterval
    private let readTimeout: TimeInterval
    private let maxMessageBytes: Int

    /// Server state guarded by `OSAllocatedUnfairLock`. `stop()` runs on the
    /// caller's thread while receive loops run on `queue`, so all access goes
    /// through the lock rather than relying on queue confinement.
    /// `uncheckedState`/`withLockUnchecked` because `Connection` holds a
    /// `DispatchWorkItem`, which is not `Sendable`; the lock still provides the
    /// mutual exclusion.
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    public init(
        socketPath: String,
        onMessage: @escaping (HookMessage) -> Void,
        onFailure: ((Error) -> Void)? = nil,
        bindTimeout: TimeInterval = 5,
        readTimeout: TimeInterval = 5,
        maxMessageBytes: Int = 1024 * 1024
    ) {
        self.socketPath = socketPath
        self.onMessage = onMessage
        self.onFailure = onFailure
        self.bindTimeout = bindTimeout
        self.readTimeout = readTimeout
        self.maxMessageBytes = maxMessageBytes
    }

    /// Number of accepted connections whose receive loop is still running.
    /// Test-only observability; guarded by the same lock as the tracking set.
    internal var activeConnectionCount: Int {
        state.withLockUnchecked { $0.conns.count }
    }

    public func start() throws {
        unlink(socketPath)  // remove any stale socket file before binding

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let listener = try NWListener(using: params)

        // Block until the listener has actually bound (its socket file exists)
        // or failed, so callers — and any client checking for the socket right
        // after `start()` returns — see a fully live endpoint. `OSAllocatedUnfairLock`
        // threads the bind error out of the `@Sendable` handler.
        let bound = DispatchSemaphore(value: 0)
        let bindError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        listener.stateUpdateHandler = { [weak self] listenerState in
            guard let self else { return }
            switch listenerState {
            case .ready:
                self.state.withLockUnchecked { $0.readied = true }
                bound.signal()
            case .failed(let error):
                // A failure before the listener ever went live is a bind failure:
                // record it for `start()` to throw and do NOT also call
                // `onFailure` (that would surface the same error twice). A failure
                // after readiness is a runtime failure: route it to `onFailure`.
                let wasReadied = self.state.withLockUnchecked { $0.readied }
                if wasReadied {
                    self.onFailure?(error)
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
            throw HookSocketError(reason: "timed out binding hook socket at \(socketPath)")
        }
        if let error = bindError.withLock({ $0 }) {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    public func stop() {
        // Mark stopped and snapshot-and-clear the in-flight set in one locked
        // block. `stopped` makes any connection accepted from here on be refused
        // by `receive(on:)`, closing the race where a `newConnectionHandler`
        // enqueued before `stop()` runs after it and tracks a fresh connection
        // with no drainer.
        let inflight = state.withLockUnchecked { current -> [Connection] in
            current.stopped = true
            let values = Array(current.conns.values)
            current.conns.removeAll()
            return values
        }
        listener?.cancel()
        listener = nil
        for entry in inflight {
            entry.deadline.cancel()
            entry.connection.cancel()
        }
        // Barrier: a receive completion runs as one serial-queue item that does
        // BOTH the drop check and the `onMessage` call, so waiting for the queue
        // to drain guarantees any completion mid-flight has fully delivered before
        // `stop()` returns, and any completion enqueued afterwards sees a failed
        // `drop` and stays silent. This is why `stop()` must not be called from
        // `onMessage`/`onFailure` (documented on the type): it would deadlock.
        queue.sync {}
        unlink(socketPath)
    }

    private func receive(on connection: NWConnection) {
        // Overall read deadline (not idle-reset): if the full message has not
        // arrived by then, drop the connection without delivering a partial read.
        // Scheduled on `queue` so it is serialized with the receive loop, and
        // cancelled inside `drop` the moment the loop finishes for any reason, so
        // a delivered connection never gets a late cancel.
        let deadline = DispatchWorkItem { [weak self] in
            _ = self?.drop(connection)
        }
        let id = ObjectIdentifier(connection)
        // Track under the lock, but refuse if `stop()` already ran: a connection
        // accepted post-stop would have no drainer, so cancel it and bail.
        let tracked = state.withLockUnchecked { current -> Bool in
            guard !current.stopped else { return false }
            current.conns[id] = Connection(connection: connection, deadline: deadline)
            return true
        }
        guard tracked else {
            connection.cancel()
            return
        }
        queue.asyncAfter(deadline: .now() + readTimeout, execute: deadline)

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
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            // Over the size cap: drop without a partial decode. Hook payloads are
            // tiny JSON, so a stream this large is either broken or hostile.
            if buffer.count > self.maxMessageBytes {
                _ = self.drop(connection)
                return
            }

            if isComplete || error != nil {
                // Only deliver if this loop won the race to finish the connection;
                // if `stop()` or the deadline already dropped it, stay silent.
                if self.drop(connection) { self.deliver(buffer) }
            } else {
                self.receiveChunk(on: connection, accumulated: buffer)
            }
        }
    }

    /// Finalizes a connection at most once: cancels its read deadline, removes it
    /// from the tracked set, and cancels the socket. Returns `true` when THIS
    /// call removed the entry (so the caller may deliver), `false` when `stop()`
    /// or the deadline already finished it (delivery must be suppressed).
    @discardableResult
    private func drop(_ connection: NWConnection) -> Bool {
        let id = ObjectIdentifier(connection)
        let entry = state.withLockUnchecked { $0.conns.removeValue(forKey: id) }
        entry?.deadline.cancel()
        connection.cancel()
        return entry != nil
    }

    private func deliver(_ buffer: Data) {
        guard !buffer.isEmpty,
              let message = try? JSONDecoder().decode(HookMessage.self, from: buffer)
        else { return }
        onMessage(message)
    }
}

/// A transport failure sending a hook message.
public struct HookSocketError: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Sends a single `HookMessage` to the app's Unix-domain socket and returns once
/// the write completes. Synchronous by design: `casper hooks feed` is short-lived.
public enum HookSocketClient {
    public static func send(
        _ message: HookMessage, toSocketAt socketPath: String,
        timeout: TimeInterval = 2
    ) throws {
        // Fast path: if the socket file is gone (app crashed/quit but the
        // surface env still carries CASPER_SOCKET), fail immediately instead
        // of letting NWConnection sit in `.waiting` for the full timeout — a
        // hook must never block the agent.
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw HookSocketError(reason: "no socket at \(socketPath)")
        }

        let data = try JSONEncoder().encode(message)

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(
            to: NWEndpoint.unix(path: socketPath), using: params)
        let queue = DispatchQueue(label: "casper.hook-socket.client")
        let done = DispatchSemaphore(value: 0)
        // The completion/state handlers below are `@Sendable`, so a plain
        // `var sendError` can't be mutated across them. `OSAllocatedUnfairLock`
        // is itself `Sendable`, so it threads the result out without resorting
        // to `@unchecked Sendable` (see the CasperAgents Swift 6 concurrency
        // convention: prefer restructuring over a second unchecked escape hatch).
        let sendError = OSAllocatedUnfairLock<Error?>(initialState: nil)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { error in
                    sendError.withLock { $0 = error }
                    // Cancelling right after `.contentProcessed` is safe for a
                    // local AF_UNIX socket: the queued bytes and the EOF are
                    // retained in the kernel socket buffer until the server
                    // reads them, so the message is not lost by cancelling.
                    connection.cancel()
                    done.signal()
                })
            case .failed(let error):
                sendError.withLock { $0 = error }
                connection.cancel()
                done.signal()
            case .waiting(let error):
                // A stale socket file (app crashed but left the socket) passes
                // the `fileExists` check above, yet the connect is refused and
                // Network.framework parks in `.waiting(ECONNREFUSED)` — it would
                // retry until the timeout. For this local endpoint there is no
                // point waiting: treat `.waiting` like `.failed` and return at
                // once. A live listener transitions straight to `.ready`, so the
                // happy path is unaffected.
                sendError.withLock { $0 = error }
                connection.cancel()
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)

        if done.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw HookSocketError(reason: "timed out sending to \(socketPath)")
        }
        if let error = sendError.withLock({ $0 }) {
            throw HookSocketError(reason: "\(error)")
        }
    }
}
