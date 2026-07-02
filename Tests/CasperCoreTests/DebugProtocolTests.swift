import Foundation
import XCTest
@testable import CasperCore

final class DebugProtocolTests: XCTestCase {
    func testCommandRoundTrip() throws {
        let command = DebugCommand(verb: .sendText, text: "ls", enter: true)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DebugCommand.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testResponseWithStateRoundTrip() throws {
        let state = DebugState(surfaces: [
            .init(title: "casper", workingDirectory: "/tmp", columns: 80, rows: 24, focused: true),
        ])
        let response = DebugResponse.success(state: state)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DebugResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.state?.surfaces.first?.columns, 80)
    }

    func testFailureHelper() {
        let response = DebugResponse.failure("no surface")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no surface")
    }
}
