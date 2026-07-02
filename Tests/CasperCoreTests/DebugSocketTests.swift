#if DEBUG
import Foundation
import XCTest
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
        let server = DebugSocketServer(socketPath: path)
        server.onCommand = { command, reply in
            XCTAssertEqual(command.verb, .dumpState)
            // Defer the reply to exercise the slow-handler path that broke the
            // `screenshot` verb: the client must not half-close early and see a
            // spurious ENETDOWN while the server is still working.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                reply(.success(text: "delayed"))
            }
        }
        try server.start()
        defer { server.stop() }

        let response = try DebugSocketClient.send(
            DebugCommand(verb: .dumpState), toSocketAt: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "delayed")
    }

    func testClientThrowsWhenSocketMissing() {
        XCTAssertThrowsError(
            try DebugSocketClient.send(
                DebugCommand(verb: .dumpState),
                toSocketAt: "/tmp/casper-dbg-none-\(UUID().uuidString).sock",
                timeout: 1))
    }

    func testDefaultPathHonorsEnvOverride() {
        // Default when unset.
        XCTAssertEqual(DebugSocketPath.default, "/tmp/casper-debug.sock")
    }
}
#endif
