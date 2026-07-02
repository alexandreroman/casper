import Foundation
import Network
import os
import XCTest
@testable import CasperAgents

/// Thread-safe delivery counter: `onMessage` runs on the server queue while the
/// test reads the count from its own thread.
private final class DeliveryCounter: Sendable {
    private let count = OSAllocatedUnfairLock<Int>(initialState: 0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

final class HookSocketTests: XCTestCase {
    /// A unique, short socket path under the temp dir (AF_UNIX paths are length
    /// limited, so avoid the long default temporaryDirectory when possible).
    private func tempSocketPath() -> String {
        "/tmp/casper-test-\(UUID().uuidString.prefix(8)).sock"
    }

    /// Opens a raw client connection to `path` and returns it started. Used by
    /// the hardening tests that drive the server with hand-rolled byte streams
    /// (partial writes, oversized writes) rather than a well-formed `HookMessage`.
    private func openRawConnection(to path: String) -> NWConnection {
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: .unix(path: path), using: params)
        connection.start(queue: .global())
        return connection
    }

    /// Sends `bytes` on `connection` WITHOUT closing the send side (no EOF), so
    /// the server keeps reading and never treats the write as complete.
    private func sendPartial(_ bytes: Data, on connection: NWConnection) {
        connection.send(content: bytes, completion: .contentProcessed { _ in })
    }

    /// Polls `condition` until it holds or `timeout` elapses. The server does its
    /// I/O on its own queue, so a sleeping test thread never blocks it.
    private func poll(timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5000)
        }
        return condition()
    }

    func testServerStartsAndStopsCleanly() throws {
        let path = tempSocketPath()
        let server = HookSocketServer(socketPath: path, onMessage: { _ in })
        try server.start()
        server.stop()
        // A fresh server can rebind the same path after stop().
        let server2 = HookSocketServer(socketPath: path, onMessage: { _ in })
        try server2.start()
        server2.stop()
    }

    func testClientToServerRoundTripDeliversMessage() throws {
        let path = tempSocketPath()
        let received = XCTestExpectation(description: "message received")
        let sentId = UUID()
        let server = HookSocketServer(socketPath: path, onMessage: { message in
            if message.workspaceId == sentId { received.fulfill() }
        })
        try server.start()
        defer { server.stop() }

        let payload = Data(#"{"hook_event_name":"SessionStart"}"#.utf8)
        try HookSocketClient.send(
            HookMessage(workspaceId: sentId, hookPayload: payload),
            toSocketAt: path)

        wait(for: [received], timeout: 5)
    }

    func testStopCancelsInFlightConnection() throws {
        let path = tempSocketPath()
        let notDelivered = XCTestExpectation(description: "onMessage must not fire after stop()")
        notDelivered.isInverted = true
        let server = HookSocketServer(socketPath: path, onMessage: { _ in notDelivered.fulfill() })
        try server.start()

        // A partial write with no half-close: the server accepts the connection
        // and sits in its receive loop waiting for more bytes.
        let connection = openRawConnection(to: path)
        sendPartial(Data(#"{"workspaceId":"#.utf8), on: connection)
        defer { connection.cancel() }

        XCTAssertTrue(
            poll { server.activeConnectionCount == 1 },
            "server should observe the in-flight connection")

        server.stop()

        XCTAssertTrue(
            poll { server.activeConnectionCount == 0 },
            "stop() should cancel every in-flight connection")
        // Grace period: the cancelled connection's receive completion must not
        // sneak a delivery through after stop() returned.
        wait(for: [notDelivered], timeout: 0.3)
    }

    func testReadTimeoutDropsStalledConnection() throws {
        let path = tempSocketPath()
        let notDelivered = XCTestExpectation(description: "no delivery for a stalled connection")
        notDelivered.isInverted = true
        let server = HookSocketServer(
            socketPath: path, onMessage: { _ in notDelivered.fulfill() }, readTimeout: 0.3)
        try server.start()
        defer { server.stop() }

        let connection = openRawConnection(to: path)
        sendPartial(Data(#"{"workspaceId":"#.utf8), on: connection)
        defer { connection.cancel() }

        // No `count == 1` pre-assertion: with a 0.3s readTimeout it races the
        // deadline and can flake under load. The `count == 0` poll plus the
        // inverted `onMessage` expectation already prove the drop.
        XCTAssertTrue(
            poll { server.activeConnectionCount == 0 },
            "the read timeout should drop the stalled connection")
        wait(for: [notDelivered], timeout: 0.3)
    }

    /// Best-effort stress for the stop()-vs-delivery races (both are inherently
    /// timing-dependent; correctness rests on the stopped flag + `queue.sync {}`
    /// barrier, not on this test). Sends a COMPLETE valid message and immediately
    /// stops: whatever the interleaving, the server must not crash, and once
    /// `stop()` has returned no further delivery may occur.
    func testStopRacingCompleteMessageIsConsistent() throws {
        for _ in 0..<50 {
            let path = tempSocketPath()
            let deliveries = DeliveryCounter()
            let sentId = UUID()
            let server = HookSocketServer(socketPath: path, onMessage: { message in
                if message.workspaceId == sentId { deliveries.increment() }
            })
            try server.start()

            let payload = Data(#"{"hook_event_name":"SessionStart"}"#.utf8)
            let message = HookMessage(workspaceId: sentId, hookPayload: payload)
            // Best effort: the send may or may not have reached the server yet.
            try? HookSocketClient.send(message, toSocketAt: path, timeout: 1)

            server.stop()
            // stop() barriers on the server queue, so no delivery can begin after
            // it returns. Any onMessage that fired did so before stop() returned.
            let afterStop = deliveries.value
            usleep(20_000)
            XCTAssertEqual(
                deliveries.value, afterStop,
                "onMessage must not fire after stop() returned")
            XCTAssertLessThanOrEqual(afterStop, 1, "at most one message was sent")
        }
    }

    func testBufferCapDropsOversizedMessage() throws {
        let path = tempSocketPath()
        let notDelivered = XCTestExpectation(description: "no delivery for an oversized message")
        notDelivered.isInverted = true
        let server = HookSocketServer(
            socketPath: path, onMessage: { _ in notDelivered.fulfill() }, maxMessageBytes: 32)
        try server.start()
        defer { server.stop() }

        let connection = openRawConnection(to: path)
        defer { connection.cancel() }

        // Stay under the 32-byte cap first so we can reliably observe the
        // accepted connection, then push past the cap without ever sending EOF.
        sendPartial(Data(repeating: UInt8(ascii: "x"), count: 8), on: connection)
        XCTAssertTrue(
            poll { server.activeConnectionCount == 1 },
            "server should observe the in-flight connection")

        sendPartial(Data(repeating: UInt8(ascii: "x"), count: 64), on: connection)
        XCTAssertTrue(
            poll { server.activeConnectionCount == 0 },
            "an over-cap message should be dropped without delivery")
        wait(for: [notDelivered], timeout: 0.3)
    }

    func testClientThrowsWhenSocketMissing() {
        let message = HookMessage(workspaceId: UUID(), hookPayload: Data())
        XCTAssertThrowsError(
            try HookSocketClient.send(
                message, toSocketAt: "/tmp/casper-nope-\(UUID().uuidString).sock",
                timeout: 1))
    }
}
