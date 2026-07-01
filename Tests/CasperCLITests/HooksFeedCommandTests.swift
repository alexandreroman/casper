import Foundation
import XCTest
@testable import CasperCLI
import CasperAgents

final class HooksFeedCommandTests: XCTestCase {
    func testMakeMessageBuildsEnvelopeFromValidEnvironment() throws {
        let id = UUID()
        let stdin = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let message = try XCTUnwrap(HooksFeedCommand.makeMessage(
            stdin: stdin, environment: ["CASPER_WORKSPACE_ID": id.uuidString]))
        XCTAssertEqual(message.workspaceId, id)
        XCTAssertEqual(message.hookPayload, stdin)
    }

    func testMakeMessageReturnsNilWithoutWorkspaceId() {
        let message = HooksFeedCommand.makeMessage(
            stdin: Data("{}".utf8), environment: [:])
        XCTAssertNil(message)
    }

    func testMakeMessageReturnsNilForInvalidWorkspaceId() {
        let message = HooksFeedCommand.makeMessage(
            stdin: Data("{}".utf8),
            environment: ["CASPER_WORKSPACE_ID": "not-a-uuid"])
        XCTAssertNil(message)
    }
}
