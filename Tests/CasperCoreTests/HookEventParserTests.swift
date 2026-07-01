import XCTest
@testable import CasperCore

final class HookEventParserTests: XCTestCase {
    private func parse(_ json: String) throws -> HookEvent {
        try HookEventParser.parse(Data(json.utf8))
    }

    func testSessionStart() throws {
        let event = try parse(#"{"hook_event_name":"SessionStart","source":"startup"}"#)
        XCTAssertEqual(event, .sessionStart)
    }

    func testStop() throws {
        let event = try parse(#"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(event, .stop)
    }

    func testNotificationCarriesMessage() throws {
        let event = try parse(#"{"hook_event_name":"Notification","message":"needs input"}"#)
        XCTAssertEqual(event, .notification(message: "needs input"))
    }

    func testPostToolUseTodoWriteParsesTodos() throws {
        let json = #"""
        {
          "hook_event_name": "PostToolUse",
          "tool_name": "TodoWrite",
          "tool_input": {
            "todos": [
              {"content": "design", "status": "completed", "activeForm": "designing"},
              {"content": "build", "status": "in_progress", "activeForm": "building"}
            ]
          }
        }
        """#
        let event = try parse(json)
        XCTAssertEqual(event, .todoUpdate(todos: [
            Todo(content: "design", status: .completed),
            Todo(content: "build", status: .inProgress),
        ]))
    }

    func testPostToolUseOtherToolIsUnsupported() {
        let json = #"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#
        XCTAssertThrowsError(try parse(json)) { error in
            XCTAssertEqual(error as? HookParseError, .unsupportedEvent("PostToolUse:Bash"))
        }
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try parse("not json")) { error in
            XCTAssertEqual(error as? HookParseError, .invalidJSON)
        }
    }

    func testMissingEventNameThrows() {
        XCTAssertThrowsError(try parse(#"{"foo":"bar"}"#)) { error in
            XCTAssertEqual(error as? HookParseError, .missingField("hook_event_name"))
        }
    }
}
