#if DEBUG
import Foundation
import Network
import XCTest
import os
@testable import CasperCore

final class DebugSocketTests: XCTestCase {
    private func tempSocketPath() -> String {
        "/tmp/casper-dbg-test-\(UUID().uuidString.prefix(8)).sock"
    }

    func testRoundTripReturnsServerResponse() throws {
        let path = tempSocketPath()
        let server = DebugSocketServer(socketPath: path)
        server.onCommand = { command, reply in
            XCTAssertEqual(command.verb, .readText)
            reply(.success(text: "viewport contents"))
        }
        try server.start()
        defer { server.stop() }

        let response = try DebugSocketClient.send(
            DebugCommand(verb: .readText, scrollback: false), toSocketAt: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "viewport contents")
    }

    func testRoundTripWithSlowHandlerStillReplies() throws {
        let path = tempSocketPath()
        // A large payload forces multi-chunk length-framed reads in both
        // directions, so the exchange exercises the accumulating read helper
        // rather than a single-receive fast path.
        let largeText = String(repeating: "casper-debug-payload ", count: 10_000)
        XCTAssertGreaterThan(largeText.utf8.count, 200_000)

        let server = DebugSocketServer(socketPath: path)
        server.onCommand = { command, reply in
            XCTAssertEqual(command.verb, .dumpState)
            // Defer the reply to exercise the slow-handler path that broke the
            // `screenshot` verb. The large, multi-chunk reply must reach the
            // client intact: the server lingers until the client closes rather
            // than hard-cancelling on send completion, so the client never sees
            // a spurious ENETDOWN from a teardown that discards buffered bytes.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                reply(.success(text: largeText))
            }
        }
        try server.start()
        defer { server.stop() }

        let response = try DebugSocketClient.send(
            DebugCommand(verb: .dumpState), toSocketAt: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, largeText)
    }

    func testRetriableRecoversFromEarlyTransportFailures() throws {
        let path = tempSocketPath()
        // The server fails the first connection before any response byte, exactly
        // like the intermittent screenshot ENETDOWN. A retriable send must open a
        // fresh connection and get the answer on the second try.
        let server = try FlakyDebugServer(socketPath: path, response: .success(text: "recovered"))
        try server.start()
        defer { server.stop() }

        let response = try DebugSocketClient.send(
            DebugCommand(verb: .dumpState), toSocketAt: path, retriable: true)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "recovered")
        // Exactly one retry: connection #1 failed, connection #2 succeeded.
        XCTAssertEqual(server.connectionCount, 2)
    }

    func testNonRetriableDoesNotRetryAfterTransportFailure() throws {
        let path = tempSocketPath()
        let server = try FlakyDebugServer(socketPath: path, response: .success(text: "recovered"))
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(
            try DebugSocketClient.send(
                DebugCommand(verb: .dumpState), toSocketAt: path, retriable: false)
        ) { XCTAssertTrue($0 is DebugSocketError) }
        // A single attempt: the failed first connection is not retried.
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testClientThrowsWhenSocketMissing() {
        XCTAssertThrowsError(
            try DebugSocketClient.send(
                DebugCommand(verb: .dumpState),
                toSocketAt: "/tmp/casper-dbg-none-\(UUID().uuidString).sock",
                timeout: 1))
    }

    func testDefaultPathWhenUnset() {
        // Default when unset.
        XCTAssertEqual(DebugSocketPath.default, "/tmp/casper-debug.sock")
    }

    func testStartSucceedsWellWithinBindTimeout() throws {
        // A local Unix-domain listener binds near-instantly, so even a tight
        // bind timeout must not trip. Guards the bounded-wait path against a
        // regression that would make a healthy `start()` throw or hang.
        let path = tempSocketPath()
        let server = DebugSocketServer(socketPath: path, bindTimeout: 2)
        server.onCommand = { _, reply in reply(.success(text: "bound")) }
        try server.start()
        defer { server.stop() }

        let response = try DebugSocketClient.send(
            DebugCommand(verb: .dumpState), toSocketAt: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "bound")
    }
}

/// A minimal debug listener that fails the FIRST inbound connection — closing it
/// before any response byte — and replies successfully on every later
/// connection. The connection counter is the sole toggle, so the retry behaviour
/// is exercised deterministically, with no dependence on real network flakiness
/// or timing.
///
/// `@unchecked Sendable`: wraps `Network.framework` whose handlers are
/// `@Sendable`; all state is a serial `queue` plus an `OSAllocatedUnfairLock`.
private final class FlakyDebugServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "casper.debug-socket.flaky-server")
    private let listener: NWListener
    private let connections = OSAllocatedUnfairLock(initialState: 0)
    private let framedResponse: Data

    var connectionCount: Int { connections.withLock { $0 } }

    init(socketPath: String, response: DebugResponse) throws {
        unlink(socketPath)  // remove any stale socket file before binding
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        listener = try NWListener(using: params)

        // Pre-frame the reply exactly like `DebugSocketServer`: a 4-byte
        // big-endian length prefix followed by the JSON payload.
        let payload = try JSONEncoder().encode(response)
        var framed = Data(capacity: 4 + payload.count)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        framedResponse = framed

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        // Bound the wait so a bind failure fails this test fast instead of
        // hanging the whole suite on an unbounded semaphore.
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw DebugSocketError(reason: "flaky debug server did not become ready within 5s")
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        let attempt = connections.withLock { $0 += 1; return $0 }
        connection.start(queue: queue)
        guard attempt > 1 else {
            connection.cancel()  // fail the first attempt before any response byte
            return
        }
        // Deliver the framed reply and leave the connection open. The client reads
        // an exact byte count and cancels once it has the full frame, so NOT
        // tearing down here avoids re-introducing the very teardown race the retry
        // exists to defend against — keeping the second attempt deterministic.
        connection.send(
            content: framedResponse, isComplete: false, completion: .contentProcessed { _ in })
    }
}
#endif
