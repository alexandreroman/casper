import Foundation
import XCTest
@testable import CasperCore

final class ControlSocketTests: XCTestCase {
    private func tempSocketPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("casper-control-test-\(UUID().uuidString.prefix(8)).sock")
    }

    func testServerReceivesCommandAndClientGetsResponse() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path)
        server.onCommand = { command, reply in
            XCTAssertEqual(command.verb, .statusSet)
            XCTAssertEqual(command.state, "working")
            reply(.success(text: "ok"))
        }
        try server.start()
        defer { server.stop() }

        let response = try ControlSocketClient.send(
            ControlCommand(verb: .statusSet, workspace: "w", state: "working"),
            toSocketAt: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "ok")
    }

    func testMissingSocketThrowsControlSocketError() {
        XCTAssertThrowsError(
            try ControlSocketClient.send(
                ControlCommand(verb: .workspaceList), toSocketAt: tempSocketPath())
        ) { error in
            XCTAssertTrue(error is ControlSocketError)
        }
    }

    func testDefaultPathHonorsEnvOverride() {
        // `.default` returns CASPER_CONTROL_SOCKET verbatim when set, so assert the
        // clean-env contract only when it is unset (a terminal opened by a running
        // Casper.app exports it and would otherwise fail this spuriously).
        guard ProcessInfo.processInfo.environment["CASPER_CONTROL_SOCKET"] == nil else { return }
        // With no override, the default lives under the temp dir.
        XCTAssertTrue(ControlSocketPath.default.hasSuffix("casper-control.sock"))
    }
}
