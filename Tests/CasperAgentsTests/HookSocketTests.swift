import Foundation
import Network
import XCTest
@testable import CasperAgents

final class HookSocketTests: XCTestCase {
    /// A unique, short socket path under the temp dir (AF_UNIX paths are length
    /// limited, so avoid the long default temporaryDirectory when possible).
    private func tempSocketPath() -> String {
        "/tmp/casper-test-\(UUID().uuidString.prefix(8)).sock"
    }

    func testServerStartsAndStopsCleanly() throws {
        let path = tempSocketPath()
        let server = HookSocketServer(socketPath: path)
        try server.start()
        server.stop()
        // A fresh server can rebind the same path after stop().
        let server2 = HookSocketServer(socketPath: path)
        try server2.start()
        server2.stop()
    }

    func testClientToServerRoundTripDeliversMessage() throws {
        let path = tempSocketPath()
        let server = HookSocketServer(socketPath: path)
        let received = XCTestExpectation(description: "message received")
        let sentId = UUID()
        server.onMessage = { message in
            if message.workspaceId == sentId { received.fulfill() }
        }
        try server.start()
        defer { server.stop() }

        let payload = Data(#"{"hook_event_name":"SessionStart"}"#.utf8)
        try HookSocketClient.send(
            HookMessage(workspaceId: sentId, hookPayload: payload),
            toSocketAt: path)

        wait(for: [received], timeout: 5)
    }

    func testClientThrowsWhenSocketMissing() {
        let message = HookMessage(workspaceId: UUID(), hookPayload: Data())
        XCTAssertThrowsError(
            try HookSocketClient.send(
                message, toSocketAt: "/tmp/casper-nope-\(UUID().uuidString).sock",
                timeout: 1))
    }
}
